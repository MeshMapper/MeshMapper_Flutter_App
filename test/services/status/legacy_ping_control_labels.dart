// FROZEN. A byte-for-byte copy of the in-app label chains as they read raw
// timers and flags at commit 51aa947, before they were pointed at the shared
// SessionStatus. It exists for one job: the differential test diffs the live
// renderers against these across the whole input space, so "no label moved" is
// a mechanical fact rather than 48 hand-picked rows. Do not evolve this file; if
// a label is meant to change, that change belongs in the live renderers and the
// oracle table, and this frozen baseline is what proves it was deliberate.

import 'package:mesh_mapper/services/ping_service.dart';
import 'package:mesh_mapper/services/status/ping_control_labels.dart'
    show StatusHint;

typedef LegacyFacts = ({
  bool isConnected,
  bool externalAntennaSet,
  bool isPowerSet,
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

String legacyPausedWord(String? skipReason) =>
    skipReason == PingService.skipReasonRecentlyCovered
        ? 'Deferred'
        : 'Skipped';

({StatusHint hint, String text})? legacyBlockingHint(
  LegacyFacts f,
  PingValidation validation,
) {
  if (!f.isConnected) {
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
    return (hint: StatusHint.noGpsLock, text: 'Waiting for GPS lock...');
  } else if (validation == PingValidation.gpsInaccurate) {
    return (hint: StatusHint.gpsInaccurate, text: 'GPS accuracy too low');
  } else if (validation == PingValidation.outsideGeofence) {
    return (hint: StatusHint.outsideServiceArea, text: 'Outside service area');
  }
  return null;
}

String legacyPortraitSendPingLabel(LegacyFacts f) => f.txBlockedByOffline
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

String legacyPortraitActiveModeLabel(LegacyFacts f) => f.txBlockedByOffline
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
                                    ? '${legacyPausedWord(f.autoPingSkipReason)} ${f.autoPingRemaining}s'
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

String legacyPortraitPassiveModeLabel(LegacyFacts f) => f.isPassiveModeRunning
    ? (f.discoveryWindowActive
        ? 'Listening ${f.discoveryWindowRemaining}s'
        : f.autoPingWaiting
            ? (f.autoPingSkipReason != null
                ? '${legacyPausedWord(f.autoPingSkipReason)} ${f.autoPingRemaining}s'
                : 'Next Disc ${f.autoPingRemaining}s')
            : 'Passive Mode')
    : f.isTxModeRunning || f.isPendingDisable
        ? 'Passive Mode'
        : f.rxWindowActive
            ? 'Cooldown ${f.rxWindowRemaining}s'
            : f.cooldownActive
                ? 'Cooldown ${f.cooldownRemaining}s'
                : 'Passive Mode';

String? legacyCompactSendPingLabel(
  LegacyFacts f, {
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

String? legacyCompactActiveModeLabel(
  LegacyFacts f, {
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
              ? '${legacyPausedWord(f.autoPingSkipReason)} ${f.autoPingRemaining}s'
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

String? legacyCompactPassiveModeLabel(
  LegacyFacts f, {
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
              ? '${legacyPausedWord(f.autoPingSkipReason)} ${f.autoPingRemaining}s'
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

String? legacyCompactTraceModeLabel(
  LegacyFacts f, {
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

String? legacyTraceStatusText(LegacyFacts f) {
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

String legacyTraceSectionLabel(LegacyFacts f, {required bool isStarting}) =>
    isStarting
        ? 'Starting...'
        : f.isTargetedRunning
            ? (legacyTraceStatusText(f) ?? 'Stop')
            : f.cooldownActive
                ? 'Cooldown ${f.cooldownRemaining}s'
                : 'Trace Mode';

int? legacyLandscapeSendPingCountdown(LegacyFacts f) => f.isPingSending
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

int? legacyLandscapeActiveModeCountdown(LegacyFacts f) => f.isTxModeRunning
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

int? legacyLandscapePassiveModeCountdown(LegacyFacts f) => f.isPassiveModeRunning
    ? (f.discoveryWindowActive
        ? f.discoveryWindowRemaining
        : f.autoPingWaiting
            ? f.autoPingRemaining
            : null)
    : null;
