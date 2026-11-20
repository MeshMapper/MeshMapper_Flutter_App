from __future__ import annotations

import contextlib
import io
import os
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

# asc_store.py lives in the repo root, next to Build.sh.
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import asc_store  # noqa: E402

Fail = asc_store.Fail


def _version(version_string: str, state: str, vid: str = 'v1') -> dict:
    return {'id': vid, 'type': 'appStoreVersions',
            'attributes': {'versionString': version_string, 'appStoreState': state,
                           'releaseType': 'AFTER_APPROVAL'}}


class CheckStoreTextTest(unittest.TestCase):
    def test_accepts_accented_letters(self) -> None:
        asc_store.check_store_text('whats_new', 'Fixed the map. Café menu.')

    def test_rejects_emoji(self) -> None:
        with self.assertRaises(Fail):
            asc_store.check_store_text('whats_new', 'New \U0001F680')

    def test_rejects_dingbats_and_variation_selector(self) -> None:
        for text in ('Done ✔', 'Heart ❤️', 'Sun ☀'):
            with self.subTest(text=text), self.assertRaises(Fail):
                asc_store.check_store_text('whats_new', text)

    def test_rejects_empty(self) -> None:
        for text in ('', '   \n'):
            with self.subTest(text=text), self.assertRaises(Fail):
                asc_store.check_store_text('whats_new', text)

    def test_length_limit(self) -> None:
        asc_store.check_store_text('whats_new', 'x' * 4000)
        with self.assertRaises(Fail):
            asc_store.check_store_text('whats_new', 'x' * 4001)


class CheckLocalesTest(unittest.TestCase):
    def test_accepts_english(self) -> None:
        asc_store.check_locales(['en-CA'])
        asc_store.check_locales(['en-CA', 'en-US'])

    def test_names_the_first_non_english_locale(self) -> None:
        with self.assertRaises(Fail) as ctx:
            asc_store.check_locales(['en-CA', 'fr-CA', 'de-DE'])
        self.assertIn('fr-CA', str(ctx.exception))
        self.assertNotIn('de-DE', str(ctx.exception))


class ChooseVersionTest(unittest.TestCase):
    def test_creates_when_nothing_is_editable(self) -> None:
        live = _version('1.4.0', 'READY_FOR_SALE')
        self.assertEqual(asc_store.choose_version([live], '1.4.1'), ('create', None))

    def test_reuses_the_matching_editable_version(self) -> None:
        live = _version('1.4.0', 'READY_FOR_SALE', 'v0')
        editable = _version('1.4.1', 'PREPARE_FOR_SUBMISSION', 'v1')
        self.assertEqual(asc_store.choose_version([live, editable], '1.4.1'),
                         ('reuse', editable))

    def test_refuses_a_different_editable_version(self) -> None:
        editable = _version('1.4.2', 'PREPARE_FOR_SUBMISSION')
        with self.assertRaises(Fail):
            asc_store.choose_version([editable], '1.4.1')


class AlreadySubmittedTest(unittest.TestCase):
    def test_submitted_states(self) -> None:
        for state in ('WAITING_FOR_REVIEW', 'IN_REVIEW', 'PENDING_DEVELOPER_RELEASE',
                      'PROCESSING_FOR_DISTRIBUTION', 'READY_FOR_DISTRIBUTION',
                      'READY_FOR_SALE'):
            with self.subTest(state=state):
                self.assertTrue(asc_store.already_submitted(
                    {'attributes': {'appStoreState': state}}))

    def test_editable_states_are_not_submitted(self) -> None:
        for state in ('PREPARE_FOR_SUBMISSION', 'REJECTED', 'DEVELOPER_REJECTED'):
            with self.subTest(state=state):
                self.assertFalse(asc_store.already_submitted(
                    {'attributes': {'appStoreState': state}}))

    def test_reads_the_newer_state_field_too(self) -> None:
        self.assertTrue(asc_store.already_submitted(
            {'attributes': {'appVersionState': 'WAITING_FOR_REVIEW'}}))


class ScreenshotSetsTest(unittest.TestCase):
    def test_watch_set(self) -> None:
        spec = asc_store.SCREENSHOT_SETS['watch-46']
        self.assertEqual(spec['displayType'], 'APP_WATCH_SERIES_10')
        self.assertEqual(spec['sizes'], {(416, 496)})

    def test_phone_and_tablet_sets_keep_their_display_types(self) -> None:
        self.assertEqual(asc_store.SCREENSHOT_SETS['ios-iphone-69']['displayType'],
                         'APP_IPHONE_67')
        self.assertEqual(asc_store.SCREENSHOT_SETS['ios-ipad-13']['displayType'],
                         'APP_IPAD_PRO_3GEN_129')


