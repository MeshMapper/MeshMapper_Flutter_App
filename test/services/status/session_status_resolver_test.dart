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
StatusDeadline _d(DateTime t) => (endsAt: t, durationMs: 5000);

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

    test('so does waiting for GPS, a stop and a blocked zone', () {
      for (final s in [
        status(isGpsLocked: false),
        status(isPendingDisable: true),
        status(txAllowed: false),
        status(isInZoneGracePeriod: true),
      ]) {
        expect(s.owner, isNull);
        expect(s.manual.activity, s.txAuto.activity);
        expect(s.discovery.activity, s.targeted.activity);
        expect(s.manual.isBlocked, isTrue);
      }
    });
  });

  group('one moment, one owner, four views', () {
    test('a manual RX window: the manual lane listens, the rest are held', () {
      final s = status(
          isManualSession: true, isRxWindowRunning: true, rxWindow: _d(_t1));

      expect(s.activity, SessionActivity.listening);
      expect(s.owner, StatusLane.manual);
      expect(s.manual, (
        activity: SessionActivity.listening,
        deadline: _d(_t1),
        isBlocked: false
      ));
      // This is the disagreement the buttons show today, now as one fact: the
      // other lanes are held by the SAME deadline they render as a cooldown.
      for (final lane in [
        StatusLane.txAuto,
        StatusLane.discovery,
        StatusLane.targeted
      ]) {
        expect(s.lane(lane).isBlocked, isTrue, reason: '$lane');
        expect(s.lane(lane).deadline, _d(_t1), reason: '$lane');
      }
    });

    test('an auto RX window belongs to the TX lane instead', () {
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
