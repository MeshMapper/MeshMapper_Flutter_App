import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/connection_state.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart' show AutoMode;
import 'package:mesh_mapper/services/live_activity/live_activity_models.dart';
import 'package:mesh_mapper/services/ping_service.dart';
import 'package:mesh_mapper/services/status/session_status.dart';
import 'package:mesh_mapper/services/status/session_status_resolver.dart';
import 'package:mesh_mapper/services/watch/watch_models.dart';

/// The test that makes "never disagree" enforced rather than aspirational.
///
/// Every surface now reads ONE resolution. The Live Activity shows the raw
/// `status.activity`; the watch and Siri show `resolveWatchSurfacePhase` of that
/// same activity (both call it through `_resolveWatchPhase`, contrary to the
/// function's own doc comment); the in-app buttons read the same model's lanes.
/// This pins the facts that keep those surfaces from drifting apart again:
///
///   1. the watch/Siri projection substitutes `idle` in exactly two cases, a
///      truly idle `starting` and a post-stop `cooldown` with no glance session,
///      and otherwise passes the phase through, so the two of them agree with
///      each other and differ from the Live Activity only by defined steps,
///      never an invented phase;
///   2. the shared resolver never itself produces `idle`, so `idle` on the wrist
///      is only ever that projection, never a state the model claimed;
///   3. the two states the buttons alone used to show (`isPingInProgress`,
///      `isSharedCooldownRunning`) now reach the glance too: an auto ping in
///      flight reads `sending` and the shared post-stop cooldown reads
///      `cooldown`, so the buttons and the glance no longer disagree about them.
///      This is the record of that disagreement being fixed in stage 4.

final _t = DateTime.utc(2026, 1, 1, 12);
StatusDeadline _d([int sec = 5]) =>
    (endsAt: _t, durationMs: null, remainingSec: sec);

SessionStatus _status({
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
  bool isDiscoveryWindowRunning = false,
  bool isManualCooldownRunning = false,
  bool isAutoPingRunning = false,
  String? autoPingSkipReason,
  bool isSharedCooldownRunning = false,
  SessionOperation? operation,
  bool isSessionStarting = false,
  bool isSessionActive = true,
}) =>
    resolveSessionStatus(
      isInZoneGracePeriod: isInZoneGracePeriod,
      zoneGraceEndsAt: isInZoneGracePeriod ? _t : null,
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
      rxWindow: isRxWindowRunning ? _d(4) : null,
      isDiscoveryWindowRunning: isDiscoveryWindowRunning,
      discoveryWindow: isDiscoveryWindowRunning ? _d(6) : null,
      isManualCooldownRunning: isManualCooldownRunning,
      manualCooldown: isManualCooldownRunning ? _d(9) : null,
      isAutoPingRunning: isAutoPingRunning,
      autoPingSkipReason: autoPingSkipReason,
      autoPing: isAutoPingRunning ? _d(22) : null,
      isSharedCooldownRunning: isSharedCooldownRunning,
      sharedCooldown: isSharedCooldownRunning ? _d(5) : null,
      operation: operation,
      isSessionStarting: isSessionStarting,
      isSessionActive: isSessionActive,
    );

/// A base state as a function of the two button-only flags, so each row can be
/// resolved twice, once as the glance sees it and once as the buttons do.
typedef _Scene = SessionStatus Function({required bool pip, required bool scd});

final List<_Scene> _scenes = [
  // Every mode, resting and mid-cycle, plus the session-wide holds and a stop.
  for (final mode in AutoMode.values) ...[
    ({required pip, required scd}) => _status(
        autoMode: mode, isPingInProgress: pip, isSharedCooldownRunning: scd),
    ({required pip, required scd}) => _status(
        autoMode: mode,
        isRxWindowRunning: true,
        isPingInProgress: pip,
        isSharedCooldownRunning: scd),
    ({required pip, required scd}) => _status(
        autoMode: mode,
        isDiscoveryWindowRunning: true,
        isPingInProgress: pip,
        isSharedCooldownRunning: scd),
    ({required pip, required scd}) => _status(
        autoMode: mode,
        isAutoPingRunning: true,
        isPingInProgress: pip,
        isSharedCooldownRunning: scd),
    ({required pip, required scd}) => _status(
        autoMode: mode,
        isAutoPingRunning: true,
        autoPingSkipReason: PingService.skipReasonRecentlyCovered,
        isPingInProgress: pip,
        isSharedCooldownRunning: scd),
    ({required pip, required scd}) => _status(
        autoMode: mode,
        isPendingDisable: true,
        isRxWindowRunning: true,
        isPingInProgress: pip,
        isSharedCooldownRunning: scd),
  ],
  // A manual ping in flight during any mode, and its cooldown.
  ({required pip, required scd}) => _status(
      autoMode: AutoMode.passive,
      isPingSending: true,
      isManualSession: true,
      isPingInProgress: pip,
      isSharedCooldownRunning: scd),
  ({required pip, required scd}) => _status(
      autoMode: AutoMode.passive,
      isManualCooldownRunning: true,
      isManualSession: true,
      isPingInProgress: pip,
      isSharedCooldownRunning: scd),
  // The operation latch.
  ({required pip, required scd}) => _status(
      operation: SessionOperation.discovering,
      isPingInProgress: pip,
      isSharedCooldownRunning: scd),
  // The session-wide holds.
  ({required pip, required scd}) => _status(
      isInZoneGracePeriod: true,
      isPingInProgress: pip,
      isSharedCooldownRunning: scd),
  ({required pip, required scd}) => _status(
      isZoneTransferInProgress: true,
      isPingInProgress: pip,
      isSharedCooldownRunning: scd),
  ({required pip, required scd}) => _status(
      connectionStep: ConnectionStep.disconnected,
      isPingInProgress: pip,
      isSharedCooldownRunning: scd),
  ({required pip, required scd}) => _status(
      isGpsLocked: false, isPingInProgress: pip, isSharedCooldownRunning: scd),
  ({required pip, required scd}) => _status(
      txAllowed: false, isPingInProgress: pip, isSharedCooldownRunning: scd),
  ({required pip, required scd}) => _status(
      isSessionActive: false,
      isPingInProgress: pip,
      isSharedCooldownRunning: scd),
  ({required pip, required scd}) => _status(
      isSessionStarting: true,
      isPingInProgress: pip,
      isSharedCooldownRunning: scd),
];

