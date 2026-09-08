import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/connection_state.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart' show AutoMode;
import 'package:mesh_mapper/services/live_activity/live_activity_models.dart';
import 'package:mesh_mapper/services/ping_service.dart';
import 'package:mesh_mapper/services/status/session_phase_resolver.dart';
import 'package:mesh_mapper/services/status/session_status.dart';

/// One golden row per return site in [resolveSessionPhase], plus a full
/// precedence ladder. This is the table that makes "no user-visible change"
/// checkable: any wording or ordering move shows up here as a diff rather than
/// on a phone.

final _deadline = DateTime.utc(2026, 1, 1, 12);
final _other = DateTime.utc(2026, 1, 1, 13);

/// The all-clear session: connected, GPS locked, nothing running. It falls
/// through every branch to the last row, so each test below turns on only the
/// facts its own branch needs.
class _Args {
  bool isInZoneGracePeriod = false;
  DateTime? zoneGraceEndsAt;
  bool isZoneTransferInProgress = false;
  String? zoneTransferFrom;
  String? zoneTransferTo;
  bool isAutoReconnecting = false;
  ConnectionStep connectionStep = ConnectionStep.connected;
  bool isPendingDisable = false;
  GpsStatus gpsStatus = GpsStatus.locked;
  AutoMode autoMode = AutoMode.active;
  bool txAllowed = true;
  bool isManualSession = false;
  bool isPingSending = false;
  bool isPingInProgress = false;
  String? targetRepeaterName = 'Beacon Hill';
  bool isRxWindowRunning = false;
  DateTime? rxWindowEndsAt;
  bool isDiscoveryWindowRunning = false;
  DateTime? discoveryWindowEndsAt;
  bool isManualCooldownRunning = false;
  DateTime? manualCooldownEndsAt;
  bool isAutoPingRunning = false;
  String? autoPingSkipReason;
  DateTime? autoPingEndsAt;
  bool isSharedCooldownRunning = false;
  DateTime? sharedCooldownEndsAt;
  int minDistanceMetres = 25;
  SessionOperation? operation;
  bool isSessionStarting = false;
  bool isSessionActive = true;
  int nameLookups = 0;

  /// Derived in the provider, so it is derived here too. Passing the two
  /// independently would let the table assert states the app cannot hold.
  bool get isConnected => connectionStep == ConnectionStep.connected;

  /// Mirrors `_liveActivityModeTitle`, so the resting row picks up the manual
  /// wording on its own rather than being told.
  String get modeTitle => isManualSession ? 'Manual' : autoMode.displayName;
}

ResolvedPhase _resolve(_Args a) => resolveSessionPhase(
      isInZoneGracePeriod: a.isInZoneGracePeriod,
      zoneGraceEndsAt: a.zoneGraceEndsAt,
      isZoneTransferInProgress: a.isZoneTransferInProgress,
      zoneTransferFrom: a.zoneTransferFrom,
      zoneTransferTo: a.zoneTransferTo,
      isAutoReconnecting: a.isAutoReconnecting,
      connectionStep: a.connectionStep,
      isConnected: a.isConnected,
      isPendingDisable: a.isPendingDisable,
      gpsStatus: a.gpsStatus,
      autoMode: a.autoMode,
      txAllowed: a.txAllowed,
      isManualSession: a.isManualSession,
      isPingSending: a.isPingSending,
      isPingInProgress: a.isPingInProgress,
      targetRepeaterName: () {
        a.nameLookups++;
        return a.targetRepeaterName;
      },
      isRxWindowRunning: a.isRxWindowRunning,
      rxWindowEndsAt: a.rxWindowEndsAt,
      isDiscoveryWindowRunning: a.isDiscoveryWindowRunning,
      discoveryWindowEndsAt: a.discoveryWindowEndsAt,
      isManualCooldownRunning: a.isManualCooldownRunning,
      manualCooldownEndsAt: a.manualCooldownEndsAt,
      isAutoPingRunning: a.isAutoPingRunning,
      autoPingSkipReason: a.autoPingSkipReason,
      autoPingEndsAt: a.autoPingEndsAt,
      isSharedCooldownRunning: a.isSharedCooldownRunning,
      sharedCooldownEndsAt: a.sharedCooldownEndsAt,
      minDistanceMetres: a.minDistanceMetres,
      operation: a.operation,
      isSessionStarting: a.isSessionStarting,
      isSessionActive: a.isSessionActive,
      modeTitle: a.modeTitle,
    );