class ReleaseEnvTest(unittest.TestCase):
    def test_parses_exports_quotes_and_comments(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, 'env')
            Path(path).write_text(
                '# comment\n\nASC_KEY_ID=ABC123\nexport ASC_ISSUER_ID="issuer-1"\n'
                "OTHER='x y'\nPLAIN=value # trailing\n", encoding='utf-8')
            with mock.patch.object(asc_store, 'RELEASE_ENV', path), \
                    mock.patch.dict(os.environ, {}, clear=True):
                values = asc_store.load_release_env()
        self.assertEqual(values['ASC_KEY_ID'], 'ABC123')
        self.assertEqual(values['ASC_ISSUER_ID'], 'issuer-1')
        self.assertEqual(values['OTHER'], 'x y')
        self.assertEqual(values['PLAIN'], 'value')

    def test_defaults(self) -> None:
        self.assertTrue(asc_store.RELEASE_ENV.endswith('.meshmapper_release.env'))
        self.assertEqual(asc_store.BUNDLE_ID, 'net.meshmapper.app')
        self.assertEqual(asc_store.DEFAULT_APP_ID, '6758073991')


class DerToRawTest(unittest.TestCase):
    def test_pads_r_and_s_to_32_bytes(self) -> None:
        r = bytes([0x01] * 31)
        s = bytes([0x00, 0x80] + [0x02] * 30)  # leading zero keeps the INTEGER positive
        der = bytes([0x30, 2 + len(r) + 2 + len(s), 0x02, len(r)]) + r + \
            bytes([0x02, len(s)]) + s
        raw = asc_store._der_to_raw(der)
        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[:32], b'\x00' + r)
        self.assertEqual(raw[32:], b'\x00' + s[1:])


# ---------------------------------------------------------------------------
# Flows against a fake App Store Connect
# ---------------------------------------------------------------------------

APP = asc_store.DEFAULT_APP_ID


class FakeASC:
    """Stands in for asc_store.api. Routes are keyed (method, path); a value is a
    response body, an exception to raise, or a callable taking the body."""

    def __init__(self, routes: dict) -> None:
        self.routes = routes
        self.calls: list[tuple] = []

    def __call__(self, method, path, body=None, params=None, ok=(200, 201, 204)):
        self.calls.append((method, path, body, params))
        if (method, path) not in self.routes:
            raise AssertionError('unexpected call %s %s' % (method, path))
        res = self.routes[(method, path)]
        if isinstance(res, Exception):
            raise res
        return res(body) if callable(res) else res

    def writes(self) -> list[tuple]:
        return [(m, p, b) for m, p, b, _ in self.calls if m != 'GET']


def _data(items):
    return {'data': items}


def _run(fn, args) -> tuple:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        result = fn(args)
    return result, out.getvalue()


