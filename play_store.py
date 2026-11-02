#!/usr/bin/env python3
"""MeshMapper Google Play release manager.

Puts an Android App Bundle on a Google Play track and replaces the phone
screenshots, through the Google Play Developer API (androidpublisher v3), for
MeshMapper (package net.meshmapper.app):

  status       read-only overview: tracks, releases (with review state),
               uploaded bundles, app details, listing languages
  upload       upload an AAB (or assign an already uploaded --version-code) to a
               track with release notes; a stable release is
               --track production --status completed, which is a 100% rollout
  promote      copy the latest release of one track to another
  screenshots  replace the phone screenshots of the default language

Release text never lives in the repo: release notes come from a notes file you
pass on the command line (500 characters at most), screenshots from the folder
the capture script writes (<dir>/android-phone/*.png, 2 to 8 files).

Every change happens inside a Play "edit" (a draft transaction). Nothing goes
live until the edit is committed, and on any failure the edit is deleted so
nothing half-applied lingers. Every write subcommand is a dry run by default;
pass --apply to commit. upload and screenshots also take --validate: stage the
whole change in an edit, ask Play to validate it (edits:validate), then delete
the edit. --validate never commits, so it proves the service account may write
without publishing anything.

The listing text is never touched, and this script only writes English: it
stops when the app has a listing in any language other than en*. Release notes
and screenshots go to the app's default language (override the notes language
with --lang).

Auth: PLAY_SERVICE_ACCOUNT_JSON (the service account's JSON key, e.g.
~/.play/play-publisher.json, chmod 600) in the environment or
~/.meshmapper_release.env (environment wins). PLAY_PACKAGE_NAME overrides the
built-in package name. The service account must be invited in Play Console >
Users and permissions with, for MeshMapper: Release to production, Manage store
presence and View app information. New grants can take 24-36 h to reach the
API. The OAuth token (RS256 JWT) is signed with the openssl CLI.

Usage:
  ./play_store.py status
  ./play_store.py upload --track production --status completed --notes-file notes.txt
  ./play_store.py upload --track production --status completed --notes-file notes.txt --validate
  ./play_store.py upload --track production --status completed --notes-file notes.txt --apply
  ./play_store.py upload --track production --version-code 1789991039 --notes-file notes.txt
  ./play_store.py promote --from beta --to production --apply
  ./play_store.py screenshots --dir shots/              # dry run
  ./play_store.py screenshots --dir shots/ --validate
  ./play_store.py screenshots --dir shots/ --apply

Add --no-review to upload/promote/screenshots --apply if Play refuses the commit
asking for changesNotSentForReview (the changes then go to review from Console).

Python 3 standard library only, plus the openssl CLI. PLAY_API_BASE overrides the
API host (for exercising the flow against a stub server).
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

REPO_DIR = os.path.dirname(os.path.abspath(__file__))
LAST_BUILD = os.path.join(REPO_DIR, '.last_build')
RELEASE_ENV = os.path.expanduser('~/.meshmapper_release.env')
DEFAULT_PACKAGE = 'net.meshmapper.app'
API_BASE = os.environ.get('PLAY_API_BASE', 'https://androidpublisher.googleapis.com').rstrip('/')
SCOPE = 'https://www.googleapis.com/auth/androidpublisher'
DEFAULT_TOKEN_URI = 'https://oauth2.googleapis.com/token'

MAX_NOTES = 500
PHONE_FOLDER = 'android-phone'
PHONE_IMAGE_TYPE = 'phoneScreenshots'
MIN_PHONE_SCREENSHOTS = 2
MAX_PHONE_SCREENSHOTS = 8
MAX_SCREENSHOT_BYTES = 8 * 1024 * 1024
MIN_SCREENSHOT_SIDE = 320
MAX_SCREENSHOT_SIDE = 3840

TRACK_LABELS = {
    'internal': 'Internal testing',
    'alpha': 'Closed testing (alpha)',
    'beta': 'Open testing (beta)',
    'production': 'Production',
}
STANDARD_TRACKS = ['internal', 'alpha', 'beta', 'production']

# Hint context filled in as commands run, used to explain known API errors
HINT = {}


class PlayError(Exception):
    """A fatal, user-facing error. main() prints it and exits 1."""


class ApiError(PlayError):
    def __init__(self, status, message, what):
        self.status = status
        self.api_message = message
        super().__init__(f'{what} failed (HTTP {status}): {message}')


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def parse_env_file(path):
    """Parse simple KEY=value lines (optional 'export ', quotes, # comments)."""
    values = {}
    if not os.path.isfile(path):
        return values
    with open(path, encoding='utf-8') as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            if line.startswith('export '):
                line = line[len('export '):].strip()
            key, sep, value = line.partition('=')
            key = key.strip()
            if not sep or not re.match(r'^[A-Za-z_][A-Za-z0-9_]*$', key):
                continue
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in '"\'':
                value = value[1:-1]
            elif ' #' in value:
                value = value.split(' #', 1)[0].rstrip()
            values[key] = value
    return values


def load_release_env():
    """Parse ~/.meshmapper_release.env. Real environment variables take
    precedence, and PLAY_* ones are picked up even when the file lacks them."""
    values = parse_env_file(RELEASE_ENV)
    for key in list(values):
        if os.environ.get(key):
            values[key] = os.environ[key]
    for key, value in os.environ.items():
        if key.startswith('PLAY_') and value:
            values[key] = value
    return values


ENV = load_release_env()


def env(key, default=''):
    return ENV.get(key, default) or default


def package_name():
    return env('PLAY_PACKAGE_NAME', DEFAULT_PACKAGE)


def read_last_build():
    return parse_env_file(LAST_BUILD)


def default_language(details: dict, override: str | None) -> str:
    """The language release notes and screenshots go to: --lang when given, else
    the app's default language from edits.details."""
    if override:
        return override
    language = (details or {}).get('defaultLanguage')
    if not language:
        raise PlayError('Play reports no default language for this app; pass --lang.')
    return language


def check_languages(languages: list[str]) -> None:
    """This script only writes English text. Stop at the first other listing
    language rather than leave it with stale or untranslated text."""
    for language in languages:
        if not language.startswith('en'):
            raise PlayError(f'The store listing has a {language} language. This script only '
                            f'writes English text; handle {language} in Play Console first.')


def check_screenshot_size(w: int, h: int) -> None:
    """Play wants each side 320-3840 px and the long side at most twice the short."""
    low, high = min(w, h), max(w, h)
    if low < MIN_SCREENSHOT_SIDE or high > MAX_SCREENSHOT_SIDE:
        raise PlayError(f'{w}x{h}: each side must be {MIN_SCREENSHOT_SIDE}-{MAX_SCREENSHOT_SIDE} px')
    if high > 2 * low:
        raise PlayError(f'{w}x{h}: the long side may be at most twice the short side')


# ---------------------------------------------------------------------------
# Credentials and OAuth
# ---------------------------------------------------------------------------

SETUP_HINT = (
    'Set PLAY_SERVICE_ACCOUNT_JSON (env or ~/.meshmapper_release.env) to the service\n'
    'account JSON key, e.g. ~/.play/play-publisher.json (chmod 600).\n'
    'See the header of play_store.py for the Play Console permissions it needs.'
)


def load_credentials():
    path = env('PLAY_SERVICE_ACCOUNT_JSON')
    if not path:
        raise PlayError('PLAY_SERVICE_ACCOUNT_JSON is not set.\n' + SETUP_HINT)
    path = os.path.expanduser(path)
    if not os.path.isfile(path):
        raise PlayError(f'Service account key not found: {path}\n' + SETUP_HINT)
    if os.stat(path).st_mode & 0o077:
        print(f'Warning: {path} is readable by other users; run: chmod 600 {path}')
    try:
        with open(path, encoding='utf-8') as fh:
            creds = json.load(fh)
    except (OSError, ValueError) as exc:
        raise PlayError(f'Could not read service account key {path}: {exc}')
    if not isinstance(creds, dict) or creds.get('type') != 'service_account':
        raise PlayError(f'{path} is not a service account JSON key (type != service_account).')
    for field in ('client_email', 'private_key'):
        if not creds.get(field):
            raise PlayError(f'{path} has no {field}; download a fresh JSON key.')
    return creds


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')


def rs256_sign(private_key_pem, data):
    """Sign with openssl, keeping the key in a 0600 temp file only while signing."""
    tmpdir = tempfile.mkdtemp(prefix='play_store_')
    key_path = os.path.join(tmpdir, 'key.pem')
    try:
        fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as fh:
            fh.write(private_key_pem)
        try:
            result = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', key_path],
                                    input=data, capture_output=True)
        except FileNotFoundError:
            raise PlayError('openssl is required but not installed.')
        if result.returncode != 0 or not result.stdout:
            raise PlayError('openssl could not sign the token request; is private_key in '
                            'the service account JSON intact?')
        return result.stdout
    finally:
        if os.path.exists(key_path):
            os.remove(key_path)
        shutil.rmtree(tmpdir, ignore_errors=True)


