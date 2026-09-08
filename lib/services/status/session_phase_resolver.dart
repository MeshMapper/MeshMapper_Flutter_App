import '../../models/connection_state.dart';
import '../../providers/app_state_provider.dart' show AutoMode;
import '../live_activity/live_activity_models.dart';
import '../ping_service.dart';
import 'session_status.dart';

/// The session phase every glance surface describes, resolved in one place.
///
/// Lifted verbatim out of `AppStateProvider._resolveLiveActivityPhase` so it can
/// be tested: nothing in this suite instantiates the provider, so in this
/// codebase "testable" means "extracted". The branch order below is load
/// bearing and is the order the provider used, unchanged.
///
/// Pure by contract. It reads no clock, no I/O and no live object: every timer
/// arrives as an already-resolved `isRunning` plus an absolute deadline, so the
/// same inputs always give the same answer. [targetRepeaterName] is a function
/// rather than a value because resolving it walks the whole zone repeater
/// catalogue, and only the three targeted branches ever ask.
typedef ResolvedPhase = ({
  LiveActivityPhase phase,
  String title,
  String? detail,
  DateTime? endsAt,
});

/// The label the waiting-for-GPS row carries.
///
/// Public only so the table can pin the [GpsStatus.locked] arm, which no branch
/// can reach: the row that reads this is guarded on the status not being
/// locked. Kept rather than deleted because it is the one place that records
/// the dead arm exists.
String gpsPhaseLabel(GpsStatus status) => switch (status) {
      GpsStatus.permissionDenied => 'Location permission required',
      GpsStatus.disabled => 'Location services disabled',
      GpsStatus.searching => 'Searching for GPS signal',
      GpsStatus.locked => 'GPS locked',
      GpsStatus.outsideGeofence => 'Outside service area',
    };

