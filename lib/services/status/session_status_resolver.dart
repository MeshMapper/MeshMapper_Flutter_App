import '../../models/connection_state.dart';
import '../../providers/app_state_provider.dart' show AutoMode;
import '../ping_service.dart';
import 'session_status.dart';

/// Resolve the whole session, once, from facts.
///
/// The precedence lives here and nowhere else. It is expressed as one ordered
/// list of observations: the single-phase surfaces take the first, and each
/// button takes the first that belongs to its own lane. That is what makes
/// "the surfaces cannot disagree" structural rather than a convention, because
/// a surface can only report a state some lane is actually in.
///
/// Pure: no clock, no I/O, no live objects. Every timer arrives as a running
/// flag plus an absolute deadline, so the same inputs always give the same
/// answer and the value is stable between countdown ticks.
SessionStatus resolveSessionStatus({
  required bool isInZoneGracePeriod,
  required DateTime? zoneGraceEndsAt,
  required bool isZoneTransferInProgress,
  required bool isAutoReconnecting,
  required ConnectionStep connectionStep,
  required bool isConnected,
  required bool isPendingDisable,
  required bool isGpsLocked,
  required AutoMode autoMode,
  required bool txAllowed,
  required bool isManualSession,
  required bool isPingSending,
  required bool isPingInProgress,
  required bool isRxWindowRunning,
  required StatusDeadline? rxWindow,
  required bool isDiscoveryWindowRunning,
  required StatusDeadline? discoveryWindow,
  required bool isManualCooldownRunning,
  required StatusDeadline? manualCooldown,
  required bool isAutoPingRunning,
  required String? autoPingSkipReason,
  required StatusDeadline? autoPing,
  required bool isSharedCooldownRunning,
  required StatusDeadline? sharedCooldown,
  required SessionOperation? operation,
  required bool isSessionStarting,
  required bool isSessionActive,
}) {
  // Ranks 1 to 7: the session as a whole is unavailable, so no lane is acting
  // and every button is held for the same reason.
  final sessionWide = _sessionWide(
    isInZoneGracePeriod: isInZoneGracePeriod,
    zoneGraceEndsAt: zoneGraceEndsAt,
    isZoneTransferInProgress: isZoneTransferInProgress,
    isAutoReconnecting: isAutoReconnecting,
    connectionStep: connectionStep,
    isConnected: isConnected,
    isPendingDisable: isPendingDisable,
    isGpsLocked: isGpsLocked,
    autoMode: autoMode,
    txAllowed: txAllowed,
    isRxWindowRunning: isRxWindowRunning,
    rxWindow: rxWindow,
    isDiscoveryWindowRunning: isDiscoveryWindowRunning,
    discoveryWindow: discoveryWindow,
  );
  if (sessionWide != null) {
    final held = (
      activity: sessionWide.activity,
      deadline: sessionWide.deadline,
      isBlocked: true,
    );
    return (
      activity: sessionWide.activity,
      owner: null,
      deadline: sessionWide.deadline,
      manual: held,
      txAuto: held,
      discovery: held,
      targeted: held,
    );
  }

  // Ranks 8 to 18, in order. Each observation names the lane it belongs to.
  //
  // [onGlance] is false for the two states the phone already shows and the
  // Live Activity, watch and Siri do not. The model records them because the
  // buttons need them; the glance answer skips them so this commit changes
  // nothing anyone can see. Flipping either to true is the whole of that
  // disagreement's fix, and the phase table will show it as a diff.
  final observations = <({
    StatusLane lane,
    SessionActivity activity,
    StatusDeadline? deadline,
    bool onGlance,
  })>[];

  void see(
    StatusLane lane,
    SessionActivity activity, {
    StatusDeadline? deadline,
    bool onGlance = true,
  }) =>
      observations.add((
        lane: lane,
        activity: activity,
        deadline: deadline,
        onGlance: onGlance
      ));

  // The TX loop's own idea of whether it is running, which is also how the
  // buttons decide who owns a listening window.
  final isTxModeRunning = isSessionActive &&
      (autoMode == AutoMode.active || autoMode == AutoMode.hybrid);

  // Observed whenever a manual send is in flight, but only shown on the glance
  // surfaces when the session is a manual one, which is today's rule. A manual
  // ping during a Passive drive raises this flag without owning the session,
  // and the Send Ping button has always said so even though the watch has not.
  if (isPingSending) {
    see(StatusLane.manual, SessionActivity.sending, onGlance: isManualSession);
  }

  if (isDiscoveryWindowRunning) {
    // In Hybrid the discovery leg is the TX loop's own, which is why the
    // Active button counts it down and the Passive button does not.
    final lane = switch (autoMode) {
      AutoMode.targeted => StatusLane.targeted,
      AutoMode.hybrid => StatusLane.txAuto,
      _ => StatusLane.discovery,
    };
    see(
      lane,
      autoMode == AutoMode.targeted
          ? SessionActivity.listeningTrace
          : SessionActivity.listeningDiscovery,
      deadline: discoveryWindow,
    );
  }

  if (isRxWindowRunning) {
    // Whoever is transmitting owns the echo window. Not the manual-session
    // flag: that tracks which surface opened the glance session, and a manual
    // ping fired during a Passive drive leaves it false while still being the
    // ping the window belongs to.
    final lane = isTxModeRunning ? StatusLane.txAuto : StatusLane.manual;
    see(lane, SessionActivity.listening, deadline: rxWindow);
  }

  // An auto ping that has been asked for but has not transmitted yet. The
  // phone has always shown this; the glance surfaces have not, because their
  // only route to "sending" is a latch set at the moment of transmit, several
  // seconds later. That is the auto-session sending gap.
  if (isPingInProgress && !isRxWindowRunning && !isDiscoveryWindowRunning) {
    see(StatusLane.txAuto, SessionActivity.sending, onGlance: false);
  }

  if (isManualSession && isManualCooldownRunning) {
    see(StatusLane.manual, SessionActivity.cooldown, deadline: manualCooldown);
  }

  if (isAutoPingRunning) {
    final lane = _autoLane(autoMode);
    final activity = autoPingSkipReason != null
        ? (autoPingSkipReason == PingService.skipReasonRecentlyCovered
            ? SessionActivity.deferred
            : SessionActivity.skipped)
        : switch (autoMode) {
            AutoMode.passive => SessionActivity.waitingDiscovery,
            AutoMode.targeted => SessionActivity.waitingTrace,
            _ => SessionActivity.waiting,
          };
    see(lane, activity, deadline: autoPing);
  }

  if (operation != null) {
    final (lane, activity) = switch (operation) {
      SessionOperation.sending => (StatusLane.txAuto, SessionActivity.sending),
      SessionOperation.discovering => (
          autoMode == AutoMode.hybrid
              ? StatusLane.txAuto
              : StatusLane.discovery,
          SessionActivity.discovering
        ),
      SessionOperation.tracing => (
          StatusLane.targeted,
          SessionActivity.tracing
        ),
    };
    see(lane, activity);
  }

  // The five second cooldown that follows stopping a TX mode. Three buttons
  // count it down and no glance surface has ever known about it: for those
  // five seconds the watch says "Ready, no session running" while the phone
  // says "Cooldown 5s".
  if (isSharedCooldownRunning) {
    see(StatusLane.txAuto, SessionActivity.cooldown,
        deadline: sharedCooldown, onGlance: false);
  }

  // Ranks 19 and 20: nothing is happening yet, or nothing is happening now.
  final resting = isSessionStarting || !isSessionActive
      ? SessionActivity.starting
      : SessionActivity.active;

  final first = observations.isEmpty ? null : observations.first;
  final firstOnGlance = observations.where((o) => o.onGlance).firstOrNull;

  LaneStatus viewFor(StatusLane lane) {
    for (final o in observations) {
      if (o.lane == lane) {
        return (activity: o.activity, deadline: o.deadline, isBlocked: false);
      }
    }
    // Not this lane's turn. It reports what is holding it up, so the button can
    // count down the window it is waiting on rather than inventing its own.
    if (first != null) {
      return (
        activity: SessionActivity.cooldown,
        deadline: first.deadline,
        isBlocked: true
      );
    }
    return (activity: resting, deadline: null, isBlocked: false);
  }

  return (
    activity: firstOnGlance?.activity ?? resting,
    owner: firstOnGlance?.lane,
    deadline: firstOnGlance?.deadline,
    manual: viewFor(StatusLane.manual),
    txAuto: viewFor(StatusLane.txAuto),
    discovery: viewFor(StatusLane.discovery),
    targeted: viewFor(StatusLane.targeted),
  );
}