def build_jwt(creds, now=None):
    now = int(now if now is not None else time.time())
    header = {'alg': 'RS256', 'typ': 'JWT'}
    if creds.get('private_key_id'):
        header['kid'] = creds['private_key_id']
    payload = {
        'iss': creds['client_email'],
        'scope': SCOPE,
        'aud': creds.get('token_uri') or DEFAULT_TOKEN_URI,
        'iat': now,
        'exp': now + 3600,
    }
    signing_input = (b64url(json.dumps(header, separators=(',', ':')).encode()) + '.'
                     + b64url(json.dumps(payload, separators=(',', ':')).encode()))
    signature = rs256_sign(creds['private_key'], signing_input.encode('ascii'))
    return signing_input + '.' + b64url(signature)


def fetch_access_token(creds):
    token_uri = creds.get('token_uri') or DEFAULT_TOKEN_URI
    body = urllib.parse.urlencode({
        'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        'assertion': build_jwt(creds),
    }).encode()
    req = urllib.request.Request(token_uri, data=body, method='POST',
                                 headers={'Content-Type': 'application/x-www-form-urlencoded'})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode('utf-8', 'replace')
        try:
            err = json.loads(raw)
            msg = err.get('error_description') or err.get('error') or raw
            if err.get('error') and err.get('error_description'):
                msg = f"{err['error']}: {err['error_description']}"
        except ValueError:
            msg = raw.strip()[:500]
        raise PlayError(f'Google OAuth token exchange failed (HTTP {exc.code}): {msg}\n'
                        'Check that the service account key is current (not deleted or '
                        'rotated in Google Cloud) and the system clock is correct.')
    except urllib.error.URLError as exc:
        raise PlayError(f'Could not reach {token_uri}: {exc.reason}')
    if not data.get('access_token'):
        raise PlayError('Google OAuth token exchange returned no access_token.')
    return data['access_token']