class SubmitFlowTest(unittest.TestCase):
    VER = 'ver1'
    LOC = 'loc1'

    def routes(self, **overrides) -> dict:
        routes = {
            ('GET', '/v1/apps/%s/appStoreVersions' % APP):
                _data([_version('1.4.0', 'READY_FOR_SALE', 'ver0'),
                       _version('1.4.1', 'PREPARE_FOR_SUBMISSION', self.VER)]),
            ('GET', '/v1/appStoreVersions/%s/build' % self.VER):
                _data({'id': 'b1', 'type': 'builds', 'attributes': {'version': '1'}}),
            ('GET', '/v1/appStoreVersions/%s/appStoreVersionLocalizations' % self.VER):
                _data([{'id': self.LOC, 'attributes': {'locale': 'en-CA',
                                                       'whatsNew': 'Fixes.'}}]),
            ('GET', '/v1/appStoreVersionLocalizations/%s/appScreenshotSets' % self.LOC):
                _data([{'id': 's-phone', 'attributes': {
                            'screenshotDisplayType': 'APP_IPHONE_67'}},
                       {'id': 's-pad', 'attributes': {
                            'screenshotDisplayType': 'APP_IPAD_PRO_3GEN_129'}},
                       {'id': 's-watch', 'attributes': {
                            'screenshotDisplayType': 'APP_WATCH_SERIES_10'}}]),
            ('GET', '/v1/reviewSubmissions'): _data([]),
            ('POST', '/v1/reviewSubmissions'):
                {'data': {'id': 'sub1', 'type': 'reviewSubmissions',
                          'attributes': {'state': 'READY_FOR_REVIEW'}}},
            ('POST', '/v1/reviewSubmissionItems'):
                {'data': {'id': 'item1', 'type': 'reviewSubmissionItems'}},
            ('PATCH', '/v1/reviewSubmissions/sub1'):
                {'data': {'id': 'sub1', 'type': 'reviewSubmissions',
                          'attributes': {'state': 'WAITING_FOR_REVIEW'}}},
        }
        for set_id in ('s-phone', 's-pad', 's-watch'):
            routes[('GET', '/v1/appScreenshotSets/%s/appScreenshots' % set_id)] = _data(
                [{'id': set_id + '-1', 'attributes': {
                    'assetDeliveryState': {'state': 'COMPLETE'}}}])
        routes.update(overrides)
        return routes

    def submit(self, fake: FakeASC, apply: bool, version: str = '1.4.1'):
        args = mock.Mock(version=version, apply=apply)
        with mock.patch.object(asc_store, 'api', fake):
            return _run(asc_store.cmd_submit, args)

    def test_dry_run_checks_everything_and_writes_nothing(self) -> None:
        fake = FakeASC(self.routes())
        _, out = self.submit(fake, apply=False)
        self.assertEqual(fake.writes(), [])
        self.assertIn('DRY RUN', out)

    def test_apply_creates_submission_adds_the_version_then_submits(self) -> None:
        fake = FakeASC(self.routes())
        self.submit(fake, apply=True)
        self.assertEqual(fake.writes(), [
            ('POST', '/v1/reviewSubmissions', {'data': {
                'type': 'reviewSubmissions', 'attributes': {'platform': 'IOS'},
                'relationships': {'app': {'data': {'type': 'apps', 'id': APP}}}}}),
            ('POST', '/v1/reviewSubmissionItems', {'data': {
                'type': 'reviewSubmissionItems', 'relationships': {
                    'reviewSubmission': {'data': {'type': 'reviewSubmissions',
                                                  'id': 'sub1'}},
                    'appStoreVersion': {'data': {'type': 'appStoreVersions',
                                                 'id': self.VER}}}}}),
            ('PATCH', '/v1/reviewSubmissions/sub1', {'data': {
                'type': 'reviewSubmissions', 'id': 'sub1',
                'attributes': {'submitted': True}}}),
        ])

    def test_looks_for_an_open_ios_submission(self) -> None:
        fake = FakeASC(self.routes())
        self.submit(fake, apply=False)
        params = [p for m, path, _, p in fake.calls
                  if (m, path) == ('GET', '/v1/reviewSubmissions')][0]
        self.assertEqual(params['filter[app]'], APP)
        self.assertEqual(params['filter[platform]'], 'IOS')
        self.assertEqual(params['filter[state]'], 'READY_FOR_REVIEW')

    @staticmethod
    def items_of(*version_ids: str) -> dict:
        return _data([{'id': 'item-' + vid, 'type': 'reviewSubmissionItems', 'relationships': {
            'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': vid}}}}
            for vid in version_ids])

    @staticmethod
    def conflict() -> asc_store.APIError:
        return asc_store.APIError(
            'POST', '/v1/reviewSubmissionItems', 409,
            {'errors': [{'status': '409', 'code': 'ENTITY_ERROR', 'title': 'conflict'}]})

    def open_submission_routes(self, items: dict, state: str | None = None) -> dict:
        routes = self.routes()
        routes[('GET', '/v1/reviewSubmissions')] = _data(
            [{'id': 'sub1', 'attributes': {'state': 'READY_FOR_REVIEW'}}])
        routes[('POST', '/v1/reviewSubmissionItems')] = self.conflict()
        routes[('GET', '/v1/reviewSubmissions/sub1/items')] = items
        if state:
            routes[('GET', '/v1/apps/%s/appStoreVersions' % APP)] = _data(
                [_version('1.4.1', state, self.VER)])
        return routes

    def test_reuses_an_open_submission_and_continues_on_409_when_the_version_is_in_it(self) -> None:
        fake = FakeASC(self.open_submission_routes(self.items_of(self.VER)))
        _, out = self.submit(fake, apply=True)
        kinds = [(m, p) for m, p, _ in fake.writes()]
        self.assertEqual(kinds, [('POST', '/v1/reviewSubmissionItems'),
                                 ('PATCH', '/v1/reviewSubmissions/sub1')])
        self.assertIn('WAITING_FOR_REVIEW', out)

    def test_409_is_also_verified_through_the_included_version(self) -> None:
        items = _data([{'id': 'item1', 'type': 'reviewSubmissionItems'}])
        items['included'] = [{'id': self.VER, 'type': 'appStoreVersions'}]
        fake = FakeASC(self.open_submission_routes(items))
        self.submit(fake, apply=True)
        self.assertEqual(fake.writes()[-1][:2], ('PATCH', '/v1/reviewSubmissions/sub1'))

    def test_409_when_the_version_is_not_in_the_submission_is_raised(self) -> None:
        for items in (self.items_of(), self.items_of('some-other-version')):
            with self.subTest(items=items):
                fake = FakeASC(self.open_submission_routes(items))
                with self.assertRaises(asc_store.APIError) as ctx:
                    self.submit(fake, apply=True)
                self.assertEqual(ctx.exception.status, 409)
                self.assertIn('conflict', str(ctx.exception))
                self.assertEqual([(m, p) for m, p, _ in fake.writes()],
                                 [('POST', '/v1/reviewSubmissionItems')])

    def test_other_item_errors_are_not_swallowed(self) -> None:
        routes = self.routes()
        routes[('POST', '/v1/reviewSubmissionItems')] = asc_store.APIError(
            'POST', '/v1/reviewSubmissionItems', 422, {'errors': []})
        fake = FakeASC(routes)
        with self.assertRaises(asc_store.APIError):
            self.submit(fake, apply=True)
        self.assertNotIn('PATCH', [m for m, _, _ in fake.writes()])

    def test_a_half_finished_submit_can_be_resumed(self) -> None:
        # The item was added, then `submitted: true` failed. The version now
        # reads READY_FOR_REVIEW (on either state field) and is no longer editable.
        for field in ('appStoreState', 'appVersionState'):
            with self.subTest(field=field):
                routes = self.open_submission_routes(self.items_of(self.VER))
                version = _version('1.4.1', 'x', self.VER)
                version['attributes'] = {'versionString': '1.4.1', field: 'READY_FOR_REVIEW'}
                routes[('GET', '/v1/apps/%s/appStoreVersions' % APP)] = _data([version])
                fake = FakeASC(routes)
                _, out = self.submit(fake, apply=True)
                self.assertEqual(fake.writes()[-1], (
                    'PATCH', '/v1/reviewSubmissions/sub1', {'data': {
                        'type': 'reviewSubmissions', 'id': 'sub1',
                        'attributes': {'submitted': True}}}))
                self.assertIn('resuming', out)

    def test_a_resumed_submit_still_checks_the_preconditions(self) -> None:
        routes = self.open_submission_routes(self.items_of(self.VER), 'READY_FOR_REVIEW')
        routes[('GET', '/v1/appScreenshotSets/s-watch/appScreenshots')] = _data([])
        fake = FakeASC(routes)
        with self.assertRaises(Fail):
            self.submit(fake, apply=True)
        self.assertEqual(fake.writes(), [])

    def test_a_version_in_a_state_that_cannot_be_submitted_is_refused(self) -> None:
        for state in ('REPLACED_WITH_NEW_VERSION', 'DEVELOPER_REMOVED_FROM_SALE'):
            with self.subTest(state=state):
                routes = self.routes()
                routes[('GET', '/v1/apps/%s/appStoreVersions' % APP)] = _data(
                    [_version('1.4.1', state, self.VER)])
                fake = FakeASC(routes)
                with self.assertRaises(Fail) as ctx:
                    self.submit(fake, apply=True)
                self.assertIn('cannot be submitted', str(ctx.exception))
                self.assertEqual(fake.writes(), [])

    def test_already_submitted_exits_cleanly_without_writes(self) -> None:
        routes = self.routes()
        routes[('GET', '/v1/apps/%s/appStoreVersions' % APP)] = _data(
            [_version('1.4.1', 'WAITING_FOR_REVIEW', self.VER)])
        fake = FakeASC(routes)
        _, out = self.submit(fake, apply=True)
        self.assertIn('already submitted (WAITING_FOR_REVIEW)', out)
        self.assertEqual(fake.writes(), [])

    def test_no_build_attached(self) -> None:
        fake = FakeASC(self.routes(**{}))
        fake.routes[('GET', '/v1/appStoreVersions/%s/build' % self.VER)] = {'data': None}
        with self.assertRaises(Fail) as ctx:
            self.submit(fake, apply=True)
        self.assertIn('build', str(ctx.exception).lower())
        self.assertEqual(fake.writes(), [])

    def test_missing_whats_new(self) -> None:
        fake = FakeASC(self.routes())
        fake.routes[('GET', '/v1/appStoreVersions/%s/appStoreVersionLocalizations'
                     % self.VER)] = _data(
            [{'id': self.LOC, 'attributes': {'locale': 'en-CA', 'whatsNew': ''}}])
        with self.assertRaises(Fail) as ctx:
            self.submit(fake, apply=True)
        self.assertIn('en-CA', str(ctx.exception))
        self.assertEqual(fake.writes(), [])

    def test_missing_watch_screenshots(self) -> None:
        fake = FakeASC(self.routes())
        fake.routes[('GET', '/v1/appScreenshotSets/s-watch/appScreenshots')] = _data([])
        with self.assertRaises(Fail) as ctx:
            self.submit(fake, apply=True)
        self.assertIn('APP_WATCH_SERIES_10', str(ctx.exception))
        self.assertEqual(fake.writes(), [])

    def test_missing_screenshot_set(self) -> None:
        fake = FakeASC(self.routes())
        fake.routes[('GET', '/v1/appStoreVersionLocalizations/%s/appScreenshotSets'
                     % self.LOC)] = _data([])
        with self.assertRaises(Fail) as ctx:
            self.submit(fake, apply=True)
        self.assertIn('APP_IPHONE_67', str(ctx.exception))

    def test_unknown_version(self) -> None:
        fake = FakeASC(self.routes())
        with self.assertRaises(Fail):
            self.submit(fake, apply=True, version='9.9.9')


