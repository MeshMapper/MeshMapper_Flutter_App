import '../ping_service.dart';

/// The words the in-app ping controls put on their buttons.
///
/// Lifted verbatim out of `ping_controls.dart`, which built all of them inline
/// from raw timers and flags and shared nothing with the resolver every other
/// surface reads. Extracted for the same reason the phase resolver was: a
/// widget cannot be asked what it would say, so until these are functions there
/// is no way to prove a label did not move.
///
/// Faithful, not tidy. Where two layouts disagree today they still disagree
/// here, each in its own function, because the point of this step is a table
/// that pins the current wording exactly. Collapsing the duplicates is the next
/// step, and the table is what will prove that collapse changed nothing.
///
/// A record rather than a class so equality is structural: the controls hang on
/// a value-compared `context.select`, and a miss costs three full validation
/// passes.
typedef PingControlFacts = ({
  bool isConnected,
  bool externalAntennaSet,
  bool isPowerSet,
  PingValidation validation,
  bool isTxModeRunning,
  bool isPassiveModeRunning,
  bool isTargetedRunning,
  bool isPendingDisable,
  bool isPingSending,
  bool isPingInProgress,
  bool hybridEnabled,
  bool txBlockedByOffline,
  bool txNotAllowed,
  bool rxWindowActive,
  int rxWindowRemaining,
  bool manualCooldownActive,
  int manualCooldownRemaining,
  bool discoveryWindowActive,
  int discoveryWindowRemaining,
  bool cooldownActive,
  int cooldownRemaining,
  bool autoPingWaiting,
  int autoPingRemaining,
  String? autoPingSkipReason,
});

/// Why a ping is refused, as identity rather than as copy.
///
/// The icon and the colour stay in the widget, so no Flutter type reaches this
/// layer; the widget's switch is exhaustive, so a new reason cannot be added
/// here without the renderer failing to compile.
enum StatusHint {
  antennaRequired,
  powerRequired,
  airborne,
  noGpsLock,
  gpsInaccurate,
  outsideServiceArea,
}

/// The countdown word for a paused auto ping. Smart Pinging holds a ping back
/// rather than dropping it, so that case reads "Deferred"; the 25 m distance
/// rule still reads "Skipped".
String pausedWord(String? skipReason) =>
    skipReason == PingService.skipReasonRecentlyCovered
        ? 'Deferred'
        : 'Skipped';

/// The hint under the buttons, in priority order.
///
/// Portrait only today: the compact and landscape layouts read the two button
/// validators but never this one, so a user in either of those gets a silently
/// disabled button and no reason at all.
({StatusHint hint, String text})? blockingHint(PingControlFacts f) {
  if (!f.isConnected) {
    // No hint when disconnected: the buttons are obviously dead.
    return null;
  } else if (!f.externalAntennaSet) {
    return (hint: StatusHint.antennaRequired, text: 'Select antenna option');
  } else if (!f.isPowerSet) {
    return (
      hint: StatusHint.powerRequired,
      text: 'Select power level in Connect tab'
    );
  } else if (f.validation == PingValidation.airborne) {
    return (hint: StatusHint.airborne, text: 'Airborne, wardriving blocked');
  } else if (f.validation == PingValidation.noGpsLock) {
    return (hint: StatusHint.noGpsLock, text: 'Waiting for GPS lock...');
  } else if (f.validation == PingValidation.gpsInaccurate) {
    return (hint: StatusHint.gpsInaccurate, text: 'GPS accuracy too low');
  } else if (f.validation == PingValidation.outsideGeofence) {
    // Dead today: no validator returns outsideGeofence. Kept so the lift is
    // faithful, and so the table records that it is unreachable.
    return (hint: StatusHint.outsideServiceArea, text: 'Outside service area');
  }
  // Cooldown and too-close are deliberately hintless; they show on the button.
  return null;
}

/// Send Ping, portrait.
String portraitSendPingLabel(PingControlFacts f) => f.txBlockedByOffline
    ? 'TX Disabled'
    : f.txNotAllowed
        ? 'Zone Full'
        : f.isTxModeRunning
            ? 'Send Ping'
            : f.isPingSending
                ? 'Sending...'
                : f.rxWindowActive
                    ? 'Listening ${f.rxWindowRemaining}s'
                    : f.manualCooldownActive
                        ? 'Cooldown ${f.manualCooldownRemaining}s'
                        : f.discoveryWindowActive
                            ? 'Cooldown ${f.discoveryWindowRemaining}s'
                            : f.cooldownActive
                                ? 'Cooldown ${f.cooldownRemaining}s'
                                : 'Send Ping';

