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

  test('leaves ordinary log lines untouched', () {
    const line = '[CONN] Frame received (7 bytes): 13 00 80 00 00 00';
    expect(DebugFileLogger.scrubSecrets(line), line);
  });

  test('does not eat short values that merely look similar', () {
    expect(DebugFileLogger.scrubSecrets('mode=1&code=7'), 'mode=1&code=7');
  });
}