class PrepareFlowTest(unittest.TestCase):
    NOTES = 'Fixed the map. Café menu.'

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.notes_file = os.path.join(self._tmp.name, 'wn.txt')
        Path(self.notes_file).write_text(self.NOTES + '\n', encoding='utf-8')

    def routes(self, existing: list[dict]) -> dict:
        routes = {
            ('GET', '/v1/apps/%s/appStoreVersions' % APP): _data(existing),
            ('GET', '/v1/builds'): _data([{
                'id': 'b1', 'type': 'builds', 'attributes': {
                    'version': '1777777777', 'processingState': 'VALID',
                    'usesNonExemptEncryption': False, 'expired': False}}]),
        }
        for v in existing:
            routes[('GET', '/v1/appStoreVersions/%s/appStoreVersionLocalizations'
                    % v['id'])] = _data([{'id': 'loc-' + v['id'], 'attributes': {
                        'locale': 'en-CA', 'whatsNew': 'old'}}])
            routes[('GET', '/v1/appStoreVersions/%s/build' % v['id'])] = {'data': None}
            routes[('GET', '/v1/appStoreVersions/%s/appStoreVersionPhasedRelease'
                    % v['id'])] = {'data': {'id': 'ph1', 'type':
                                            'appStoreVersionPhasedReleases'}}
        return routes

    def prepare(self, fake: FakeASC, apply: bool, version: str = '1.4.1',
                notes_file: str | None = None, wait: int = 0):
        args = mock.Mock(version=version, build='1777777777', apply=apply, wait=wait,
                         whats_new_file=notes_file or self.notes_file)
        with mock.patch.object(asc_store, 'api', fake), \
                mock.patch.object(asc_store.time, 'sleep'):
            return _run(asc_store.cmd_prepare, args)

    def test_dry_run_on_an_editable_version_plans_every_write(self) -> None:
        editable = _version('1.4.1', 'PREPARE_FOR_SUBMISSION', 'ver1')
        editable['attributes']['releaseType'] = 'MANUAL'
        fake = FakeASC(self.routes([editable]))
        _, out = self.prepare(fake, apply=False)
        self.assertEqual(fake.writes(), [])
        for planned in ('build', 'releaseType', 'phased', 'whatsNew', 'DRY RUN'):
            self.assertIn(planned, out)

    def test_dry_run_with_no_editable_version_plans_the_create(self) -> None:
        live = _version('1.4.0', 'READY_FOR_SALE', 'ver0')
        fake = FakeASC(self.routes([live]))
        _, out = self.prepare(fake, apply=False)
        self.assertEqual(fake.writes(), [])
        self.assertIn('1.4.1', out)
        self.assertIn('create', out)

    def test_apply_on_an_editable_version(self) -> None:
        editable = _version('1.4.1', 'PREPARE_FOR_SUBMISSION', 'ver1')
        editable['attributes']['releaseType'] = 'MANUAL'
        routes = self.routes([editable])
        routes[('PATCH', '/v1/appStoreVersions/ver1/relationships/build')] = {}
        routes[('PATCH', '/v1/appStoreVersions/ver1')] = {}
        routes[('DELETE', '/v1/appStoreVersionPhasedReleases/ph1')] = None
        routes[('PATCH', '/v1/appStoreVersionLocalizations/loc-ver1')] = {}
        fake = FakeASC(routes)
        self.prepare(fake, apply=True)
        self.assertEqual(fake.writes(), [
            ('PATCH', '/v1/appStoreVersions/ver1/relationships/build',
             {'data': {'type': 'builds', 'id': 'b1'}}),
            ('PATCH', '/v1/appStoreVersions/ver1', {'data': {
                'type': 'appStoreVersions', 'id': 'ver1',
                'attributes': {'releaseType': 'AFTER_APPROVAL'}}}),
            ('DELETE', '/v1/appStoreVersionPhasedReleases/ph1', None),
            ('PATCH', '/v1/appStoreVersionLocalizations/loc-ver1', {'data': {
                'type': 'appStoreVersionLocalizations', 'id': 'loc-ver1',
                'attributes': {'whatsNew': self.NOTES}}}),
        ])

    def test_apply_creates_the_version_first(self) -> None:
        live = _version('1.4.0', 'READY_FOR_SALE', 'ver0')
        new = _version('1.4.1', 'PREPARE_FOR_SUBMISSION', 'ver1')
        routes = self.routes([live])
        routes.update(self.routes([new]))  # the new version's own reads
        routes[('GET', '/v1/apps/%s/appStoreVersions' % APP)] = _data([live])
        routes[('POST', '/v1/appStoreVersions')] = {'data': new}
        routes[('PATCH', '/v1/appStoreVersions/ver1/relationships/build')] = {}
        routes[('DELETE', '/v1/appStoreVersionPhasedReleases/ph1')] = None
        routes[('PATCH', '/v1/appStoreVersionLocalizations/loc-ver1')] = {}
        fake = FakeASC(routes)
        self.prepare(fake, apply=True)
        first = fake.writes()[0]
        self.assertEqual(first[:2], ('POST', '/v1/appStoreVersions'))
        self.assertEqual(first[2], {'data': {
            'type': 'appStoreVersions',
            'attributes': {'platform': 'IOS', 'versionString': '1.4.1',
                           'releaseType': 'AFTER_APPROVAL'},
            'relationships': {'app': {'data': {'type': 'apps', 'id': APP}}}}})

    def test_second_run_after_apply_has_nothing_to_do(self) -> None:
        editable = _version('1.4.1', 'PREPARE_FOR_SUBMISSION', 'ver1')
        routes = self.routes([editable])
        routes[('GET', '/v1/appStoreVersions/ver1/build')] = {
            'data': {'id': 'b1', 'type': 'builds'}}
        routes[('GET', '/v1/appStoreVersions/ver1/appStoreVersionPhasedRelease')] = {
            'data': None}
        routes[('GET', '/v1/appStoreVersions/ver1/appStoreVersionLocalizations')] = _data(
            [{'id': 'loc-ver1', 'attributes': {'locale': 'en-CA',
                                               'whatsNew': self.NOTES}}])
        fake = FakeASC(routes)
        _, out = self.prepare(fake, apply=True)
        self.assertEqual(fake.writes(), [])
        self.assertIn('No changes', out)

    def test_refuses_an_emoji_before_any_write(self) -> None:
        Path(self.notes_file).write_text('Shiny \U0001F680\n', encoding='utf-8')
        fake = FakeASC(self.routes([_version('1.4.0', 'READY_FOR_SALE', 'ver0')]))
        with self.assertRaises(Fail):
            self.prepare(fake, apply=True)
        self.assertEqual(fake.writes(), [])

    def test_refuses_a_non_english_locale_before_any_write(self) -> None:
        editable = _version('1.4.1', 'PREPARE_FOR_SUBMISSION', 'ver1')
        routes = self.routes([editable])
        routes[('GET', '/v1/appStoreVersions/ver1/appStoreVersionLocalizations')] = _data(
            [{'id': 'a', 'attributes': {'locale': 'en-CA', 'whatsNew': ''}},
             {'id': 'b', 'attributes': {'locale': 'fr-CA', 'whatsNew': ''}}])
        fake = FakeASC(routes)
        with self.assertRaises(Fail) as ctx:
            self.prepare(fake, apply=True)
        self.assertIn('fr-CA', str(ctx.exception))
        self.assertEqual(fake.writes(), [])

    def test_refuses_a_version_that_already_exists_and_is_not_editable(self) -> None:
        live = _version('1.4.0', 'READY_FOR_SALE', 'ver0')
        fake = FakeASC(self.routes([live]))
        with self.assertRaises(Fail):
            self.prepare(fake, apply=False, version='1.4.0')

    def test_prepare_still_refuses_a_version_waiting_in_an_unsubmitted_submission(self) -> None:
        pending = _version('1.4.1', 'READY_FOR_REVIEW', 'ver1')
        fake = FakeASC(self.routes([pending]))
        with self.assertRaises(Fail) as ctx:
            self.prepare(fake, apply=True)
        self.assertIn('READY_FOR_REVIEW', str(ctx.exception))
        self.assertEqual(fake.writes(), [])

    def test_waits_for_the_build_to_become_valid(self) -> None:
        editable = _version('1.4.1', 'PREPARE_FOR_SUBMISSION', 'ver1')
        routes = self.routes([editable])
        states = iter(['PROCESSING', 'PROCESSING', 'VALID'])

        def builds(_body):
            return _data([{'id': 'b1', 'type': 'builds', 'attributes': {
                'version': '1777777777', 'processingState': next(states),
                'usesNonExemptEncryption': False}}])

        routes[('GET', '/v1/builds')] = builds
        fake = FakeASC(routes)
        _, out = self.prepare(fake, apply=False, wait=120)
        self.assertEqual(fake.writes(), [])
        self.assertIn('VALID', out)

    def test_gives_up_when_the_build_never_becomes_valid(self) -> None:
        editable = _version('1.4.1', 'PREPARE_FOR_SUBMISSION', 'ver1')
        routes = self.routes([editable])
        routes[('GET', '/v1/builds')] = _data([{'id': 'b1', 'type': 'builds', 'attributes': {
            'version': '1777777777', 'processingState': 'PROCESSING'}}])
        fake = FakeASC(routes)
        fake_now = iter(range(0, 10000, 31))
        with mock.patch.object(asc_store.time, 'time', lambda: next(fake_now)), \
                self.assertRaises(Fail) as ctx:
            self.prepare(fake, apply=False, wait=60)
        self.assertIn('PROCESSING', str(ctx.exception))

    def test_a_failed_build_stops_at_once(self) -> None:
        editable = _version('1.4.1', 'PREPARE_FOR_SUBMISSION', 'ver1')
        routes = self.routes([editable])
        routes[('GET', '/v1/builds')] = _data([{'id': 'b1', 'type': 'builds', 'attributes': {
            'version': '1777777777', 'processingState': 'INVALID'}}])
        fake = FakeASC(routes)
        with self.assertRaises(Fail) as ctx:
            self.prepare(fake, apply=False, wait=1800)
        self.assertIn('INVALID', str(ctx.exception))


