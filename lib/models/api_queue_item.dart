import 'package:hive/hive.dart';

part 'api_queue_item.g.dart';

/// Item in the API upload queue
/// Persisted using Hive for crash recovery
///
/// Matches WebClient wardrive payload format:
/// {
///   "type": "TX" or "RX",
///   "lat": 45.26974,
///   "lon": -75.77746,
///   "noisefloor": -103,
///   "heard_repeats": "4e(12.25),77(12.25)",
///   "timestamp": 1768762843
/// }
@HiveType(typeId: 3)
class ApiQueueItem extends HiveObject {
  @HiveField(0)
  final String type; // 'TX' or 'RX'

  @HiveField(1)
  final double latitude;

  @HiveField(2)
  final double longitude;

  @HiveField(3)
  final DateTime timestamp;

  @HiveField(5)
  int retryCount;

  @HiveField(6)
  DateTime? lastRetryAt;

  @HiveField(11)
  final int? noiseFloor;

  /// Heard repeats string formatted as "id(snr),id(snr)" e.g. "4e(12.25),77(12.25)"
  /// For TX: multiple repeaters separated by comma
  /// For RX: single repeater e.g. "4e(12.0)"
  @HiveField(12)
  final String heardRepeats;

  ApiQueueItem({
    required this.type,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.heardRepeats,
    this.retryCount = 0,
    this.lastRetryAt,
    this.noiseFloor,
  });

  /// Create from TX ping
  /// heardRepeats format: "4e(12.25),77(12.25)" or "None"
  factory ApiQueueItem.fromTx({
    required double latitude,
    required double longitude,
    required String heardRepeats,
    required int timestamp,
    int? noiseFloor,
  }) {
    return ApiQueueItem(
      type: 'TX',
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
      heardRepeats: heardRepeats,
      noiseFloor: noiseFloor,
    );
  }

  /// Create from RX observation
  /// heardRepeats format: "4e(12.0)" (single repeater with SNR)
  factory ApiQueueItem.fromRx({
    required double latitude,
    required double longitude,
    required String heardRepeats,
    required int timestamp,
    int? noiseFloor,
  }) {
    return ApiQueueItem(
      type: 'RX',
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
      heardRepeats: heardRepeats,
      noiseFloor: noiseFloor,
    );
  }

  /// Create from DISC discovery observation
  /// Each discovered node is stored as a separate item
  factory ApiQueueItem.fromDisc({
    required double latitude,
    required double longitude,
    required String repeaterId,
    required String nodeType,
    required double localSnr,
    required int localRssi,
    required double remoteSnr,
    required String pubkeyFull,
    required int timestamp,
    int? noiseFloor,
  }) {
    // Format: "repeaterId:nodeType:localSnr:localRssi:remoteSnr:pubkeyFull"
    final heardRepeats = '$repeaterId:$nodeType:${localSnr.toStringAsFixed(2)}:$localRssi:${remoteSnr.toStringAsFixed(2)}:$pubkeyFull';
    return ApiQueueItem(
      type: 'DISC',
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
      heardRepeats: heardRepeats,
      noiseFloor: noiseFloor,
    );
  }

  /// Convert to API JSON format (matches WebClient exactly)
  Map<String, dynamic> toApiJson() {
    // For DISC type, parse the heardRepeats field to extract individual values
    if (type == 'DISC') {
      // Format: "repeaterId:nodeType:localSnr:localRssi:remoteSnr:pubkeyFull"
      final parts = heardRepeats.split(':');
      return {
        'type': type,
        'lat': latitude,
        'lon': longitude,
        'noisefloor': noiseFloor,
        'repeater_id': parts.isNotEmpty ? parts[0] : '',
        'node_type': parts.length > 1 ? parts[1] : '',
        'local_snr': parts.length > 2 ? double.tryParse(parts[2]) ?? 0.0 : 0.0,
        'local_rssi': parts.length > 3 ? int.tryParse(parts[3]) ?? 0 : 0,
        'remote_snr': parts.length > 4 ? double.tryParse(parts[4]) ?? 0.0 : 0.0,
        'public_key': parts.length > 5 ? parts[5] : '',
        'timestamp': timestamp.millisecondsSinceEpoch ~/ 1000, // Unix timestamp in seconds
      };
    }

    return {
      'type': type,
      'lat': latitude,
      'lon': longitude,
      'noisefloor': noiseFloor,
      'heard_repeats': heardRepeats,
      'timestamp': timestamp.millisecondsSinceEpoch ~/ 1000, // Unix timestamp in seconds
    };
  }

  /// Calculate next retry delay using exponential backoff
  Duration get nextRetryDelay {
    // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 32s, max 60s
    final seconds = (1 << retryCount).clamp(1, 60);
    return Duration(seconds: seconds);
  }

  /// Check if item is ready for retry
  bool get isReadyForRetry {
    if (lastRetryAt == null) return true;
    return DateTime.now().difference(lastRetryAt!) >= nextRetryDelay;
  }

  /// Mark as retried
  void markRetried() {
    retryCount++;
    lastRetryAt = DateTime.now();
    save(); // Persist to Hive
  }

  @override
  String toString() => 'ApiQueueItem($type, $latitude, $longitude, retries=$retryCount)';
}