ResolvedPhase resolveSessionPhase({
  required bool isInZoneGracePeriod,
  required DateTime? zoneGraceEndsAt,
  required bool isZoneTransferInProgress,
  required String? zoneTransferFrom,
  required String? zoneTransferTo,
  required bool isAutoReconnecting,
  required ConnectionStep connectionStep,
  required bool isConnected,
  required bool isPendingDisable,
  required GpsStatus gpsStatus,
  required AutoMode autoMode,
  required bool txAllowed,
  required bool isManualSession,
  required bool isPingSending,
  required String? Function() targetRepeaterName,
  required bool isRxWindowRunning,
  required DateTime? rxWindowEndsAt,
  required bool isDiscoveryWindowRunning,
  required DateTime? discoveryWindowEndsAt,
  required bool isManualCooldownRunning,
  required DateTime? manualCooldownEndsAt,
  required bool isAutoPingRunning,
  required String? autoPingSkipReason,
  required DateTime? autoPingEndsAt,
  required int minDistanceMetres,
  required SessionOperation? operation,
  required bool isSessionStarting,
  required bool isSessionActive,
  required String modeTitle,
}) {
  if (isInZoneGracePeriod) {
    return (
      phase: LiveActivityPhase.pausedOutsideZone,
      title: 'Outside service area',
      detail: 'Searching for a nearby wardriving zone',
      endsAt: zoneGraceEndsAt,
    );
  }

  if (isZoneTransferInProgress) {
    return (
      phase: LiveActivityPhase.pausedOutsideZone,
      title: 'Changing region…',
      detail:
          [zoneTransferFrom, zoneTransferTo].whereType<String>().join(' → '),
      endsAt: null,
    );
  }

  if (isAutoReconnecting || connectionStep == ConnectionStep.reconnecting) {
    return (
      phase: LiveActivityPhase.disconnected,
      title: 'Reconnecting…',
      detail: 'Restoring MeshCore connection',
      endsAt: null,
    );
  }

  if (!isConnected) {
    return (
      phase: LiveActivityPhase.disconnected,
      title: connectionStep == ConnectionStep.disconnecting
          ? 'Disconnecting…'
          : 'Device disconnected',
      detail: 'Open MeshMapper to reconnect',
      endsAt: null,
    );
  }

  if (isPendingDisable) {
    return (
      phase: LiveActivityPhase.stopping,
      title: 'Stopping…',
      detail: 'Finishing the current listening window',
      endsAt: rxWindowEndsAt ?? discoveryWindowEndsAt,
    );
  }

  if (gpsStatus != GpsStatus.locked) {
    return (
      phase: LiveActivityPhase.waitingForGps,
      title: 'Waiting for GPS',
      detail: gpsPhaseLabel(gpsStatus),
      endsAt: null,
    );
  }

  if ((autoMode == AutoMode.active ||
          autoMode == AutoMode.hybrid ||
          autoMode == AutoMode.targeted) &&
      !txAllowed) {
    return (
      phase: LiveActivityPhase.txBlocked,
      title: 'TX unavailable',
      detail: 'This zone is currently passive-only',
      endsAt: null,
    );
  }

  if (isManualSession && isPingSending) {
    return (
      phase: LiveActivityPhase.sending,
      title: 'Sending ping…',
      detail: null,
      endsAt: null,
    );
  }

  if (isDiscoveryWindowRunning) {
    final isTrace = autoMode == AutoMode.targeted;
    return (
      phase: isTrace
          ? LiveActivityPhase.listeningTrace
          : LiveActivityPhase.listeningDiscovery,
      title: isTrace ? 'Listening for trace…' : 'Listening…',
      detail: isTrace ? targetRepeaterName() : 'Discovery responses',
      endsAt: discoveryWindowEndsAt,
    );
  }

  if (isRxWindowRunning) {
    return (
      phase: LiveActivityPhase.listening,
      title: 'Listening…',
      detail: 'Waiting for repeater echoes',
      endsAt: rxWindowEndsAt,
    );
  }

  if (isManualSession && isManualCooldownRunning) {
    return (
      phase: LiveActivityPhase.cooldown,
      title: 'Cooldown',
      detail: 'Manual ping available when the timer ends',
      endsAt: manualCooldownEndsAt,
    );
  }

  if (isAutoPingRunning) {
    final deferred =
        autoPingSkipReason == PingService.skipReasonRecentlyCovered;
    if (autoPingSkipReason != null) {
      return (
        phase:
            deferred ? LiveActivityPhase.deferred : LiveActivityPhase.skipped,
        title: deferred ? 'Deferred' : 'Ping skipped',
        detail: deferred
            ? 'Recently covered, waiting for a fresh square'
            : 'Move at least $minDistanceMetres m',
        endsAt: autoPingEndsAt,
      );
    }

    if (autoMode == AutoMode.passive) {
      return (
        phase: LiveActivityPhase.waitingDiscovery,
        title: 'Next discovery',
        detail: null,
        endsAt: autoPingEndsAt,
      );
    }

    if (autoMode == AutoMode.targeted) {
      return (
        phase: LiveActivityPhase.waitingTrace,
        title: 'Next trace',
        detail: targetRepeaterName(),
        endsAt: autoPingEndsAt,
      );
    }

    return (
      phase: LiveActivityPhase.waiting,
      title: 'Next ping',
      detail: null,
      endsAt: autoPingEndsAt,
    );
  }

  switch (operation) {
    case SessionOperation.sending:
      return (
        phase: LiveActivityPhase.sending,
        title: 'Sending ping…',
        detail: null,
        endsAt: null,
      );
    case SessionOperation.discovering:
      return (
        phase: LiveActivityPhase.discovering,
        title: 'Discovering…',
        detail: 'Requesting nearby repeaters',
        endsAt: null,
      );
    case SessionOperation.tracing:
      return (
        phase: LiveActivityPhase.tracing,
        title: 'Tracing repeater…',
        detail: targetRepeaterName(),
        endsAt: null,
      );
    case null:
      break;
  }

  if (isSessionStarting || !isSessionActive) {
    return (
      phase: LiveActivityPhase.starting,
      title: 'Preparing session…',
      detail: null,
      endsAt: null,
    );
  }

  return (
    phase: LiveActivityPhase.active,
    title: '$modeTitle active',
    detail: 'Waiting for the next cycle',
    endsAt: null,
  );
}
