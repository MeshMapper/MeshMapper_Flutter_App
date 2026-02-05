import 'package:intl/intl.dart';

/// Represents a repeater from the MeshMapper API.
/// Used to display repeater markers on the map.
class Repeater {
  /// Unique ID (e.g., "01", "92")
  final String id;

  /// Hex ID (8-character hex string)
  final String hexId;

  /// Display name of the repeater
  final String name;

  /// Latitude coordinate
  final double lat;

  /// Longitude coordinate
  final double lon;

  /// Last heard timestamp (Unix seconds)
  final int lastHeard;

  /// Enabled status (1 = enabled, 0 = disabled)
  final int enabled;

  /// IATA zone code (e.g., "YOW")
  final String? iata;

  /// Created at timestamp (Unix seconds), nullable for backwards compatibility
  final int? createdAt;

  /// Server-provided staleness cutoff (Unix seconds).
  /// The repeater is active while `now < staleTime`.
  final int? staleTime;

  const Repeater({
    required this.id,
    required this.hexId,
    required this.name,
    required this.lat,
    required this.lon,
    required this.lastHeard,
    required this.enabled,
    this.iata,
    this.createdAt,
    this.staleTime,
  });

  /// Parse from JSON object in repeaters.json
  factory Repeater.fromJson(Map<String, dynamic> json) {
    // Parse created_at which may be int or String
    int? createdAt;
    final rawCreatedAt = json['created_at'];
    if (rawCreatedAt is int) {
      createdAt = rawCreatedAt;
    } else if (rawCreatedAt is String) {
      createdAt = int.tryParse(rawCreatedAt);
    }

    // Parse stale_time which may be int or String
    int? staleTime;
    final rawStaleTime = json['stale_time'];
    if (rawStaleTime is int) {
      staleTime = rawStaleTime;
    } else if (rawStaleTime is String) {
      staleTime = int.tryParse(rawStaleTime);
    }

    return Repeater(
      id: json['id'] as String,
      hexId: json['hex_id'] as String? ?? '',
      name: json['name'] as String? ?? 'Unknown',
      lat: (json['lat'] as num).toDouble(),
      lon: (json['lon'] as num).toDouble(),
      lastHeard: json['last_heard'] as int? ?? 0,
      enabled: json['enabled'] as int? ?? 0,
      iata: json['iata'] as String?,
      createdAt: createdAt,
      staleTime: staleTime,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'hex_id': hexId,
      'name': name,
      'lat': lat,
      'lon': lon,
      'last_heard': lastHeard,
      'enabled': enabled,
      'iata': iata,
      'created_at': createdAt,
      'stale_time': staleTime,
    };
  }

  /// Get formatted last heard date/time (locale-aware)
  String get lastHeardFormatted {
    if (lastHeard == 0) return 'Never';
    final date = DateTime.fromMillisecondsSinceEpoch(lastHeard * 1000);
    return DateFormat.yMMMd().add_jm().format(date);
  }

  /// Check if the repeater is enabled (any non-zero value)
  bool get isEnabled => enabled != 0;

  /// Check if the repeater was created within the past 7 days
  bool get isNew {
    if (createdAt == null) return false;
    final created = DateTime.fromMillisecondsSinceEpoch(createdAt! * 1000);
    return DateTime.now().difference(created).inDays < 7;
  }

  /// Check if the repeater is active.
  /// Uses server-provided [staleTime] when available, otherwise falls back
  /// to a 24-hour threshold from [lastHeard].
  bool get isActive {
    if (staleTime != null) {
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return nowSeconds < staleTime!;
    }
    // Fallback: 24-hour threshold from lastHeard
    if (lastHeard == 0) return false;
    final heard = DateTime.fromMillisecondsSinceEpoch(lastHeard * 1000);
    return DateTime.now().difference(heard).inHours < 24;
  }

  /// Check if the repeater has not been heard in the past 24 hours
  bool get isDead => !isActive;

  @override
  String toString() => 'Repeater(id=$id, name=$name, enabled=$isEnabled)';
}
