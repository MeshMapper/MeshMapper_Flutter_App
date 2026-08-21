import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/debug_file_logger.dart';

/// Debug log FILES are uploaded verbatim with bug reports and debug logging is
/// on in release builds, so the file writer scrubs credential shapes even when
/// a caller was careless.
void main() {
  test('redacts a bearer token', () {
    expect(
      DebugFileLogger.scrubSecrets(
          'POST with Authorization: Bearer ${'a' * 64}'),
      'POST with Authorization: Bearer <redacted>',
    );
  });

  test('redacts a token JSON field', () {
    expect(
      DebugFileLogger.scrubSecrets('body {"ok":true,"token":"${'b' * 64}"}'),
      contains('"token":"<redacted>"'),
    );
    expect(
      DebugFileLogger.scrubSecrets('body {"ok":true,"token":"${'b' * 64}"}'),
      isNot(contains('b' * 64)),
    );
  });

  test('redacts code, code_verifier and code_challenge query parameters', () {
    final scrubbed = DebugFileLogger.scrubSecrets(
        'callback?code=${'c' * 64}&code_verifier=${'d' * 43}&state=xyz');
    expect(scrubbed, contains('code=<redacted>'));
    expect(scrubbed, contains('code_verifier=<redacted>'));
    expect(scrubbed, isNot(contains('c' * 64)));
    expect(scrubbed, isNot(contains('d' * 43)));
  });

  test('redacts an unquoted token in a rendered map', () {
    // Dart's Map.toString() has neither quotes nor `=`, and
    // debug_submit_service.dart logs a decoded response body exactly this way
    // ("Full response: $data"). The quoted-JSON pattern never sees that shape.
    final scrubbed = DebugFileLogger.scrubSecrets(
        'Full response: {ok: true, token: ${'f' * 64}}');
    expect(scrubbed, contains('token: <redacted>'));
    expect(scrubbed, isNot(contains('f' * 64)));
  });

  test('redacts the X-MM-App-Token header shape', () {
    final scrubbed =
        DebugFileLogger.scrubSecrets('X-MM-App-Token: ${'a1b2c3d4' * 8}');
    expect(scrubbed, 'X-MM-App-Token: <redacted>');
  });

  test('leaves a short token value alone', () {
    expect(DebugFileLogger.scrubSecrets('token: abc'), 'token: abc');
  });

  test('leaves a wire tag untouched', () {
    // MM:<10 base64url> is not a secret and shows up constantly in TX logs.
    const line = '[PING] on-air body MM:YVNPAr5OIw';
    expect(DebugFileLogger.scrubSecrets(line), line);
  });

  test('leaves ordinary log lines untouched', () {
    const line = '[CONN] Frame received (7 bytes): 13 00 80 00 00 00';
    expect(DebugFileLogger.scrubSecrets(line), line);
  });

  test('does not eat short values that merely look similar', () {
    expect(DebugFileLogger.scrubSecrets('mode=1&code=7'), 'mode=1&code=7');
  });
}
