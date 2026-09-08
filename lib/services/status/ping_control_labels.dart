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