# ---------------------------------------------------------------------------
# API client and edits
# ---------------------------------------------------------------------------

class PlayApi:
    def __init__(self, creds, package):
        self.package = package
        self.client_email = creds['client_email']
        self.token = fetch_access_token(creds)

    def call(self, method, path, body=None, *, upload_path=None, upload_bytes=None,
             content_type=None, query=None, timeout=120, what=None):
        upload = upload_path is not None or upload_bytes is not None
        prefix = '/upload/androidpublisher/v3' if upload else '/androidpublisher/v3'
        url = f'{API_BASE}{prefix}/applications/{urllib.parse.quote(self.package)}{path}'
        params = dict(query or {})
        if upload:
            params['uploadType'] = 'media'
        if params:
            url += '?' + urllib.parse.urlencode(params)
        headers = {'Authorization': f'Bearer {self.token}'}
        data = None
        fileobj = None
        if upload_path is not None:
            fileobj = open(upload_path, 'rb')
            data = fileobj
            headers['Content-Type'] = content_type or 'application/octet-stream'
            headers['Content-Length'] = str(os.path.getsize(upload_path))
        elif upload_bytes is not None:
            data = upload_bytes
            headers['Content-Type'] = content_type or 'application/octet-stream'
        elif body is not None:
            data = json.dumps(body).encode('utf-8')
            headers['Content-Type'] = 'application/json'
        elif method in ('POST', 'PUT', 'PATCH'):
            data = b''
        what = what or f'{method} {path}'
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode('utf-8', 'replace')
            message = raw.strip()[:1000] or exc.reason
            try:
                err = json.loads(raw).get('error', {})
                if isinstance(err, dict) and err.get('message'):
                    message = err['message']
            except (ValueError, AttributeError):
                pass
            raise ApiError(exc.code, message, what)
        except urllib.error.URLError as exc:
            raise PlayError(f'{what} failed: could not reach {API_BASE}: {exc.reason}')
        except TimeoutError:
            raise PlayError(f'{what} timed out after {timeout}s.')
        finally:
            if fileobj:
                fileobj.close()
        if not raw:
            return {}
        try:
            return json.loads(raw.decode('utf-8'))
        except ValueError:
            return {}


class Edit:
    """An androidpublisher edit. Deleted on exit unless committed."""

    def __init__(self, api):
        self.api = api
        self.id = None
        self.deleted = False

    def __enter__(self):
        resp = self.api.call('POST', '/edits', {}, what='Opening an edit (edits.insert)')
        self.id = resp.get('id')
        if not self.id:
            raise PlayError('edits.insert returned no edit id.')
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.id:
            try:
                self.api.call('DELETE', f'/edits/{self.id}', what='edits.delete')
                self.deleted = True
            except PlayError as err:
                print(f'Warning: could not delete edit {self.id}: {err}')
                print('It expires on its own; nothing in it was committed.')
            self.id = None
        return False

    def call(self, method, path, body=None, **kw):
        return self.api.call(method, f'/edits/{self.id}{path}', body, **kw)

    def validate(self):
        """Ask Play to validate everything staged in this edit (edits.validate)."""
        self.api.call('POST', f'/edits/{self.id}:validate',
                      what='Validating the edit (edits.validate)')

    def commit(self, no_review=False):
        query = {'changesNotSentForReview': 'true'} if no_review else None
        self.api.call('POST', f'/edits/{self.id}:commit', query=query,
                      what='Committing the edit (edits.commit)')
        self.id = None  # committed edits no longer exist; nothing to delete


