import '../ping_service.dart';
import 'session_status.dart';

/// The words the in-app ping controls put on their buttons.
///
/// Every one of these reads the one shared [SessionStatus] that the Live
/// Activity, watch, Siri and Android read too, so the phone can no longer drift
/// away from what the glance surfaces say about the same instant. Each button
/// takes its own lane's view ([SessionStatus.lane]); the countdown a button
/// prints is that lane's `deadline.remainingSec`, the exact number its timer
/// reports today.
///
/// Faithful, not tidy. Where two layouts disagree about the same state they
/// still disagree here, each in its own function, because A promises no visible
/// change; the vocabulary work (Project B) is where they are unified. The words
/// per state stay per surface, which is why these are per-surface renderers over
/// one model rather than one string everyone prints.
///
/// [PingRenderFacts] carries the handful of things that are genuinely not
/// session state: the offline / zone-capacity blocks, the Hybrid preference, and
/// which mode is running (the model says what each lane is doing, but a button
/// still has to know whether ITS mode is the one running to pick between its
/// active chain and its idle one). What is NOT here, on purpose: the ping
/// validation. Reading it runs a full `canPing()` pass, including a distance
/// calculation and a coverage lookup, and only the portrait hint chain wants it,
/// so [blockingHint] takes it as a separate argument (see [PingHintFacts]).
typedef PingRenderFacts = ({
  bool txBlockedByOffline,
  bool txNotAllowed,
  bool hybridEnabled,
  bool isTxModeRunning,
  bool isPassiveModeRunning,
  bool isTargetedRunning,
  // A stop is the session's answer, not a lane's, so it never sits on a lane in
  // the model (that would shadow the window the lane is still closing). The
  // Active button, which is the stop indicator, reads it from here.
  bool isPendingDisable,
});

