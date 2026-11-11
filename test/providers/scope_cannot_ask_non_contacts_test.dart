import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';

/// The flag flipping on drops one warning in the error log, once per
/// connection: `AppStateProvider` cannot be built in these tests (it needs a
/// live Bluetooth service, Hive boxes, and a dozen other services), so this
/// exercises the pure once-per-connection decision `_wireScopeCannotAskNonContacts`
/// makes at the call site instead.
void main() {
  test('the first flip on a connection should log', () {
    expect(
        shouldLogScopeContactsFull(alreadyLoggedThisConnection: false),
        isTrue);
  });

  test('a later flip on the same connection should not log again', () {
    expect(
        shouldLogScopeContactsFull(alreadyLoggedThisConnection: true),
        isFalse);
  });
}
