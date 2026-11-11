import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';

/// The stuck-timer watchdog must not name a window that is merely waiting
/// for its next 500 ms tick to clear it.
void main() {
  final deadline = DateTime(2026, 10, 6, 12);

  test('not running is never stuck', () {
    expect(
        countdownLooksStuck(
            isRunning: false,
            endTime: deadline,
            now: deadline.add(const Duration(minutes: 5))),
        isFalse);
  });

  test('100 ms past the deadline is not stuck yet', () {
    expect(
        countdownLooksStuck(
            isRunning: true,
            endTime: deadline,
            now: deadline.add(const Duration(milliseconds: 100))),
        isFalse);
  });

  test('before the deadline is not stuck', () {
    expect(
        countdownLooksStuck(
            isRunning: true,
            endTime: deadline,
            now: deadline.subtract(const Duration(seconds: 1))),
        isFalse);
  });

  test('past the grace is stuck', () {
    expect(
        countdownLooksStuck(
            isRunning: true,
            endTime: deadline,
            now: deadline.add(stuckCountdownGrace)),
        isTrue);
  });

  test('running with no deadline is stuck', () {
    expect(countdownLooksStuck(isRunning: true, endTime: null, now: deadline),
        isTrue);
  });
}
