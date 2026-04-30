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

  /// Number of bytes per hop hash for this repeater's path (1, 2, or 3)
  final int hopBytes;

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
    this.hopBytes = 1,
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
      hopBytes: (json['hop_bytes'] as int?) ?? 1,
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
      'hop_bytes': hopBytes,
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

  /// True when the repeater has known GPS coordinates. The API uses
  /// `(0, 0)` as a sentinel for "location not yet published" — those
  /// repeaters are excluded from map focus geometry (no line, no
  /// distance label, not part of the bounds-fit) but still appear in
  /// heard-repeater listings with a `location_off` indicator.
  bool get hasLocation => lat != 0.0 || lon != 0.0;

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

  /// True if the repeater has been heard within the past 30 days. Used by
  /// the map to hide long-stale repeaters. Returns false when [lastHeard]
  /// is 0 (never heard).
  bool get isHeardRecently {
    if (lastHeard == 0) return false;
    final heard = DateTime.fromMillisecondsSinceEpoch(lastHeard * 1000);
    return DateTime.now().difference(heard).inDays < 30;
  }

  /// Get display hex ID based on hop bytes (or override).
  /// [overrideHopBytes] is used when regional admin enforces a byte size.
  String displayHexId({int? overrideHopBytes}) {
    final bytes = overrideHopBytes ?? hopBytes;
    final hexChars = bytes * 2; // 1 byte = 2 hex chars
    if (hexId.length >= hexChars) {
      return hexId.substring(0, hexChars).toUpperCase();
    }
    return id; // Fallback to short numeric ID
  }

  @override
  String toString() => 'Repeater(id=$id, name=$name, enabled=$isEnabled)';
}