/// Active / Hybrid, portrait.
String portraitActiveModeLabel(PingControlFacts f) => f.txBlockedByOffline
    ? 'TX Disabled'
    : f.txNotAllowed
        ? 'Zone Full'
        : f.isPendingDisable
            ? (f.rxWindowActive
                ? 'Stopping ${f.rxWindowRemaining}s'
                : f.discoveryWindowActive
                    ? 'Stopping ${f.discoveryWindowRemaining}s'
                    : 'Stopping...')
            : f.isTxModeRunning
                ? (f.isPingInProgress &&
                        !f.rxWindowActive &&
                        !f.discoveryWindowActive
                    ? 'Sending...'
                    : f.discoveryWindowActive
                        ? 'Listening ${f.discoveryWindowRemaining}s'
                        : f.rxWindowActive
                            ? 'Listening ${f.rxWindowRemaining}s'
                            : f.autoPingWaiting
                                ? (f.autoPingSkipReason != null
                                    ? '${pausedWord(f.autoPingSkipReason)} ${f.autoPingRemaining}s'
                                    : 'Next ping ${f.autoPingRemaining}s')
                                : f.hybridEnabled
                                    ? 'Hybrid Mode'
                                    : 'Active Mode')
                : f.rxWindowActive
                    ? 'Cooldown ${f.rxWindowRemaining}s'
                    : f.cooldownActive
                        ? 'Cooldown ${f.cooldownRemaining}s'
                        : f.hybridEnabled
                            ? 'Hybrid Mode'
                            : 'Active Mode';

/// Passive, portrait.
String portraitPassiveModeLabel(PingControlFacts f) => f.isPassiveModeRunning
    ? (f.discoveryWindowActive
        ? 'Listening ${f.discoveryWindowRemaining}s'
        : f.autoPingWaiting
            ? (f.autoPingSkipReason != null
                ? '${pausedWord(f.autoPingSkipReason)} ${f.autoPingRemaining}s'
                : 'Next Disc ${f.autoPingRemaining}s')
            : 'Passive Mode')
    : f.isTxModeRunning || f.isPendingDisable
        ? 'Passive Mode'
        : f.rxWindowActive
            ? 'Cooldown ${f.rxWindowRemaining}s'
            : f.cooldownActive
                ? 'Cooldown ${f.cooldownRemaining}s'
                : 'Passive Mode';

// ---------------------------------------------------------------------------
// Compact layout.
//
// A separate set on purpose: it says different words for the same state than
// portrait does. Waiting for the next auto ping reads "Next ping" expanded and
// "Waiting" minimized, and the Passive button reads "Next Disc" expanded and
// "Waiting" minimized, so a user who collapses the panel watches the word
// change with no state change. Kept as it ships; the vocabulary work settles it.
//
// [showFullText] is the button's own expanded flag, which decides between the
// word and a bare countdown. It is an argument rather than a fact because it
// depends on which button was last active, which is history, not the instant.
// ---------------------------------------------------------------------------

/// Send Ping, compact. Null means the button shows its icon alone.
String? compactSendPingLabel(
  PingControlFacts f, {
  required bool showFullText,
}) {
  if (f.isPingSending) return showFullText ? 'Sending...' : '...';
  if (f.rxWindowActive) {
    return showFullText
        ? 'Listening ${f.rxWindowRemaining}s'
        : '${f.rxWindowRemaining}s';
  }
  if (f.manualCooldownActive) {
    return showFullText
        ? 'Cooldown ${f.manualCooldownRemaining}s'
        : '${f.manualCooldownRemaining}s';
  }
  if (f.discoveryWindowActive) {
    return showFullText
        ? 'Cooldown ${f.discoveryWindowRemaining}s'
        : '${f.discoveryWindowRemaining}s';
  }
  if (f.cooldownActive) {
    return showFullText
        ? 'Cooldown ${f.cooldownRemaining}s'
        : '${f.cooldownRemaining}s';
  }
  return null;
}

/// Active / Hybrid, compact.
String? compactActiveModeLabel(
  PingControlFacts f, {
  required bool showFullText,
  required bool isExpandedDuringCooldown,
}) {
  if (f.isPendingDisable) {
    if (f.rxWindowActive) {
      return showFullText
          ? 'Stopping ${f.rxWindowRemaining}s'
          : '${f.rxWindowRemaining}s';
    }
    if (f.discoveryWindowActive) {
      return showFullText
          ? 'Stopping ${f.discoveryWindowRemaining}s'
          : '${f.discoveryWindowRemaining}s';
    }
    return showFullText ? 'Stopping...' : '...';
  }
  if (f.isTxModeRunning) {
    // Note the order: portrait asks about the send first, compact asks about
    // the discovery window first. Same answer, different written order.
    if (f.discoveryWindowActive) {
      return showFullText
          ? 'Listening ${f.discoveryWindowRemaining}s'
          : '${f.discoveryWindowRemaining}s';
    }
    if (f.isPingInProgress && !f.rxWindowActive) {
      return showFullText ? 'Sending...' : '...';
    }
    if (f.rxWindowActive) {
      return showFullText
          ? 'Listening ${f.rxWindowRemaining}s'
          : '${f.rxWindowRemaining}s';
    }
    if (f.autoPingWaiting) {
      return showFullText
          ? (f.autoPingSkipReason != null
              ? '${pausedWord(f.autoPingSkipReason)} ${f.autoPingRemaining}s'
              : 'Waiting ${f.autoPingRemaining}s')
          : '${f.autoPingRemaining}s';
    }
  }
  if (f.cooldownActive && isExpandedDuringCooldown) {
    return showFullText
        ? 'Cooldown ${f.cooldownRemaining}s'
        : '${f.cooldownRemaining}s';
  }
  return null;
}

