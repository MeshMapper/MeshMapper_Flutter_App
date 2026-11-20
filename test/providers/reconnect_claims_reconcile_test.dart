import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';

/// Every connect refreshes the companion's repeater claims through the
/// server's `mine` action, which allows 60 calls an hour. A reconnect loop
/// spent that in minutes (HTTP 429). Auto-reconnects inside one session now
/// refresh at most once per [claimsReconcileReconnectSpacing].

void main() {
  final t0 = DateTime(2026, 11, 8, 12);

  bool decide({
    bool autoReconnect = true,
    String? lastSession = 'YOW-20261108-0001',
    DateTime? lastAt,
    String? session = 'YOW-20261108-0001',
    required DateTime now,
  }) =>
      shouldReconcileClaimsOnConnect(
        autoReconnect: autoReconnect,
        sessionId: session,
        lastSessionId: lastSession,
        lastAt: lastAt,
        now: now,
      );

  test('a manual connect always refreshes', () {
    expect(decide(autoReconnect: false, lastAt: t0, now: t0), isTrue);
  });

  test('a reconnect soon after the last refresh in the session skips', () {
    expect(
        decide(lastAt: t0, now: t0.add(const Duration(minutes: 2))), isFalse);
  });

  test('a reconnect past the spacing refreshes', () {
    expect(
        decide(
            lastAt: t0,
            now: t0.add(claimsReconcileReconnectSpacing)),
        isTrue);
  });

  test('a reconnect into a new session refreshes', () {
    expect(
        decide(
            lastAt: t0,
            session: 'YOW-20261108-0002',
            now: t0.add(const Duration(minutes: 1))),
        isTrue);
  });

  test('a reconnect with no earlier refresh refreshes', () {
    expect(decide(lastAt: null, now: t0), isTrue);
  });
}