def explain_api_error(err):
    """Extra guidance for known Play API errors."""
    low = (err.api_message or '').lower()
    track = HINT.get('track', '<track>')
    if re.search(r'version code.*(already been used|has already been)', low):
        vc = HINT.get('version_code', 'N')
        return (
            f'versionCode {vc} was already uploaded to Play; a versionCode can only be\n'
            'uploaded once. To put that existing build on a track without uploading:\n'
            f'  ./play_store.py upload --track {track} --version-code {vc} --apply\n'
            'Or build again (./Build.sh) to get a new versionCode.')
    if 'changesnotsentforreview' in low:
        return ('Play wants these changes committed without sending them for review.\n'
                'Re-run with --no-review, then send the changes for review in Play Console\n'
                '(Publishing overview).')
    if err.status == 404 and 'package' in low:
        return (f'Play cannot find package {package_name()} for this service account. The app\n'
                'must already exist in Play Console, and the service account must be invited\n'
                'with access to it (Users and permissions).')
    if err.status in (401, 403):
        return ('The service account lacks permission. In Play Console > Users and\n'
                'permissions, give it Release to production, Manage store presence and\n'
                'View app information for MeshMapper. New grants can take 24-36 h to apply.\n'
                'Also confirm the Google Play Android Developer API is enabled in the\n'
                "service account's Google Cloud project.")
    return None


# ---------------------------------------------------------------------------
# Local file inspection: AAB manifest, PNG headers
# ---------------------------------------------------------------------------

def _varint(buf, i):
    shift = result = 0
    while True:
        if i >= len(buf):
            raise ValueError('truncated varint')
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def _pb_fields(buf):
    i = 0
    while i < len(buf):
        key, i = _varint(buf, i)
        field, wire = key >> 3, key & 7
        if wire == 0:
            value, i = _varint(buf, i)
        elif wire == 1:
            value, i = buf[i:i + 8], i + 8
        elif wire == 2:
            n, i = _varint(buf, i)
            value, i = buf[i:i + n], i + n
        elif wire == 5:
            value, i = buf[i:i + 4], i + 4
        else:
            raise ValueError(f'unsupported wire type {wire}')
        yield field, wire, value


def read_aab_manifest(aab_path):
    """Read package, versionCode and versionName from an AAB's proto manifest.

    base/manifest/AndroidManifest.xml is an aapt2 XmlNode protobuf:
    XmlNode.element(1) > XmlElement.attribute(4) > XmlAttribute{name(2), value(3),
    compiled_item(6) > Item.prim(7) > Primitive.int_decimal_value(6)}.
    """
    with zipfile.ZipFile(aab_path) as z:
        data = z.read('base/manifest/AndroidManifest.xml')
    element = next((v for f, w, v in _pb_fields(data) if f == 1 and w == 2), None)
    if element is None:
        raise ValueError('no root element in manifest')
    attrs = {}
    for f, w, v in _pb_fields(element):
        if f != 4 or w != 2:
            continue
        name = value = None
        prim_int = None
        for af, aw, av in _pb_fields(v):
            if af == 2 and aw == 2:
                name = av.decode('utf-8', 'replace')
            elif af == 3 and aw == 2:
                value = av.decode('utf-8', 'replace')
            elif af == 6 and aw == 2:
                for itf, itw, itv in _pb_fields(av):
                    if itf == 7 and itw == 2:
                        for pf, pw, pv in _pb_fields(itv):
                            if pf in (6, 7) and pw == 0:
                                prim_int = pv
        if name:
            attrs[name] = value if value else (str(prim_int) if prim_int is not None else None)
    version_code = attrs.get('versionCode')
    return {
        'package': attrs.get('package'),
        'versionCode': int(version_code) if version_code and version_code.isdigit() else None,
        'versionName': attrs.get('versionName'),
    }


def png_info(path):
    """Return (width, height, color_type) from a PNG's IHDR chunk."""
    with open(path, 'rb') as fh:
        head = fh.read(26)
    if len(head) < 26 or head[:8] != b'\x89PNG\r\n\x1a\n' or head[12:16] != b'IHDR':
        raise ValueError('not a PNG file')
    width = int.from_bytes(head[16:20], 'big')
    height = int.from_bytes(head[20:24], 'big')
    return width, height, head[25]


def sha1_file(path):
    h = hashlib.sha1()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def human_size(n):
    for unit in ('B', 'KB', 'MB', 'GB'):
        if n < 1024 or unit == 'GB':
            return f'{n:.1f} {unit}' if unit != 'B' else f'{n} B'
        n /= 1024.0


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def track_label(name):
    return TRACK_LABELS.get(name, 'Closed testing (custom track)')


def sort_tracks(tracks):
    order = {t: i for i, t in enumerate(STANDARD_TRACKS)}
    return sorted(tracks, key=lambda t: (order.get(t.get('track'), 99), t.get('track', '')))


def release_max_code(release):
    codes = [int(c) for c in release.get('versionCodes', []) if str(c).isdigit()]
    return max(codes) if codes else -1


def describe_release(r, indent='    '):
    lines = [f"{indent}{r.get('name') or '(unnamed)'}: status={r.get('status', '?')}"
             f" versionCodes={','.join(r.get('versionCodes', [])) or '-'}"
             + (f" userFraction={r['userFraction']}" if 'userFraction' in r else '')]
    for note in r.get('releaseNotes', []):
        text = note.get('text', '').replace('\n', ' / ')
        if len(text) > 100:
            text = text[:97] + '...'
        lines.append(f"{indent}  notes[{note.get('language')}]: {text}")
    return '\n'.join(lines)


