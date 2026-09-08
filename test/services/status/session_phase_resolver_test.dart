import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/connection_state.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart' show AutoMode;
import 'package:mesh_mapper/services/live_activity/live_activity_models.dart';
import 'package:mesh_mapper/services/ping_service.dart';
import 'package:mesh_mapper/services/status/session_phase_resolver.dart';
import 'package:mesh_mapper/services/status/session_status.dart';

/// One golden row per return site in [resolveSessionPhase], plus the branch
/// orderings where two conditions are true at once. This is the table that
/// makes "no user-visible change" checkable: any wording or precedence move
/// shows up here as a diff rather than on a phone.

final _deadline = DateTime.utc(2026, 1, 1, 12);
final _other = DateTime.utc(2026, 1, 1, 13);

/// Defaults are the all-clear session: connected, GPS locked, nothing running.
/// It falls through every branch to the last one, so each test below overrides
/// only the facts its own branch needs.
ResolvedPhase phase({
  bool isInZoneGracePeriod = false,
  DateTime? zoneGraceEndsAt,
  bool isZoneTransferInProgress = false,
  String? zoneTransferFrom,
  String? zoneTransferTo,
  bool isAutoReconnecting = false,
  ConnectionStep connectionStep = ConnectionStep.connected,
  bool isConnected = true,
  bool isPendingDisable = false,
  GpsStatus gpsStatus = GpsStatus.locked,
  AutoMode autoMode = AutoMode.active,
  bool txAllowed = true,
  bool isManualSession = false,
  bool isPingSending = false,
  String? targetRepeaterName = 'Beacon Hill',
  bool isRxWindowRunning = false,
  DateTime? rxWindowEndsAt,
  bool isDiscoveryWindowRunning = false,
  DateTime? discoveryWindowEndsAt,
  bool isManualCooldownRunning = false,
  DateTime? manualCooldownEndsAt,
  bool isAutoPingRunning = false,
  String? autoPingSkipReason,
  DateTime? autoPingEndsAt,
  int minDistanceMetres = 25,
  SessionOperation? operation,
  bool isSessionStarting = false,
  bool isSessionActive = true,
  String modeTitle = 'Active',
}) =>
    resolveSessionPhase(
      isInZoneGracePeriod: isInZoneGracePeriod,
      zoneGraceEndsAt: zoneGraceEndsAt,
      isZoneTransferInProgress: isZoneTransferInProgress,
      zoneTransferFrom: zoneTransferFrom,
      zoneTransferTo: zoneTransferTo,
      isAutoReconnecting: isAutoReconnecting,
      connectionStep: connectionStep,
      isConnected: isConnected,
      isPendingDisable: isPendingDisable,
      gpsStatus: gpsStatus,
      autoMode: autoMode,
      txAllowed: txAllowed,
      isManualSession: isManualSession,
      isPingSending: isPingSending,
      targetRepeaterName: () => targetRepeaterName,
      isRxWindowRunning: isRxWindowRunning,
      rxWindowEndsAt: rxWindowEndsAt,
      isDiscoveryWindowRunning: isDiscoveryWindowRunning,
      discoveryWindowEndsAt: discoveryWindowEndsAt,
      isManualCooldownRunning: isManualCooldownRunning,
      manualCooldownEndsAt: manualCooldownEndsAt,
      isAutoPingRunning: isAutoPingRunning,
      autoPingSkipReason: autoPingSkipReason,
      autoPingEndsAt: autoPingEndsAt,
      minDistanceMetres: minDistanceMetres,
      operation: operation,
      isSessionStarting: isSessionStarting,
      isSessionActive: isSessionActive,
      modeTitle: modeTitle,
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

void main() {
  group('one row per return site', () {
    test('zone grace', () {
      expectRow(
        phase(isInZoneGracePeriod: true, zoneGraceEndsAt: _deadline),
        phase: LiveActivityPhase.pausedOutsideZone,
        title: 'Outside service area',
        detail: 'Searching for a nearby wardriving zone',
        endsAt: _deadline,
      );
    });

    test('zone transfer', () {
      expectRow(
        phase(
          isZoneTransferInProgress: true,
          zoneTransferFrom: 'YOW',
          zoneTransferTo: 'PAE',
        ),
        phase: LiveActivityPhase.pausedOutsideZone,
        title: 'Changing region…',
        detail: 'YOW → PAE',
      );
    });

    test('a zone transfer with neither end named still has a blank detail', () {
      // Not a nicety: the join yields the empty string rather than null, so
      // the phase carries a detail that is present and says nothing.
      expect(phase(isZoneTransferInProgress: true).detail, '');
    });

    test('reconnecting', () {
      expectRow(
        phase(isAutoReconnecting: true),
        phase: LiveActivityPhase.disconnected,
        title: 'Reconnecting…',
        detail: 'Restoring MeshCore connection',
      );
    });

    test('the reconnecting step reaches the same row without the flag', () {
      expect(phase(connectionStep: ConnectionStep.reconnecting).title,
          'Reconnecting…');
    });

    test('disconnecting', () {
      expectRow(
        phase(isConnected: false, connectionStep: ConnectionStep.disconnecting),
        phase: LiveActivityPhase.disconnected,
        title: 'Disconnecting…',
        detail: 'Open MeshMapper to reconnect',
      );
    });

    test('disconnected', () {
      expectRow(
        phase(isConnected: false),
        phase: LiveActivityPhase.disconnected,
        title: 'Device disconnected',
        detail: 'Open MeshMapper to reconnect',
      );
    });

    test('every other connection step collapses to the same two words', () {
      // The branch is a two-way ternary, not a per-step description.
      for (final step in [
        ConnectionStep.transportConnecting,
        ConnectionStep.error,
        ConnectionStep.connected,
      ]) {
        expect(phase(isConnected: false, connectionStep: step).title,
            'Device disconnected',
            reason: 'step $step');
      }
    });

    test('stopping takes the RX window deadline first', () {
      expectRow(
        phase(
          isPendingDisable: true,
          isRxWindowRunning: true,
          rxWindowEndsAt: _deadline,
          isDiscoveryWindowRunning: true,
          discoveryWindowEndsAt: _other,
        ),
        phase: LiveActivityPhase.stopping,
        title: 'Stopping…',
        detail: 'Finishing the current listening window',
        endsAt: _deadline,
      );
    });

    test('stopping falls back to the discovery deadline', () {
      expect(
        phase(
          isPendingDisable: true,
          isDiscoveryWindowRunning: true,
          discoveryWindowEndsAt: _other,
        ).endsAt,
        _other,
      );
    });

    test('stopping can have no deadline at all', () {
      // The 12 second pending-disable backstop is exactly the case where no
      // window is open, so the countdown has nothing to show.
      expect(phase(isPendingDisable: true).endsAt, isNull);
    });

    test('waiting for GPS names the reason', () {
      const labels = {
        GpsStatus.permissionDenied: 'Location permission required',
        GpsStatus.disabled: 'Location services disabled',
        GpsStatus.searching: 'Searching for GPS signal',
        GpsStatus.outsideGeofence: 'Outside service area',
      };
      labels.forEach((status, label) {
        expectRow(
          phase(gpsStatus: status),
          phase: LiveActivityPhase.waitingForGps,
          title: 'Waiting for GPS',
          detail: label,
        );
      });
    });

    test('TX blocked, for the three transmitting modes only', () {
      for (final mode in [AutoMode.active, AutoMode.hybrid, AutoMode.targeted]) {
        expectRow(
          phase(autoMode: mode, txAllowed: false, modeTitle: 'Active'),
          phase: LiveActivityPhase.txBlocked,
          title: 'TX unavailable',
          detail: 'This zone is currently passive-only',
        );
      }
      expect(phase(autoMode: AutoMode.passive, txAllowed: false).phase,
          isNot(LiveActivityPhase.txBlocked),
          reason: 'a passive session is not blocked by a passive-only zone');
    });

    test('a manual send', () {
      expectRow(
        phase(isManualSession: true, isPingSending: true, modeTitle: 'Manual'),
        phase: LiveActivityPhase.sending,
        title: 'Sending ping…',
      );
    });

    test('listening for discovery responses', () {
      expectRow(
        phase(
          autoMode: AutoMode.passive,
          isDiscoveryWindowRunning: true,
          discoveryWindowEndsAt: _deadline,
        ),
        phase: LiveActivityPhase.listeningDiscovery,
        title: 'Listening…',
        detail: 'Discovery responses',
        endsAt: _deadline,
      );
    });

    test('listening for a trace names the repeater', () {
      expectRow(
        phase(
          autoMode: AutoMode.targeted,
          isDiscoveryWindowRunning: true,
          discoveryWindowEndsAt: _deadline,
        ),
        phase: LiveActivityPhase.listeningTrace,
        title: 'Listening for trace…',
        detail: 'Beacon Hill',
        endsAt: _deadline,
      );
    });

    test('listening for echoes', () {
      expectRow(
        phase(isRxWindowRunning: true, rxWindowEndsAt: _deadline),
        phase: LiveActivityPhase.listening,
        title: 'Listening…',
        detail: 'Waiting for repeater echoes',
        endsAt: _deadline,
      );
    });

    test('the manual cooldown, which needs a manual session', () {
      expectRow(
        phase(
          isManualSession: true,
          isManualCooldownRunning: true,
          manualCooldownEndsAt: _deadline,
          modeTitle: 'Manual',
        ),
        phase: LiveActivityPhase.cooldown,
        title: 'Cooldown',
        detail: 'Manual ping available when the timer ends',
        endsAt: _deadline,
      );
      expect(
        phase(isManualCooldownRunning: true, manualCooldownEndsAt: _deadline)
            .phase,
        isNot(LiveActivityPhase.cooldown),
        reason: 'an auto session never reaches the manual cooldown row',
      );
    });

    test('deferred', () {
      expectRow(
        phase(
          isAutoPingRunning: true,
          autoPingSkipReason: PingService.skipReasonRecentlyCovered,
          autoPingEndsAt: _deadline,
        ),
        phase: LiveActivityPhase.deferred,
        title: 'Deferred',
        detail: 'Recently covered, waiting for a fresh square',
        endsAt: _deadline,
      );
    });

    test('skipped, and it quotes the configured distance', () {
      expectRow(
        phase(
          isAutoPingRunning: true,
          autoPingSkipReason: 'too close',
          autoPingEndsAt: _deadline,
          minDistanceMetres: 50,
        ),
        phase: LiveActivityPhase.skipped,
        title: 'Ping skipped',
        detail: 'Move at least 50 m',
        endsAt: _deadline,
      );
    });

    test('any unknown skip reason reads as skipped', () {
      // Only the recently-covered reason is a named constant; 'too close' is a
      // bare literal and the doc comment advertises a third nobody sets.
      expect(
        phase(
          isAutoPingRunning: true,
          autoPingSkipReason: 'gps too old',
          autoPingEndsAt: _deadline,
        ).title,
        'Ping skipped',
      );
    });

    test('next discovery', () {
      expectRow(
        phase(
          autoMode: AutoMode.passive,
          isAutoPingRunning: true,
          autoPingEndsAt: _deadline,
        ),
        phase: LiveActivityPhase.waitingDiscovery,
        title: 'Next discovery',
        endsAt: _deadline,
      );
    });

    test('next trace', () {
      expectRow(
        phase(
          autoMode: AutoMode.targeted,
          isAutoPingRunning: true,
          autoPingEndsAt: _deadline,
        ),
        phase: LiveActivityPhase.waitingTrace,
        title: 'Next trace',
        detail: 'Beacon Hill',
        endsAt: _deadline,
      );
    });

    test('next ping', () {
      expectRow(
        phase(isAutoPingRunning: true, autoPingEndsAt: _deadline),
        phase: LiveActivityPhase.waiting,
        title: 'Next ping',
        endsAt: _deadline,
      );
    });

    test('the operation latch: sending, discovering, tracing', () {
      expectRow(
        phase(operation: SessionOperation.sending),
        phase: LiveActivityPhase.sending,
        title: 'Sending ping…',
      );
      expectRow(
        phase(operation: SessionOperation.discovering),
        phase: LiveActivityPhase.discovering,
        title: 'Discovering…',
        detail: 'Requesting nearby repeaters',
      );
      expectRow(
        phase(operation: SessionOperation.tracing),
        phase: LiveActivityPhase.tracing,
        title: 'Tracing repeater…',
        detail: 'Beacon Hill',
      );
    });

    test('preparing a session', () {
      expectRow(
        phase(isSessionStarting: true),
        phase: LiveActivityPhase.starting,
        title: 'Preparing session…',
      );
      expectRow(
        phase(isSessionActive: false),
        phase: LiveActivityPhase.starting,
        title: 'Preparing session…',
      );
    });

    test('the resting row repeats the mode word', () {
      expectRow(
        phase(),
        phase: LiveActivityPhase.active,
        title: 'Active active',
        detail: 'Waiting for the next cycle',
      );
    });
  });

  group('precedence, where two facts are true at once', () {
    test('zone grace outranks a disconnect', () {
      expect(phase(isInZoneGracePeriod: true, isConnected: false).title,
          'Outside service area');
    });

    test('a disconnect outranks a live discovery window', () {
      // Why a stale discovery countdown can never reach a native surface: the
      // in-app buttons have no such guard, which is where that leak shows.
      expect(
        phase(
          isConnected: false,
          isDiscoveryWindowRunning: true,
          discoveryWindowEndsAt: _deadline,
        ).title,
        'Device disconnected',
      );
    });

    test('stopping outranks both listening windows', () {
      expect(
        phase(
          isPendingDisable: true,
          isRxWindowRunning: true,
          rxWindowEndsAt: _deadline,
        ).phase,
        LiveActivityPhase.stopping,
      );
    });

    test('no GPS outranks a TX block', () {
      expect(
        phase(gpsStatus: GpsStatus.searching, txAllowed: false).phase,
        LiveActivityPhase.waitingForGps,
      );
    });

    test('a manual send outranks the windows and the manual cooldown', () {
      // The reason this row exists at all: sendPing raises the sending flag
      // before the manual cooldown refuses the tap, so without the precedence
      // the label would flip to Cooldown mid-send.
      expect(
        phase(
          isManualSession: true,
          isPingSending: true,
          isRxWindowRunning: true,
          rxWindowEndsAt: _deadline,
          isManualCooldownRunning: true,
          manualCooldownEndsAt: _other,
        ).title,
        'Sending ping…',
      );
    });

    test('the discovery window outranks the RX window', () {
      expect(
        phase(
          isDiscoveryWindowRunning: true,
          discoveryWindowEndsAt: _deadline,
          isRxWindowRunning: true,
          rxWindowEndsAt: _other,
        ).endsAt,
        _deadline,
      );
    });

    test('a running interval outranks the operation latch', () {
      // This is the auto-session sending gap, pinned as it stands today: an
      // auto TX in flight still reports the interval it is no longer waiting
      // out. Changing it is a later commit, and this row is what will show it.
      expect(
        phase(
          isAutoPingRunning: true,
          autoPingEndsAt: _deadline,
          operation: SessionOperation.sending,
        ).title,
        'Next ping',
      );
    });
  });

  test('the repeater name is only resolved when a branch needs it', () {
    // Naming a repeater walks the whole zone catalogue, and the resolver runs
    // on every notify, so the three targeted branches must be the only callers.
    var calls = 0;
    String? name() {
      calls++;
      return 'Beacon Hill';
    }

    resolveSessionPhase(
      isInZoneGracePeriod: false,
      zoneGraceEndsAt: null,
      isZoneTransferInProgress: false,
      zoneTransferFrom: null,
      zoneTransferTo: null,
      isAutoReconnecting: false,
      connectionStep: ConnectionStep.connected,
      isConnected: true,
      isPendingDisable: false,
      gpsStatus: GpsStatus.locked,
      autoMode: AutoMode.active,
      txAllowed: true,
      isManualSession: false,
      isPingSending: false,
      targetRepeaterName: name,
      isRxWindowRunning: true,
      rxWindowEndsAt: _deadline,
      isDiscoveryWindowRunning: false,
      discoveryWindowEndsAt: null,
      isManualCooldownRunning: false,
      manualCooldownEndsAt: null,
      isAutoPingRunning: false,
      autoPingSkipReason: null,
      autoPingEndsAt: null,
      minDistanceMetres: 25,
      operation: null,
      isSessionStarting: false,
      isSessionActive: true,
      modeTitle: 'Active',
    );

    expect(calls, 0, reason: 'an echo-listening session never names a target');
  });
}
