import '../../models/connection_state.dart';
import '../../providers/app_state_provider.dart' show AutoMode;
import '../live_activity/live_activity_models.dart';
import 'session_status.dart';
import 'session_status_resolver.dart';

/// The session phase every glance surface describes.
///
/// A rendering, not a decision. What state the session is in is worked out once
/// by [resolveSessionStatus], which the in-app buttons read too; this turns that
/// one answer into the title and detail the Live Activity, the watch and Siri
/// show. Two states still carry more than one sentence, and those are noted
/// where they happen.
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
  StatusDeadline? at(DateTime? endsAt) =>
      endsAt == null ? null : (endsAt: endsAt, durationMs: null);

  final status = resolveSessionStatus(
    isInZoneGracePeriod: isInZoneGracePeriod,
    zoneGraceEndsAt: zoneGraceEndsAt,
    isZoneTransferInProgress: isZoneTransferInProgress,
    isAutoReconnecting: isAutoReconnecting,
    connectionStep: connectionStep,
    isConnected: isConnected,
    isPendingDisable: isPendingDisable,
    isGpsLocked: gpsStatus == GpsStatus.locked,
    autoMode: autoMode,
    txAllowed: txAllowed,
    isManualSession: isManualSession,
    isPingSending: isPingSending,
    isRxWindowRunning: isRxWindowRunning,
    rxWindow: at(rxWindowEndsAt),
    isDiscoveryWindowRunning: isDiscoveryWindowRunning,
    discoveryWindow: at(discoveryWindowEndsAt),
    isManualCooldownRunning: isManualCooldownRunning,
    manualCooldown: at(manualCooldownEndsAt),
    isAutoPingRunning: isAutoPingRunning,
    autoPingSkipReason: autoPingSkipReason,
    autoPing: at(autoPingEndsAt),
    operation: operation,
    isSessionStarting: isSessionStarting,
    isSessionActive: isSessionActive,
  );

  final (String title, String? detail) = switch (status.activity) {
    // Two titles for one state. The model says the session is paused outside a
    // zone; which sentence says so is a wording choice, and the vocabulary work
    // may well collapse them.
    SessionActivity.pausedOutsideZone => isInZoneGracePeriod
        ? ('Outside service area', 'Searching for a nearby wardriving zone')
        : (
            'Changing region…',
            [zoneTransferFrom, zoneTransferTo].whereType<String>().join(' → ')
          ),
    SessionActivity.disconnected =>
      isAutoReconnecting || connectionStep == ConnectionStep.reconnecting
          ? ('Reconnecting…', 'Restoring MeshCore connection')
          : (
              connectionStep == ConnectionStep.disconnecting
                  ? 'Disconnecting…'
                  : 'Device disconnected',
              'Open MeshMapper to reconnect'
            ),
    SessionActivity.stopping => (
        'Stopping…',
        'Finishing the current listening window'
      ),
    SessionActivity.waitingForGps => (
        'Waiting for GPS',
        gpsPhaseLabel(gpsStatus)
      ),
    SessionActivity.txBlocked => (
        'TX unavailable',
        'This zone is currently passive-only'
      ),
    SessionActivity.sending => ('Sending ping…', null),
    SessionActivity.listeningDiscovery => ('Listening…', 'Discovery responses'),
    SessionActivity.listeningTrace => (
        'Listening for trace…',
        targetRepeaterName()
      ),
    SessionActivity.listening => ('Listening…', 'Waiting for repeater echoes'),
    SessionActivity.cooldown => (
        'Cooldown',
        'Manual ping available when the timer ends'
      ),
    SessionActivity.deferred => (
        'Deferred',
        'Recently covered, waiting for a fresh square'
      ),
    SessionActivity.skipped => (
        'Ping skipped',
        'Move at least $minDistanceMetres m'
      ),
    SessionActivity.waitingDiscovery => ('Next discovery', null),
    SessionActivity.waitingTrace => ('Next trace', targetRepeaterName()),
    SessionActivity.waiting => ('Next ping', null),
    SessionActivity.discovering => (
        'Discovering…',
        'Requesting nearby repeaters'
      ),
    SessionActivity.tracing => ('Tracing repeater…', targetRepeaterName()),
    SessionActivity.starting => ('Preparing session…', null),
    SessionActivity.active => (
        '$modeTitle active',
        'Waiting for the next cycle'
      ),
    // Watch only, and produced by that surface's own projection rather than
    // here, so it can never reach this switch from a live session.
    SessionActivity.idle => ('Ready', 'No session running'),
  };

  return (
    phase: status.activity,
    title: title,
    detail: detail,
    endsAt: status.deadline?.endsAt,
  );
}
