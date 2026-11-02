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

# play_store.py lives in the repo root, next to Build.sh.
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import play_store  # noqa: E402

PlayError = play_store.PlayError
EDIT = 'E1'


def _parse(*argv: str):
    return play_store.build_parser().parse_args(list(argv))


def _run(fn, args) -> tuple:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        result = fn(args)
    return result, out.getvalue()


def _png(path: Path, width: int, height: int, extra: bytes = b'') -> None:
    """Just enough of a PNG for play_store.png_info: signature and IHDR."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' +
                     struct.pack('>II', width, height) + b'\x08\x06\x00\x00\x00' + extra)


class DefaultLanguageTest(unittest.TestCase):
    def test_uses_the_default_language_of_the_app(self) -> None:
        self.assertEqual(play_store.default_language({'defaultLanguage': 'en-US'}, None),
                         'en-US')

    def test_override_wins(self) -> None:
        self.assertEqual(play_store.default_language({'defaultLanguage': 'en-US'}, 'fr-CA'),
                         'fr-CA')

    def test_missing_default_language_is_an_error(self) -> None:
        with self.assertRaises(PlayError):
            play_store.default_language({}, None)


class CheckScreenshotSizeTest(unittest.TestCase):
    def test_accepts_a_1080x1920_phone_screenshot(self) -> None:
        play_store.check_screenshot_size(1080, 1920)

    def test_accepts_the_limits_and_landscape(self) -> None:
        for w, h in ((320, 640), (3840, 1920), (1920, 1080), (320, 320)):
            with self.subTest(size=(w, h)):
                play_store.check_screenshot_size(w, h)

    def test_rejects_a_ratio_over_two(self) -> None:
        with self.assertRaises(PlayError):
            play_store.check_screenshot_size(1080, 2400)

    def test_rejects_a_side_under_320(self) -> None:
        with self.assertRaises(PlayError):
            play_store.check_screenshot_size(300, 600)

    def test_rejects_a_side_over_3840(self) -> None:
        with self.assertRaises(PlayError):
            play_store.check_screenshot_size(4000, 2000)


class ReadNotesTest(unittest.TestCase):
    def write(self, text: str) -> str:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = os.path.join(tmp.name, 'notes.txt')
        Path(path).write_text(text, encoding='utf-8')
        return path

    def test_501_characters_are_refused(self) -> None:
        with self.assertRaises(PlayError) as ctx:
            play_store.read_notes(self.write('x' * 501), 'en-US')
        self.assertIn('501', str(ctx.exception))

    def test_exactly_500_characters_pass(self) -> None:
        notes = play_store.read_notes(self.write('x' * 500), 'en-US')
        self.assertEqual(notes, [{'language': 'en-US', 'text': 'x' * 500}])

    def test_surrounding_whitespace_is_not_counted(self) -> None:
        notes = play_store.read_notes(self.write('\n' + 'x' * 500 + '\n\n'), 'en-US')
        self.assertEqual(len(notes[0]['text']), 500)

    def test_empty_file_is_refused(self) -> None:
        with self.assertRaises(PlayError):
            play_store.read_notes(self.write('  \n'), 'en-US')

    def test_missing_file_is_refused(self) -> None:
        with self.assertRaises(PlayError):
            play_store.read_notes('/nonexistent/notes.txt', 'en-US')

    def test_no_notes_file_means_no_notes(self) -> None:
        self.assertIsNone(play_store.read_notes(None, 'en-US'))


class CheckLanguagesTest(unittest.TestCase):
    def test_accepts_english(self) -> None:
        play_store.check_languages(['en-US'])
        play_store.check_languages(['en-US', 'en-GB'])
        play_store.check_languages([])

    def test_names_the_first_non_english_language(self) -> None:
        with self.assertRaises(PlayError) as ctx:
            play_store.check_languages(['en-US', 'fr-CA', 'de-DE'])
        self.assertIn('fr-CA', str(ctx.exception))
        self.assertNotIn('de-DE', str(ctx.exception))


class ReleaseEnvTest(unittest.TestCase):
    def test_parses_exports_quotes_and_comments(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, 'env')
            Path(path).write_text(
                '# comment\n\nPLAY_SERVICE_ACCOUNT_JSON=/k/key.json\n'
                'export PLAY_PACKAGE_NAME="x.y.z"\nOTHER=\'x y\'\nPLAIN=value # trailing\n',
                encoding='utf-8')
            with mock.patch.object(play_store, 'RELEASE_ENV', path), \
                    mock.patch.dict(os.environ, {}, clear=True):
                values = play_store.load_release_env()
        self.assertEqual(values['PLAY_SERVICE_ACCOUNT_JSON'], '/k/key.json')
        self.assertEqual(values['PLAY_PACKAGE_NAME'], 'x.y.z')
        self.assertEqual(values['OTHER'], 'x y')
        self.assertEqual(values['PLAIN'], 'value')

    def test_environment_wins(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, 'env')
            Path(path).write_text('PLAY_PACKAGE_NAME=from.file\n', encoding='utf-8')
            with mock.patch.object(play_store, 'RELEASE_ENV', path), \
                    mock.patch.dict(os.environ, {'PLAY_PACKAGE_NAME': 'from.env'}, clear=True):
                values = play_store.load_release_env()
        self.assertEqual(values['PLAY_PACKAGE_NAME'], 'from.env')

    def test_defaults(self) -> None:
        self.assertTrue(play_store.RELEASE_ENV.endswith('.meshmapper_release.env'))
        self.assertEqual(play_store.DEFAULT_PACKAGE, 'net.meshmapper.app')
        with mock.patch.object(play_store, 'ENV', {}):
            self.assertEqual(play_store.package_name(), 'net.meshmapper.app')


class ParserTest(unittest.TestCase):
    def test_listing_is_gone(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            _parse('listing')

    def test_apply_and_validate_exclude_each_other(self) -> None:
        for argv in (('upload', '--track', 'production', '--apply', '--validate'),
                     ('screenshots', '--dir', '/x', '--apply', '--validate')):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit):
                _parse(*argv)

    def test_upload_language_defaults_to_the_app_default(self) -> None:
        self.assertIsNone(_parse('upload', '--track', 'production').lang)
        self.assertEqual(_parse('upload', '--track', 'production', '--lang', 'en-GB').lang,
                         'en-GB')


class FakePlay:
    """Stands in for play_store.PlayApi. Routes are keyed (method, path) with the
    full path (edit id included); a value is a response body, an exception to
    raise, or a callable taking the body."""

    client_email = 'play-publisher@example.test'
    package = 'net.meshmapper.app'

    def __init__(self, routes: dict | None = None) -> None:
        self.routes = {
            ('POST', '/edits'): {'id': EDIT},
            ('DELETE', '/edits/' + EDIT): {},
            ('GET', '/edits/%s/details' % EDIT): {'defaultLanguage': 'en-US'},
            ('GET', '/edits/%s/listings' % EDIT): {'listings': [
                {'language': 'en-US', 'title': 'MeshMapper'}]},
            ('GET', '/edits/%s/tracks' % EDIT): {'tracks': [
                {'track': 'production', 'releases': [
                    {'name': '1.4.0 (1789991039)', 'status': 'completed',
                     'versionCodes': ['1789991039']}]}]},
        }
        self.routes.update(routes or {})
        self.calls: list[tuple] = []

    def __call__(self, creds, package):
        return self

    def call(self, method, path, body=None, **kw):
        self.calls.append((method, path, body, kw))
        if (method, path) not in self.routes:
            raise AssertionError('unexpected call %s %s' % (method, path))
        res = self.routes[(method, path)]
        if isinstance(res, Exception):
            raise res
        return res(body) if callable(res) else res

    def paths(self) -> list[tuple]:
        return [(m, p) for m, p, _, _ in self.calls]

    def writes(self) -> list[tuple]:
        """Calls that change something, not counting opening and deleting the edit."""
        skip = {('POST', '/edits'), ('DELETE', '/edits/' + EDIT)}
        return [(m, p, b) for m, p, b, _ in self.calls if m != 'GET' and (m, p) not in skip]

    def committed(self) -> bool:
        return ('POST', '/edits/%s:commit' % EDIT) in self.paths()


class _Patched:
    """Swaps the API client and the credentials loader for FakePlay."""

    def __init__(self, fake: FakePlay) -> None:
        self.stack = contextlib.ExitStack()
        self.fake = fake

    def __enter__(self):
        self.stack.enter_context(mock.patch.object(play_store, 'PlayApi', self.fake))
        self.stack.enter_context(mock.patch.object(
            play_store, 'load_credentials',
            lambda: {'client_email': FakePlay.client_email}))
        return self

    def __exit__(self, *exc):
        return self.stack.__exit__(*exc)


class UploadFlowTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.notes = os.path.join(self._tmp.name, 'notes.txt')
        Path(self.notes).write_text('Faster map.\nFixes.', encoding='utf-8')

    def routes(self, extra: dict | None = None) -> dict:
        routes = {
            ('PUT', '/edits/%s/tracks/production' % EDIT): {},
            ('POST', '/edits/%s:validate' % EDIT): {'id': EDIT},
            ('POST', '/edits/%s:commit' % EDIT): {},
        }
        routes.update(extra or {})
        return routes

    def upload(self, fake: FakePlay, *flags: str, version_code: str = '1789991039'):
        args = _parse('upload', '--track', 'production', '--status', 'completed',
                      '--notes-file', self.notes, '--version-code', version_code, *flags)
        with _Patched(fake):
            return _run(play_store.cmd_upload, args)

    RELEASE = {'track': 'production', 'releases': [{
        'versionCodes': ['1789991039'], 'status': 'completed',
        'releaseNotes': [{'language': 'en-US', 'text': 'Faster map.\nFixes.'}]}]}

    def test_dry_run_writes_nothing_and_does_not_commit(self) -> None:
        fake = FakePlay(self.routes())
        _, out = self.upload(fake)
        self.assertEqual(fake.writes(), [])
        self.assertIn('Dry run', out)
        self.assertIn(('DELETE', '/edits/' + EDIT), fake.paths())

    def test_validate_stages_the_release_validates_and_never_commits(self) -> None:
        fake = FakePlay(self.routes())
        _, out = self.upload(fake, '--validate')
        self.assertEqual(fake.writes(), [
            ('PUT', '/edits/%s/tracks/production' % EDIT, self.RELEASE),
            ('POST', '/edits/%s:validate' % EDIT, None),
        ])
        self.assertFalse(fake.committed())
        self.assertEqual(fake.paths()[-1], ('DELETE', '/edits/' + EDIT))
        self.assertIn('validate: OK', out)
        self.assertIn('edit deleted', out)

    def test_apply_commits_and_does_not_validate(self) -> None:
        fake = FakePlay(self.routes())
        _, out = self.upload(fake, '--apply')
        self.assertEqual(fake.writes(), [
            ('PUT', '/edits/%s/tracks/production' % EDIT, self.RELEASE),
            ('POST', '/edits/%s:commit' % EDIT, None),
        ])
        self.assertNotIn(('DELETE', '/edits/' + EDIT), fake.paths())
        self.assertIn('Committed', out)

    def test_no_review_commits_without_sending_for_review(self) -> None:
        fake = FakePlay(self.routes())
        self.upload(fake, '--apply', '--no-review')
        commit = [kw for m, p, _, kw in fake.calls if p.endswith(':commit')][0]
        self.assertEqual(commit['query'], {'changesNotSentForReview': 'true'})

    def test_release_notes_use_the_default_language(self) -> None:
        fake = FakePlay(self.routes({
            ('GET', '/edits/%s/details' % EDIT): {'defaultLanguage': 'en-GB'},
            ('GET', '/edits/%s/listings' % EDIT): {'listings': [{'language': 'en-GB'}]}}))
        self.upload(fake, '--validate')
        put = [b for m, p, b, _ in fake.calls if m == 'PUT'][0]
        self.assertEqual(put['releases'][0]['releaseNotes'][0]['language'], 'en-GB')

    def test_lang_flag_overrides_the_default_language(self) -> None:
        fake = FakePlay(self.routes())
        self.upload(fake, '--validate', '--lang', 'en-CA')
        put = [b for m, p, b, _ in fake.calls if m == 'PUT'][0]
        self.assertEqual(put['releases'][0]['releaseNotes'][0]['language'], 'en-CA')

    def test_a_non_english_listing_stops_everything_before_any_write(self) -> None:
        fake = FakePlay(self.routes({
            ('GET', '/edits/%s/listings' % EDIT): {'listings': [
                {'language': 'en-US'}, {'language': 'fr-CA'}]}}))
        with self.assertRaises(PlayError) as ctx:
            self.upload(fake, '--apply')
        self.assertIn('fr-CA', str(ctx.exception))
        self.assertEqual(fake.writes(), [])
        self.assertIn(('DELETE', '/edits/' + EDIT), fake.paths())

    def test_a_validate_failure_leaves_nothing_behind(self) -> None:
        err = play_store.ApiError(400, 'bad release', 'Validating')
        fake = FakePlay(self.routes({('POST', '/edits/%s:validate' % EDIT): err}))
        with self.assertRaises(play_store.ApiError):
            self.upload(fake, '--validate')
        self.assertFalse(fake.committed())
        self.assertEqual(fake.paths()[-1], ('DELETE', '/edits/' + EDIT))

    def test_notes_over_the_limit_are_refused_before_any_request(self) -> None:
        Path(self.notes).write_text('x' * 501, encoding='utf-8')
        fake = FakePlay(self.routes())
        with self.assertRaises(PlayError):
            self.upload(fake, '--apply')
        self.assertEqual(fake.calls, [])

    def test_a_fraction_needs_in_progress(self) -> None:
        fake = FakePlay(self.routes())
        with self.assertRaises(PlayError):
            self.upload(fake, '--fraction', '0.2')
        self.assertEqual(fake.calls, [])


class ScreenshotsFlowTest(unittest.TestCase):
    PHONE = '/edits/%s/listings/en-US/phoneScreenshots' % EDIT

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.shots = self.root / 'android-phone'
        # Written out of order on purpose: uploads must follow the file names.
        for name in ('03_history.png', '01_map.png', '02_log.png'):
            _png(self.shots / name, 1080, 1920, extra=name.encode())

    def routes(self, extra: dict | None = None) -> dict:
        routes = {
            ('GET', self.PHONE): {'images': []},
            ('DELETE', self.PHONE): {},
            ('POST', self.PHONE): {},
            ('POST', '/edits/%s:validate' % EDIT): {'id': EDIT},
            ('POST', '/edits/%s:commit' % EDIT): {},
        }
        routes.update(extra or {})
        return routes

    def screenshots(self, fake: FakePlay, *flags: str):
        args = _parse('screenshots', '--dir', str(self.root), *flags)
        with _Patched(fake):
            return _run(play_store.cmd_screenshots, args)

    def uploaded(self, fake: FakePlay) -> list[str]:
        return [os.path.basename(kw['upload_path']) for m, p, _, kw in fake.calls
                if (m, p) == ('POST', self.PHONE)]

    def test_dry_run_plans_the_replacement_and_writes_nothing(self) -> None:
        fake = FakePlay(self.routes())
        _, out = self.screenshots(fake)
        self.assertEqual(fake.writes(), [])
        self.assertIn('Dry run', out)
        self.assertIn('01_map.png', out)

    def test_validate_replaces_in_name_order_validates_and_never_commits(self) -> None:
        fake = FakePlay(self.routes())
        _, out = self.screenshots(fake, '--validate')
        self.assertEqual([(m, p) for m, p, _ in fake.writes()], [
            ('DELETE', self.PHONE),
            ('POST', self.PHONE), ('POST', self.PHONE), ('POST', self.PHONE),
            ('POST', '/edits/%s:validate' % EDIT),
        ])
        self.assertEqual(self.uploaded(fake), ['01_map.png', '02_log.png', '03_history.png'])
        self.assertFalse(fake.committed())
        self.assertEqual(fake.paths()[-1], ('DELETE', '/edits/' + EDIT))
        self.assertIn('validate: OK', out)
        self.assertIn('edit deleted', out)

    def test_uploads_are_png(self) -> None:
        fake = FakePlay(self.routes())
        self.screenshots(fake, '--validate')
        kw = [kw for m, p, _, kw in fake.calls if (m, p) == ('POST', self.PHONE)][0]
        self.assertEqual(kw['content_type'], 'image/png')

    def test_apply_replaces_and_commits(self) -> None:
        fake = FakePlay(self.routes())
        _, out = self.screenshots(fake, '--apply')
        self.assertEqual(fake.writes()[0][:2], ('DELETE', self.PHONE))
        self.assertEqual(self.uploaded(fake), ['01_map.png', '02_log.png', '03_history.png'])
        self.assertTrue(fake.committed())
        self.assertNotIn(('POST', '/edits/%s:validate' % EDIT), fake.paths())
        self.assertIn('Committed', out)

    def test_apply_does_nothing_when_play_already_matches(self) -> None:
        remote = [{'sha1': play_store.sha1_file(str(self.shots / n))}
                  for n in ('01_map.png', '02_log.png', '03_history.png')]
        fake = FakePlay(self.routes({('GET', self.PHONE): {'images': remote}}))
        _, out = self.screenshots(fake, '--apply')
        self.assertEqual(fake.writes(), [])
        self.assertFalse(fake.committed())
        self.assertIn('already matches', out)

    def test_validate_still_stages_when_play_already_matches(self) -> None:
        remote = [{'sha1': play_store.sha1_file(str(self.shots / n))}
                  for n in ('01_map.png', '02_log.png', '03_history.png')]
        fake = FakePlay(self.routes({('GET', self.PHONE): {'images': remote}}))
        _, out = self.screenshots(fake, '--validate')
        self.assertIn(('POST', '/edits/%s:validate' % EDIT), fake.paths())
        self.assertIn('validate: OK', out)

    def test_a_non_english_listing_stops_everything_before_any_write(self) -> None:
        fake = FakePlay(self.routes({
            ('GET', '/edits/%s/listings' % EDIT): {'listings': [
                {'language': 'en-US'}, {'language': 'fr-CA'}]}}))
        with self.assertRaises(PlayError) as ctx:
            self.screenshots(fake, '--apply')
        self.assertIn('fr-CA', str(ctx.exception))
        self.assertEqual(fake.writes(), [])

    def test_fewer_than_two_files_is_refused_before_any_request(self) -> None:
        (self.shots / '03_history.png').unlink()
        (self.shots / '02_log.png').unlink()
        fake = FakePlay(self.routes())
        with self.assertRaises(PlayError) as ctx:
            self.screenshots(fake, '--apply')
        self.assertIn('2-8', str(ctx.exception))
        self.assertEqual(fake.calls, [])

    def test_more_than_eight_files_is_refused(self) -> None:
        for i in range(4, 10):
            _png(self.shots / ('%02d_x.png' % i), 1080, 1920)
        fake = FakePlay(self.routes())
        with self.assertRaises(PlayError):
            self.screenshots(fake, '--apply')
        self.assertEqual(fake.calls, [])

    def test_a_wrong_size_is_refused_before_any_request(self) -> None:
        _png(self.shots / '04_bad.png', 1080, 2400)
        fake = FakePlay(self.routes())
        with self.assertRaises(PlayError) as ctx:
            self.screenshots(fake, '--apply')
        self.assertIn('04_bad.png', str(ctx.exception))
        self.assertEqual(fake.calls, [])

    def test_a_file_that_is_not_a_png_is_refused(self) -> None:
        (self.shots / '04_junk.png').write_bytes(b'not a png at all, just text')
        fake = FakePlay(self.routes())
        with self.assertRaises(PlayError) as ctx:
            self.screenshots(fake, '--apply')
        self.assertIn('04_junk.png', str(ctx.exception))

    def test_a_missing_android_phone_folder_is_refused(self) -> None:
        args = _parse('screenshots', '--dir', str(self.root / 'nope'))
        with self.assertRaises(PlayError) as ctx:
            with _Patched(FakePlay()):
                _run(play_store.cmd_screenshots, args)
        self.assertIn('android-phone', str(ctx.exception))


class StatusAndPromoteTest(unittest.TestCase):
    def test_status_is_read_only(self) -> None:
        fake = FakePlay({
            ('GET', '/tracks/production/releases'): {'releases': []},
            ('GET', '/edits/%s/bundles' % EDIT): {'bundles': [{'versionCode': 1789991039}]},
        })
        with _Patched(fake):
            _, out = _run(play_store.cmd_status, _parse('status'))
        self.assertEqual(fake.writes(), [])
        self.assertFalse(fake.committed())
        self.assertIn('defaultLanguage: en-US', out)
        self.assertIn('1.4.0 (1789991039)', out)
        self.assertIn('en-US', out)

    def test_promote_dry_run_writes_nothing_and_apply_commits(self) -> None:
        tracks = {'tracks': [
            {'track': 'beta', 'releases': [{'name': '1.4.1 (1790000000)', 'status': 'completed',
                                            'versionCodes': ['1790000000']}]},
            {'track': 'production', 'releases': []}]}
        routes = {('GET', '/edits/%s/tracks' % EDIT): tracks,
                  ('PUT', '/edits/%s/tracks/production' % EDIT): {},
                  ('POST', '/edits/%s:commit' % EDIT): {}}
        fake = FakePlay(routes)
        with _Patched(fake):
            _run(play_store.cmd_promote, _parse('promote', '--from', 'beta', '--to', 'production'))
        self.assertEqual(fake.writes(), [])
        fake = FakePlay(routes)
        with _Patched(fake):
            _run(play_store.cmd_promote,
                 _parse('promote', '--from', 'beta', '--to', 'production', '--apply'))
        self.assertTrue(fake.committed())
        put = [b for m, p, b, _ in fake.calls if m == 'PUT'][0]
        self.assertEqual(put['releases'][0]['versionCodes'], ['1790000000'])


class ExplainApiErrorTest(unittest.TestCase):
    def test_permission_hint_names_the_production_permissions(self) -> None:
        hint = play_store.explain_api_error(play_store.ApiError(403, 'forbidden', 'x'))
        self.assertIn('Release to production', hint)
        self.assertIn('Manage store presence', hint)


if __name__ == '__main__':
    unittest.main()