StatusLane _autoLane(AutoMode mode) => switch (mode) {
      AutoMode.passive => StatusLane.discovery,
      AutoMode.targeted => StatusLane.targeted,
      _ => StatusLane.txAuto,
    };

({SessionActivity activity, StatusDeadline? deadline})? _sessionWide({
  required bool isInZoneGracePeriod,
  required DateTime? zoneGraceEndsAt,
  required bool isZoneTransferInProgress,
  required bool isAutoReconnecting,
  required ConnectionStep connectionStep,
  required bool isConnected,
  required bool isPendingDisable,
  required bool isGpsLocked,
  required AutoMode autoMode,
  required bool txAllowed,
  required bool isRxWindowRunning,
  required StatusDeadline? rxWindow,
  required bool isDiscoveryWindowRunning,
  required StatusDeadline? discoveryWindow,
}) {
  if (isInZoneGracePeriod) {
    return (
      activity: SessionActivity.pausedOutsideZone,
      deadline: zoneGraceEndsAt == null
          ? null
          : (endsAt: zoneGraceEndsAt, durationMs: null, remainingSec: 0),
    );
  }
  if (isZoneTransferInProgress) {
    return (activity: SessionActivity.pausedOutsideZone, deadline: null);
  }
  if (isAutoReconnecting || connectionStep == ConnectionStep.reconnecting) {
    return (activity: SessionActivity.disconnected, deadline: null);
  }
  if (!isConnected) {
    return (activity: SessionActivity.disconnected, deadline: null);
  }
  if (isPendingDisable) {
    return (
      activity: SessionActivity.stopping,
      // Whichever window is still open. Both can be shut, which is exactly the
      // case the 12 second backstop covers, and then there is nothing to count.
      deadline: rxWindow ?? discoveryWindow,
    );
  }
  if (!isGpsLocked) {
    return (activity: SessionActivity.waitingForGps, deadline: null);
  }
  if ((autoMode == AutoMode.active ||
          autoMode == AutoMode.hybrid ||
          autoMode == AutoMode.targeted) &&
      !txAllowed) {
    return (activity: SessionActivity.txBlocked, deadline: null);
  }
  return null;
}
