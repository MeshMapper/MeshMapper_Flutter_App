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
///   1. the watch/Siri projection only ever maps `starting` to `idle`, so the
///      two of them agree with each other and differ from the Live Activity by
///      exactly one defined step, never an invented one;
///   2. the shared resolver never itself produces `idle`, so `idle` on the wrist
///      is only ever that projection, never a state the model claimed;
///   3. the two button-only observations (`isPingInProgress`,
///      `isSharedCooldownRunning`) never move the glance answer, so the buttons,
///      which see them, and the glance surfaces, which do not, describe the same
///      activity, owner and deadline.

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
    test('the watch/Siri projection only ever maps starting to idle', () {
      // The Live Activity shows the raw phase; the watch and Siri show this
      // projection of it. It changes exactly one state, and only when the
      // session is neither running nor starting, so the surfaces can differ by
      // that one defined step and never invent a phase of their own.
      for (final p in LiveActivityPhase.values) {
        for (final active in [false, true]) {
          for (final starting in [false, true]) {
            final projected = resolveWatchSurfacePhase(
              sharedPhase: p,
              isSessionActive: active,
              isSessionStarting: starting,
            );
            final expected =
                p == LiveActivityPhase.starting && !active && !starting
                    ? LiveActivityPhase.idle
                    : p;
            expect(projected, expected,
                reason: '$p active=$active starting=$starting');
          }
        }
      }
    });

    test('the projection is total: every phase maps to a real phase', () {
      // No state falls through to a blank on the wrist.
      for (final p in LiveActivityPhase.values) {
        for (final active in [false, true]) {
          for (final starting in [false, true]) {
            expect(
              LiveActivityPhase.values,
              contains(resolveWatchSurfacePhase(
                  sharedPhase: p,
                  isSessionActive: active,
                  isSessionStarting: starting)),
              reason: '$p',
            );
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

  group('the buttons and the glance describe the same state', () {
    test('the two button-only observations never move the glance answer', () {
      // The buttons resolve the full model; the glance shims these two flags
      // off. Flipping them adds only observations the glance is told to ignore,
      // so the single answer, activity, owner and deadline, cannot move. When
      // Project B flips either flag on, this expectation changes, which is
      // exactly the record of that disagreement being fixed.
      for (final make in _scenes) {
        final glance = make(pip: false, scd: false);
        final buttons = make(pip: true, scd: true);
        expect(buttons.activity, glance.activity, reason: '$glance');
        expect(buttons.owner, glance.owner, reason: '$glance');
        expect(buttons.deadline, glance.deadline, reason: '$glance');
      }
    });
  });
}
