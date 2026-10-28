import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';

/// The Log tab's red dot used to mean "the error log is not empty", so
/// reading every error left it on and only Clear all logs (which also wipes
/// the ping log) removed it (#617). It now means an error logged after the
/// last time the Errors tab was on screen.
void main() {
  test('no errors, no dot', () {
    expect(errorLogHasUnseen(hasEntries: false, logged: 0, seen: 0), isFalse);
  });

  test('errors never seen show the dot', () {
    expect(errorLogHasUnseen(hasEntries: true, logged: 2, seen: 0), isTrue);
  });

  test('errors seen up to the newest clear it', () {
    expect(errorLogHasUnseen(hasEntries: true, logged: 2, seen: 2), isFalse);
  });

  test('a newer error brings it back', () {
    expect(errorLogHasUnseen(hasEntries: true, logged: 3, seen: 2), isTrue);
  });

  test('a cleared log shows no dot whatever the counts', () {
    // Clear all logs empties the list; the next error logged is new again.
    expect(errorLogHasUnseen(hasEntries: false, logged: 5, seen: 2), isFalse);
  });
}
