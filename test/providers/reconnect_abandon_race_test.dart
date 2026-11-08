import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';

/// An auto-reconnect that is abandoned (the 30 s budget, or the user's
/// Cancel) while its connect is still in flight must not tear down a newer
/// connection when that stale attempt finally ends. In one log the user
/// cancelled, connected again by hand, and the stale attempt's end then read
/// the new connection's "connected" step as its own and disconnected it.

void main() {
  group('shouldDisconnectOrphanedReconnect', () {
    test('budget expires, the stale connect completes, nothing newer', () {
      // The abandon stamped generation 8 and nobody connected since: the
      // connection that is up is the stale attempt's own.
      expect(
        shouldDisconnectOrphanedReconnect(
            abandonedAtGeneration: 8, currentGeneration: 8, connected: true),
        isTrue,
      );
    });

    test('budget expires, the stale connect completes after a manual connect',
        () {
      // A manual connect bumped the generation: the connection is not ours.
      expect(
        shouldDisconnectOrphanedReconnect(
            abandonedAtGeneration: 8, currentGeneration: 9, connected: true),
        isFalse,
      );
    });

    test('cancel, then a manual connect, while the stale attempt fails', () {
      expect(
        shouldDisconnectOrphanedReconnect(
            abandonedAtGeneration: 8, currentGeneration: 9, connected: true),
        isFalse,
      );
      expect(
        shouldDisconnectOrphanedReconnect(
            abandonedAtGeneration: 8, currentGeneration: 9, connected: false),
        isFalse,
      );
    });

    test('a user Disconnect ended the reconnect: the orphan still closes', () {
      // No abandon caught the attempt in flight, so nothing else closes a
      // connection it completes afterwards.
      expect(
        shouldDisconnectOrphanedReconnect(
            abandonedAtGeneration: null, currentGeneration: 8, connected: true),
        isTrue,
      );
    });

    test('nothing is connected', () {
      expect(
        shouldDisconnectOrphanedReconnect(
            abandonedAtGeneration: 8, currentGeneration: 8, connected: false),
        isFalse,
      );
    });
  });

  group('reconnectBudgetGivesConnectGrace', () {
    test('a connect in flight gets one grace period', () {
      expect(
          reconnectBudgetGivesConnectGrace(
              connectInFlight: true, graceUsed: false),
          isTrue);
    });

    test('the grace is bounded: a second expiry abandons', () {
      expect(
          reconnectBudgetGivesConnectGrace(
              connectInFlight: true, graceUsed: true),
          isFalse);
    });

    test('nothing in flight abandons at once', () {
      expect(
          reconnectBudgetGivesConnectGrace(
              connectInFlight: false, graceUsed: false),
          isFalse);
    });
  });
}
