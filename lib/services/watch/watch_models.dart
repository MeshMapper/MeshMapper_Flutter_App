import 'dart:ui' show Color;

import '../live_activity/live_activity_models.dart';

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

/// An sRGB colour resolved from the active colour-vision palette.
///
/// Resolving on the phone is deliberate: Dart owns [PingColors], so the watch
/// renders accessibility palettes correctly without duplicating any of them.
class WatchColor {
  const WatchColor(this.r, this.g, this.b);

  factory WatchColor.fromColor(Color color) => WatchColor(
        (color.r * 255.0).roundToDouble() / 255.0,
        (color.g * 255.0).roundToDouble() / 255.0,
        (color.b * 255.0).roundToDouble() / 255.0,
      );

  final double r;
  final double g;
  final double b;

  Map<String, Object?> toMap() => {'r': r, 'g': g, 'b': b};

  @override
  bool operator ==(Object other) =>
      other is WatchColor && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);
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
    required this.name,
    required this.lat,
    required this.lon,
    required this.color,
    required this.heardThisCycle,
  });

  final String id;
  final String name;
  final double lat;
  final double lon;
  final WatchColor color;
  final bool heardThisCycle;

  Map<String, Object?> toMap() => {
        'id': id,
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
    this.manualCooldownEndsAt,
    this.blockedReason,
  });

  final bool canStartStop;
  final bool canManualPing;
  final bool isSessionActive;
  final DateTime? manualCooldownEndsAt;
  final String? blockedReason;

  Map<String, Object?> toMap() => {
        'canStartStop': canStartStop,
        'canManualPing': canManualPing,
        'isSessionActive': isSessionActive,
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
  const WatchHapticCue({required this.id, required this.kind, this.message});

  final String id;

  /// 'success' | 'failure' | 'notification'
  final String kind;

  /// Human-readable detail for an event whose outcome arrived after command
  /// admission. This additive field is optional, so v2 remains decodable; no
  /// wire bump is needed while the matched phone and watch targets ship it.
  final String? message;

  Map<String, Object?> toMap() => {
        'id': id,
        'kind': kind,
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
    this.pingColor,
    this.cue,
    this.phaseDurationMs,
  });

  /// Session core, reused from the Live Activity so both surfaces agree.
  final LiveActivitySnapshot core;
  final WatchGeo geo;
  final WatchControls controls;
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
        'geo': geo.toMap(),
        'controls': controls.toMap(),
        'cue': cue?.toMap(),
        'updatedAtMs': updatedAt.millisecondsSinceEpoch.toDouble(),
      };

  /// Fields that must bypass the update throttle.
  ///
  /// Deliberately excludes geo: a moving GPS would otherwise mark every
  /// update urgent and defeat the throttle entirely.
  String get urgencyKey => [
        core.sessionId,
        core.mode,
        core.phase.wireValue,
        core.phaseTitle,
        core.phaseDetail ?? '',
        core.phaseEndsAt?.millisecondsSinceEpoch ?? 0,
        core.isConnected,
        controls.canStartStop,
        controls.canManualPing,
        controls.isSessionActive,
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
