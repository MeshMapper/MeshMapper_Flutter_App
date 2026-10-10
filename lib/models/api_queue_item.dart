import 'package:hive/hive.dart';

import '../utils/public_key.dart';

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
  final String type; // 'TX', 'RX', 'DISC', 'TRACE', 'DEFER' or 'SCOPES'

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

  /// TX wire-tag ping counter (token mode only; null otherwise).
  @HiveField(16)
  final int? pingCounter;

  /// TX wire-tag body sent on the air, e.g. "MM:FlmLG4I" (token mode only; null otherwise).
  @HiveField(17)
  final String? wireTag;

  /// Altitude of the fix in meters, null when the phone did not know it.
  /// Uploaded ONLY together with [altitudeRef]: an altitude whose reference
  /// is not proved is stored but never emitted. Contract:
  /// MeshMapper_Server/docs/APP_API.md.
  @HiveField(18)
  final double? altitude;

  /// The auto mode running when this item was queued, as the server's enum:
  /// `active`, `hybrid`, `passive`, `trace`, or `none` for a manual ping or
  /// an RX row heard while connected with no mode running. Null only when the
  /// queue has no mode getter wired, which the server reads as unknown. An
  /// analytics stamp: the server copies it to the coverage row.
  @HiveField(19)
  final String? autoMode;

  /// The radio configuration this item was recorded under, the full
  /// `freqMHz,bwKHz,SF,CR` tag the radio reported at connect (e.g.
  /// `910.525,62.5,7,5`). Stamped at enqueue time from the live radio, so
  /// the server reads the preset off the row instead of joining the session,
  /// and an item queued before a preset change keeps the preset it was heard
  /// on. Null when the radio reported no configuration or the queue has no
  /// getter wired; the server then falls back to the session's value.
  @HiveField(20)
  final String? radioFreq;

  /// A repeater's scope discovery answer, sent only for a SCOPES item. The
  /// list is exactly what the repeater sent (case kept, `*` kept, at most
  /// 33 entries, may be empty). Null for every other type. The answering
  /// repeater's public key rides in [heardRepeats] instead, the DISC/DEFER
  /// packing precedent, since a list needs its own field.
  @HiveField(21)
  final List<String>? scopes;

  /// The vertical reference [altitude] is measured from, `msl` (above mean
  /// sea level) or `ellipsoid` (above the WGS84 ellipsoid). Null when the
  /// app could not prove it, in which case [toApiJson] emits no altitude.
  @HiveField(22)
  final String? altitudeRef;

  /// Vertical accuracy of the fix in meters, about one standard deviation.
  /// Null when the phone did not know it. Emitted only beside a labelled
  /// altitude and only when finite and above zero.
  @HiveField(23)
  final double? altitudeAccuracy;

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
    this.pingCounter,
    this.wireTag,
    this.altitude,
    this.altitudeRef,
    this.altitudeAccuracy,
    this.autoMode,
    this.radioFreq,
    this.scopes,
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
    int? pingCounter,
    String? wireTag,
    double? altitude,
    String? altitudeRef,
    double? altitudeAccuracy,
    String? autoMode,
    String? radioFreq,
  }) {
    return ApiQueueItem(
      type: 'TX',
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
      heardRepeats: heardRepeats,
      canUploadAfter: DateTime.now()
          .millisecondsSinceEpoch, // Immediate — flush timer controls upload timing
      externalAntenna: externalAntenna,
      noiseFloor: noiseFloor,
      power: power,
      pingCounter: pingCounter,
      wireTag: wireTag,
      altitude: altitude,
      altitudeRef: altitudeRef,
      altitudeAccuracy: altitudeAccuracy,
      autoMode: autoMode,
      radioFreq: radioFreq,
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
    double? altitude,
    String? altitudeRef,
    double? altitudeAccuracy,
    String? autoMode,
    String? radioFreq,
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
      altitude: altitude,
      altitudeRef: altitudeRef,
      altitudeAccuracy: altitudeAccuracy,
      autoMode: autoMode,
      radioFreq: radioFreq,
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
    double? altitude,
    String? altitudeRef,
    double? altitudeAccuracy,
    String? autoMode,
    String? radioFreq,
  }) {
    // Format: "repeaterId:nodeType:localSnr:localRssi:remoteSnr:pubkeyFull"
    final heardRepeats =
        '$repeaterId:$nodeType:${localSnr.toStringAsFixed(2)}:$localRssi:${remoteSnr.toStringAsFixed(2)}:$pubkeyFull';
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
      altitude: altitude,
      altitudeRef: altitudeRef,
      altitudeAccuracy: altitudeAccuracy,
      autoMode: autoMode,
      radioFreq: radioFreq,
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
    double? altitude,
    String? altitudeRef,
    double? altitudeAccuracy,
    String? autoMode,
    String? radioFreq,
  }) {
    final heardRepeats =
        '$repeaterId:${localSnr.toStringAsFixed(2)}:$localRssi:${remoteSnr.toStringAsFixed(2)}';
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
      altitude: altitude,
      altitudeRef: altitudeRef,
      altitudeAccuracy: altitudeAccuracy,
      autoMode: autoMode,
      radioFreq: radioFreq,
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
    double? altitude,
    String? altitudeRef,
    double? altitudeAccuracy,
    String? autoMode,
    String? radioFreq,
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
      altitude: altitude,
      altitudeRef: altitudeRef,
      altitudeAccuracy: altitudeAccuracy,
      autoMode: autoMode,
      radioFreq: radioFreq,
    );
  }

  /// A square where smart pinging held a ping: the server verifies it was
  /// covered and credits it. [held] is `tx` or `disc`, stored in the
  /// heardRepeats slot the way DISC and TRACE overload it. Nothing else is
  /// carried: the server pays for the square, not the reading, and the item
  /// is never stamped with the auto mode.
  factory ApiQueueItem.fromDefer({
    required double latitude,
    required double longitude,
    required int timestamp,
    required String held,
    String? radioFreq,
  }) {
    return ApiQueueItem(
      type: 'DEFER',
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
      heardRepeats: held,
      canUploadAfter: DateTime.now().millisecondsSinceEpoch, // Immediate
      externalAntenna: false,
      radioFreq: radioFreq,
    );
  }

  /// A repeater's answer to a direct scope discovery question, sent only
  /// after a discovery found it. The public key rides in [heardRepeats]
  /// (the DISC/DEFER packing precedent); the answer itself needs its own
  /// field since a list cannot be squeezed safely into that string. Never
  /// stamped with the auto mode, the DEFER precedent again: this is a
  /// repeater fact, not a session-mode analytics stamp.
  ///
  /// [publicKeyHex] is normalized to 64 upper-case hex via
  /// [normalizePublicKey], so the item never serializes any other shape.
  /// Anything that does not normalize throws [ArgumentError]: the server
  /// would reject the whole item, and a caller that can meet a bad key
  /// (`ApiQueueService.enqueueScopes` does) validates it first and refuses
  /// it without building the item.
  factory ApiQueueItem.fromScopes({
    required String publicKeyHex,
    required List<String> scopes,
    required double lat,
    required double lon,
    required int timestamp,
    String? radioFreq,
  }) {
    final key = normalizePublicKey(publicKeyHex);
    if (key == null) {
      throw ArgumentError.value(publicKeyHex, 'publicKeyHex',
          'must be a 64 hex character public key');
    }
    return ApiQueueItem(
      type: 'SCOPES',
      latitude: lat,
      longitude: lon,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
      heardRepeats: key,
      canUploadAfter: DateTime.now().millisecondsSinceEpoch, // Immediate
      externalAntenna: false,
      scopes: scopes,
      radioFreq: radioFreq,
    );
  }

  /// Convert to API JSON format (matches WebClient exactly)
  /// The altitude trio, or nothing. An altitude is never emitted without its
  /// reference, and the accuracy only beside both and when usable. The
  /// enqueue paths already pass null for all three when the reference is
  /// unknown; this gate makes sure neither side alone can leak a bare value.
  Map<String, dynamic> get _altitudeFields {
    final meters = altitude;
    final ref = altitudeRef;
    if (meters == null || ref == null) return const {};
    final acc = altitudeAccuracy;
    return {
      'altitude': meters.round(),
      'altitude_ref': ref,
      if (acc != null && acc.isFinite && acc > 0) 'altitude_acc': acc.round(),
    };
  }

  Map<String, dynamic> toApiJson() {
    // A repeater's scope answer: public key, the scopes exactly as heard,
    // when the answer arrived, and where the discovery that found it was
    // made. Never the mode stamp and never external_antenna/noisefloor/
    // altitude/power, the DEFER precedent.
    if (type == 'SCOPES') {
      return {
        'type': type,
        'public_key': heardRepeats,
        'scopes': scopes ?? const <String>[],
        'timestamp': timestamp.millisecondsSinceEpoch ~/ 1000,
        'lat': latitude,
        'lon': longitude,
        if (radioFreq != null) 'radio_freq': radioFreq,
      };
    }

    // A deferral carries only the square and which kind of ping was held.
    // Never the mode stamp (the server stores none for a deferral), but the
    // radio tag rides along.
    if (type == 'DEFER') {
      return {
        'type': type,
        'lat': latitude,
        'lon': longitude,
        'timestamp': timestamp.millisecondsSinceEpoch ~/ 1000,
        'held': heardRepeats,
        // The preset the square was crossed on. The server verifies the
        // square against that preset's coverage, not the region's whole
        // history.
        if (radioFreq != null) 'radio_freq': radioFreq,
      };
    }

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
        ..._altitudeFields,
        if (autoMode != null) 'auto_mode': autoMode,
        if (radioFreq != null) 'radio_freq': radioFreq,
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
          ..._altitudeFields,
          if (autoMode != null) 'auto_mode': autoMode,
          if (radioFreq != null) 'radio_freq': radioFreq,
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
        'timestamp': timestamp.millisecondsSinceEpoch ~/
            1000, // Unix timestamp in seconds
        'external_antenna': externalAntenna,
        'power': power != null ? '${power!.toStringAsFixed(1)}w' : null,
        ..._altitudeFields,
        if (autoMode != null) 'auto_mode': autoMode,
        if (radioFreq != null) 'radio_freq': radioFreq,
      };
    }

    return {
      'type': type,
      'lat': latitude,
      'lon': longitude,
      'noisefloor': noiseFloor,
      'heard_repeats': heardRepeats,
      'timestamp':
          timestamp.millisecondsSinceEpoch ~/ 1000, // Unix timestamp in seconds
      'external_antenna': externalAntenna,
      'power': power != null ? '${power!.toStringAsFixed(1)}w' : null,
      // Token-mode TX only. Their presence selects the server's validated path;
      // absence (coords mode / RX) is the unchanged-from-today coords path.
      if (pingCounter != null) 'ping_counter': pingCounter,
      if (wireTag != null) 'wire_tag': wireTag,
      // Altitude, its reference and its accuracy together, or nothing.
      ..._altitudeFields,
      if (autoMode != null) 'auto_mode': autoMode,
      if (radioFreq != null) 'radio_freq': radioFreq,
    };
  }

  /// Whether this item carries a TX wire-tag claim.
  ///
  /// A tag only re-derives under the session that minted it, so a tagged item
  /// is uploadable ONLY under that session. Once it outlives it the item is
  /// undeliverable and gets dropped rather than uploaded, because every
  /// alternative is worse: keeping the tag makes the server skip the row while
  /// reporting success (a silent loss plus a wire_tag_mismatch warn), and
  /// stripping it sends the ping down the coords path where, with no status-4
  /// WAIT row left to join, it inserts as DEAD(3) and paints a GREY "dead"
  /// cell on the map for a ping that actually got heard.
  bool get hasWireTag => wireTag != null || pingCounter != null;

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
  bool get isUploadEligible =>
      DateTime.now().millisecondsSinceEpoch >= canUploadAfter;

  /// Mark as retried
  void markRetried() {
    retryCount++;
    lastRetryAt = DateTime.now();
    save(); // Persist to Hive
  }

  @override
  String toString() =>
      'ApiQueueItem($type, $latitude, $longitude, retries=$retryCount)';
}
