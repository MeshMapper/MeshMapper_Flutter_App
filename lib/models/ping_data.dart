import 'package:hive/hive.dart';

part 'ping_data.g.dart';

/// Type of ping (TX = transmitted, RX = received from repeater)
@HiveType(typeId: 0)
enum PingType {
  @HiveField(0)
  tx,
  
  @HiveField(1)
  rx,
}

/// TX ping data - sent to #wardriving channel
@HiveType(typeId: 1)
class TxPing {
  @HiveField(0)
  final double latitude;

  @HiveField(1)
  final double longitude;

  @HiveField(2)
  final int power;

  @HiveField(3)
  final DateTime timestamp;

  @HiveField(4)
  final String deviceId;

  /// Heard repeaters (populated after echo tracking window ends)
  /// Not persisted to Hive - transient runtime data
  final List<HeardRepeater> heardRepeaters;

  TxPing({
    required this.latitude,
    required this.longitude,
    required this.power,
    required this.timestamp,
    required this.deviceId,
    List<HeardRepeater>? heardRepeaters,
  }) : heardRepeaters = heardRepeaters ?? [];

  /// Format ping message for BLE transmission
  /// Format: @[MapperBot] LAT, LON [POWERw]
  /// Note: power is stored in dBm but the message format uses watts
  /// The actual message is built in PingService with the correct watts value
  String toMessageFormat({double? powerWatts}) {
    final coordsStr = '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
    final pw = powerWatts ?? 0.3; // Default to 0.3w if not provided
    return '@[MapperBot] $coordsStr [${pw.toStringAsFixed(1)}w]';
  }

  Map<String, dynamic> toApiJson() {
    return {
      'type': 'TX',
      'lat': latitude,
      'lon': longitude,
      'power': power,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'device_id': deviceId,
    };
  }
}

/// RX ping data - received from repeater echoes
@HiveType(typeId: 2)
class RxPing {
  @HiveField(0)
  final double latitude;
  
  @HiveField(1)
  final double longitude;
  
  @HiveField(2)
  final String repeaterId;
  
  @HiveField(3)
  final DateTime timestamp;
  
  @HiveField(4)
  final double snr;
  
  @HiveField(5)
  final int rssi;

  const RxPing({
    required this.latitude,
    required this.longitude,
    required this.repeaterId,
    required this.timestamp,
    required this.snr,
    required this.rssi,
  });

  Map<String, dynamic> toApiJson() {
    return {
      'type': 'RX',
      'lat': latitude,
      'lon': longitude,
      'repeater_id': repeaterId,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'snr': snr,
      'rssi': rssi,
    };
  }
}

/// Repeater that heard a TX ping (from echo tracking)
class HeardRepeater {
  final String repeaterId; // Hex ID (e.g., "4e", "77")
  final double snr; // Best SNR observed
  final int rssi; // RSSI in dBm
  final int seenCount; // How many times this repeater was heard

  const HeardRepeater({
    required this.repeaterId,
    required this.snr,
    this.rssi = 0,
    this.seenCount = 1,
  });
}

/// Information about a known repeater
class RepeaterInfo {
  final String id;
  final String name;
  final int colorValue;

  const RepeaterInfo({
    required this.id,
    required this.name,
    required this.colorValue,
  });

  /// Get a stable color for this repeater based on its ID
  static int colorFromId(String id) {
    // Generate consistent color from repeater ID hash
    final hash = id.hashCode;
    final hue = (hash % 360).abs();
    // Convert HSL to RGB (simplified)
    return _hslToRgb(hue / 360.0, 0.7, 0.5);
  }

  static int _hslToRgb(double h, double s, double l) {
    double r, g, b;

    if (s == 0) {
      r = g = b = l;
    } else {
      double q = l < 0.5 ? l * (1 + s) : l + s - l * s;
      double p = 2 * l - q;
      r = _hueToRgb(p, q, h + 1 / 3);
      g = _hueToRgb(p, q, h);
      b = _hueToRgb(p, q, h - 1 / 3);
    }

    return (0xFF << 24) |
        ((r * 255).round() << 16) |
        ((g * 255).round() << 8) |
        (b * 255).round();
  }

  static double _hueToRgb(double p, double q, double t) {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 1 / 2) return q;
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  }
}

/// Ping statistics
class PingStats {
  final int txCount;
  final int rxCount;
  final int discCount; // Discovery count (Passive Mode)
  final int successfulUploads;
  final int failedUploads;
  final int queuedCount;

  const PingStats({
    this.txCount = 0,
    this.rxCount = 0,
    this.discCount = 0,
    this.successfulUploads = 0,
    this.failedUploads = 0,
    this.queuedCount = 0,
  });

  PingStats copyWith({
    int? txCount,
    int? rxCount,
    int? discCount,
    int? successfulUploads,
    int? failedUploads,
    int? queuedCount,
  }) {
    return PingStats(
      txCount: txCount ?? this.txCount,
      rxCount: rxCount ?? this.rxCount,
      discCount: discCount ?? this.discCount,
      successfulUploads: successfulUploads ?? this.successfulUploads,
      failedUploads: failedUploads ?? this.failedUploads,
      queuedCount: queuedCount ?? this.queuedCount,
    );
  }

  double get successRate {
    final total = successfulUploads + failedUploads;
    if (total == 0) return 0;
    return successfulUploads / total;
  }
}
