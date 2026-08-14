import '../live_activity/live_activity_models.dart';
import 'watch_color.dart';

export 'watch_color.dart';

/// Wire contract for the watchOS companion.
///
/// The Swift mirror lives in `ios/Shared/MeshMapperWatchPayload.swift` and is
/// compiled into both Runner and the watch target. This file and that one are
/// a matched pair — change one, change the other, and update the golden
/// fixtures in `test/services/watch/`.
///
/// [LiveActivitySnapshot] is reused verbatim for the session core rather than
/// re-deriving phase/counter semantics, which is the expensive and bug-prone
/// part. This snapshot composes it with the geography, controls, and haptic
/// cue the Live Activity has no use for.
class WatchWire {
  WatchWire._();

  /// Bump when a field changes meaning or is removed. The watch refuses
  /// payloads it doesn't understand rather than rendering something wrong.
  ///
  /// v2: heard nodes mirror the app's "Top Heard" map overlay — hex ID and
  /// ping-type colour — instead of the richer per-echo data. Hop counts are
  /// gone: the overlay is fed `directRepeaters` only.
  ///
  /// Additive optional fields do not bump this version. A new watch defaults
  /// an absent start-mode list to Passive and absent Ping applicability to
  /// false, while an older phone ignores the optional mode on a command and
  /// retains its existing safe resolver. A bump would therefore strand
  /// compatible pairs without preventing a bad decode.
  static const int version = 2;

  static const int maxPings = 60;
  static const int maxRepeaters = 20;

  /// Three top-SNR rows plus the RX slot, matching `_buildTopRepeatersOverlay`.
  static const int maxHeard = 4;

  /// Skip a geo-only update unless the fix moved at least this far. Phase
  /// changes and new pings always go through; this only suppresses the
  /// jitter of a stationary GPS.
  static const double minMoveMeters = 15.0;
}

/// Start modes the phone may explicitly offer to the wrist.
///
/// Active remains a phone-only choice. The wrist setting deliberately stays
/// small: Passive is safe everywhere, while Hybrid is advertised only when
/// current zone policy permits transmission.
enum WatchStartMode {
  passive,
  hybrid;

  static WatchStartMode? fromWire(String value) {
    for (final mode in WatchStartMode.values) {
      if (mode.name == value) return mode;
    }
    return null;
  }
}

class WatchPosition {
  const WatchPosition({
    required this.lat,
    required this.lon,
    required this.fixedAt,
    this.headingDeg,
    this.accuracyM,
  });

  final double lat;
  final double lon;
  final double? headingDeg;
  final double? accuracyM;
  final DateTime fixedAt;

  Map<String, Object?> toMap() => {
        'lat': lat,
        'lon': lon,
        'headingDeg': headingDeg,
        'accuracyM': accuracyM,
        'fixedAtMs': fixedAt.millisecondsSinceEpoch.toDouble(),
      };
}

class WatchPing {
  const WatchPing({
    required this.id,
    required this.lat,
    required this.lon,
    required this.kind,
    required this.color,
    required this.at,
  });

  final String id;
  final double lat;
  final double lon;

  /// 'tx' | 'rx' | 'disc' | 'trace' — drives glyph choice, not colour.
  final String kind;
  final WatchColor color;
  final DateTime at;

  Map<String, Object?> toMap() => {
        'id': id,
        'lat': lat,
        'lon': lon,
        'kind': kind,
        'color': color.toMap(),
        'atMs': at.millisecondsSinceEpoch.toDouble(),
      };
}

class WatchRepeater {
  const WatchRepeater({
    required this.id,
    required this.hexId,
    required this.name,
    required this.lat,
    required this.lon,
    required this.color,
    required this.heardThisCycle,
  });

  final String id;
  final String hexId;
  final String name;
  final double lat;
  final double lon;
  final WatchColor color;
  final bool heardThisCycle;

  Map<String, Object?> toMap() => {
        'id': id,
        'hexId': hexId,
        'name': name,
        'lat': lat,
        'lon': lon,
        'color': color.toMap(),
        'heardThisCycle': heardThisCycle,
      };
}