def review_states(api, track):
    """versionCode -> review state for the track's non-obsolete releases
    (tracks.releases.list, outside the edit; the edits API has no review state)."""
    try:
        releases = api.call('GET', f'/tracks/{urllib.parse.quote(track)}/releases',
                            what=f'Reading review state (tracks.releases.list {track})').get('releases', [])
    except PlayError as exc:
        print(f'    (review state unavailable: {exc})')
        return {}
    states = {}
    for r in releases:
        state = r.get('releaseLifecycleState', '?').removeprefix('RELEASE_LIFECYCLE_STATE_')
        for a in r.get('activeArtifacts', []):
            states[str(a.get('versionCode'))] = state
    return states


def list_tracks(edit):
    return edit.call('GET', '/tracks', what='Listing tracks (edits.tracks.list)').get('tracks', [])


def edit_language(edit, override=None):
    """The language this run writes to, after the language rule: stop when the
    edit's store listing has any language other than English. Reads only."""
    listings = edit.call('GET', '/listings',
                         what='Listing store listings (edits.listings.list)').get('listings', [])
    check_languages([lst.get('language', '') for lst in listings])
    details = edit.call('GET', '/details', what='Reading app details (edits.details.get)')
    return default_language(details, override)


def validate_status(args):
    if args.fraction is not None:
        if args.status != 'inProgress':
            raise PlayError('--fraction only applies with --status inProgress (a staged rollout).')
        if not 0 < args.fraction < 1:
            raise PlayError('--fraction must be between 0 and 1 (exclusive), e.g. 0.2.')
    elif args.status == 'inProgress':
        raise PlayError('--status inProgress needs --fraction F (e.g. --fraction 0.2).')


def build_release(name, version_codes, notes, status, fraction):
    release = {'versionCodes': [str(c) for c in version_codes], 'status': status}
    if name:
        release['name'] = name
    if notes:
        release['releaseNotes'] = notes
    if fraction is not None:
        release['userFraction'] = fraction
    return release


def finish_validate(edit):
    """Validate the staged edit with Play. The caller's `with` block deletes the
    edit afterwards; nothing is ever committed from here."""
    edit.validate()
    print('')
    print('validate: OK (Play accepted everything staged in the edit)')


def report_edit_deleted(edit):
    if edit.deleted:
        print('edit deleted, nothing was committed.')


# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

def cmd_status(args):
    api = PlayApi(load_credentials(), package_name())
    print(f'Package: {api.package}')
    print(f'Service account: {api.client_email}')
    with Edit(api) as edit:
        print('')
        print('Tracks:')
        tracks = sort_tracks(list_tracks(edit))
        if not tracks:
            print('  (none)')
        for t in tracks:
            print(f"  {t.get('track')} - {track_label(t.get('track'))}")
            releases = t.get('releases', [])
            if not releases:
                print('    (no releases)')
            states = review_states(api, t.get('track')) if releases else {}
            for r in releases:
                print(describe_release(r))
                review = sorted({states[c] for c in r.get('versionCodes', []) if c in states})
                if review:
                    print(f"      review: {', '.join(review)}")

        bundles = edit.call('GET', '/bundles', what='Listing bundles (edits.bundles.list)').get('bundles', [])
        codes = sorted((b.get('versionCode') for b in bundles if b.get('versionCode')), reverse=True)
        print('')
        print(f'Uploaded bundles: {len(codes)}'
              + (f" (latest versionCodes: {', '.join(map(str, codes[:5]))})" if codes else ''))

        details = edit.call('GET', '/details', what='Reading app details (edits.details.get)')
        print('')
        print('App details:')
        for key in ('defaultLanguage', 'contactEmail', 'contactWebsite', 'contactPhone'):
            if details.get(key):
                print(f'  {key}: {details[key]}')

        listings = edit.call('GET', '/listings', what='Listing store listings (edits.listings.list)').get('listings', [])
        print('')
        print('Store listing languages:')
        if not listings:
            print('  (none)')
        for lst in sorted(listings, key=lambda x: x.get('language', '')):
            print(f"  {lst.get('language')}: {lst.get('title', '')!r}")
    print('')
    print('(Read-only: the edit was discarded, nothing committed.)')


# ---------------------------------------------------------------------------
# upload
# ---------------------------------------------------------------------------

def load_notes_text(path):
    """The release notes text from a file ('-' for stdin), checked against the
    Play limit; None when no file was given."""
    if not path:
        return None
    if path == '-':
        text = sys.stdin.read()
    else:
        if not os.path.isfile(path):
            raise PlayError(f'Notes file not found: {path}')
        with open(path, encoding='utf-8') as fh:
            text = fh.read()
    text = text.strip()
    if not text:
        raise PlayError(f'Notes file {path} is empty.')
    if len(text) > MAX_NOTES:
        raise PlayError(f'Release notes are {len(text)} characters; Play allows {MAX_NOTES} '
                        f'per language. Shorten {path}.')
    return text