void expectRow(
  ResolvedPhase actual, {
  required LiveActivityPhase phase,
  required String title,
  String? detail,
  DateTime? endsAt,
}) {
  expect(actual.phase, phase);
  expect(actual.title, title);
  expect(actual.detail, detail);
  expect(actual.endsAt, endsAt);
}

/// One rung per branch, in the order the resolver checks them, each turning on
/// the least that reaches it. The ladder below asserts every higher rung beats
/// every lower one, which is what stops a branch being quietly hoisted.
typedef _Rung = ({
  String name,
  LiveActivityPhase phase,
  void Function(_Args) on
});

final List<_Rung> _ladder = [
  (
    name: 'zone grace',
    phase: LiveActivityPhase.pausedOutsideZone,
    on: (a) {
      a.isInZoneGracePeriod = true;
      a.zoneGraceEndsAt = _deadline;
    }
  ),
  (
    name: 'zone transfer',
    phase: LiveActivityPhase.pausedOutsideZone,
    on: (a) {
      a.isZoneTransferInProgress = true;
      a.zoneTransferFrom = 'YOW';
      a.zoneTransferTo = 'PAE';
    }
  ),
  (
    name: 'reconnecting',
    phase: LiveActivityPhase.disconnected,
    // The real shape: the step is reconnecting, so isConnected is already
    // false. The flag alone is what has to keep this above the plain
    // disconnected row.
    on: (a) {
      a.isAutoReconnecting = true;
      a.connectionStep = ConnectionStep.reconnecting;
    }
  ),
  (
    name: 'disconnected',
    phase: LiveActivityPhase.disconnected,
    on: (a) => a.connectionStep = ConnectionStep.disconnected
  ),
  (
    name: 'stopping',
    phase: LiveActivityPhase.stopping,
    on: (a) => a.isPendingDisable = true
  ),
  (
    name: 'waiting for GPS',
    phase: LiveActivityPhase.waitingForGps,
    on: (a) => a.gpsStatus = GpsStatus.searching
  ),
  (
    name: 'TX blocked',
    phase: LiveActivityPhase.txBlocked,
    on: (a) => a.txAllowed = false
  ),
  (
    name: 'manual send',
    phase: LiveActivityPhase.sending,
    on: (a) {
      a.isManualSession = true;
      a.isPingSending = true;
    }
  ),
  (
    name: 'discovery window',
    phase: LiveActivityPhase.listeningDiscovery,
    on: (a) {
      a.isDiscoveryWindowRunning = true;
      a.discoveryWindowEndsAt = _deadline;
    }
  ),
  (
    name: 'RX window',
    phase: LiveActivityPhase.listening,
    on: (a) {
      a.isRxWindowRunning = true;
      a.rxWindowEndsAt = _other;
    }
  ),
  (
    name: 'manual cooldown',
    phase: LiveActivityPhase.cooldown,
    on: (a) {
      a.isManualSession = true;
      a.isManualCooldownRunning = true;
      a.manualCooldownEndsAt = _deadline;
    }
  ),
  (
    name: 'auto interval',
    phase: LiveActivityPhase.waiting,
    on: (a) {
      a.isAutoPingRunning = true;
      a.autoPingEndsAt = _deadline;
    }
  ),
  (
    name: 'operation latch',
    phase: LiveActivityPhase.sending,
    on: (a) => a.operation = SessionOperation.sending
  ),
  (
    name: 'starting',
    phase: LiveActivityPhase.starting,
    on: (a) => a.isSessionStarting = true
  ),
];