/// Passive, compact.
String? compactPassiveModeLabel(
  PingControlFacts f, {
  required bool showFullText,
  required bool isExpandedDuringCooldown,
}) {
  if (f.isPassiveModeRunning) {
    if (f.discoveryWindowActive) {
      return showFullText
          ? 'Listening ${f.discoveryWindowRemaining}s'
          : '${f.discoveryWindowRemaining}s';
    }
    if (f.autoPingWaiting) {
      return showFullText
          ? (f.autoPingSkipReason != null
              ? '${pausedWord(f.autoPingSkipReason)} ${f.autoPingRemaining}s'
              : 'Waiting ${f.autoPingRemaining}s')
          : '${f.autoPingRemaining}s';
    }
  }
  if (f.cooldownActive && isExpandedDuringCooldown) {
    return showFullText
        ? 'Cooldown ${f.cooldownRemaining}s'
        : '${f.cooldownRemaining}s';
  }
  return null;
}

/// Trace, compact.
///
/// The one chain that never says "Deferred": it hardcodes the skipped word
/// instead of asking [pausedWord]. Harmless only because Smart Pinging does not
/// defer a trace today.
String? compactTraceModeLabel(
  PingControlFacts f, {
  required bool showFullText,
  required bool isExpandedDuringCooldown,
}) {
  if (f.isTargetedRunning) {
    if (f.discoveryWindowActive) {
      return showFullText
          ? 'Listening ${f.discoveryWindowRemaining}s'
          : '${f.discoveryWindowRemaining}s';
    }
    if (f.autoPingWaiting) {
      return showFullText
          ? (f.autoPingSkipReason != null
              ? 'Skipped ${f.autoPingRemaining}s'
              : 'Next in ${f.autoPingRemaining}s')
          : '${f.autoPingRemaining}s';
    }
    return showFullText ? 'Stop' : null;
  }
  if (f.cooldownActive && isExpandedDuringCooldown) {
    return showFullText
        ? 'Cooldown ${f.cooldownRemaining}s'
        : '${f.cooldownRemaining}s';
  }
  return null;
}

// ---------------------------------------------------------------------------
// The Trace section, shared by portrait and landscape.
// ---------------------------------------------------------------------------

/// The running status line inside the Trace section. Hardcodes "Skipped" for
/// the same reason the compact trace chain does.
String? traceStatusText(PingControlFacts f) {
  if (!f.isTargetedRunning) return null;
  if (f.discoveryWindowActive) {
    return 'Listening ${f.discoveryWindowRemaining}s';
  }
  if (f.autoPingWaiting) {
    return f.autoPingSkipReason != null
        ? 'Skipped ${f.autoPingRemaining}s'
        : 'Next in ${f.autoPingRemaining}s';
  }
  return null;
}

/// The Trace section's own button word.
///
/// [isStarting] is widget-local state, raised by the section's own tap and
/// cleared when the toggle returns, so no shared model can own it.
String traceSectionLabel(PingControlFacts f, {required bool isStarting}) =>
    isStarting
        ? 'Starting...'
        : f.isTargetedRunning
            ? (traceStatusText(f) ?? 'Stop')
            : f.cooldownActive
                ? 'Cooldown ${f.cooldownRemaining}s'
                : 'Trace Mode';

// ---------------------------------------------------------------------------
// Landscape, which shows no words at all.
//
// Three more derivations of the same precedence, emitting a bare integer beside
// an icon. Included so the ordering cannot drift away from the words.
// ---------------------------------------------------------------------------

/// Send Ping, landscape. A manual send shows nothing at all, not even a dash.
int? landscapeSendPingCountdown(PingControlFacts f) => f.isPingSending
    ? null
    : f.rxWindowActive && !f.isTxModeRunning
        ? f.rxWindowRemaining
        : f.manualCooldownActive
            ? f.manualCooldownRemaining
            : f.discoveryWindowActive
                ? f.discoveryWindowRemaining
                : f.cooldownActive
                    ? f.cooldownRemaining
                    : null;

/// Active / Hybrid, landscape. No skip reason reaches here, so a deferred ping
/// and a skipped one are indistinguishable in this layout.
int? landscapeActiveModeCountdown(PingControlFacts f) => f.isTxModeRunning
    ? (f.discoveryWindowActive
        ? f.discoveryWindowRemaining
        : f.rxWindowActive
            ? f.rxWindowRemaining
            : f.autoPingWaiting
                ? f.autoPingRemaining
                : null)
    : f.isPendingDisable && (f.rxWindowActive || f.discoveryWindowActive)
        ? (f.rxWindowActive ? f.rxWindowRemaining : f.discoveryWindowRemaining)
        : null;

/// Passive, landscape. The shared cooldown never shows here, unlike portrait.
int? landscapePassiveModeCountdown(PingControlFacts f) => f.isPassiveModeRunning
    ? (f.discoveryWindowActive
        ? f.discoveryWindowRemaining
        : f.autoPingWaiting
            ? f.autoPingRemaining
            : null)
    : null;