def read_notes(path, lang):
    text = load_notes_text(path)
    return [{'language': lang, 'text': text}] if text else None


def cmd_upload(args):
    pkg = package_name()
    validate_status(args)
    last = read_last_build()
    HINT['track'] = args.track
    notes_text = load_notes_text(args.notes_file)

    release_name = args.release_name

    aab = None
    info = {}
    version_code = args.version_code
    if version_code is None:
        aab = args.aab or last.get('AAB_PATH')
        if not aab:
            raise PlayError('No AAB given and .last_build has no AAB_PATH. Run ./Build.sh or pass --aab PATH.')
        aab = os.path.abspath(os.path.expanduser(aab))
        if not os.path.isfile(aab):
            raise PlayError(f'AAB not found: {aab}\nRun ./Build.sh or pass --aab PATH.')
        try:
            info = read_aab_manifest(aab)
        except (zipfile.BadZipFile, KeyError, ValueError) as exc:
            raise PlayError(f'{aab} is not a readable Android App Bundle: {exc}')
        if info['package'] and info['package'] != pkg:
            raise PlayError(f"{aab} is package {info['package']}, but PLAY_PACKAGE_NAME is {pkg}.")
        version_code = info['versionCode']
        if version_code is None:
            if last.get('EPOCH') and os.path.abspath(last.get('AAB_PATH', '')) == aab:
                version_code = int(last['EPOCH'])
                print(f'Note: versionCode not readable from the manifest; using EPOCH {version_code} from .last_build.')
            else:
                print('Warning: versionCode not readable from the bundle manifest; Play will report it after upload.')
    HINT['version_code'] = version_code if version_code is not None else 'N'

    # Name the release after the bundle actually being uploaded; .last_build
    # only describes the newest local build, which may not be this one
    if not release_name and aab and info.get('versionName') and version_code is not None:
        release_name = f"{info['versionName']} ({version_code})"

    api = PlayApi(load_credentials(), pkg)
    with Edit(api) as edit:
        # The language rule comes before anything is written
        lang = edit_language(edit, args.lang)
        notes = [{'language': lang, 'text': notes_text}] if notes_text else None

        print(f'Package:       {pkg}')
        print(f'Track:         {args.track} - {track_label(args.track)}')
        if aab:
            print(f'Bundle:        {aab} ({human_size(os.path.getsize(aab))})')
            print(f"versionCode:   {version_code if version_code is not None else '(unknown until upload)'}"
                  + (f"  versionName: {info['versionName']}" if info.get('versionName') else ''))
        else:
            print(f'Bundle:        (no upload) assigning existing versionCode {version_code}')
        print(f"Release name:  {release_name or '(Play default)'}")
        print(f'Status:        {args.status}'
              + (f' (userFraction {args.fraction})' if args.fraction is not None else ''))
        if notes:
            print(f'Release notes [{lang}] ({len(notes_text)}/{MAX_NOTES} chars):')
            for line in notes_text.splitlines():
                print(f'  | {line}')
        else:
            print('Release notes: (none)')

        tracks = {t.get('track'): t for t in list_tracks(edit)}
        current = tracks.get(args.track)
        print('')
        if current is None:
            print(f"Warning: track '{args.track}' does not exist yet for this app. Custom closed "
                  'tracks must be created in Play Console first.')
        else:
            print(f'Current {args.track} releases:')
            for r in current.get('releases', []):
                print(describe_release(r))
            if not current.get('releases'):
                print('    (none)')

        if not (args.apply or args.validate):
            print('')
            print('Dry run: nothing uploaded or changed. Re-run with --validate to have Play check it '
                  'without publishing, or --apply to publish.')
            return

        if aab:
            print('')
            print(f'Uploading {os.path.basename(aab)} (this can take a few minutes)...')
            resp = edit.call('POST', '/bundles', upload_path=aab,
                             content_type='application/octet-stream', timeout=1800,
                             what='Uploading the bundle (edits.bundles.upload)')
            uploaded = resp.get('versionCode')
            if uploaded is None:
                raise PlayError('Bundle upload returned no versionCode.')
            if version_code is not None and int(uploaded) != int(version_code):
                print(f'Warning: Play reports versionCode {uploaded}, expected {version_code}.')
            version_code = uploaded
            print(f"Uploaded versionCode {version_code} (sha1 {resp.get('sha1', '?')}).")

        release = build_release(release_name, [version_code], notes, args.status, args.fraction)
        edit.call('PUT', f'/tracks/{urllib.parse.quote(args.track)}',
                  {'track': args.track, 'releases': [release]},
                  what=f'Updating track {args.track} (edits.tracks.update)')
        if args.validate:
            finish_validate(edit)
        else:
            edit.commit(no_review=args.no_review)
    print('')
    if args.validate:
        report_edit_deleted(edit)
        return
    print(f'Committed: versionCode {version_code} is on {args.track} with status {args.status}.')
    if args.status == 'draft':
        print('The release is a draft; roll it out from Play Console > Testing.')


