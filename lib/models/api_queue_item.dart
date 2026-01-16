import 'package:hive/hive.dart';

part 'api_queue_item.g.dart';

/// Item in the API upload queue
/// Persisted using Hive for crash recovery
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
  
  @HiveField(4)
  final String deviceId;
  
  @HiveField(5)
  int retryCount;
  
  @HiveField(6)
  DateTime? lastRetryAt;
  
  // TX-specific fields
  @HiveField(7)
  final int? power;
  
  // RX-specific fields
  @HiveField(8)
  final String? repeaterId;
  
  @HiveField(9)
  final double? snr;
  
  @HiveField(10)
  final int? rssi;

  ApiQueueItem({
    required this.type,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.deviceId,
    this.retryCount = 0,
    this.lastRetryAt,
    this.power,
    this.repeaterId,
    this.snr,
    this.rssi,
  });

  /// Create from TX ping
  factory ApiQueueItem.fromTx({
    required double latitude,
    required double longitude,
    required int power,
    required String deviceId,
  }) {
    return ApiQueueItem(
      type: 'TX',
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.now(),
      deviceId: deviceId,
      power: power,
    );
  }

  /// Create from RX ping
  factory ApiQueueItem.fromRx({
    required double latitude,
    required double longitude,
    required String repeaterId,
    required double snr,
    required int rssi,
    required String deviceId,
  }) {
    return ApiQueueItem(
      type: 'RX',
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.now(),
      deviceId: deviceId,
      repeaterId: repeaterId,
      snr: snr,
      rssi: rssi,
    );
  }

  /// Convert to API JSON format (matches WebClient exactly)
  Map<String, dynamic> toApiJson() {
    final json = <String, dynamic>{
      'type': type,
      'lat': latitude,
      'lon': longitude,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'device_id': deviceId,
    };

    if (type == 'TX') {
      json['power'] = power;
    } else {
      json['repeater_id'] = repeaterId;
      json['snr'] = snr;
      json['rssi'] = rssi;
    }

    return json;
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
