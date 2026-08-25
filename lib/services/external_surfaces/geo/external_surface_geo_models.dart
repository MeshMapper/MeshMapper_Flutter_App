import 'dart:math' as math;

import '../external_surface_color.dart';

class ExternalSurfaceGeoWire {
  ExternalSurfaceGeoWire._();

  static const int maxPings = 60;
  static const int maxRepeaters = 20;
  static const int maxHeard = 4;
  static const double minMoveMeters = 15.0;

  static bool movedEnough({
    required double? lastLat,
    required double? lastLon,
    required double lat,
    required double lon,
    double thresholdMeters = minMoveMeters,
  }) {
    if (lastLat == null || lastLon == null) return true;
    return distanceMeters(lastLat, lastLon, lat, lon) >= thresholdMeters;
  }

  /// Great-circle distance in metres.
  static double distanceMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadius = 6371000.0;
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _toRadians(double degrees) => degrees * math.pi / 180.0;
}

class ExternalSurfacePosition {
  const ExternalSurfacePosition({
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

class ExternalSurfacePing {
  const ExternalSurfacePing({
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
  final String kind;
  final ExternalSurfaceColor color;
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

class ExternalSurfaceRepeater {
  const ExternalSurfaceRepeater({
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
  final ExternalSurfaceColor color;
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

class ExternalSurfaceHeardNode {
  const ExternalSurfaceHeardNode({
    required this.id,
    required this.typeColor,
    required this.at,
    this.name,
    this.snr,
    this.distanceM,
    this.snrColor,
  });

  final String id;
  final String? name;
  final double? snr;
  final DateTime at;
  final double? distanceM;
  final ExternalSurfaceColor? snrColor;
  final ExternalSurfaceColor typeColor;

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

class ExternalSurfaceGeo {
  const ExternalSurfaceGeo({
    required this.pings,
    required this.repeaters,
    required this.heard,
    required this.linkedRepeaterIds,
    this.you,
  });

  final ExternalSurfacePosition? you;
  final List<ExternalSurfacePing> pings;
  final List<ExternalSurfaceRepeater> repeaters;
  final List<ExternalSurfaceHeardNode> heard;
  final List<String> linkedRepeaterIds;

  Map<String, Object?> toMap({bool includeMapDetail = true}) => {
        'you': you?.toMap(),
        'pings': includeMapDetail
            ? pings.map((ping) => ping.toMap()).toList()
            : const [],
        'repeaters': includeMapDetail
            ? repeaters.map((repeater) => repeater.toMap()).toList()
            : const [],
        'heard': heard.map((node) => node.toMap()).toList(),
        'linkedRepeaterIds': includeMapDetail ? linkedRepeaterIds : const [],
      };
}