/// The three flags the blocking hint needs that are not session state and not
/// in [PingRenderFacts]: whether the radio is connected and whether the antenna
/// and power have been declared. The hint is the one chain that cannot come from
/// [SessionStatus] at all, because it is a projection of the ping validators,
/// which the model deliberately does not carry.
typedef PingHintFacts = ({
  bool isConnected,
  bool externalAntennaSet,
  bool isPowerSet,
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
///
/// The model resolves these into distinct [SessionActivity] values, so the
/// renderers no longer call this; it stays because it is a small public fact the
/// vocabulary work will move, and because the phase resolver's twin lives beside
/// it.
String pausedWord(String? skipReason) =>
    skipReason == PingService.skipReasonRecentlyCovered
        ? 'Deferred'
        : 'Skipped';

int _sec(LaneStatus v) => v.deadline?.remainingSec ?? 0;

/// The shared five second cooldown that follows stopping a TX mode, or null.
///
/// It lives on the txAuto lane and is the only cooldown that lane can OWN: the
/// manual cooldown belongs to the manual lane, so an OWNED txAuto cooldown
/// identifies the shared one exactly. Three idle buttons borrow it. A manual
/// cooldown holds those same lanes with the same [SessionActivity.cooldown], so
/// the borrow tests the owner here rather than the borrowing lane's held
/// activity, which is what keeps a manual cooldown from leaking onto them.
StatusDeadline? _sharedCooldown(SessionStatus s) =>
    s.txAuto.activity == SessionActivity.cooldown && !s.txAuto.isBlocked
        ? s.txAuto.deadline
        : null;

/// The RX (echo) window, wherever it sits, or null. It is owned by the manual
/// lane for a tap and by the txAuto lane for an auto TX ping. The idle Active
/// and Passive buttons borrow it as their cooldown, and they borrow the WINDOW,
/// not whatever the model happens to rank first when several things overlap, so
/// this recovers the specific window the way those buttons always read it. It
/// returns null under a session-wide hold, since no lane is listening then, so a
/// stop or a disconnect shows the mode word rather than a borrowed number.
StatusDeadline? _rxWindow(SessionStatus s) {
  if (s.manual.activity == SessionActivity.listening && !s.manual.isBlocked) {
    return s.manual.deadline;
  }
  if (s.txAuto.activity == SessionActivity.listening && !s.txAuto.isBlocked) {
    return s.txAuto.deadline;
  }
  return null;
}

/// The discovery or trace listening window, wherever it sits, or null. Owned by
/// the discovery lane in Passive, the txAuto lane in Hybrid, the targeted lane
/// in Trace. Send Ping borrows it as its cooldown, and it stays visible to that
/// borrow even while the session is stopping, which is when the button's own
/// lane is held rather than owning anything.
StatusDeadline? _discWindow(SessionStatus s) {
  for (final v in [s.discovery, s.txAuto, s.targeted]) {
    if ((v.activity == SessionActivity.listeningDiscovery ||
            v.activity == SessionActivity.listeningTrace) &&
        !v.isBlocked) {
      return v.deadline;
    }
  }
  return null;
}

/// The 15 second manual cooldown, or null. It is the manual lane's own, so an
/// owned manual cooldown is exactly it.
StatusDeadline? _manualCooldown(SessionStatus s) =>
    s.manual.activity == SessionActivity.cooldown && !s.manual.isBlocked
        ? s.manual.deadline
        : null;

/// The hint under the buttons, in priority order.
///
/// Portrait only today: the compact and landscape layouts read the two button
/// validators but never this one, so a user in either of those gets a silently
/// disabled button and no reason at all.
///
/// The one chain kept on facts. It is a projection of the ping validators, and
/// the model carries no validator result on purpose (reading one is a full
/// `canPing()` pass, and the model is resolved on every countdown tick). So this
/// takes the flags and the validation directly; Project B can still reach it
/// from one place, because this is that place.
({StatusHint hint, String text})? blockingHint(
  PingHintFacts f,
  PingValidation validation,
) {
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
  } else if (validation == PingValidation.airborne) {
    return (hint: StatusHint.airborne, text: 'Airborne, wardriving blocked');
  } else if (validation == PingValidation.noGpsLock) {
    return (hint: StatusHint.noGpsLock, text: 'Waiting for GPS');
  } else if (validation == PingValidation.gpsInaccurate) {
    return (hint: StatusHint.gpsInaccurate, text: 'GPS signal is weak');
  } else if (validation == PingValidation.outsideGeofence) {
    // Dead today: no validator returns outsideGeofence. Kept so the lift is
    // faithful, and so the table records that it is unreachable.
    return (hint: StatusHint.outsideServiceArea, text: 'Outside a zone');
  }
  // Cooldown and too-close are deliberately hintless; they show on the button.
  return null;
}

/// Send Ping, portrait.
///
/// It shows its own send and RX window, then borrows, in this fixed order, a
/// manual cooldown, a discovery window and the shared cooldown, all as
/// "Cooldown" (one of the disagreements Project B ends). The borrows read the
/// windows directly rather than the manual lane's held activity, so they still
/// appear while the session is stopping, when that lane is held by the stop.
String portraitSendPingLabel(SessionStatus s, PingRenderFacts f) {
  if (f.txBlockedByOffline) return 'TX Disabled';
  if (f.txNotAllowed) return 'Zone Full';
  // An auto TX mode greys Send Ping to its resting word; the window on it then
  // belongs to that mode, not to a manual tap.
  if (f.isTxModeRunning) return 'Send Ping';
  if (s.manual.activity == SessionActivity.sending && !s.manual.isBlocked) {
    return 'Sending...';
  }
  final rx = _rxWindow(s);
  if (rx != null) return 'Listening ${rx.remainingSec}s';
  final mcd = _manualCooldown(s);
  if (mcd != null) return 'Cooldown ${mcd.remainingSec}s';
  final disc = _discWindow(s);
  if (disc != null) return 'Cooldown ${disc.remainingSec}s';
  final shared = _sharedCooldown(s);
  if (shared != null) return 'Cooldown ${shared.remainingSec}s';
  return 'Send Ping';
}

/// Active / Hybrid, portrait.
String portraitActiveModeLabel(SessionStatus s, PingRenderFacts f) {
  if (f.txBlockedByOffline) return 'TX Disabled';
  if (f.txNotAllowed) return 'Zone Full';
  final mode = f.hybridEnabled ? 'Hybrid Mode' : 'Active Mode';
  // The Active button is the stop indicator, and it counts down whichever window
  // is still closing (the auto echo first, then a discovery leg).
  if (f.isPendingDisable) {
    final w = _rxWindow(s) ?? _discWindow(s);
    return w != null ? 'Stopping ${w.remainingSec}s' : 'Stopping...';
  }
  final v = s.txAuto;
  if (!v.isBlocked) {
    return switch (v.activity) {
      SessionActivity.sending => 'Sending...',
      SessionActivity.listening ||
      SessionActivity.listeningDiscovery =>
        'Listening ${_sec(v)}s',
      SessionActivity.waiting => 'Next ping ${_sec(v)}s',
      SessionActivity.deferred => 'Deferred ${_sec(v)}s',
      SessionActivity.skipped => 'Skipped ${_sec(v)}s',
      // The shared cooldown, which this lane owns.
      SessionActivity.cooldown => 'Cooldown ${_sec(v)}s',
      _ => mode,
    };
  }
  // Held. It borrows the RX window as its cooldown, wherever that window sits;
  // a discovery window or a manual cooldown holding it shows the mode word, as
  // today. `_rxWindow` is null under a stop, so a stop shows the mode word.
  final rx = _rxWindow(s);
  if (rx != null) return 'Cooldown ${rx.remainingSec}s';
  return mode;
}

/// Passive, portrait.
String portraitPassiveModeLabel(SessionStatus s, PingRenderFacts f) {
  if (f.isPassiveModeRunning) {
    final v = s.discovery;
    return switch (v.activity) {
      SessionActivity.listeningDiscovery => 'Listening ${_sec(v)}s',
      SessionActivity.waitingDiscovery => 'Next disc ${_sec(v)}s',
      SessionActivity.deferred => 'Deferred ${_sec(v)}s',
      SessionActivity.skipped => 'Skipped ${_sec(v)}s',
      _ => 'Passive Mode',
    };
  }
  // A TX mode, or a stop of some other mode, greys it to the mode word. (Its own
  // stop is the running branch above, which keeps showing the discovery window.)
  if (f.isTxModeRunning || f.isPendingDisable) return 'Passive Mode';
  // Idle: it borrows the RX window and the shared cooldown; a manual cooldown
  // holding it shows the mode word (the shared helper is null there).
  final rx = _rxWindow(s);
  if (rx != null) return 'Cooldown ${rx.remainingSec}s';
  final shared = _sharedCooldown(s);
  if (shared != null) return 'Cooldown ${shared.remainingSec}s';
  return 'Passive Mode';
}

// ---------------------------------------------------------------------------
// Compact layout.
//
// The waiting labels now match portrait word for word ("Next ping" / "Next disc"
// / "Next trace"), so collapsing the panel no longer changes the wording. What
// still differs is structural, not vocabulary: compact can collapse to a bare
// countdown, and it borrows fewer windows than portrait.
//
// [showFullText] is the button's own expanded flag, which decides between the
// word and a bare countdown. [isExpandedDuringCooldown] is the same flag anded
// with the shared cooldown running. Both are widget arguments rather than model
// facts because they depend on which button was last active, which is history,
// not the instant.
// ---------------------------------------------------------------------------

String? _n(int sec, {required bool showFullText, required String word}) =>
    showFullText ? '$word ${sec}s' : '${sec}s';

/// Send Ping, compact. Null means the button shows its icon alone.
///
/// Unlike portrait it does not grey out under an auto TX mode; it borrows that
/// mode's RX window too. Same fixed borrow order as portrait otherwise.
String? compactSendPingLabel(
  SessionStatus s,
  PingRenderFacts f, {
  required bool showFullText,
}) {
  if (s.manual.activity == SessionActivity.sending && !s.manual.isBlocked) {
    return showFullText ? 'Sending...' : '...';
  }
  final rx = _rxWindow(s);
  if (rx != null) {
    return _n(rx.remainingSec, showFullText: showFullText, word: 'Listening');
  }
  final mcd = _manualCooldown(s);
  if (mcd != null) {
    return _n(mcd.remainingSec, showFullText: showFullText, word: 'Cooldown');
  }
  final disc = _discWindow(s);
  if (disc != null) {
    return _n(disc.remainingSec, showFullText: showFullText, word: 'Cooldown');
  }
  final shared = _sharedCooldown(s);
  if (shared != null) {
    return _n(shared.remainingSec, showFullText: showFullText, word: 'Cooldown');
  }
  return null;
}

/// Active / Hybrid, compact.
String? compactActiveModeLabel(
  SessionStatus s,
  PingRenderFacts f, {
  required bool showFullText,
  required bool isExpandedDuringCooldown,
}) {
  if (f.isPendingDisable) {
    final w = _rxWindow(s) ?? _discWindow(s);
    return w != null
        ? _n(w.remainingSec, showFullText: showFullText, word: 'Stopping')
        : (showFullText ? 'Stopping...' : '...');
  }
  final v = s.txAuto;
  if (!v.isBlocked) {
    switch (v.activity) {
      case SessionActivity.listening:
      case SessionActivity.listeningDiscovery:
        return _n(_sec(v), showFullText: showFullText, word: 'Listening');
      case SessionActivity.sending:
        return showFullText ? 'Sending...' : '...';
      case SessionActivity.waiting:
        return _n(_sec(v), showFullText: showFullText, word: 'Next ping');
      case SessionActivity.deferred:
        return _n(_sec(v), showFullText: showFullText, word: 'Deferred');
      case SessionActivity.skipped:
        return _n(_sec(v), showFullText: showFullText, word: 'Skipped');
      case SessionActivity.cooldown:
        // The shared cooldown, and only while this button stays expanded.
        return isExpandedDuringCooldown
            ? _n(_sec(v), showFullText: showFullText, word: 'Cooldown')
            : null;
      default:
        return null;
    }
  }
  // Held. Compact does not borrow the RX window the way portrait does.
  return null;
}

/// Passive, compact.
String? compactPassiveModeLabel(
  SessionStatus s,
  PingRenderFacts f, {
  required bool showFullText,
  required bool isExpandedDuringCooldown,
}) {
  if (f.isPassiveModeRunning) {
    final v = s.discovery;
    final word = switch (v.activity) {
      SessionActivity.listeningDiscovery => 'Listening',
      SessionActivity.waitingDiscovery => 'Next disc',
      SessionActivity.deferred => 'Deferred',
      SessionActivity.skipped => 'Skipped',
      _ => null,
    };
    if (word != null) return _n(_sec(v), showFullText: showFullText, word: word);
  }
  final shared = _sharedCooldown(s);
  if (shared != null && isExpandedDuringCooldown) {
    return _n(shared.remainingSec, showFullText: showFullText, word: 'Cooldown');
  }
  return null;
}

/// Trace, compact.
///
/// The `deferred` arm is unreachable: a Trace is never deferred (the trace send
/// path does not consult the coverage lookup, and the banked-ping release
/// refuses in Trace mode), so mapping it to the skipped word is a dead branch
/// kept only for totality. Trace deferral is not wanted by design.
String? compactTraceModeLabel(
  SessionStatus s,
  PingRenderFacts f, {
  required bool showFullText,
  required bool isExpandedDuringCooldown,
}) {
  if (f.isTargetedRunning) {
    final v = s.targeted;
    switch (v.activity) {
      case SessionActivity.listeningTrace:
      case SessionActivity.listeningDiscovery:
        return _n(_sec(v), showFullText: showFullText, word: 'Listening');
      case SessionActivity.waitingTrace:
        return _n(_sec(v), showFullText: showFullText, word: 'Next trace');
      case SessionActivity.deferred:
      case SessionActivity.skipped:
        return _n(_sec(v), showFullText: showFullText, word: 'Skipped');
      default:
        return showFullText ? 'Stop' : null;
    }
  }
  final shared = _sharedCooldown(s);
  if (shared != null && isExpandedDuringCooldown) {
    return _n(shared.remainingSec, showFullText: showFullText, word: 'Cooldown');
  }
  return null;
}

// ---------------------------------------------------------------------------
// The Trace section, shared by portrait and landscape.
// ---------------------------------------------------------------------------

/// The running status line inside the Trace section. Reads the skipped word for
/// a deferral too, for the same reason the compact trace chain does.
String? traceStatusText(SessionStatus s, PingRenderFacts f) {
  if (!f.isTargetedRunning) return null;
  final v = s.targeted;
  return switch (v.activity) {
    SessionActivity.listeningTrace ||
    SessionActivity.listeningDiscovery =>
      'Listening ${_sec(v)}s',
    SessionActivity.waitingTrace => 'Next trace ${_sec(v)}s',
    SessionActivity.deferred || SessionActivity.skipped => 'Skipped ${_sec(v)}s',
    _ => null,
  };
}

/// The Trace section's own button word.
///
/// [isStarting] is widget-local state, raised by the section's own tap and
/// cleared when the toggle returns, so no shared model can own it.
String traceSectionLabel(
  SessionStatus s,
  PingRenderFacts f, {
  required bool isStarting,
}) {
  if (isStarting) return 'Starting...';
  if (f.isTargetedRunning) return traceStatusText(s, f) ?? 'Stop';
  final shared = _sharedCooldown(s);
  if (shared != null) return 'Cooldown ${shared.remainingSec}s';
  return 'Trace Mode';
}

// ---------------------------------------------------------------------------
// Landscape, which shows no words at all.
//
// Three more derivations of the same precedence, emitting a bare integer beside
// an icon. Included so the ordering cannot drift away from the words.
// ---------------------------------------------------------------------------

/// Send Ping, landscape. A manual send shows nothing at all, not even a dash,
/// and an auto TX mode hides the manual listening number.
int? landscapeSendPingCountdown(SessionStatus s, PingRenderFacts f) {
  if (s.manual.activity == SessionActivity.sending && !s.manual.isBlocked) {
    return null;
  }
  // The RX window only when this button owns it, i.e. no auto TX mode is running.
  if (!f.isTxModeRunning) {
    final rx = _rxWindow(s);
    if (rx != null) return rx.remainingSec;
  }
  final mcd = _manualCooldown(s);
  if (mcd != null) return mcd.remainingSec;
  final disc = _discWindow(s);
  if (disc != null) return disc.remainingSec;
  final shared = _sharedCooldown(s);
  if (shared != null) return shared.remainingSec;
  return null;
}

/// Active / Hybrid, landscape. No skip reason reaches here, so a deferred ping
/// and a skipped one are indistinguishable in this layout.
int? landscapeActiveModeCountdown(SessionStatus s, PingRenderFacts f) {
  if (f.isPendingDisable) {
    return (_rxWindow(s) ?? _discWindow(s))?.remainingSec;
  }
  final v = s.txAuto;
  if (!v.isBlocked) {
    return switch (v.activity) {
      SessionActivity.listening ||
      SessionActivity.listeningDiscovery ||
      SessionActivity.waiting ||
      SessionActivity.deferred ||
      SessionActivity.skipped =>
        _sec(v),
      _ => null,
    };
  }
  // Held: landscape does not borrow anything here.
  return null;
}

/// Passive, landscape. The shared cooldown never shows here, unlike portrait.
int? landscapePassiveModeCountdown(SessionStatus s, PingRenderFacts f) {
  if (!f.isPassiveModeRunning) return null;
  final v = s.discovery;
  return switch (v.activity) {
    SessionActivity.listeningDiscovery ||
    SessionActivity.waitingDiscovery ||
    SessionActivity.deferred ||
    SessionActivity.skipped =>
      _sec(v),
    _ => null,
  };
}
