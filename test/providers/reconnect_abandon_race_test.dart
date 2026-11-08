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

  // The connect workflow's auth step runs the provider's callback, which
  // awaits a GPS fix and sometimes a radio rename before it POSTs. An
  // abandon in that gap used to let the stale attempt POST /auth
  // reason=connect anyway, alongside the abandon's own release.
  group('authCallbackSuperseded', () {
    test('the attempt that made the callback still owns the connect', () {
      expect(
          authCallbackSuperseded(
              createdAtGeneration: 4,
              currentGeneration: 4,
              sameConnection: true),
          isFalse);
    });

    test('an abandon or a newer connect moved the generation on', () {
      expect(
          authCallbackSuperseded(
              createdAtGeneration: 4,
              currentGeneration: 5,
              sameConnection: true),
          isTrue);
    });

    test('the connection it was made for is gone or replaced', () {
      // The abandon disposes and drops the stale connection at once.
      expect(
          authCallbackSuperseded(
              createdAtGeneration: 4,
              currentGeneration: 4,
              sameConnection: false),
          isTrue);
    });
  });

  // The disconnect cleanup awaits the queue flush and the session release
  // before it disposes the connection. Cancel, then a quick Connect, put a
  // new connection in place during those awaits, and the cleanup's end used
  // to dispose that one.
  group('cleanupOwnsCurrentConnection', () {
    test('nothing connected since the cleanup started', () {
      expect(
          cleanupOwnsCurrentConnection(
              cleanupGeneration: 7, currentGeneration: 7),
          isTrue);
    });

    test('a connect started during the cleanup owns what is current', () {
      expect(
          cleanupOwnsCurrentConnection(
              cleanupGeneration: 7, currentGeneration: 8),
          isFalse);
    });
  });
}
