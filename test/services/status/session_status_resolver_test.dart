import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/connection_state.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart' show AutoMode;
import 'package:mesh_mapper/services/ping_service.dart';
import 'package:mesh_mapper/services/status/session_status.dart';
import 'package:mesh_mapper/services/status/session_status_resolver.dart';

/// The lane half of the model. The phase table already pins the single answer
/// every glance surface reads; this pins the four views the buttons read, and
/// the rule that binds them: a lane either owns the moment or is held by it.

final _t1 = DateTime.utc(2026, 1, 1, 12);
final _t2 = DateTime.utc(2026, 1, 1, 13);
StatusDeadline _d(DateTime t, [int sec = 4]) =>
    (endsAt: t, durationMs: 5000, remainingSec: sec);

SessionStatus status({
  bool isInZoneGracePeriod = false,
  bool isZoneTransferInProgress = false,
  bool isAutoReconnecting = false,
  ConnectionStep connectionStep = ConnectionStep.connected,
  bool isPendingDisable = false,
  bool isGpsLocked = true,
  AutoMode autoMode = AutoMode.active,
  bool txAllowed = true,
  bool isManualSession = false,
  bool isPingSending = false,
  bool isPingInProgress = false,
  bool isRxWindowRunning = false,
  StatusDeadline? rxWindow,
  bool isDiscoveryWindowRunning = false,
  StatusDeadline? discoveryWindow,
  bool isManualCooldownRunning = false,
  StatusDeadline? manualCooldown,
  bool isAutoPingRunning = false,
  String? autoPingSkipReason,
  StatusDeadline? autoPing,
  bool isSharedCooldownRunning = false,
  StatusDeadline? sharedCooldown,
  SessionOperation? operation,
  bool isSessionStarting = false,
  bool isSessionActive = true,
}) =>
    resolveSessionStatus(
      isInZoneGracePeriod: isInZoneGracePeriod,
      zoneGraceEndsAt: isInZoneGracePeriod ? _t1 : null,
      isZoneTransferInProgress: isZoneTransferInProgress,
      isAutoReconnecting: isAutoReconnecting,
      connectionStep: connectionStep,
      isConnected: connectionStep == ConnectionStep.connected,
      isPendingDisable: isPendingDisable,
      isGpsLocked: isGpsLocked,
      autoMode: autoMode,
      txAllowed: txAllowed,
      isManualSession: isManualSession,
      isPingSending: isPingSending,
      isPingInProgress: isPingInProgress,
      isRxWindowRunning: isRxWindowRunning,
      rxWindow: rxWindow,
      isDiscoveryWindowRunning: isDiscoveryWindowRunning,
      discoveryWindow: discoveryWindow,
      isManualCooldownRunning: isManualCooldownRunning,
      manualCooldown: manualCooldown,
      isAutoPingRunning: isAutoPingRunning,
      autoPingSkipReason: autoPingSkipReason,
      autoPing: autoPing,
      isSharedCooldownRunning: isSharedCooldownRunning,
      sharedCooldown: sharedCooldown,
      operation: operation,
      isSessionStarting: isSessionStarting,
      isSessionActive: isSessionActive,
    );