/// One row of the "Top Heard" overlay.
///
/// Mirrors `_buildTopRepeatersOverlay` in `map_widget.dart`: a dot coloured by
/// which kind of ping the repeater answered, the hex path-hash ID, and the SNR.
///
/// The **ID is the identity**, not the name. Path hashes are 1–3 bytes, so a
/// 2-character ID frequently cannot be resolved to a single repeater — [name]
/// is sent only when the match is unambiguous, and the watch always shows the
/// hex.
///
/// There is no hop count here by design: the overlay is fed `directRepeaters`,
/// with multi-hop events deliberately excluded.
class WatchHeardNode {
  const WatchHeardNode({
    required this.id,
    required this.typeColor,
    required this.at,
    this.name,
    this.snr,
    this.distanceM,
    this.snrColor,
  });

  /// Uppercase hex path hash, 2/4/6 chars depending on the zone's hop bytes.
  final String id;

  /// Resolved repeater name, when the hex maps to exactly one repeater.
  final String? name;
  final double? snr;
  final DateTime at;
  final double? distanceM;

  /// SNR traffic-light colour.
  final WatchColor? snrColor;

  /// Ping type the repeater answered — green flood/active, teal discovery,
  /// cyan trace, purple most-recent RX.
  final WatchColor typeColor;

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'snr': snr,
        'atMs': at.millisecondsSinceEpoch.toDouble(),
        'distanceM': distanceM,
        'snrColor': snrColor?.toMap(),
        'typeColor': typeColor.toMap(),
      };
}

class WatchGeo {
  const WatchGeo({
    required this.pings,
    required this.repeaters,
    required this.heard,
    required this.linkedRepeaterIds,
    this.you,
  });

  final WatchPosition? you;
  final List<WatchPing> pings;
  final List<WatchRepeater> repeaters;
  final List<WatchHeardNode> heard;
  final List<String> linkedRepeaterIds;

  Map<String, Object?> toMap() => {
        'you': you?.toMap(),
        'pings': pings.map((p) => p.toMap()).toList(),
        'repeaters': repeaters.map((r) => r.toMap()).toList(),
        'heard': heard.map((h) => h.toMap()).toList(),
        'linkedRepeaterIds': linkedRepeaterIds,
      };
}

/// What the wrist may do right now.
///
/// Drives button enablement only. The phone revalidates every command, so a
/// stale payload can never talk it into an illegal transmit.
class WatchControls {
  const WatchControls({
    required this.canStartStop,
    required this.canManualPing,
    required this.isSessionActive,
    this.manualPingApplicable = false,
    this.manualCooldownEndsAt,
    this.blockedReason,
  });

  final bool canStartStop;
  final bool canManualPing;
  final bool isSessionActive;

  /// Stable ownership for the corner slot. Unlike [canManualPing], this does
  /// not flicker during cooldowns or receive windows; those only disable the
  /// ping control that already owns the slot.
  final bool manualPingApplicable;
  final DateTime? manualCooldownEndsAt;
  final String? blockedReason;

  Map<String, Object?> toMap() => {
        'canStartStop': canStartStop,
        'canManualPing': canManualPing,
        'isSessionActive': isSessionActive,
        'manualPingApplicable': manualPingApplicable,
        'manualCooldownEndsAtMs':
            manualCooldownEndsAt?.millisecondsSinceEpoch.toDouble(),
        'blockedReason': blockedReason,
      };
}

/// A one-shot event the watch should feel.
///
/// Carries an [id] so the watch fires exactly once: diffing state would
/// double-fire on redelivery, which WatchConnectivity does routinely.
class WatchHapticCue {
  const WatchHapticCue({
    required this.id,
    required this.kind,
    required this.issuedAt,
    this.message,
  });

  final String id;

  /// 'success' | 'failure' | 'notification'
  final String kind;

  /// Creation time lets a restarted watch distinguish a current failure from
  /// an old cue retained in WatchConnectivity's application context.
  final DateTime issuedAt;

  /// Human-readable detail for an event whose outcome arrived after command
  /// admission. This additive field is optional, so v2 remains decodable; no
  /// wire bump is needed while the matched phone and watch targets ship it.
  final String? message;

  Map<String, Object?> toMap() => {
        'id': id,
        'kind': kind,
        'issuedAtMs': issuedAt.millisecondsSinceEpoch.toDouble(),
        'message': message,
      };
}