def _png(path: Path, width: int, height: int) -> None:
    """Just enough of a PNG for asc_store.png_size: signature and IHDR."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' +
                     struct.pack('>II', width, height) + b'\x08\x06\x00\x00\x00')


class ScreenshotsFlowTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        _png(self.root / 'watch-46' / '01_map.png', 416, 496)
        _png(self.root / 'ios-iphone-69' / '01_map.png', 1320, 2868)

    def routes(self, versions: list[dict], locales: list[str] = ['en-CA']) -> dict:
        return {
            ('GET', '/v1/apps/%s/appStoreVersions' % APP): _data(versions),
            ('GET', '/v1/appStoreVersions/%s/appStoreVersionLocalizations'
             % versions[0]['id']): _data(
                [{'id': 'loc-' + l, 'attributes': {'locale': l}} for l in locales]),
            ('GET', '/v1/appStoreVersionLocalizations/loc-en-CA/appScreenshotSets'): _data([]),
        }

    def run_screenshots(self, fake: FakeASC, apply: bool = False):
        args = mock.Mock(dir=str(self.root), apply=apply, replace=False)
        with mock.patch.object(asc_store, 'api', fake):
            return _run(asc_store.cmd_screenshots, args)

    def test_dry_run_plans_the_watch_set(self) -> None:
        fake = FakeASC(self.routes([_version('1.4.1', 'PREPARE_FOR_SUBMISSION', 'ver1')]))
        _, out = self.run_screenshots(fake)
        self.assertEqual(fake.writes(), [])
        self.assertIn('create APP_WATCH_SERIES_10', out)
        self.assertIn('upload 416x496', out)
        self.assertIn('upload 1320x2868', out)

    def test_refuses_more_than_one_locale(self) -> None:
        fake = FakeASC(self.routes([_version('1.4.1', 'PREPARE_FOR_SUBMISSION', 'ver1')],
                                   ['en-CA', 'en-US']))
        with self.assertRaises(Fail) as ctx:
            self.run_screenshots(fake)
        self.assertIn('exactly one', str(ctx.exception))

    def test_refuses_a_non_english_locale(self) -> None:
        fake = FakeASC(self.routes([_version('1.4.1', 'PREPARE_FOR_SUBMISSION', 'ver1')],
                                   ['fr-CA']))
        with self.assertRaises(Fail) as ctx:
            self.run_screenshots(fake)
        self.assertIn('fr-CA', str(ctx.exception))

    def test_wrong_size_is_refused_before_any_request(self) -> None:
        _png(self.root / 'watch-46' / '02_bad.png', 400, 400)
        fake = FakeASC({})
        with self.assertRaises(Fail) as ctx:
            self.run_screenshots(fake)
        self.assertIn('02_bad.png', str(ctx.exception))
        self.assertEqual(fake.calls, [])

    def test_without_an_editable_version_dry_run_previews_and_apply_refuses(self) -> None:
        live = _version('1.4.0', 'READY_FOR_SALE', 'ver0')
        _, out = self.run_screenshots(FakeASC(self.routes([live])))
        self.assertIn('previewing against 1.4.0', out)
        fake = FakeASC(self.routes([live]))
        with self.assertRaises(Fail) as ctx:
            self.run_screenshots(fake, apply=True)
        self.assertIn('No editable App Store version', str(ctx.exception))
        self.assertEqual(fake.writes(), [])


class StateLabelTest(unittest.TestCase):
    def test_shows_both_names_when_they_differ(self) -> None:
        v = {'attributes': {'appVersionState': 'READY_FOR_DISTRIBUTION',
                            'appStoreState': 'READY_FOR_SALE'}}
        self.assertEqual(asc_store.state_label(v),
                         'READY_FOR_DISTRIBUTION / READY_FOR_SALE')
        self.assertEqual(asc_store.state_label(_version('1.4.1', 'REJECTED')), 'REJECTED')


class UploadScreenshotPollTest(unittest.TestCase):
    """Apple sometimes answers HTTP 500 for a screenshot it has only just received.
    The wait for processing must ride that out instead of stopping the release."""

    SHOT = '/v1/appScreenshots/shot1'

    def _shot(self, state: str) -> dict:
        return {'data': {'id': 'shot1', 'type': 'appScreenshots',
                         'attributes': {'assetDeliveryState': {'state': state}}}}

    def _run_upload(self, reads: list) -> tuple:
        seq = list(reads)

        def read(_body):
            nxt = seq.pop(0)
            if isinstance(nxt, Exception):
                raise nxt
            return nxt

        fake = FakeASC({
            ('POST', '/v1/appScreenshots'):
                {'data': {'id': 'shot1', 'type': 'appScreenshots',
                          'attributes': {'uploadOperations': []}}},
            ('PATCH', self.SHOT): self._shot('UPLOAD_COMPLETE'),
            ('GET', self.SHOT): read,
        })
        with tempfile.TemporaryDirectory() as tmp:
            png = Path(tmp) / '01_map.png'
            png.write_bytes(b'png')
            with mock.patch.object(asc_store, 'api', fake), \
                    mock.patch.object(asc_store.time, 'sleep'):
                cur, out = _run(lambda a: asc_store.upload_screenshot('set1', str(png), 'md5'),
                                None)
        return cur, out, fake

    def test_a_server_error_while_waiting_is_retried(self) -> None:
        err = asc_store.APIError('GET', self.SHOT, 500, None)
        cur, out, fake = self._run_upload([err, err, self._shot('COMPLETE')])
        self.assertEqual(asc_store.shot_state(cur), 'COMPLETE')
        self.assertEqual(len([c for c in fake.calls if c[0] == 'GET']), 3)
        self.assertIn('HTTP 500', out)

    def test_a_client_error_while_waiting_still_stops(self) -> None:
        err = asc_store.APIError('GET', self.SHOT, 404, None)
        with self.assertRaises(asc_store.APIError):
            self._run_upload([err])

    def test_server_errors_past_the_deadline_stop(self) -> None:
        err = asc_store.APIError('GET', self.SHOT, 500, None)
        clock = iter([0, 0] + [1000] * 10)
        with mock.patch.object(asc_store.time, 'time', lambda: next(clock)):
            with self.assertRaises(asc_store.APIError):
                self._run_upload([err, err, err])


if __name__ == '__main__':
    unittest.main()
