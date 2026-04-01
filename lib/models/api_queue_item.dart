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

  /// Earliest time this item can be uploaded (milliseconds since epoch)
  /// All items are immediate; upload timing is controlled by flush timers
  @HiveField(13)
  final int canUploadAfter;

  /// Whether an external antenna is being used
  @HiveField(14)
  final bool externalAntenna;

  /// Radio power in watts (e.g., 0.3, 1.0, 2.0) — included in every API post
  @HiveField(15)
  final double? power;

  ApiQueueItem({
    required this.type,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.heardRepeats,
    required this.canUploadAfter,
    required this.externalAntenna,
    this.retryCount = 0,
    this.lastRetryAt,
    this.noiseFloor,
    this.power,
  });

  /// Create from TX ping
  /// heardRepeats format: "4e(12.25),77(12.25)" or "None"
  factory ApiQueueItem.fromTx({
    required double latitude,
    required double longitude,
    required String heardRepeats,
    required int timestamp,
    required bool externalAntenna,
    int? noiseFloor,
    double? power,
  }) {
    return ApiQueueItem(
      type: 'TX',
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
      heardRepeats: heardRepeats,
      canUploadAfter: DateTime.now().millisecondsSinceEpoch, // Immediate — flush timer controls upload timing
      externalAntenna: externalAntenna,
      noiseFloor: noiseFloor,
      power: power,
    );
  }

  /// Create from RX observation
  /// heardRepeats format: "4e(12.0)" (single repeater with SNR)
  factory ApiQueueItem.fromRx({
    required double latitude,
    required double longitude,
    required String heardRepeats,
    required int timestamp,
    required bool externalAntenna,
    int? noiseFloor,
    double? power,
  }) {
    return ApiQueueItem(
      type: 'RX',
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
      heardRepeats: heardRepeats,
      canUploadAfter: DateTime.now().millisecondsSinceEpoch, // Immediate
      externalAntenna: externalAntenna,
      noiseFloor: noiseFloor,
      power: power,
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
    required bool externalAntenna,
    int? noiseFloor,
    double? power,
  }) {
    // Format: "repeaterId:nodeType:localSnr:localRssi:remoteSnr:pubkeyFull"
    final heardRepeats = '$repeaterId:$nodeType:${localSnr.toStringAsFixed(2)}:$localRssi:${remoteSnr.toStringAsFixed(2)}:$pubkeyFull';
    return ApiQueueItem(
      type: 'DISC',
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
      heardRepeats: heardRepeats,
      canUploadAfter: DateTime.now().millisecondsSinceEpoch, // Immediate
      externalAntenna: externalAntenna,
      noiseFloor: noiseFloor,
      power: power,
    );
  }

  /// Create from a successful TRACE ping (targeted zero-hop trace)
  /// heardRepeats format: "repeaterId:localSnr:localRssi:remoteSnr"
  factory ApiQueueItem.fromTrace({
    required double latitude,
    required double longitude,
    required String repeaterId,
    required double localSnr,
    required int localRssi,
    required double remoteSnr,
    required int timestamp,
    required bool externalAntenna,
    int? noiseFloor,
    double? power,
  }) {
    final heardRepeats = '$repeaterId:${localSnr.toStringAsFixed(2)}:$localRssi:${remoteSnr.toStringAsFixed(2)}';
    return ApiQueueItem(
      type: 'TRACE',
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
      heardRepeats: heardRepeats,
      canUploadAfter: DateTime.now().millisecondsSinceEpoch, // Immediate
      externalAntenna: externalAntenna,
      noiseFloor: noiseFloor,
      power: power,
    );
  }

  /// Create from a failed DISC discovery (no nodes responded)
  factory ApiQueueItem.fromDiscDrop({
    required double latitude,
    required double longitude,
    required int timestamp,
    required bool externalAntenna,
    int? noiseFloor,
    double? power,
  }) {
    return ApiQueueItem(
      type: 'DISC',
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
      heardRepeats: 'None',
      canUploadAfter: DateTime.now().millisecondsSinceEpoch, // Immediate
      externalAntenna: externalAntenna,
      noiseFloor: noiseFloor,
      power: power,
    );
  }

  /// Convert to API JSON format (matches WebClient exactly)
  Map<String, dynamic> toApiJson() {
    // For TRACE type, parse the heardRepeats field to extract individual values
    if (type == 'TRACE') {
      // Format: "repeaterId:localSnr:localRssi:remoteSnr"
      final parts = heardRepeats.split(':');
      return {
        'type': type,
        'lat': latitude,
        'lon': longitude,
        'noisefloor': noiseFloor,
        'repeater_id': parts.isNotEmpty ? parts[0] : '',
        'local_snr': parts.length > 1 ? double.tryParse(parts[1]) : null,
        'local_rssi': parts.length > 2 ? int.tryParse(parts[2]) : null,
        'remote_snr': parts.length > 3 ? double.tryParse(parts[3]) : null,
        'timestamp': timestamp.millisecondsSinceEpoch ~/ 1000,
        'external_antenna': externalAntenna,
        'power': power != null ? '${power!.toStringAsFixed(1)}w' : null,
      };
    }

    // For DISC type, parse the heardRepeats field to extract individual values
    if (type == 'DISC') {
      // Failed discovery (no nodes responded)
      if (heardRepeats == 'None') {
        return {
          'type': type,
          'lat': latitude,
          'lon': longitude,
          'noisefloor': noiseFloor,
          'repeater_id': 'None',
          'timestamp': timestamp.millisecondsSinceEpoch ~/ 1000,
          'external_antenna': externalAntenna,
          'power': power != null ? '${power!.toStringAsFixed(1)}w' : null,
        };
      }

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
        'external_antenna': externalAntenna,
        'power': power != null ? '${power!.toStringAsFixed(1)}w' : null,
      };
    }

    return {
      'type': type,
      'lat': latitude,
      'lon': longitude,
      'noisefloor': noiseFloor,
      'heard_repeats': heardRepeats,
      'timestamp': timestamp.millisecondsSinceEpoch ~/ 1000, // Unix timestamp in seconds
      'external_antenna': externalAntenna,
      'power': power != null ? '${power!.toStringAsFixed(1)}w' : null,
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

  /// Check if item is eligible for upload based on canUploadAfter
  bool get isUploadEligible => DateTime.now().millisecondsSinceEpoch >= canUploadAfter;

  /// Mark as retried
  void markRetried() {
    retryCount++;
    lastRetryAt = DateTime.now();
    save(); // Persist to Hive
  }

  @override
  String toString() => 'ApiQueueItem($type, $latitude, $longitude, retries=$retryCount)';
}