/// The complete state the watch renders.
class WatchSnapshot {
  const WatchSnapshot({
    required this.core,
    required this.geo,
    required this.controls,
    required this.updatedAt,
    this.availableStartModes = const [WatchStartMode.passive],
    this.pingColor,
    this.cue,
    this.phaseDurationMs,
  });

  /// Session core, reused from the Live Activity so both surfaces agree.
  final LiveActivitySnapshot core;
  final WatchGeo geo;
  final WatchControls controls;
  final List<WatchStartMode> availableStartModes;
  final WatchColor? pingColor;
  final WatchHapticCue? cue;
  final DateTime updatedAt;

  /// Total length of the current phase.
  ///
  /// With [LiveActivitySnapshot.phaseEndsAt] this is everything the watch needs
  /// to draw a depleting progress bar locally — no per-second traffic, and the
  /// bar stays correct even if the app opens midway through a phase.
  final int? phaseDurationMs;

  Map<String, Object?> toMap() => {
        'wireVersion': WatchWire.version,
        'sessionId': core.sessionId,
        'mode': core.mode,
        'phase': core.phase.wireValue,
        'phaseTitle': core.phaseTitle,
        'phaseDetail': core.phaseDetail,
        'phaseEndsAtMs': core.phaseEndsAt?.millisecondsSinceEpoch.toDouble(),
        'phaseDurationMs': phaseDurationMs,
        'isConnected': core.isConnected,
        'zoneCode': core.zoneCode,
        'txCount': core.txCount,
        'rxCount': core.rxCount,
        'discoveryCount': core.discoveryCount,
        'traceCount': core.traceCount,
        'queueSize': core.queueSize,
        'pingColor': pingColor?.toMap(),
        'availableStartModes':
            availableStartModes.map((mode) => mode.name).toList(),
        'geo': geo.toMap(),
        'controls': controls.toMap(),
        'cue': cue?.toMap(),
        'updatedAtMs': updatedAt.millisecondsSinceEpoch.toDouble(),
      };

  /// Fields that must bypass the update throttle.
  ///
  /// Deliberately excludes geo: a moving GPS would otherwise mark every
  /// update urgent and defeat the throttle entirely.
  String get urgencyKey => buildUrgencyKey(
        sessionId: core.sessionId,
        mode: core.mode,
        phase: core.phase,
        phaseTitle: core.phaseTitle,
        phaseDetail: core.phaseDetail,
        phaseEndsAt: core.phaseEndsAt,
        isConnected: core.isConnected,
        controls: controls,
        cue: cue,
      );

  static String buildUrgencyKey({
    required String sessionId,
    required String mode,
    required LiveActivityPhase phase,
    required String phaseTitle,
    required String? phaseDetail,
    required DateTime? phaseEndsAt,
    required bool isConnected,
    required WatchControls controls,
    required WatchHapticCue? cue,
  }) =>
      [
        sessionId,
        mode,
        phase.wireValue,
        phaseTitle,
        phaseDetail ?? '',
        phaseEndsAt?.millisecondsSinceEpoch ?? 0,
        isConnected,
        controls.canStartStop,
        controls.canManualPing,
        controls.isSessionActive,
        controls.manualPingApplicable,
        cue?.id ?? '',
      ].join('|');
}

/// An intent from the wrist. Never state — the phone decides what happens.
enum WatchCommandKind {
  startSession,
  stopSession,
  manualPing,
  requestSnapshot;