void main() {
  group('one row per return site', () {
    test('zone grace', () {
      final a = _Args()
        ..isInZoneGracePeriod = true
        ..zoneGraceEndsAt = _deadline;
      expectRow(_resolve(a),
          phase: LiveActivityPhase.pausedOutsideZone,
          title: 'Outside service area',
          detail: 'Searching for a nearby wardriving zone',
          endsAt: _deadline);
    });

    test('zone transfer', () {
      final a = _Args()
        ..isZoneTransferInProgress = true
        ..zoneTransferFrom = 'YOW'
        ..zoneTransferTo = 'PAE';
      expectRow(_resolve(a),
          phase: LiveActivityPhase.pausedOutsideZone,
          title: 'Changing region…',
          detail: 'YOW → PAE');
    });

    test('a zone transfer with neither end named still has a blank detail', () {
      // Not a nicety: the join yields the empty string rather than null, so the
      // phase carries a detail that is present and says nothing.
      expect(_resolve(_Args()..isZoneTransferInProgress = true).detail, '');
    });

    test('reconnecting', () {
      final a = _Args()
        ..isAutoReconnecting = true
        ..connectionStep = ConnectionStep.reconnecting;
      expectRow(_resolve(a),
          phase: LiveActivityPhase.disconnected,
          title: 'Reconnecting…',
          detail: 'Restoring MeshCore connection');
    });

    test('the reconnecting step reaches the same row without the flag', () {
      expect(
          _resolve(_Args()..connectionStep = ConnectionStep.reconnecting).title,
          'Reconnecting…');
    });

    test('disconnecting', () {
      final a = _Args()..connectionStep = ConnectionStep.disconnecting;
      expectRow(_resolve(a),
          phase: LiveActivityPhase.disconnected,
          title: 'Disconnecting…',
          detail: 'Open MeshMapper to reconnect');
    });

    test('disconnected', () {
      final a = _Args()..connectionStep = ConnectionStep.disconnected;
      expectRow(_resolve(a),
          phase: LiveActivityPhase.disconnected,
          title: 'Device disconnected',
          detail: 'Open MeshMapper to reconnect');
    });

    test('every other connection step collapses to the same two words', () {
      // The branch is a two-way ternary, not a per-step description.
      for (final step in [
        ConnectionStep.transportConnecting,
        ConnectionStep.deviceQuery,
        ConnectionStep.error,
      ]) {
        expect(_resolve(_Args()..connectionStep = step).title,
            'Device disconnected',
            reason: 'step $step');
      }
    });

    test('stopping takes the RX window deadline first', () {
      final a = _Args()
        ..isPendingDisable = true
        ..isRxWindowRunning = true
        ..rxWindowEndsAt = _deadline
        ..isDiscoveryWindowRunning = true
        ..discoveryWindowEndsAt = _other;
      expectRow(_resolve(a),
          phase: LiveActivityPhase.stopping,
          title: 'Stopping…',
          detail: 'Finishing the current listening window',
          endsAt: _deadline);
    });

    test('stopping falls back to the discovery deadline', () {
      final a = _Args()
        ..isPendingDisable = true
        ..isDiscoveryWindowRunning = true
        ..discoveryWindowEndsAt = _other;
      expect(_resolve(a).endsAt, _other);
    });

    test('stopping can have no deadline at all', () {
      // The 12 second pending-disable backstop is exactly the case where no
      // window is open, so the countdown has nothing to show.
      expect(_resolve(_Args()..isPendingDisable = true).endsAt, isNull);
    });

    test('waiting for GPS names the reason', () {
      const labels = {
        GpsStatus.permissionDenied: 'Location permission required',
        GpsStatus.disabled: 'Location services disabled',
        GpsStatus.searching: 'Searching for GPS signal',
        GpsStatus.outsideGeofence: 'Outside service area',
      };
      labels.forEach((status, label) {
        expectRow(_resolve(_Args()..gpsStatus = status),
            phase: LiveActivityPhase.waitingForGps,
            title: 'Waiting for GPS',
            detail: label);
      });
    });

    test('the locked label exists but no branch can reach it', () {
      // Kept as a deliberate record: the fifth arm of the label switch is dead,
      // because the only branch that reads it is guarded on not being locked.
      expect(gpsPhaseLabel(GpsStatus.locked), 'GPS locked');
      expect(_resolve(_Args()..gpsStatus = GpsStatus.locked).phase,
          isNot(LiveActivityPhase.waitingForGps));
    });

    test('TX blocked, for the three transmitting modes only', () {
      for (final mode in [
        AutoMode.active,
        AutoMode.hybrid,
        AutoMode.targeted
      ]) {
        final a = _Args()
          ..autoMode = mode
          ..txAllowed = false;
        expectRow(_resolve(a),
            phase: LiveActivityPhase.txBlocked,
            title: 'TX unavailable',
            detail: 'This zone is currently passive-only');
      }
      final passive = _Args()
        ..autoMode = AutoMode.passive
        ..txAllowed = false;
      expect(_resolve(passive).phase, isNot(LiveActivityPhase.txBlocked),
          reason: 'a passive session is not blocked by a passive-only zone');
    });

    test('a manual send needs both the session and the flag', () {
      final a = _Args()
        ..isManualSession = true
        ..isPingSending = true;
      expectRow(_resolve(a),
          phase: LiveActivityPhase.sending, title: 'Sending ping…');

      // A manual send flag without a manual session belongs to the manual lane
      // only, so it does not reach the glance phase. The auto ping in flight is
      // a different flag with its own row below.
      expect(_resolve(_Args()..isPingSending = true).phase,
          isNot(LiveActivityPhase.sending));
    });

    test('the auto sending gap: a ping in flight before it transmits', () {
      // A TX mode with a ping asked for but no window open yet, the two or
      // three seconds of GPS fetch. The phone said Sending all along; the glance
      // surfaces now do too instead of resting on the mode-active row.
      final a = _Args()
        ..autoMode = AutoMode.active
        ..isPingInProgress = true;
      expectRow(_resolve(a),
          phase: LiveActivityPhase.sending, title: 'Sending ping…');

      // The same flag during Passive is a manual ping in flight, not the auto
      // TX gap, so it does not light this row without a TX mode running.
      final passive = _Args()
        ..autoMode = AutoMode.passive
        ..isPingInProgress = true;
      expect(_resolve(passive).phase, isNot(LiveActivityPhase.sending),
          reason: 'a ping in flight during Passive is not the auto TX gap');
    });

    test('listening for discovery responses', () {
      final a = _Args()
        ..autoMode = AutoMode.passive
        ..isDiscoveryWindowRunning = true
        ..discoveryWindowEndsAt = _deadline;
      expectRow(_resolve(a),
          phase: LiveActivityPhase.listeningDiscovery,
          title: 'Listening…',
          detail: 'Discovery responses',
          endsAt: _deadline);
    });

    test('listening for a trace names the repeater', () {
      final a = _Args()
        ..autoMode = AutoMode.targeted
        ..isDiscoveryWindowRunning = true
        ..discoveryWindowEndsAt = _deadline;
      expectRow(_resolve(a),
          phase: LiveActivityPhase.listeningTrace,
          title: 'Listening for trace…',
          detail: 'Beacon Hill',
          endsAt: _deadline);
    });

    test('an unnamed target leaves the detail empty on all three rows', () {
      // Reachable: changing the hop bytes or the path mode clears the target id
      // while Trace is selected, and the name resolves to null from there.
      for (final on in <void Function(_Args)>[
        (a) {
          a.isDiscoveryWindowRunning = true;
          a.discoveryWindowEndsAt = _deadline;
        },
        (a) {
          a.isAutoPingRunning = true;
          a.autoPingEndsAt = _deadline;
        },
        (a) => a.operation = SessionOperation.tracing,
      ]) {
        final a = _Args()
          ..autoMode = AutoMode.targeted
          ..targetRepeaterName = null;
        on(a);
        expect(_resolve(a).detail, isNull);
      }
    });

    test('listening for echoes', () {
      final a = _Args()
        ..isRxWindowRunning = true
        ..rxWindowEndsAt = _deadline;
      expectRow(_resolve(a),
          phase: LiveActivityPhase.listening,
          title: 'Listening…',
          detail: 'Waiting for repeater echoes',
          endsAt: _deadline);
    });

    test('the manual cooldown, which needs a manual session', () {
      final a = _Args()
        ..isManualSession = true
        ..isManualCooldownRunning = true
        ..manualCooldownEndsAt = _deadline;
      expectRow(_resolve(a),
          phase: LiveActivityPhase.cooldown,
          title: 'Cooldown',
          detail: 'Manual ping available when the timer ends',
          endsAt: _deadline);

      final auto = _Args()
        ..isManualCooldownRunning = true
        ..manualCooldownEndsAt = _deadline;
      expect(_resolve(auto).phase, isNot(LiveActivityPhase.cooldown),
          reason: 'an auto session never reaches the manual cooldown row');
    });

    test('the shared post-stop cooldown reaches the phase', () {
      // After stopping a TX mode the auto interval is gone, so the shared five
      // second cooldown wins the glance. The model says Cooldown here; the wrist
      // projects it back to idle, which is the watch surface's own test.
      final a = _Args()
        ..isSessionActive = false
        ..isSharedCooldownRunning = true
        ..sharedCooldownEndsAt = _deadline;
      expectRow(_resolve(a),
          phase: LiveActivityPhase.cooldown,
          title: 'Cooldown',
          detail: 'Manual ping available when the timer ends',
          endsAt: _deadline);

      // Mid-session the auto interval outranks it, so it never shows there.
      final active = _Args()
        ..isSharedCooldownRunning = true
        ..sharedCooldownEndsAt = _deadline
        ..isAutoPingRunning = true
        ..autoPingEndsAt = _other;
      expect(_resolve(active).phase, LiveActivityPhase.waiting,
          reason: 'the auto interval beats the shared cooldown mid-session');
    });

    test('deferred, in every mode that can defer', () {
      for (final mode in [AutoMode.active, AutoMode.hybrid, AutoMode.passive]) {
        final a = _Args()
          ..autoMode = mode
          ..isAutoPingRunning = true
          ..autoPingSkipReason = PingService.skipReasonRecentlyCovered
          ..autoPingEndsAt = _deadline;
        expectRow(_resolve(a),
            phase: LiveActivityPhase.deferred,
            title: 'Deferred',
            detail: 'Recently covered, waiting for a fresh square',
            endsAt: _deadline);
      }
    });

    test('skipped, in every mode, and it quotes the configured distance', () {
      for (final mode in AutoMode.values) {
        final a = _Args()
          ..autoMode = mode
          ..isAutoPingRunning = true
          ..autoPingSkipReason = 'too close'
          ..autoPingEndsAt = _deadline
          ..minDistanceMetres = 50;
        expectRow(
          _resolve(a),
          phase: LiveActivityPhase.skipped,
          title: 'Ping skipped',
          detail: 'Move at least 50 m',
          endsAt: _deadline,
        );
      }
    });

    test('any unknown skip reason reads as skipped', () {
      // Only the recently-covered reason is a named constant; 'too close' is a
      // bare literal and the doc comment advertises a third nobody sets.
      final a = _Args()
        ..isAutoPingRunning = true
        ..autoPingSkipReason = 'gps too old'
        ..autoPingEndsAt = _deadline;
      expect(_resolve(a).title, 'Ping skipped');
    });

    test('next discovery', () {
      final a = _Args()
        ..autoMode = AutoMode.passive
        ..isAutoPingRunning = true
        ..autoPingEndsAt = _deadline;
      expectRow(_resolve(a),
          phase: LiveActivityPhase.waitingDiscovery,
          title: 'Next discovery',
          endsAt: _deadline);
    });

    test('next trace', () {
      final a = _Args()
        ..autoMode = AutoMode.targeted
        ..isAutoPingRunning = true
        ..autoPingEndsAt = _deadline;
      expectRow(_resolve(a),
          phase: LiveActivityPhase.waitingTrace,
          title: 'Next trace',
          detail: 'Beacon Hill',
          endsAt: _deadline);
    });

    test('next ping, for the two modes that fall past the other checks', () {
      for (final mode in [AutoMode.active, AutoMode.hybrid]) {
        final a = _Args()
          ..autoMode = mode
          ..isAutoPingRunning = true
          ..autoPingEndsAt = _deadline;
        expectRow(_resolve(a),
            phase: LiveActivityPhase.waiting,
            title: 'Next ping',
            endsAt: _deadline);
      }
    });

    test('the operation latch: sending, discovering, tracing', () {
      expectRow(_resolve(_Args()..operation = SessionOperation.sending),
          phase: LiveActivityPhase.sending, title: 'Sending ping…');
      expectRow(_resolve(_Args()..operation = SessionOperation.discovering),
          phase: LiveActivityPhase.discovering,
          title: 'Discovering…',
          detail: 'Requesting nearby repeaters');
      expectRow(_resolve(_Args()..operation = SessionOperation.tracing),
          phase: LiveActivityPhase.tracing,
          title: 'Tracing repeater…',
          detail: 'Beacon Hill');
    });

    test('preparing a session, from either half of the condition', () {
      expectRow(_resolve(_Args()..isSessionStarting = true),
          phase: LiveActivityPhase.starting, title: 'Preparing session…');
      expectRow(_resolve(_Args()..isSessionActive = false),
          phase: LiveActivityPhase.starting, title: 'Preparing session…');
    });

    test('the resting row repeats the mode word', () {
      expectRow(_resolve(_Args()),
          phase: LiveActivityPhase.active,
          title: 'Active active',
          detail: 'Waiting for the next cycle');

      // The same row for a manual session, which is where the doubled word
      // reads worst.
      expect(_resolve(_Args()..isManualSession = true).title, 'Manual active');
      expect(_resolve(_Args()..autoMode = AutoMode.passive).title,
          'Passive active');
    });
  });

  group('precedence', () {
    // Every rung must beat every rung below it. Without this an accidental
    // hoist stays green: moving the passive check above the skip check, say,
    // would replace Deferred with Next discovery for every Passive user and no
    // single-branch row would notice.
    for (var upper = 0; upper < _ladder.length; upper++) {
      for (var lower = upper + 1; lower < _ladder.length; lower++) {
        final u = _ladder[upper];
        final l = _ladder[lower];
        test('${u.name} outranks ${l.name}', () {
          final a = _Args();
          u.on(a);
          l.on(a);
          expect(_resolve(a).phase, u.phase,
              reason: '${u.name} should win over ${l.name}');
        });
      }
    }

    test('a skip reason outranks the mode rows inside the interval block', () {
      // The sub-branch ordering the ladder cannot express, because both rungs
      // live inside the same `isAutoPingRunning` block.
      for (final mode in AutoMode.values) {
        final a = _Args()
          ..autoMode = mode
          ..isAutoPingRunning = true
          ..autoPingSkipReason = PingService.skipReasonRecentlyCovered
          ..autoPingEndsAt = _deadline;
        expect(_resolve(a).title, 'Deferred', reason: 'mode $mode');
      }
    });
  });

  test('the repeater name is only resolved when a branch needs it', () {
    // Naming a repeater walks the whole zone catalogue, and the resolver runs
    // on every notify, so only the three targeted branches may ask. Checked on
    // the all-clear args, which walk every branch condition to the last row.
    final a = _Args();
    _resolve(a);
    expect(a.nameLookups, 0, reason: 'the resting row names no target');

    final trace = _Args()
      ..autoMode = AutoMode.targeted
      ..operation = SessionOperation.tracing;
    _resolve(trace);
    expect(trace.nameLookups, 1);
  });
}
