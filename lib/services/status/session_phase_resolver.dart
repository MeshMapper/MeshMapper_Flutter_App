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
      GpsStatus.searching => 'Finding your location',
      GpsStatus.locked => 'GPS locked',
      GpsStatus.outsideGeofence => 'Outside a zone',
    };

/// The Trace target as a spoken phrase, or null when the repeater is unnamed.
/// These keep the name logic out of the switch arms so [targetRepeaterName] is
/// still resolved exactly once, only inside a targeted branch.
String? _traceReplyDetail(String? name) =>
    name == null ? null : 'Waiting for $name to reply';

String? _nextTraceDetail(String? name) => name == null ? null : 'To $name';

String _tracingTitle(String? name) => name == null ? 'Tracing' : 'Tracing $name';

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
  required bool isOfflineMode,
  required bool isManualSession,
  required bool isPingSending,
  required bool isPingInProgress,
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
  required bool isSharedCooldownRunning,
  required DateTime? sharedCooldownEndsAt,
  required int minDistanceMetres,
  required SessionOperation? operation,
  required bool isSessionStarting,
  required bool isSessionActive,
  required String modeTitle,
}) {
  StatusDeadline? at(DateTime? endsAt) => endsAt == null
      ? null
      : (endsAt: endsAt, durationMs: null, remainingSec: 0);

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
    // The glance surfaces now see these two, so they pass through rather than
    // being shimmed off: an auto ping in flight before it transmits reads
    // "Sending ping", and the shared post-stop cooldown reads "Cooldown" (which
    // only the model and the phone see, since the watch and Siri project it to
    // idle and the Live Activity session has already ended by then).
    isPingInProgress: isPingInProgress,
    isSharedCooldownRunning: isSharedCooldownRunning,
    sharedCooldown: at(sharedCooldownEndsAt),
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
    // Two titles for one state: the session is paused outside a zone, and which
    // sentence says so depends on whether this is the grace period or an active
    // transfer to a new one.
    SessionActivity.pausedOutsideZone => isInZoneGracePeriod
        ? ('Outside a zone', 'Searching for a nearby wardriving zone')
        : (
            'Switching zones',
            zoneTransferTo == null ? '' : 'Moving to $zoneTransferTo'
          ),
    SessionActivity.disconnected =>
      isAutoReconnecting || connectionStep == ConnectionStep.reconnecting
          ? ('Reconnecting', 'Restoring the connection')
          : (
              connectionStep == ConnectionStep.disconnecting
                  ? 'Disconnecting'
                  : 'Disconnected',
              'Open MeshMapper to reconnect'
            ),
    SessionActivity.stopping => (
        'Stopping',
        'Finishing the current listening window'
      ),
    SessionActivity.waitingForGps => (
        'Waiting for GPS',
        gpsPhaseLabel(gpsStatus)
      ),
    // Discovery is a zero-hop TX and stays allowed here, so the state is Passive,
    // not "listen only". The cause of the block picks the detail.
    SessionActivity.txBlocked => (
        'Passive only',
        isOfflineMode
            ? 'Only Passive mode works in Offline Mode'
            : 'Only Passive mode works in this zone'
      ),
    SessionActivity.sending => ('Sending ping', null),
    SessionActivity.listeningDiscovery => ('Listening', 'Waiting for replies'),
    SessionActivity.listeningTrace => (
        'Listening',
        _traceReplyDetail(targetRepeaterName())
      ),
    SessionActivity.listening => ('Listening', 'Waiting for repeater echoes'),
    SessionActivity.cooldown => (
        'Cooldown',
        'You can ping again when this ends'
      ),
    SessionActivity.deferred => (
        'Deferred',
        'Waiting for a square with no recent mapping'
      ),
    SessionActivity.skipped => (
        'Skipped',
        'Move at least $minDistanceMetres m to ping'
      ),
    SessionActivity.waitingDiscovery => ('Next discovery', null),
    SessionActivity.waitingTrace => (
        'Next trace',
        _nextTraceDetail(targetRepeaterName())
      ),
    SessionActivity.waiting => ('Next ping', null),
    SessionActivity.discovering => (
        'Discovering',
        'Looking for nearby repeaters'
      ),
    SessionActivity.tracing => (_tracingTitle(targetRepeaterName()), null),
    SessionActivity.starting => ('Starting', 'Getting the session ready'),
    SessionActivity.active => ('$modeTitle mode', 'Wardriving'),
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
