#!/usr/bin/env python3
"""MeshMapper App Store Connect release manager.

Gets an iOS release from an uploaded build to "Waiting for Review" through the
App Store Connect API, for MeshMapper (bundle id net.meshmapper.app):

  status       read-only overview: versions, builds, What's New, screenshots
  prepare      create/reuse the App Store version, attach the build, release
               after approval, no phased release, set What's New
  screenshots  replace the iPhone, iPad and Apple Watch screenshots
  submit       submit the prepared version for App Review

Release text never lives in the repo: What's New comes from a notes file you
pass on the command line, screenshots from the folders the capture scripts
write (<dir>/ios-iphone-69, <dir>/ios-ipad-13, <dir>/watch-46).

Auth: the same credentials upload_ios.sh uses. ASC_KEY_ID and ASC_ISSUER_ID in
the environment or ~/.meshmapper_release.env (environment wins), with the .p8
at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 unless ASC_KEY_PATH says
otherwise. ASC_APP_ID overrides the built-in app id. A fresh ES256 token is
minted (via openssl) for every request.

Every write subcommand is a dry run by default: it prints what it would change
(current -> desired) and sends no writes. Pass --apply to write. Re-running
after an apply shows no changes.

Usage:
  ./asc_store.py status
  ./asc_store.py prepare --version 1.4.1 --build 1777777777 --whats-new-file notes.txt
  ./asc_store.py prepare --version 1.4.1 --build 1777777777 --whats-new-file notes.txt --apply
  ./asc_store.py screenshots --dir shots/              # dry run
  ./asc_store.py screenshots --dir shots/ --apply --replace
  ./asc_store.py submit --version 1.4.1                # dry run
  ./asc_store.py submit --version 1.4.1 --apply

Python 3 standard library only. ASC_API_BASE overrides the API host (for
exercising the flow against a stub server).
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

RELEASE_ENV = os.path.expanduser('~/.meshmapper_release.env')

API_BASE = os.environ.get('ASC_API_BASE', 'https://api.appstoreconnect.apple.com')
BUNDLE_ID = os.environ.get('ASC_BUNDLE_ID', 'net.meshmapper.app')
DEFAULT_APP_ID = '6758073991'

# The new version goes live when approved, not on a date or by hand.
RELEASE_TYPE = 'AFTER_APPROVAL'

LIMITS = {
    'whats_new': 4000,
}

# Characters App Store text must not carry: emoji and pictographs
# (U+1F000-U+1FAFF), miscellaneous symbols and dingbats (U+2600-U+27BF) and the
# emoji variation selector (U+FE0F). Accented letters are fine.
_FORBIDDEN_TEXT = re.compile('[\U0001F000-\U0001FAFF☀-➿️]')

BUILD_POLL_SECONDS = 30

# Screenshot folders -> App Store Connect ScreenshotDisplayType.
# The API has no APP_IPHONE_69 / APP_IPAD_13 values: the 6.9" iPhone slot is
# APP_IPHONE_67 and the 13" iPad slot is APP_IPAD_PRO_3GEN_129. Accepted sizes
# per Apple's "Screenshot specifications" help page.
SCREENSHOT_SETS = {
    'ios-iphone-69': {
        'displayType': 'APP_IPHONE_67',
        'label': '6.9" iPhone',
        'sizes': {(1320, 2868), (2868, 1320), (1290, 2796), (2796, 1290),
                  (1260, 2736), (2736, 1260)},
    },
    'ios-ipad-13': {
        'displayType': 'APP_IPAD_PRO_3GEN_129',
        'label': '13" iPad',
        'sizes': {(2064, 2752), (2752, 2064), (2048, 2732), (2732, 2048)},
    },
    'watch-46': {
        'displayType': 'APP_WATCH_SERIES_10',
        'label': 'Apple Watch 46mm',
        'sizes': {(416, 496)},
    },
}
MAX_SCREENSHOTS_PER_SET = 10

# App Store version states in which the version can still be edited
EDITABLE_VERSION_STATES = {
    'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED',
    'METADATA_REJECTED', 'INVALID_BINARY',
}
# A version becomes READY_FOR_REVIEW once it is an item of a review submission
# that has not been submitted yet (submit stopped halfway); submit resumes it.
READY_FOR_REVIEW = 'READY_FOR_REVIEW'
# States of a version that has already been sent to App Review (or is past it)
SUBMITTED_STATES = {
    'WAITING_FOR_REVIEW', 'IN_REVIEW', 'PENDING_DEVELOPER_RELEASE',
    'PROCESSING_FOR_DISTRIBUTION', 'READY_FOR_DISTRIBUTION', 'READY_FOR_SALE',
}


class Fail(Exception):
    """A user-facing error: printed without a traceback."""


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def load_release_env():
    """Parse ~/.meshmapper_release.env (KEY=value, optional quotes, # comments).
    Real environment variables take precedence."""
    values = {}
    if os.path.isfile(RELEASE_ENV):
        with open(RELEASE_ENV, encoding='utf-8') as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith('#'):
                    continue
                if line.startswith('export '):
                    line = line[len('export '):].strip()
                if '=' not in line:
                    continue
                key, _, value = line.partition('=')
                key = key.strip()
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in '"\'':
                    value = value[1:-1]
                elif ' #' in value:
                    value = value.split(' #', 1)[0].rstrip()
                values[key] = value
    for key in list(values):
        if os.environ.get(key):
            values[key] = os.environ[key]
    for key, value in os.environ.items():
        if key.startswith('ASC_') and value:
            values[key] = value
    return values


ENV = load_release_env()


def env(key, default=''):
    return ENV.get(key, default) or default


def check_store_text(key: str, text: str) -> None:
    """Refuse text App Store Connect would reject or that we do not want there:
    empty, over the limit for `key`, or carrying emoji / symbol characters."""
    if text is None or not text.strip():
        raise Fail('%s is empty.' % key)
    limit = LIMITS[key]
    if len(text) > limit:
        raise Fail('%s is %d characters; App Store Connect allows %d.' % (key, len(text), limit))
    bad = _FORBIDDEN_TEXT.search(text)
    if bad:
        raise Fail('%s has a character App Store text must not carry: U+%04X at position %d '
                   '(no emoji or symbols; accented letters are fine).' % (
                       key, ord(bad.group()), bad.start() + 1))


def check_locales(locales: list[str]) -> None:
    """This script only writes English text. Stop at the first other locale
    rather than leave it with stale or untranslated text."""
    for locale in locales:
        if not locale.startswith('en'):
            raise Fail('Localization %s is not English. This script only writes English '
                       'text; handle that locale in App Store Connect first.' % locale)


def read_notes(path):
    if not os.path.isfile(path):
        raise Fail('Notes file not found: %s' % path)
    with open(path, encoding='utf-8') as fh:
        return fh.read().strip()


# ---------------------------------------------------------------------------
# App Store Connect API
# ---------------------------------------------------------------------------

def _b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b'=').decode('ascii')


def _der_to_raw(der):
    """openssl emits ECDSA signatures as DER (SEQUENCE of two INTEGERs); JWS
    ES256 wants the raw r||s pair, each padded to 32 bytes."""
    if not der or der[0] != 0x30:
        raise Fail('Unexpected signature encoding from openssl.')
    idx = 1
    length_byte = der[idx]
    idx += 1
    if length_byte & 0x80:
        idx += length_byte & 0x7F
    parts = []
    for _ in range(2):
        if der[idx] != 0x02:
            raise Fail('Unexpected signature encoding from openssl.')
        idx += 1
        int_len = der[idx]
        idx += 1
        parts.append(int.from_bytes(der[idx:idx + int_len], 'big'))
        idx += int_len
    return parts[0].to_bytes(32, 'big') + parts[1].to_bytes(32, 'big')


def mint_jwt():
    """Fresh ES256 token per request (ASC caps token lifetime at 20 minutes)."""
    key_id = env('ASC_KEY_ID')
    issuer_id = env('ASC_ISSUER_ID')
    if not key_id or not issuer_id:
        raise Fail('ASC_KEY_ID and ASC_ISSUER_ID must be set (env or %s).' % RELEASE_ENV)
    key_path = os.path.expanduser(env('ASC_KEY_PATH') or
                                  '~/.appstoreconnect/private_keys/AuthKey_%s.p8' % key_id)
    if not os.path.isfile(key_path):
        raise Fail('API key file not found: %s' % key_path)

    def compact(obj):
        return json.dumps(obj, separators=(',', ':')).encode('utf-8')

    now = int(time.time())
    header = {'alg': 'ES256', 'kid': key_id, 'typ': 'JWT'}
    payload = {'iss': issuer_id, 'iat': now, 'exp': now + 900, 'aud': 'appstoreconnect-v1'}
    signing_input = (_b64(compact(header)) + '.' + _b64(compact(payload))).encode('ascii')
    result = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', key_path],
                            input=signing_input, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise Fail('openssl could not sign with the API key:\n' +
                   result.stderr.decode('utf-8', 'replace'))
    return signing_input.decode('ascii') + '.' + _b64(_der_to_raw(result.stdout))


class APIError(Fail):
    def __init__(self, method, path, status, body):
        self.status = status
        self.body = body
        self.errors = []
        if isinstance(body, dict):
            self.errors = body.get('errors') or []
        lines = ['%s %s failed (HTTP %s).' % (method, path.split('?')[0], status)]
        if self.errors:
            for err in self.errors:
                line = '  [%s] %s: %s' % (err.get('status', status), err.get('code', ''),
                                          err.get('title', ''))
                if err.get('detail'):
                    line += ' - ' + err['detail']
                pointer = (err.get('source') or {}).get('pointer')
                if pointer:
                    line += ' (%s)' % pointer
                lines.append(line)
        elif body:
            lines.append('  ' + str(body)[:500])
        Fail.__init__(self, '\n'.join(lines))


def api(method, path, body=None, params=None, ok=(200, 201, 204)):
    url = path if path.startswith('http') else API_BASE + path
    if params:
        url += ('&' if '?' in url else '?') + urllib.parse.urlencode(params, safe='[],')
    data = json.dumps(body).encode('utf-8') if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('Authorization', 'Bearer ' + mint_jwt())
    if data is not None:
        req.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            status = resp.status
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        status = exc.code
        raw = exc.read()
    except urllib.error.URLError as exc:
        raise Fail('Could not reach App Store Connect: %s' % exc.reason)
    parsed = None
    if raw:
        try:
            parsed = json.loads(raw.decode('utf-8'))
        except ValueError:
            parsed = raw.decode('utf-8', 'replace')
    if status not in ok:
        raise APIError(method, path, status, parsed)
    return parsed


def get(path, params=None):
    return api('GET', path, params=params)


def get_optional(path, params=None):
    """GET a to-one relationship; None when ASC answers 404 or data: null."""
    try:
        res = get(path, params)
    except APIError as exc:
        if exc.status == 404:
            return None
        raise
    return (res or {}).get('data')


def get_all(path, params=None):
    params = dict(params or {})
    params.setdefault('limit', '200')
    res = get(path, params)
    items = list(res.get('data') or [])
    included = list(res.get('included') or [])
    nxt = (res.get('links') or {}).get('next')
    while nxt:
        res = get(nxt)
        items.extend(res.get('data') or [])
        included.extend(res.get('included') or [])
        nxt = (res.get('links') or {}).get('next')
    return items, included


def patch(type_, id_, attributes=None, relationships=None):
    data = {'type': type_, 'id': id_}
    if attributes:
        data['attributes'] = attributes
    if relationships:
        data['relationships'] = relationships
    return api('PATCH', '/v1/%s/%s' % (type_, id_), {'data': data})


def create(type_, attributes=None, relationships=None):
    data = {'type': type_}
    if attributes:
        data['attributes'] = attributes
    if relationships:
        data['relationships'] = relationships
    return api('POST', '/v1/' + type_, {'data': data})['data']


def rel(type_, id_):
    return {'data': {'type': type_, 'id': id_}}


# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------

def app_id():
    return env('ASC_APP_ID', DEFAULT_APP_ID)


def version_state(version):
    attrs = version['attributes']
    return attrs.get('appVersionState') or attrs.get('appStoreState') or 'UNKNOWN'


def state_label(version):
    """The version state, plus the older appStoreState name when it differs
    (READY_FOR_DISTRIBUTION is READY_FOR_SALE there)."""
    attrs = version['attributes']
    old = attrs.get('appStoreState')
    state = version_state(version)
    return state if not old or old == state else '%s / %s' % (state, old)


def ios_versions(app):
    versions, _ = get_all('/v1/apps/%s/appStoreVersions' % app, {'filter[platform]': 'IOS'})
    return versions


def editable_version(versions):
    for version in versions:
        attrs = version['attributes']
        if (attrs.get('appVersionState') in EDITABLE_VERSION_STATES or
                attrs.get('appStoreState') in EDITABLE_VERSION_STATES):
            return version
    return None


def newest_version(versions):
    return max(versions, key=lambda v: v['attributes'].get('createdDate') or '', default=None)


def choose_version(versions: list[dict], version_string: str) -> tuple[str, dict | None]:
    """('create', None) when no version is editable, ('reuse', v) when the
    editable one already carries version_string. Another editable version is an
    error: App Store Connect allows only one, so it needs a decision first."""
    editable = editable_version(versions)
    if editable is None:
        return 'create', None
    have = editable['attributes'].get('versionString')
    if have == version_string:
        return 'reuse', editable
    raise Fail('The editable App Store version is %s (%s), not %s. Edit or delete it in App '
               'Store Connect, or pass --version %s.' % (have, version_state(editable),
                                                          version_string, have))


def already_submitted(version: dict) -> bool:
    attrs = version['attributes']
    return (attrs.get('appVersionState') in SUBMITTED_STATES or
            attrs.get('appStoreState') in SUBMITTED_STATES)


def in_unsubmitted_submission(version: dict) -> bool:
    attrs = version['attributes']
    return READY_FOR_REVIEW in (attrs.get('appVersionState'), attrs.get('appStoreState'))


def version_localizations(version):
    locs, _ = get_all('/v1/appStoreVersions/%s/appStoreVersionLocalizations' % version['id'])
    return locs


def locale_of(loc):
    return loc['attributes'].get('locale') or '?'


class BuildNotFound(Fail):
    pass


def find_build(app, number):
    res = get('/v1/builds', {'filter[app]': app, 'filter[version]': str(number),
                             'sort': '-uploadedDate', 'limit': '1'})
    if not res.get('data'):
        raise BuildNotFound('Build %s not found in App Store Connect.' % number)
    return res['data'][0]


def wait_for_build(app, number, wait):
    """Poll until the build is VALID. Right after an upload ASC does not list the
    build at all for a while, then shows it PROCESSING."""
    deadline = time.time() + wait
    while True:
        try:
            build = find_build(app, number)
            state = build['attributes'].get('processingState') or 'UNKNOWN'
        except BuildNotFound:
            build, state = None, 'NOT_LISTED_YET'
        if build and state == 'VALID':
            if build['attributes'].get('expired'):
                raise Fail('Build %s has expired.' % number)
            return build
        if state in ('FAILED', 'INVALID'):
            raise Fail('Build %s is %s; App Store Connect will not accept it.' % (number, state))
        if time.time() + BUILD_POLL_SECONDS > deadline:
            raise Fail('Build %s is still %s after waiting %d s. Re-run later or raise --wait.'
                       % (number, state, wait))
        print('   build %s is %s; checking again in %d s' % (number, state, BUILD_POLL_SECONDS))
        time.sleep(BUILD_POLL_SECONDS)


# ---------------------------------------------------------------------------
# Diff plumbing
# ---------------------------------------------------------------------------

def show(value):
    if value is None or value == '':
        return '(empty)'
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if not isinstance(value, str):
        return json.dumps(value)
    flat = value.replace('\n', '\\n')
    if len(flat) > 70:
        return "'%s...' (%d chars)" % (flat[:67], len(value))
    return "'%s'" % flat


class Plan(object):
    """Collects pending writes. In dry-run they are only printed."""

    def __init__(self, apply):
        self.apply = apply
        self.count = 0

    def section(self, title):
        print('')
        print('== ' + title)

    def same(self, label, value):
        print('   = %-28s %s' % (label, show(value)))

    def change(self, label, current, desired):
        self.count += 1
        print('   ~ %-28s %s -> %s' % (label, show(current), show(desired)))

    def info(self, text):
        print('     ' + text)

    def note(self, text):
        print('   ! ' + text)

    def diff_attrs(self, current_attrs, desired, labels=None):
        """Print each desired attribute; return the subset that differs."""
        changed = {}
        for key, value in desired.items():
            if value is None:
                continue
            cur = (current_attrs or {}).get(key)
            label = (labels or {}).get(key, key)
            if cur == value:
                self.same(label, cur)
            else:
                self.change(label, cur, value)
                changed[key] = value
        return changed

    def finish(self):
        print('')
        if self.count == 0:
            print('No changes.')
        elif self.apply:
            print('%d change(s) applied.' % self.count)
        else:
            print('%d change(s) pending. DRY RUN - nothing was sent. Re-run with --apply to write.'
                  % self.count)


# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

def field_line(label, value, limit=None):
    if value is None or value == '':
        print('   %-26s EMPTY' % label)
    else:
        extra = ''
        if isinstance(value, str) and limit:
            extra = '  [%d/%d]' % (len(value), limit)
        print('   %-26s %s%s' % (label, show(value), extra))


def screenshot_sets(loc):
    sets, _ = get_all('/v1/appStoreVersionLocalizations/%s/appScreenshotSets' % loc['id'])
    return sets


def shot_state(shot):
    return ((shot['attributes'].get('assetDeliveryState') or {}).get('state')) or 'UNKNOWN'


def cmd_status(args):
    app = app_id()
    a = get('/v1/apps/%s' % app)['data']['attributes']
    print('')
    print('== App %s' % app)
    print('   %-26s %s' % ('name', a.get('name')))
    print('   %-26s %s' % ('bundleId', a.get('bundleId')))
    print('   %-26s %s' % ('primaryLocale', a.get('primaryLocale')))

    versions = ios_versions(app)
    print('')
    print('== App Store versions (iOS)')
    if not versions:
        print('   none')
    for v in versions:
        print('   %s  %-10s %s' % (v['id'], v['attributes'].get('versionString'), state_label(v)))

    version = editable_version(versions)
    print('')
    if version:
        print('== Editable version %s (%s)' % (version['attributes'].get('versionString'),
                                               state_label(version)))
    else:
        version = newest_version(versions)
        print('No editable App Store version (./asc_store.py prepare creates the next one).')
        if version:
            print('== Newest version %s (%s), read-only' % (version['attributes'].get('versionString'),
                                                            state_label(version)))
    if version:
        va = version['attributes']
        field_line('releaseType', va.get('releaseType'))
        build = get_optional('/v1/appStoreVersions/%s/build' % version['id'])
        field_line('build', build and build['attributes'].get('version'))
        phased = get_optional('/v1/appStoreVersions/%s/appStoreVersionPhasedRelease' % version['id'])
        print('   %-26s %s' % ('phased release', phased['attributes'].get('phasedReleaseState')
                               if phased else 'none'))
        locs = version_localizations(version)
        print('   localizations: %s' % (', '.join(sorted(locale_of(l) for l in locs)) or 'none'))
        for loc in locs:
            field_line(locale_of(loc) + ' whatsNew', loc['attributes'].get('whatsNew'),
                       LIMITS['whats_new'])
            sets = screenshot_sets(loc)
            print('   %s screenshot sets:' % locale_of(loc))
            for s in sets:
                shots, _ = get_all('/v1/appScreenshotSets/%s/appScreenshots' % s['id'])
                states = {}
                for shot in shots:
                    states[shot_state(shot)] = states.get(shot_state(shot), 0) + 1
                print('     %-24s %d screenshot(s) %s' % (
                    s['attributes'].get('screenshotDisplayType'), len(shots),
                    ' '.join('%s=%d' % kv for kv in sorted(states.items()))))
            for folder, spec in SCREENSHOT_SETS.items():
                if not any(s['attributes'].get('screenshotDisplayType') == spec['displayType']
                           for s in sets):
                    print('     %-24s MISSING (%s, from %s/)' % (
                        spec['displayType'], spec['label'], folder))
        detail = get_optional('/v1/appStoreVersions/%s/appStoreReviewDetail' % version['id'])
        print('   App Review detail:')
        da = detail['attributes'] if detail else {}
        for key in ('contactFirstName', 'contactLastName', 'contactEmail', 'contactPhone',
                    'demoAccountRequired'):
            field_line('  ' + key, da.get(key))

    builds, included = get_all('/v1/builds', {
        'filter[app]': app, 'sort': '-uploadedDate', 'limit': '5',
        'include': 'preReleaseVersion'})
    builds = builds[:5]
    prv = {i['id']: i for i in included if i['type'] == 'preReleaseVersions'}
    print('')
    print('== Latest builds')
    for b in builds:
        ba = b['attributes']
        rel_p = ((b.get('relationships') or {}).get('preReleaseVersion') or {}).get('data') or {}
        pv = prv.get(rel_p.get('id'), {}).get('attributes', {})
        print('   %s (%s) uploaded %s processing=%s encryption=%s%s' % (
            ba.get('version'), pv.get('version', '?'), (ba.get('uploadedDate') or '')[:10],
            ba.get('processingState'), show(ba.get('usesNonExemptEncryption')),
            ' EXPIRED' if ba.get('expired') else ''))

    subs, _ = get_all('/v1/reviewSubmissions', {'filter[app]': app, 'filter[platform]': 'IOS'})
    subs.sort(key=lambda s: s['attributes'].get('submittedDate') or '9999', reverse=True)
    print('')
    print('== Review submissions (iOS, newest first)')
    if not subs:
        print('   none')
    for s in subs[:5]:
        print('   %s  %-18s submitted %s' % (
            s['id'], s['attributes'].get('state'),
            (s['attributes'].get('submittedDate') or 'never')[:10]))

    print('')
    print('Not managed here (App Store Connect web UI): listing text, App Privacy "nutrition')
    print('labels" (no public API), pricing and availability.')


# ---------------------------------------------------------------------------
# prepare
# ---------------------------------------------------------------------------

def cmd_prepare(args):
    # Read and validate everything first; the writes below then run in order.
    text = read_notes(args.whats_new_file)
    check_store_text('whats_new', text)
    plan = Plan(args.apply)
    app = app_id()
    versions = ios_versions(app)

    action, version = choose_version(versions, args.version)
    if action == 'create':
        clash = [v for v in versions if v['attributes'].get('versionString') == args.version]
        if clash:
            raise Fail('Version %s already exists (%s) and cannot be edited.' % (
                args.version, version_state(clash[0])))
        # A new version starts with the previous version's localizations.
        previous = newest_version(versions)
        if previous:
            check_locales([locale_of(l) for l in version_localizations(previous)])
        locs = None
    else:
        locs = version_localizations(version)
        check_locales([locale_of(l) for l in locs])

    plan.section('Build %s' % args.build)
    build = wait_for_build(app, args.build, args.wait)
    ba = build['attributes']
    plan.info('processingState=%s uploaded=%s' % (ba.get('processingState'),
                                                  (ba.get('uploadedDate') or '')[:19]))

    # 1. the version
    plan.section('App Store version %s' % args.version)
    if action == 'create':
        plan.change('app store version', None, 'create %s' % args.version)
        plan.info('releaseType %s is set when it is created' % RELEASE_TYPE)
        if plan.apply:
            version = create('appStoreVersions',
                             {'platform': 'IOS', 'versionString': args.version,
                              'releaseType': RELEASE_TYPE},
                             {'app': rel('apps', app)})
            locs = version_localizations(version)
            check_locales([locale_of(l) for l in locs])
            if not locs:
                raise Fail('The new version has no localizations; add one in App Store Connect.')
    else:
        plan.same('app store version', '%s (%s)' % (args.version, version_state(version)))
    vid = version['id'] if version else None

    # 2. the build
    plan.section('Build on the version')
    attached = get_optional('/v1/appStoreVersions/%s/build' % vid) if vid else None
    if attached and attached['id'] == build['id']:
        plan.same('build', ba.get('version'))
    else:
        plan.change('build', attached and (attached.get('attributes') or {}).get('version'),
                    ba.get('version'))
        if plan.apply:
            api('PATCH', '/v1/appStoreVersions/%s/relationships/build' % vid,
                {'data': {'type': 'builds', 'id': build['id']}})

    # 3. release after approval
    if version is not None:
        cur = version['attributes'].get('releaseType')
        if cur == RELEASE_TYPE:
            plan.same('releaseType', cur)
        else:
            plan.change('releaseType', cur, RELEASE_TYPE)
            if plan.apply:
                patch('appStoreVersions', vid, {'releaseType': RELEASE_TYPE})

    # 4. no phased release
    phased = get_optional('/v1/appStoreVersions/%s/appStoreVersionPhasedRelease' % vid) if vid else None
    if phased:
        plan.change('phased release', phased['id'], 'removed')
        if plan.apply:
            api('DELETE', '/v1/appStoreVersionPhasedReleases/%s' % phased['id'])
    else:
        plan.same('phased release', 'none')

    # 5. What's New on every localization
    plan.section("What's New")
    if locs is None:
        plan.change('whatsNew', None, text)
        plan.info('(applied to every localization once the version exists)')
    for loc in locs or []:
        changed = plan.diff_attrs(loc['attributes'], {'whatsNew': text},
                                  {'whatsNew': locale_of(loc) + ' whatsNew'})
        if changed and plan.apply:
            patch('appStoreVersionLocalizations', loc['id'], changed)

    # 6. export compliance
    if ba.get('usesNonExemptEncryption') is None:
        plan.note('Build %s has no export compliance answer (usesNonExemptEncryption is '
                  'null); App Review will not accept it until it is set.' % ba.get('version'))

    plan.finish()


# ---------------------------------------------------------------------------
# screenshots
# ---------------------------------------------------------------------------

def png_size(path):
    with open(path, 'rb') as fh:
        head = fh.read(24)
    if len(head) < 24 or head[:8] != b'\x89PNG\r\n\x1a\n' or head[12:16] != b'IHDR':
        raise Fail('%s is not a PNG.' % path)
    return struct.unpack('>II', head[16:24])


def md5_file(path):
    h = hashlib.md5()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def upload_screenshot(set_id, path, checksum):
    size = os.path.getsize(path)
    name = os.path.basename(path)
    shot = create('appScreenshots', {'fileName': name, 'fileSize': size},
                  {'appScreenshotSet': rel('appScreenshotSets', set_id)})
    ops = shot['attributes'].get('uploadOperations') or []
    with open(path, 'rb') as fh:
        blob = fh.read()
    for op in ops:
        chunk = blob[op['offset']:op['offset'] + op['length']]
        req = urllib.request.Request(op['url'], data=chunk, method=op.get('method', 'PUT'))
        for header in op.get('requestHeaders') or []:
            req.add_header(header['name'], header['value'])
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                resp.read()
        except urllib.error.HTTPError as exc:
            raise Fail('Uploading %s chunk at offset %s failed (HTTP %s): %s' % (
                name, op['offset'], exc.code, exc.read()[:300]))
        except urllib.error.URLError as exc:
            raise Fail('Uploading %s failed: %s' % (name, exc.reason))
    patch('appScreenshots', shot['id'], {'uploaded': True, 'sourceFileChecksum': checksum})
    deadline = time.time() + 300
    while True:
        try:
            cur = get('/v1/appScreenshots/%s' % shot['id'])['data']
        except APIError as exc:
            # Apple sometimes answers 5xx for a screenshot it has only just
            # received, then recovers within seconds. Keep waiting until the
            # deadline; a 4xx or a 5xx past the deadline still stops here.
            if exc.status < 500 or time.time() > deadline:
                raise
            print('     %s: App Store Connect answered HTTP %s, checking again...' % (
                name, exc.status))
            time.sleep(5)
            continue
        state = shot_state(cur)
        if state == 'COMPLETE':
            return cur
        if state == 'FAILED':
            errs = (cur['attributes'].get('assetDeliveryState') or {}).get('errors') or []
            raise Fail('ASC failed to process %s: %s' % (name, '; '.join(
                '%s %s' % (e.get('code', ''), e.get('description', '')) for e in errs) or 'no detail'))
        if time.time() > deadline:
            print('     %s still %s after 5 min; continuing (check again with status).' % (name, state))
            return cur
        time.sleep(3)


def cmd_screenshots(args):
    plan = Plan(args.apply)
    root = os.path.abspath(args.dir)
    if not os.path.isdir(root):
        raise Fail('Screenshot directory not found: %s' % root)

    # Validate local files first, before any network call
    local = {}
    for folder, spec in SCREENSHOT_SETS.items():
        path = os.path.join(root, folder)
        if not os.path.isdir(path):
            continue
        files = sorted(f for f in os.listdir(path) if f.lower().endswith('.png'))
        if not files:
            continue
        if len(files) > MAX_SCREENSHOTS_PER_SET:
            raise Fail('%s has %d PNGs; App Store Connect allows %d per set.' % (
                folder, len(files), MAX_SCREENSHOTS_PER_SET))
        entries = []
        for name in files:
            full = os.path.join(path, name)
            w, h = png_size(full)
            if (w, h) not in spec['sizes']:
                raise Fail('%s/%s is %dx%d; %s accepts %s.' % (
                    folder, name, w, h, spec['label'],
                    ', '.join('%dx%d' % s for s in sorted(spec['sizes']))))
            entries.append({'name': name, 'path': full, 'md5': md5_file(full), 'size': (w, h)})
        local[folder] = entries
    if not local:
        raise Fail('No PNGs found under %s/{%s}.' % (root, ','.join(SCREENSHOT_SETS)))

    app = app_id()
    versions = ios_versions(app)
    version = editable_version(versions)
    if not version:
        if args.apply:
            raise Fail('No editable App Store version. Create one first: '
                       './asc_store.py prepare --version X.Y.Z --build N --whats-new-file F --apply')
        # Dry run before prepare: compare with the newest version for a preview.
        version = newest_version(versions)
        if not version:
            raise Fail('The app has no iOS App Store version.')
        plan.note('No editable version yet; previewing against %s (%s), read-only. A new version '
                  'normally starts with the previous version\'s screenshots.' % (
                      version['attributes'].get('versionString'), version_state(version)))
    locs = version_localizations(version)
    locales = [locale_of(l) for l in locs]
    check_locales(locales)
    if len(locales) != 1:
        raise Fail('Screenshots go to exactly one localization; version %s has %d (%s).' % (
            version['attributes'].get('versionString'), len(locales), ', '.join(locales) or 'none'))
    loc = locs[0]
    sets = screenshot_sets(loc)

    for folder, entries in local.items():
        spec = SCREENSHOT_SETS[folder]
        dtype = spec['displayType']
        plan.section('%s -> %s (%s)' % (folder, dtype, spec['label']))
        sset = next((s for s in sets if s['attributes'].get('screenshotDisplayType') == dtype), None)
        existing = []
        if sset:
            existing, _ = get_all('/v1/appScreenshotSets/%s/appScreenshots' % sset['id'])
            order = get('/v1/appScreenshotSets/%s/relationships/appScreenshots' % sset['id'],
                        {'limit': '50'}).get('data') or []
            pos = {o['id']: i for i, o in enumerate(order)}
            existing.sort(key=lambda s: pos.get(s['id'], 999))
        else:
            plan.change('screenshot set', None, 'create ' + dtype)
            if plan.apply:
                sset = create('appScreenshotSets', {'screenshotDisplayType': dtype},
                              {'appStoreVersionLocalization': rel('appStoreVersionLocalizations', loc['id'])})

        # Screenshots to delete: everything on --replace, plus failed uploads
        to_delete = []
        keep = []
        for shot in existing:
            if args.replace or shot_state(shot) == 'FAILED':
                to_delete.append(shot)
            else:
                keep.append(shot)
        for shot in to_delete:
            plan.change('delete', '%s [%s]' % (shot['attributes'].get('fileName'), shot_state(shot)), None)

        by_md5 = {}
        for shot in keep:
            by_md5.setdefault(shot['attributes'].get('sourceFileChecksum'), []).append(shot)
        matched = []  # (entry, existing shot or None)
        for entry in entries:
            hit = by_md5.get(entry['md5'])
            if hit:
                shot = hit.pop(0)
                plan.same(entry['name'], 'already uploaded (%s)' % shot_state(shot))
                matched.append((entry, shot))
            else:
                plan.change(entry['name'], None, 'upload %dx%d' % entry['size'])
                matched.append((entry, None))
        extras = [s for lst in by_md5.values() for s in lst]
        for shot in extras:
            plan.info('kept, not in %s/: %s (pass --replace to remove)' % (
                folder, shot['attributes'].get('fileName')))
        total = len(entries) + len(extras)
        if total > MAX_SCREENSHOTS_PER_SET:
            raise Fail('%s would hold %d screenshots (max %d). Use --replace.' % (
                dtype, total, MAX_SCREENSHOTS_PER_SET))

        current_order = [s['id'] for s in keep]
        desired_known = [s['id'] for _, s in matched if s] + [s['id'] for s in extras]
        needs_upload = any(s is None for _, s in matched)
        if not needs_upload and not to_delete and current_order != desired_known:
            plan.change('order', ', '.join(s['attributes'].get('fileName') or '?' for s in keep),
                        ', '.join(e['name'] for e in entries))

        if not plan.apply:
            continue
        for shot in to_delete:
            api('DELETE', '/v1/appScreenshots/%s' % shot['id'])
        final = []
        for entry, shot in matched:
            if shot is None:
                print('     uploading %s...' % entry['name'])
                shot = upload_screenshot(sset['id'], entry['path'], entry['md5'])
            final.append(shot['id'])
        final += [s['id'] for s in extras]
        order = get('/v1/appScreenshotSets/%s/relationships/appScreenshots' % sset['id'],
                    {'limit': '50'}).get('data') or []
        if [o['id'] for o in order] != final:
            api('PATCH', '/v1/appScreenshotSets/%s/relationships/appScreenshots' % sset['id'],
                {'data': [{'type': 'appScreenshots', 'id': i} for i in final]})
            print('     reordered to match file order')

    for folder in SCREENSHOT_SETS:
        if folder not in local:
            print('')
            print('(%s/ not found or empty - %s set left unchanged)' % (folder, SCREENSHOT_SETS[folder]['displayType']))
    plan.finish()


# ---------------------------------------------------------------------------
# submit
# ---------------------------------------------------------------------------

def check_ready_to_submit(version):
    """Everything App Review needs that this script manages. Raises Fail on the
    first thing missing; reads only."""
    build = get_optional('/v1/appStoreVersions/%s/build' % version['id'])
    if not build:
        raise Fail('Version %s has no build attached. Run ./asc_store.py prepare first.'
                   % version['attributes'].get('versionString'))
    locs = version_localizations(version)
    if not locs:
        raise Fail('Version %s has no localizations.' % version['attributes'].get('versionString'))
    no_notes = [locale_of(l) for l in locs if not (l['attributes'].get('whatsNew') or '').strip()]
    if no_notes:
        raise Fail("No What's New for: %s. Run ./asc_store.py prepare first." % ', '.join(no_notes))
    wanted = [spec['displayType'] for spec in SCREENSHOT_SETS.values()]
    for loc in locs:
        sets = {s['attributes'].get('screenshotDisplayType'): s for s in screenshot_sets(loc)}
        missing = []
        for dtype in wanted:
            shots = []
            if dtype in sets:
                shots, _ = get_all('/v1/appScreenshotSets/%s/appScreenshots' % sets[dtype]['id'])
            if not [s for s in shots if shot_state(s) != 'FAILED']:
                missing.append(dtype)
        if missing:
            raise Fail('The %s localization has no screenshots for: %s. Run '
                       './asc_store.py screenshots --dir DIR --apply.' % (
                           locale_of(loc), ', '.join(missing)))
    return build


def submission_has_version(submission_id, version_id):
    items, included = get_all('/v1/reviewSubmissions/%s/items' % submission_id,
                              {'include': 'appStoreVersion'})
    for item in items:
        linked = ((item.get('relationships') or {}).get('appStoreVersion') or {}).get('data') or {}
        if linked.get('id') == version_id:
            return True
    return any(i.get('type') == 'appStoreVersions' and i.get('id') == version_id
               for i in included)


def cmd_submit(args):
    plan = Plan(args.apply)
    app = app_id()
    versions = ios_versions(app)
    version = next((v for v in versions
                    if v['attributes'].get('versionString') == args.version), None)
    if not version:
        raise Fail('No iOS App Store version %s. Run ./asc_store.py prepare first.' % args.version)
    if already_submitted(version):
        print('already submitted (%s)' % version_state(version))
        return
    resuming = in_unsubmitted_submission(version)
    if editable_version([version]) is None and not resuming:
        raise Fail('Version %s is %s and cannot be submitted.' % (args.version, version_state(version)))

    plan.section('Ready for review?')
    if resuming:
        plan.info('The version is already an item of a submission that was not submitted; '
                  'resuming it.')
    build = check_ready_to_submit(version)
    plan.same('build', (build.get('attributes') or {}).get('version') or build['id'])
    plan.same("What's New", 'set on every localization')
    plan.same('screenshots', ', '.join(spec['displayType'] for spec in SCREENSHOT_SETS.values()))

    # The review-submissions API: a submission (one open per app and platform),
    # an item that points at the App Store version, then submitted=true.
    plan.section('App Review submission')
    open_subs, _ = get_all('/v1/reviewSubmissions', {
        'filter[app]': app, 'filter[platform]': 'IOS', 'filter[state]': READY_FOR_REVIEW})
    sub = open_subs[0] if open_subs else None
    if sub:
        plan.same('review submission', 'reuse open %s' % sub['id'])
    else:
        plan.change('review submission', None, 'create (IOS)')
    plan.change('submission item', None, 'App Store version %s' % args.version)
    plan.change('submitted', False, True)

    if plan.apply:
        if sub is None:
            sub = create('reviewSubmissions', {'platform': 'IOS'}, {'app': rel('apps', app)})
        try:
            create('reviewSubmissionItems', None, {
                'reviewSubmission': rel('reviewSubmissions', sub['id']),
                'appStoreVersion': rel('appStoreVersions', version['id'])})
        except APIError as exc:
            # ASC answers 409 for most state and validation errors, not only for
            # a duplicate: carry on only when the version really is in the submission.
            if exc.status != 409 or not submission_has_version(sub['id'], version['id']):
                raise
            print('     the version is already an item of this submission')
        res = patch('reviewSubmissions', sub['id'], {'submitted': True})
        state = (((res or {}).get('data') or {}).get('attributes') or {}).get('state')
        print('     submission %s is now %s' % (sub['id'], state or 'submitted'))

    plan.finish()


# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Prepare, screenshot and submit MeshMapper iOS releases through '
                    'App Store Connect.')
    sub = parser.add_subparsers(dest='command')
    sub.required = True

    sub.add_parser('status', help='read-only overview of versions, builds and screenshots')

    p = sub.add_parser('prepare', help='version, build, release type, What\'s New '
                                       '(dry run unless --apply)')
    p.add_argument('--version', required=True, metavar='X.Y.Z', help='App Store version string')
    p.add_argument('--build', required=True, metavar='EPOCH',
                   help='build number (the epoch Build.sh printed)')
    p.add_argument('--whats-new-file', required=True, metavar='FILE',
                   help='text file with the What\'s New text')
    p.add_argument('--wait', type=int, default=1800, metavar='SECONDS',
                   help='how long to wait for the build to finish processing (default 1800)')
    p.add_argument('--apply', action='store_true', help='perform the writes')

    p = sub.add_parser('screenshots', help='upload screenshots (dry run unless --apply)')
    p.add_argument('--dir', required=True,
                   help='folder holding ios-iphone-69/, ios-ipad-13/ and watch-46/')
    p.add_argument('--apply', action='store_true', help='perform the writes')
    p.add_argument('--replace', action='store_true',
                   help='delete existing screenshots in those sets first')

    p = sub.add_parser('submit', help='submit the prepared version for App Review '
                                      '(dry run unless --apply)')
    p.add_argument('--version', required=True, metavar='X.Y.Z', help='App Store version string')
    p.add_argument('--apply', action='store_true', help='submit for real')

    args = parser.parse_args()
    handlers = {'status': cmd_status, 'prepare': cmd_prepare,
                'screenshots': cmd_screenshots, 'submit': cmd_submit}
    print('App Store Connect: %s (app %s)%s' % (
        BUNDLE_ID, app_id(),
        '' if getattr(args, 'apply', False) or args.command == 'status' else '  [DRY RUN]'))
    try:
        handlers[args.command](args)
    except Fail as exc:
        print('')
        print('Error: %s' % exc, file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print('\nInterrupted.', file=sys.stderr)
        sys.exit(130)


if __name__ == '__main__':
    main()
