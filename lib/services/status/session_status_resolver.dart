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
  // [onGlance] decides whether an observation can win the single glance answer
  // as well as its own lane. It is true for every state now: the two the phone
  // used to show alone (an auto ping in flight before it transmits, and the
  // shared post-stop cooldown) reach the glance too. The shared cooldown only
  // wins post-stop, where the Live Activity session has already ended and the
  // native projection reads it as idle, so making it reachable changes no
  // pixels; the sending gap does, on the Live Activity, watch and Siri.
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

  // A pending disable is handled as a glance override at the end, NOT as a lane
  // observation. It is the session stopping, which the single-phase surfaces and
  // the Active button say, but it must not sit on any lane, or it would shadow
  // the very window that lane is still closing (the auto echo on the TX lane,
  // the discovery window on Hybrid's TX lane), which is what every other button
  // still reads. So every lane records its real activity below and the stop is
  // layered over only the glance.

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

  // An auto TX ping that has been asked for but has not transmitted yet. The
  // phone has always shown this; now the glance surfaces do too, closing the
  // gap where their only route to "sending" was a latch set at the moment of
  // transmit, several seconds later, so they said "active" in between. Gated on
  // the TX loop running, because a manual ping also holds `isPingInProgress` and
  // belongs to the manual lane (the button beside it must not read "Sending" for
  // it). Gated on no skip reason, because `isPingInProgress` latches at the top
  // of the send, before the fresh fix and validation: an attempt that is about
  // to defer (covered) or skip (25 m) still holds it, and would otherwise flash
  // "Sending" for the length of the GPS read before dropping to Deferred/Skipped
  // (the Hybrid-while-parked flapping). A real send has already cleared the skip
  // reason by the time it validates, so it still reads Sending.
  if (isTxModeRunning &&
      isPingInProgress &&
      autoPingSkipReason == null &&
      !isRxWindowRunning &&
      !isDiscoveryWindowRunning) {
    see(StatusLane.txAuto, SessionActivity.sending);
  }

  // Observed whenever the manual cooldown is running, shown on the glance
  // surfaces only when the session is a manual one, exactly like the manual
  // send above. The button needs it either way: a manual ping during a Passive
  // drive holds this cooldown while the manual-session flag stays false, and if
  // the manual lane did not carry it the Send Ping button would count down the
  // discovery interval that happens to be first in the order instead.
  if (isManualCooldownRunning) {
    see(StatusLane.manual, SessionActivity.cooldown,
        deadline: manualCooldown, onGlance: isManualSession);
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
  // count it down. It reaches the glance answer too now, but only ever wins it
  // post-stop, where the auto interval no longer outranks it. There the Live
  // Activity session has already ended (so it never publishes this) and the
  // watch and Siri project it to idle (`resolveWatchSurfacePhase`, keyed on
  // there being no glance session), so the wrist still reads "Ready". The model
  // is honest without a pixel moving.
  if (isSharedCooldownRunning) {
    see(StatusLane.txAuto, SessionActivity.cooldown, deadline: sharedCooldown);
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
    // Not this lane's turn. It reports the thing that is holding it up, with
    // that thing's own activity and deadline, so the button can count down the
    // window it is waiting on and decide for itself whether to borrow it. A
    // session-wide hold does the same above; this makes the per-lane hold match.
    if (first != null) {
      return (
        activity: first.activity,
        deadline: first.deadline,
        isBlocked: true
      );
    }
    return (activity: resting, deadline: null, isBlocked: false);
  }

  // The glance answer. A pending disable is the session stopping: it outranks
  // every observation here and names the Active lane as the owner, but it is
  // laid over the glance only, so each lane above still carries its own closing
  // window. Its deadline is whichever window is still shutting (both can be shut,
  // the case the 12 second backstop covers, and then there is nothing to count).
  final (
    SessionActivity glanceActivity,
    StatusLane? glanceOwner,
    StatusDeadline? glanceDeadline
  ) = isPendingDisable
      ? (
          SessionActivity.stopping,
          StatusLane.txAuto,
          rxWindow ?? discoveryWindow
        )
      : (
          firstOnGlance?.activity ?? resting,
          firstOnGlance?.lane,
          firstOnGlance?.deadline
        );

  return (
    activity: glanceActivity,
    owner: glanceOwner,
    deadline: glanceDeadline,
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
  // A pending disable is NOT a session-wide hold: the mode being stopped is
  // still running its closing window, and only the Active button and the glance
  // say Stopping. It is recorded as a high-precedence observation instead (see
  // the caller), so it still outranks GPS and a blocked zone, both skipped here
  // while it is set, without flattening every lane onto one deadline.
  if (isPendingDisable) return null;
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