void main() {
  group('a session-wide hold reaches every lane', () {
    test('nothing owns a disconnected session', () {
      final s = status(connectionStep: ConnectionStep.disconnected);
      expect(s.activity, SessionActivity.disconnected);
      expect(s.owner, isNull);
      for (final lane in StatusLane.values) {
        expect(s.lane(lane).activity, SessionActivity.disconnected,
            reason: '$lane');
        expect(s.lane(lane).isBlocked, isTrue, reason: '$lane');
      }
    });

    test('so does waiting for GPS and a blocked zone', () {
      for (final s in [
        status(isGpsLocked: false),
        status(txAllowed: false),
        status(isInZoneGracePeriod: true),
      ]) {
        expect(s.owner, isNull);
        expect(s.manual.activity, s.txAuto.activity);
        expect(s.discovery.activity, s.targeted.activity);
        expect(s.manual.isBlocked, isTrue);
      }
    });

    test('a stop is a glance answer, not a lane state', () {
      // A stop is not a session-wide hold like the others: it names the Active
      // lane as the owner and reads Stopping on the single surfaces, but it is
      // laid over the glance only and never sits on a lane, so it cannot shadow a
      // window a lane is still closing. With nothing else running the lanes
      // simply rest; the buttons that show Stopping read the flag, not the lane.
      final s = status(isPendingDisable: true);
      expect(s.activity, SessionActivity.stopping);
      expect(s.owner, StatusLane.txAuto);
      expect(s.deadline, isNull);
      for (final lane in StatusLane.values) {
        expect(s.lane(lane).activity, isNot(SessionActivity.stopping),
            reason: '$lane');
      }
    });

    test('a stop lets the mode being stopped keep its closing window', () {
      // The Passive discovery window is still closing during the graceful stop,
      // so its lane keeps showing it while the glance and the Active button say
      // Stopping. This is what lets the Passive button count the window down as
      // it always has, instead of flipping to the mode word the moment a stop
      // begins.
      final s = status(
        autoMode: AutoMode.passive,
        isPendingDisable: true,
        isDiscoveryWindowRunning: true,
        discoveryWindow: _d(_t1, 6),
      );
      expect(s.activity, SessionActivity.stopping);
      expect(s.owner, StatusLane.txAuto);
      expect(s.discovery.activity, SessionActivity.listeningDiscovery);
      expect(s.discovery.isBlocked, isFalse);
      expect(s.discovery.deadline, _d(_t1, 6));
    });
  });

  group('one moment, one owner, four views', () {
    test('a manual RX window: the manual lane listens, the rest are held', () {
      // A manual-only session: no auto mode is running, so the echo window
      // belongs to the tap that opened it.
      final s = status(
          isManualSession: true,
          isSessionActive: false,
          isRxWindowRunning: true,
          rxWindow: _d(_t1));

      expect(s.activity, SessionActivity.listening);
      expect(s.owner, StatusLane.manual);
      expect(s.manual, (
        activity: SessionActivity.listening,
        deadline: _d(_t1),
        isBlocked: false
      ));
      // This is the disagreement the buttons show today, now as one fact: the
      // other lanes are held by the SAME deadline, and by the SAME activity,
      // that the owner is in. A held lane reports the holding activity rather
      // than a generic cooldown, so each button can decide for itself whether
      // to borrow that window as its own cooldown or ignore it.
      for (final lane in [
        StatusLane.txAuto,
        StatusLane.discovery,
        StatusLane.targeted
      ]) {
        expect(s.lane(lane).isBlocked, isTrue, reason: '$lane');
        expect(s.lane(lane).deadline, _d(_t1), reason: '$lane');
        expect(s.lane(lane).activity, SessionActivity.listening,
            reason: '$lane');
      }
    });

    test('an auto RX window belongs to the TX lane instead', () {
      // Ownership follows who is transmitting, not which surface opened the
      // glance session: a manual ping during a Passive drive still owns its
      // own window even though the manual-session flag stays false.
      final s = status(isRxWindowRunning: true, rxWindow: _d(_t1));
      expect(s.owner, StatusLane.txAuto);
      expect(s.txAuto.isBlocked, isFalse);
      expect(s.manual.isBlocked, isTrue);
    });

    test('a discovery window belongs to Passive, Trace or Hybrid by mode', () {
      expect(
          status(
                  autoMode: AutoMode.passive,
                  isDiscoveryWindowRunning: true,
                  discoveryWindow: _d(_t1))
              .owner,
          StatusLane.discovery);
      expect(
          status(
                  autoMode: AutoMode.targeted,
                  isDiscoveryWindowRunning: true,
                  discoveryWindow: _d(_t1))
              .owner,
          StatusLane.targeted);
      // Hybrid's discovery leg is the TX loop's own, which is why the Active
      // button counts it down and the Passive button does not.
      expect(
          status(
                  autoMode: AutoMode.hybrid,
                  isDiscoveryWindowRunning: true,
                  discoveryWindow: _d(_t1))
              .owner,
          StatusLane.txAuto);
    });

    test('the interval belongs to whichever mode armed it', () {
      expect(status(isAutoPingRunning: true, autoPing: _d(_t1)).owner,
          StatusLane.txAuto);
      expect(
          status(
                  autoMode: AutoMode.passive,
                  isAutoPingRunning: true,
                  autoPing: _d(_t1))
              .owner,
          StatusLane.discovery);
      expect(
          status(
                  autoMode: AutoMode.targeted,
                  isAutoPingRunning: true,
                  autoPing: _d(_t1))
              .owner,
          StatusLane.targeted);
    });

    test('a deferral and a skip are different states, not one', () {
      expect(
          status(
                  isAutoPingRunning: true,
                  autoPing: _d(_t1),
                  autoPingSkipReason: PingService.skipReasonRecentlyCovered)
              .activity,
          SessionActivity.deferred);
      expect(
          status(
                  isAutoPingRunning: true,
                  autoPing: _d(_t1),
                  autoPingSkipReason: 'too close')
              .activity,
          SessionActivity.skipped);
    });
  });

  group('two lanes at once, which is what a single deadline could not hold',
      () {
    test('a manual cooldown and a Passive interval run together', () {
      // Reachable: a manual ping is legal during a Passive drive, so the 15 s
      // manual cooldown and the 30 s discovery interval overlap. One deadline
      // cannot render that frame, which is why the model carries one per lane.
      final s = status(
        autoMode: AutoMode.passive,
        isManualSession: true,
        isManualCooldownRunning: true,
        manualCooldown: _d(_t1),
        isAutoPingRunning: true,
        autoPing: _d(_t2),
      );

      expect(s.manual.activity, SessionActivity.cooldown);
      expect(s.manual.deadline, _d(_t1));
      expect(s.discovery.activity, SessionActivity.waitingDiscovery);
      expect(s.discovery.deadline, _d(_t2));
      expect(s.manual.deadline, isNot(s.discovery.deadline));

      // The single-phase surfaces still get today's answer, the manual
      // cooldown, because it sits higher in the order.
      expect(s.activity, SessionActivity.cooldown);
      expect(s.owner, StatusLane.manual);
    });

    test('a manual cooldown without a manual session is a button-only fact', () {
      // A manual ping fired during a Passive drive holds the manual cooldown
      // while the manual-session flag stays false. The Send Ping button must
      // still count it down, so the manual lane carries it; the glance surfaces
      // must not show it, so it does not reach the single answer.
      final s = status(
        autoMode: AutoMode.passive,
        isManualSession: false,
        isManualCooldownRunning: true,
        manualCooldown: _d(_t1, 9),
      );

      expect(s.manual.activity, SessionActivity.cooldown);
      expect(s.manual.deadline, _d(_t1, 9));
      expect(s.manual.isBlocked, isFalse);
      // Off the glance: nothing owns the single answer, which rests.
      expect(s.owner, isNull);
      expect(s.activity, isNot(SessionActivity.cooldown));
    });
  });

  group('the two states the glance used to miss', () {
    test('an auto ping in flight before it transmits owns the glance', () {
      // The sending gap: a TX mode with the ping asked for but no window open
      // yet. The Active button always said Sending; now the single answer does
      // too, on the txAuto lane, instead of resting as active.
      final s = status(autoMode: AutoMode.active, isPingInProgress: true);
      expect(s.activity, SessionActivity.sending);
      expect(s.owner, StatusLane.txAuto);
      expect(s.txAuto.activity, SessionActivity.sending);

      // A ping in flight during Passive is a manual ping, not the auto gap, so
      // it stays off the glance.
      final manual = status(autoMode: AutoMode.passive, isPingInProgress: true);
      expect(manual.activity, isNot(SessionActivity.sending));
    });

    test('an attempt about to defer or skip does not flash Sending', () {
      // isPingInProgress latches at the top of the send, before validation and
      // the fresh fix, so an auto attempt that is about to be deferred (covered
      // ground) or skipped (25 m) would otherwise flash "Sending" for the length
      // of the GPS read. While a skip reason is set the lane is deferred/skipped,
      // never sending.
      final deferring = status(
        autoMode: AutoMode.hybrid,
        isPingInProgress: true,
        isAutoPingRunning: true,
        autoPing: _d(_t1),
        autoPingSkipReason: PingService.skipReasonRecentlyCovered,
      );
      expect(deferring.txAuto.activity, SessionActivity.deferred);
      expect(deferring.activity, isNot(SessionActivity.sending));

      final skipping = status(
        autoMode: AutoMode.active,
        isPingInProgress: true,
        isAutoPingRunning: true,
        autoPing: _d(_t1),
        autoPingSkipReason: 'too close',
      );
      expect(skipping.txAuto.activity, SessionActivity.skipped);
    });

    test('the shared post-stop cooldown owns the glance', () {
      // After stopping a TX mode nothing outranks the shared five second
      // cooldown, so it reaches the single answer on the txAuto lane. The native
      // projection reads that back as idle (tested on the watch surface); the
      // model is honest either way.
      final s = status(
        isSessionActive: false,
        isSharedCooldownRunning: true,
        sharedCooldown: _d(_t1, 5),
      );
      expect(s.activity, SessionActivity.cooldown);
      expect(s.owner, StatusLane.txAuto);
      expect(s.txAuto.activity, SessionActivity.cooldown);
      expect(s.deadline, _d(_t1, 5));

      // Mid-session the auto interval outranks it, so the cooldown never wins.
      final active = status(
        isSharedCooldownRunning: true,
        sharedCooldown: _d(_t1, 5),
        isAutoPingRunning: true,
        autoPing: _d(_t2),
      );
      expect(active.activity, SessionActivity.waiting);
      expect(active.owner, StatusLane.txAuto);
    });
  });

  group('nothing happening', () {
    test('an idle running session rests, unblocked', () {
      final s = status();
      expect(s.activity, SessionActivity.active);
      expect(s.owner, isNull);
      for (final lane in StatusLane.values) {
        expect(s.lane(lane).isBlocked, isFalse, reason: '$lane');
        expect(s.lane(lane).deadline, isNull, reason: '$lane');
      }
    });

    test('a starting session rests as starting', () {
      expect(
          status(isSessionStarting: true).activity, SessionActivity.starting);
      expect(status(isSessionActive: false).activity, SessionActivity.starting);
    });
  });

  test('the same inputs resolve equal, which the button selector relies on',
      () {
    // A record, so equality is structural. A miss costs three full validation
    // passes, including a distance calculation.
    expect(status(isRxWindowRunning: true, rxWindow: _d(_t1)),
        status(isRxWindowRunning: true, rxWindow: _d(_t1)));
  });
}
