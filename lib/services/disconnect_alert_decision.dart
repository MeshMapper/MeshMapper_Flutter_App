/// Whether the disconnect alert is still worth playing out loud.
///
/// The alert exists to tell the user, at the moment it happens, that their
/// radio stopped being heard. It is fired from decisions that are driven by
/// timers, and a timer does not run while Android has the process frozen. One
/// user's reconnect timeout was armed for 30 seconds and fired 21 minutes
/// later, when the phone thawed: by then they were standing back at the radio
/// and the beep described a problem that had already passed.
///
/// `AppStateProvider._startAutoReconnect` no longer stops the foreground
/// service, which is what allowed that freeze, so in practice the age here is
/// seconds. This is the backstop: OEM battery managers vary and a frozen
/// process is never fully the app's to control, so a stale beep is made
/// impossible rather than merely unlikely.
///
/// Pure, so the rule is checkable in a table without a device.
library;

/// How long after the causing event the alert is still meaningful.
///
/// Comfortably longer than the reconnect budget (30 seconds, three attempts),
/// so a slow but healthy give-up still beeps, and far shorter than the freezes
/// that produced the bug.
const Duration maxDisconnectAlertAge = Duration(minutes: 2);

/// True when [age] is recent enough that the beep still describes now.
bool shouldPlayDisconnectAlert(Duration age) =>
    age <= maxDisconnectAlertAge && !age.isNegative;

/// The error-log sentence for an alert that was too late to play.
///
/// Says when the radio actually went quiet, because the point of suppressing
/// the beep is that the current moment is the wrong answer.
String staleDisconnectAlertMessage(Duration age) {
  final minutes = age.inMinutes;
  final ago = minutes >= 1
      ? '$minutes minute${minutes == 1 ? '' : 's'} ago'
      : '${age.inSeconds} seconds ago';
  return 'Pinging stopped $ago, while the app was suspended. '
      'The alert sound was skipped because it would have been that late too.';
}