  static WatchCommandKind? fromWire(String value) {
    for (final kind in WatchCommandKind.values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// Decoded wrist intent. [mode] stays raw until phone-side admission so an
/// unknown value can be refused rather than mistaken for an omitted mode.
class WatchCommand {
  const WatchCommand({required this.kind, this.mode});

  final WatchCommandKind kind;
  final String? mode;
}

typedef WatchRequestedStartModeResolution = ({
  WatchStartMode? mode,
  String? refusal,
});

/// Revalidate an explicit wrist mode against current phone state.
///
/// A null result means an older watch omitted the field and the provider must
/// retain its established `_resolvedWatchSessionMode` fallback. An unsupported
/// or newly-forbidden request is never downgraded silently.
WatchRequestedStartModeResolution resolveWatchRequestedStartMode({
  required String? requestedMode,
  required bool isConnected,
  required bool txAllowed,
}) {
  if (requestedMode == null) return (mode: null, refusal: null);

  final mode = WatchStartMode.fromWire(requestedMode);
  if (mode == null) return (mode: null, refusal: 'Unsupported start mode');
  if (mode == WatchStartMode.hybrid && !isConnected) {
    return (mode: null, refusal: 'Not connected');
  }
  if (mode == WatchStartMode.hybrid && !txAllowed) {
    return (mode: null, refusal: 'Passive Only');
  }
  return (mode: mode, refusal: null);
}

typedef WatchCommandAdmission = ({bool shouldRun, String? refusal});

typedef SessionStartAvailability = ({bool allowed, String? reason});

/// One start-admission rule shared by the wrist snapshot and command handler.
///
/// Passive monitoring does not transmit, so a manual TX, its receive window,
/// TX cooldown, offline TX policy, and zone TX policy must not block it. The
/// setup and transition guards still apply to every mode. Keeping that split
/// here prevents the offered button and the radio admission from drifting back
/// into separate policy copies.
SessionStartAvailability resolveSessionStartAvailability({
  required bool isTransmitMode,
  required bool isConnected,
  required bool antennaConfigured,
  required bool powerConfigured,
  required bool isPendingDisable,
  required bool isTargetedRunning,
  required bool isAutoStarting,
  required bool cooldownActive,
  required bool isPingSending,
  required bool rxWindowActive,
  required bool txBlockedByOffline,
  required bool txNotAllowed,
  required String? transmitValidationReason,
}) {
  if (!isConnected) return (allowed: false, reason: 'Not connected');
  if (isPendingDisable) return (allowed: false, reason: 'Still stopping');
  if (isTargetedRunning) {
    return (allowed: false, reason: 'Trace session active');
  }
  if (isAutoStarting) return (allowed: false, reason: 'Already starting');
  if (!antennaConfigured) {
    return (allowed: false, reason: 'Select antenna option');
  }
  if (!powerConfigured) {
    return (allowed: false, reason: 'Select power level');
  }

  if (!isTransmitMode) return (allowed: true, reason: null);

  if (txBlockedByOffline) return (allowed: false, reason: 'Offline Mode');
  if (txNotAllowed) return (allowed: false, reason: 'Passive Only');
  if (cooldownActive) return (allowed: false, reason: 'Cooling down');
  if (isPingSending) return (allowed: false, reason: 'Ping in progress');
  if (rxWindowActive) {
    return (allowed: false, reason: 'Listening for ping response');
  }
  if (transmitValidationReason != null) {
    return (allowed: false, reason: transmitValidationReason);
  }
  return (allowed: true, reason: null);
}

/// Resolve the wrist's single Start/Stop control without racing the phone's
/// asynchronous start transaction. A second Start is the same intent and can
/// disappear harmlessly; Stop is the opposite intent, so claiming success
/// before there is a running session would lie to the wearer.
WatchCommandAdmission resolveWatchSessionCommandAdmission({
  required WatchCommandKind kind,
  required bool isSessionActive,
  required bool isSessionStarting,
}) {
  switch (kind) {
    case WatchCommandKind.startSession:
      return (
        shouldRun: !isSessionActive && !isSessionStarting,
        refusal: null,
      );
    case WatchCommandKind.stopSession:
      if (isSessionStarting && !isSessionActive) {
        return (
          shouldRun: false,
          refusal: 'Still starting — try Stop again',
        );
      }
      return (shouldRun: isSessionActive, refusal: null);
    case WatchCommandKind.manualPing:
    case WatchCommandKind.requestSnapshot:
      throw ArgumentError.value(kind, 'kind', 'Expected Start or Stop');
  }
}

/// The shared resolver's Starting fallback is correct for a Live Activity,
/// which only exists for a session, but the watch also renders while idle.
/// Only the watch calls this projection, keeping the phone surface unchanged.
LiveActivityPhase resolveWatchSurfacePhase({
  required LiveActivityPhase sharedPhase,
  required bool isSessionActive,
  required bool isSessionStarting,
}) {
  if (sharedPhase == LiveActivityPhase.starting &&
      !isSessionActive &&
      !isSessionStarting) {
    return LiveActivityPhase.idle;
  }
  return sharedPhase;
}