# ---------------------------------------------------------------------------
# promote
# ---------------------------------------------------------------------------

def cmd_promote(args):
    pkg = package_name()
    validate_status(args)
    HINT['track'] = args.to_track
    if args.from_track == args.to_track:
        raise PlayError('--from and --to must be different tracks.')
    api = PlayApi(load_credentials(), pkg)
    with Edit(api) as edit:
        tracks = {t.get('track'): t for t in list_tracks(edit)}
        src = tracks.get(args.from_track)
        releases = [r for r in (src or {}).get('releases', []) if r.get('versionCodes')]
        if not releases:
            raise PlayError(f"Track '{args.from_track}' has no release with a build to promote.")
        latest = max(releases, key=release_max_code)
        HINT['version_code'] = release_max_code(latest)
        release = build_release(latest.get('name'), latest['versionCodes'],
                                latest.get('releaseNotes'), args.status, args.fraction)

        print(f'Package: {pkg}')
        print(f'From {args.from_track} ({track_label(args.from_track)}), latest release:')
        print(describe_release(latest))
        dest = tracks.get(args.to_track)
        print(f'To {args.to_track} ({track_label(args.to_track)}), currently:')
        if dest is None:
            print(f"    Warning: track '{args.to_track}' does not exist yet for this app.")
        for r in (dest or {}).get('releases', []) or []:
            print(describe_release(r))
        if dest is not None and not dest.get('releases'):
            print('    (no releases)')
        print('New release:')
        print(describe_release(release))

        if not args.apply:
            print('')
            print('Dry run: nothing changed. Re-run with --apply to promote.')
            return
        edit.call('PUT', f'/tracks/{urllib.parse.quote(args.to_track)}',
                  {'track': args.to_track, 'releases': [release]},
                  what=f'Updating track {args.to_track} (edits.tracks.update)')
        edit.commit(no_review=args.no_review)
    print('')
    print(f"Committed: versionCodes {','.join(release['versionCodes'])} promoted to {args.to_track}.")


# ---------------------------------------------------------------------------
# screenshots
# ---------------------------------------------------------------------------

def collect_phone_screenshots(base_dir):
    """The android-phone/*.png files under base_dir, in name order, checked for
    count, size and weight. Raises PlayError listing every problem found."""
    folder = os.path.join(os.path.abspath(os.path.expanduser(base_dir)), PHONE_FOLDER)
    if not os.path.isdir(folder):
        raise PlayError(f'{folder} not found. Run tool/store_screenshots/capture_android.sh first, '
                        f'or pass the folder that holds {PHONE_FOLDER}/ as --dir.')
    files = sorted(os.path.join(folder, name) for name in os.listdir(folder)
                   if name.lower().endswith('.png'))
    if not MIN_PHONE_SCREENSHOTS <= len(files) <= MAX_PHONE_SCREENSHOTS:
        raise PlayError(f'{folder}: {len(files)} PNG files, Play needs '
                        f'{MIN_PHONE_SCREENSHOTS}-{MAX_PHONE_SCREENSHOTS} phone screenshots.')
    errors = []
    for path in files:
        name = os.path.basename(path)
        try:
            width, height, _ = png_info(path)
            check_screenshot_size(width, height)
        except (OSError, ValueError, PlayError) as exc:
            errors.append(f'{name}: {exc}')
            continue
        size = os.path.getsize(path)
        if size > MAX_SCREENSHOT_BYTES:
            errors.append(f'{name}: {human_size(size)} exceeds the '
                          f'{human_size(MAX_SCREENSHOT_BYTES)} limit')
    if errors:
        raise PlayError('The phone screenshots are not valid:\n  - ' + '\n  - '.join(errors))
    return files


def remote_images(edit, lang, image_type):
    try:
        return edit.call('GET', f'/listings/{lang}/{image_type}',
                         what=f'Listing {image_type} (edits.images.list)').get('images', [])
    except ApiError as exc:
        if exc.status != 404:
            raise
        return []