void main() {
  group('the glance surfaces read one activity', () {
    test('the watch/Siri projection substitutes only idle, in two cases', () {
      // The Live Activity shows the raw phase; the watch and Siri show this
      // projection of it. It substitutes idle in exactly two cases, a truly
      // idle Starting and a post-stop cooldown with no glance session, and
      // otherwise passes the phase through. Whatever it does, the only value it
      // ever substitutes is idle, so the surfaces never invent a phase.
      for (final p in LiveActivityPhase.values) {
        for (final active in [false, true]) {
          for (final starting in [false, true]) {
            for (final glance in [false, true]) {
              final projected = resolveWatchSurfacePhase(
                sharedPhase: p,
                isSessionActive: active,
                isSessionStarting: starting,
                isGlanceSessionActive: glance,
              );
              final expected =
                  (p == LiveActivityPhase.starting && !active && !starting)
                      ? LiveActivityPhase.idle
                      : (p == LiveActivityPhase.cooldown && !glance)
                          ? LiveActivityPhase.idle
                          : p;
              expect(projected, expected,
                  reason:
                      '$p active=$active starting=$starting glance=$glance');
              if (projected != p) {
                expect(projected, LiveActivityPhase.idle, reason: '$p');
              }
            }
          }
        }
      }
    });

    test('the projection is total: every phase maps to a real phase', () {
      // No state falls through to a blank on the wrist.
      for (final p in LiveActivityPhase.values) {
        for (final active in [false, true]) {
          for (final starting in [false, true]) {
            for (final glance in [false, true]) {
              expect(
                LiveActivityPhase.values,
                contains(resolveWatchSurfacePhase(
                    sharedPhase: p,
                    isSessionActive: active,
                    isSessionStarting: starting,
                    isGlanceSessionActive: glance)),
                reason: '$p',
              );
            }
          }
        }
      }
    });

    test('the shared resolver never itself produces idle', () {
      // The Live Activity reads the raw activity, so idle could only reach a
      // glance through the watch projection. If the resolver could produce idle
      // the phone and the wrist would part ways.
      for (final make in _scenes) {
        expect(make(pip: false, scd: false).activity,
            isNot(SessionActivity.idle));
        expect(
            make(pip: true, scd: true).activity, isNot(SessionActivity.idle));
      }
    });
  });

  group('the two states the buttons showed now reach the glance', () {
    // Before stage 4 these two flags moved only the buttons; the glance shimmed
    // them off, and this pinned that they could not move it. Now the glance
    // follows the buttons, so the expectation is the opposite. That flip is the
    // record of the disagreement being fixed.
    test('an auto ping in flight moves the glance to sending', () {
      final resting = _status(autoMode: AutoMode.active);
      final inFlight =
          _status(autoMode: AutoMode.active, isPingInProgress: true);
      expect(resting.activity, isNot(SessionActivity.sending));
      expect(inFlight.activity, SessionActivity.sending);
      expect(inFlight.owner, StatusLane.txAuto);
    });

    test('the shared post-stop cooldown moves the glance to cooldown', () {
      final resting = _status(isSessionActive: false);
      final cooling =
          _status(isSessionActive: false, isSharedCooldownRunning: true);
      expect(resting.activity, isNot(SessionActivity.cooldown));
      expect(cooling.activity, SessionActivity.cooldown);
      expect(cooling.owner, StatusLane.txAuto);
    });

    test('a ping in flight still does not disturb an open window', () {
      // The sending gap sits below the window branches: during an RX window the
      // glance stays Listening whether or not a ping is in flight, so the fix
      // cannot stomp the echo window that fills five seconds of every cycle.
      final listening =
          _status(autoMode: AutoMode.active, isRxWindowRunning: true);
      final both = _status(
          autoMode: AutoMode.active,
          isRxWindowRunning: true,
          isPingInProgress: true);
      expect(both.activity, listening.activity);
      expect(both.owner, listening.owner);
      expect(both.deadline, listening.deadline);
    });
  });
}