def cmd_screenshots(args):
    pkg = package_name()
    files = collect_phone_screenshots(args.dir)
    local = [sha1_file(path) for path in files]

    api = PlayApi(load_credentials(), pkg)
    with Edit(api) as edit:
        # The language rule comes before anything is written
        lang = edit_language(edit)
        remote = remote_images(edit, lang, PHONE_IMAGE_TYPE)

        print(f'Package: {pkg}')
        print(f'{PHONE_IMAGE_TYPE} for {lang}: {len(remote)} on Play, {len(files)} local:')
        for path in files:
            width, height, _ = png_info(path)
            print(f'  {os.path.basename(path)} {width}x{height}')

        matches = [r.get('sha1') for r in remote] == local
        # --validate stages the replacement even when Play already matches, so it
        # still proves the service account may write
        if matches and not args.validate:
            print('')
            print('Play already matches the local screenshots; nothing to change.')
            return
        if not (args.apply or args.validate):
            print('')
            print(f'Replace {len(remote)} remote with {len(files)} local. Dry run: nothing changed. '
                  'Re-run with --validate to have Play check it without publishing, or --apply.')
            return

        edit.call('DELETE', f'/listings/{lang}/{PHONE_IMAGE_TYPE}',
                  what=f'Clearing {PHONE_IMAGE_TYPE} (edits.images.deleteall)')
        for path in files:
            edit.call('POST', f'/listings/{lang}/{PHONE_IMAGE_TYPE}', upload_path=path,
                      content_type='image/png', timeout=300,
                      what=f'Uploading {os.path.basename(path)} as {PHONE_IMAGE_TYPE} (edits.images.upload)')
            print(f'  uploaded {os.path.basename(path)}')
        if args.validate:
            finish_validate(edit)
        else:
            edit.commit(no_review=args.no_review)
    print('')
    if args.validate:
        report_edit_deleted(edit)
        return
    print(f'Committed: {len(files)} {PHONE_IMAGE_TYPE} for {lang}.')


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        prog='play_store.py',
        description='Upload MeshMapper to Google Play and replace its phone screenshots. '
                    'Dry run unless --apply (or --validate) is passed.')
    sub = parser.add_subparsers(dest='command')
    sub.required = True

    sub.add_parser('status', help='show tracks, releases and listing languages (read-only)')

    def add_no_review(p):
        p.add_argument('--no-review', action='store_true',
                       help='commit with changesNotSentForReview=true (send for review from Console)')

    def add_write_mode(p, validatable):
        group = p.add_mutually_exclusive_group()
        group.add_argument('--apply', action='store_true', help='actually make the change')
        if validatable:
            group.add_argument('--validate', action='store_true',
                               help='stage the change in an edit, have Play validate it, then '
                                    'delete the edit; never commits')
        add_no_review(p)

    def add_status(p):
        p.add_argument('--status', choices=['draft', 'completed', 'inProgress'], default='completed',
                       help='release status (default completed; on production that is a 100%% rollout)')
        p.add_argument('--fraction', type=float, help='userFraction for --status inProgress (0-1)')

    up = sub.add_parser('upload', help='upload an AAB and put it on a track')
    up.add_argument('--track', required=True,
                    help='production, beta (open), alpha (closed), internal or a custom closed track')
    up.add_argument('--aab', help='AAB path (default: AAB_PATH from .last_build)')
    up.add_argument('--version-code', type=int,
                    help='assign this already uploaded versionCode to the track instead of uploading')
    up.add_argument('--notes-file', help=f"release notes file ('-' for stdin), max {MAX_NOTES} chars")
    up.add_argument('--lang',
                    help="release notes language (default: the app's default language on Play)")
    up.add_argument('--release-name',
                    help='release name (default: versionName (versionCode) read from the AAB)')
    add_status(up)
    add_write_mode(up, validatable=True)

    pr = sub.add_parser('promote', help='copy the latest release from one track to another')
    pr.add_argument('--from', dest='from_track', required=True, help='source track, e.g. beta')
    pr.add_argument('--to', dest='to_track', required=True, help='destination track, e.g. production')
    add_status(pr)
    add_write_mode(pr, validatable=False)

    sc = sub.add_parser('screenshots',
                        help=f'replace the {PHONE_IMAGE_TYPE} of the default language')
    sc.add_argument('--dir', required=True, metavar='DIR',
                    help=f'folder holding {PHONE_FOLDER}/ with {MIN_PHONE_SCREENSHOTS}-'
                         f'{MAX_PHONE_SCREENSHOTS} PNG files')
    add_write_mode(sc, validatable=True)
    return parser


def mode_label(args):
    if args.command == 'status' or getattr(args, 'apply', False):
        return ''
    if getattr(args, 'validate', False):
        return '  [VALIDATE ONLY, nothing is committed]'
    return '  [DRY RUN]'


def main():
    args = build_parser().parse_args()
    handlers = {'status': cmd_status, 'upload': cmd_upload, 'promote': cmd_promote,
                'screenshots': cmd_screenshots}
    print(f'Google Play: {package_name()}{mode_label(args)}')
    try:
        handlers[args.command](args)
    except ApiError as exc:
        print('')
        print(f'Error: {exc}', file=sys.stderr)
        hint = explain_api_error(exc)
        if hint:
            print('', file=sys.stderr)
            print(hint, file=sys.stderr)
        print('', file=sys.stderr)
        print('Nothing was committed (the edit was discarded).', file=sys.stderr)
        sys.exit(1)
    except PlayError as exc:
        print('')
        print(f'Error: {exc}', file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print('\nInterrupted; nothing was committed.', file=sys.stderr)
        sys.exit(130)


if __name__ == '__main__':
    main()
