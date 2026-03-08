import 'dart:async';
import 'dart:math';

import '../../utils/debug_logger_io.dart';
import 'packet_metadata.dart';
import 'packet_validator.dart';

/// Passive RX logger for continuous wardriving observations
/// Reference: handleRxLogging() + handleRxBatching() in wardrive.js (lines 3812-4140)
class RxLogger {
  bool isWardriving = false;
  
  /// Map of repeaterId (hex) -> RxBatch
  final Map<String, RxBatch> _batchBuffer = {};
  
  /// Configuration constants
  static const int batchDistanceMeters = 25;
  static const Duration batchTimeout = Duration(seconds: 30);
  
  /// Callback for batched/finalized RX entries (API queue posting)
  final Future<void> Function(RxApiEntry) onRxEntry;

  /// Callback for immediate observation (fires before batching, for real-time UI)
  final void Function(RxObservation)? onObservation;

  /// GPS location provider
  final ({double lat, double lon})? Function() getGpsLocation;

  /// Function to check if a repeater ID should be ignored
  /// Returns true if the repeater should be filtered out
  final bool Function(String repeaterId)? shouldIgnoreRepeater;

  /// Callback for carpeater drops (for quiet error logging)
  /// Called with repeater ID and reason when a packet is dropped due to carpeater detection
  final void Function(String repeaterId, String reason)? onCarpeaterDrop;

  /// CARpeater prefix — when set, multi-hop packets with this firstHop are stripped
  /// to report the underlying repeater with null SNR/RSSI
  String? carpeaterPrefix;

  RxLogger({
    required this.onRxEntry,
    this.onObservation,
    required this.getGpsLocation,
    this.shouldIgnoreRepeater,
    this.onCarpeaterDrop,
    this.carpeaterPrefix,
  });

  /// Start passive RX wardriving
  void startWardriving() {
    debugLog('[RX LOG] Starting passive RX wardriving');
    isWardriving = true;
  }

  /// Stop passive RX wardriving and flush all batches
  void stopWardriving({String trigger = 'user_stop'}) {
    debugLog('[RX LOG] Stopping passive RX wardriving: trigger=$trigger');
    isWardriving = false;
    flushAllBatches(trigger: trigger);
  }

  /// Handle incoming packet for passive logging
  /// Returns true if packet was logged
  Future<bool> handlePacket(
    PacketMetadata metadata,
    PacketValidator validator,
  ) async {
    if (!isWardriving) return false;
    
    try {
      debugLog('[RX LOG] Processing packet for passive logging');
      
      // VALIDATION: Check path length (need at least one hop)
      // Packets with no path are direct transmissions and don't provide repeater coverage info
      if (metadata.pathHashCount == 0) {
        debugLog('[RX LOG] Ignoring: no path (direct transmission, not via repeater)');
        return false;
      }

      bool carpeaterStripped = false;
      String repeaterId;
      double? reportedSnr = metadata.snr;
      int? reportedRssi = metadata.rssi;

      // Extract LAST hop from path (the repeater that directly delivered to us)
      final lastHopHex = metadata.lastHopHex!;

      // CARpeater check: the carpeater is co-located with us, so it only
      // appears as the last hop (the delivery repeater) on RX packets
      if (carpeaterPrefix != null && lastHopHex == carpeaterPrefix!.toUpperCase()) {
        if (metadata.pathHashCount < 2) {
          debugLog('[RX LOG] CARpeater pass-through: single-hop, dropping');
          return false;
        }
        // Second-to-last hop = the real repeater that forwarded to our carpeater
        repeaterId = metadata.getHopHex(metadata.pathHashCount - 2)!;
        carpeaterStripped = true;
        reportedSnr = null;
        reportedRssi = null;
        debugLog('[RX LOG] CARpeater pass-through: stripped $lastHopHex, reporting underlying repeater $repeaterId');
      } else {
        repeaterId = lastHopHex;
      }

      // Get current GPS location
      final gpsLocation = getGpsLocation();
      if (gpsLocation == null) {
        debugLog('[RX LOG] No GPS fix available, skipping entry');
        return false;
      }

      // Check if this repeater should be ignored (user carpeater filter)
      // Must run before RSSI check so user never sees confusing "RSSI too strong"
      // errors for a device they told the app to ignore
      // Skip for CARpeater pass-through (CARpeater itself was already handled)
      if (!carpeaterStripped && shouldIgnoreRepeater != null && shouldIgnoreRepeater!(repeaterId)) {
        debugLog('[RX LOG] ❌ Ignoring repeater $repeaterId (user carpeater filter)');
        return false;
      }

      // PACKET FILTER: Validate packet before logging
      // Skip RSSI check for CARpeater pass-through
      final validation = await validator.validate(metadata, skipRssiCheck: carpeaterStripped);
      if (!validation.valid) {
        final rawHex = metadata.raw
            .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
            .join(' ');
        debugLog('[RX LOG] ❌ Packet dropped: ${validation.reason}');
        debugLog('[RX LOG] Dropped packet hex: $rawHex');

        // Log carpeater drops to error log (without auto-switching)
        if (validation.reason == 'carpeater-rssi') {
          onCarpeaterDrop?.call(repeaterId, 'RSSI too strong (${metadata.rssi} dBm)');
        }
        return false;
      }

      debugLog('[RX LOG] Packet heard via ${carpeaterStripped ? 'underlying' : 'last'} hop: $repeaterId, '
          'SNR=$reportedSnr, path_length=${metadata.pathHashCount}${carpeaterStripped ? ' (CARpeater stripped)' : ''}');

      debugLog('[RX LOG] ✅ Packet validated and passed filter');

      // Create observation for this packet
      final observation = RxObservation(
        repeaterId: repeaterId,
        snr: reportedSnr,
        rssi: reportedRssi,
        pathLength: metadata.pathHashCount,
        header: metadata.header,
        lat: gpsLocation.lat,
        lon: gpsLocation.lon,
        timestamp: DateTime.now(),
        metadata: metadata,
      );

      // Handle tracking for API (best SNR with distance trigger)
      // Returns true if this observation updated the batch (new repeater or better SNR)
      final wasKept = await _handleRxBatching(
        repeaterId: repeaterId,
        snr: reportedSnr,
        rssi: reportedRssi,
        pathLength: metadata.pathHashCount,
        header: metadata.header,
        currentLocation: gpsLocation,
        metadata: metadata,
      );

      // Only fire immediate callback if this observation was actually kept
      // (either first time hearing this repeater, or better SNR than previous)
      if (wasKept) {
        // IMPORTANT: Use the batch's bestObservation which has the FIRST location
        // where we heard this repeater, not the current GPS location.
        // This ensures map pins stay at the original location.
        final batchedObservation = _batchBuffer[repeaterId]?.bestObservation ?? observation;
        onObservation?.call(batchedObservation);
        debugLog('[RX LOG] ✅ Observation kept in batch: repeater=$repeaterId, '
            'snr=${batchedObservation.snr ?? 'null'}, location=${batchedObservation.lat.toStringAsFixed(5)},${batchedObservation.lon.toStringAsFixed(5)}');
      } else {
        debugLog('[RX LOG] ⏭️  Observation ignored (worse SNR): repeater=$repeaterId, '
            'snr=$reportedSnr, current_best=${_batchBuffer[repeaterId]?.bestObservation.snr}');
      }
      
      return true;
    } catch (error, stackTrace) {
      debugError('[RX LOG] Error processing passive RX: $error');
      debugError('[RX LOG] Stack trace: $stackTrace');
      return false;
    }
  }

  /// Handle passive RX event for API batching
  /// Tracks best SNR observation per repeater with distance-based trigger
  /// Returns true if this observation was kept (new repeater or better SNR)
  Future<bool> _handleRxBatching({
    required String repeaterId,
    required double? snr,
    required int? rssi,
    required int pathLength,
    required int header,
    required ({double lat, double lon}) currentLocation,
    required PacketMetadata metadata,
  }) async {
    // Get or create buffer entry for this repeater
    RxBatch? buffer = _batchBuffer[repeaterId];
    bool wasKept = false; // Track if this observation updated the batch

    if (buffer == null) {
      // First time hearing this repeater - create new entry
      buffer = RxBatch(
        firstLocation: currentLocation,
        bestObservation: RxObservation(
          repeaterId: repeaterId,
          snr: snr,
          rssi: rssi,
          pathLength: pathLength,
          header: header,
          lat: currentLocation.lat,
          lon: currentLocation.lon,
          timestamp: DateTime.now(),
          metadata: metadata,
        ),
      );
      _batchBuffer[repeaterId] = buffer;
      wasKept = true; // New repeater, observation is kept
      debugLog('[RX BATCH] First observation for repeater $repeaterId: SNR=$snr');

      // Start 30-second timeout timer for this repeater
      buffer.timeoutTimer = Timer(batchTimeout, () {
        debugLog('[RX BATCH] 30s timeout triggered for repeater $repeaterId');
        _flushRepeater(repeaterId);
      });
      debugLog('[RX BATCH] Started 30s timeout timer for repeater $repeaterId');
    } else {
      // Already tracking this repeater - check if new SNR is better
      // Null SNR never replaces non-null; non-null always replaces null
      final existingSnr = buffer.bestObservation.snr;
      final shouldUpdate = snr != null && existingSnr != null
          ? snr > existingSnr
          : snr != null && existingSnr == null;
      if (shouldUpdate) {
        debugLog('[RX BATCH] Better SNR for repeater $repeaterId: '
            '$existingSnr -> $snr');
        // IMPORTANT: Keep the FIRST location where we heard this repeater,
        // only update the SNR/RSSI/metadata. This ensures the map pin stays
        // at the original location and doesn't follow the user.
        buffer.bestObservation = RxObservation(
          repeaterId: repeaterId,
          snr: snr,
          rssi: rssi,
          pathLength: pathLength,
          header: header,
          lat: buffer.firstLocation.lat,  // Keep original location
          lon: buffer.firstLocation.lon,  // Keep original location
          timestamp: DateTime.now(),
          metadata: metadata,
        );
        wasKept = true; // Better SNR, observation is kept
      } else {
        debugLog('[RX BATCH] Ignoring worse SNR for repeater $repeaterId: '
            'current=${buffer.bestObservation.snr}, new=$snr');
        wasKept = false; // Worse SNR, observation is ignored
      }
    }

    // Check distance trigger (25m from firstLocation)
    final distance = _calculateHaversineDistance(
      currentLocation.lat,
      currentLocation.lon,
      buffer.firstLocation.lat,
      buffer.firstLocation.lon,
    );

    debugLog('[RX BATCH] Distance check for repeater $repeaterId: '
        '${distance.toStringAsFixed(2)}m from first observation '
        '(threshold=${batchDistanceMeters}m)');

    if (distance >= batchDistanceMeters) {
      debugLog('[RX BATCH] Distance threshold met for repeater $repeaterId, flushing');
      await _flushRepeater(repeaterId);
    }

    return wasKept;
  }

  /// Check all active RX batches for distance threshold on GPS position update
  /// Called from GPS service when position changes
  Future<void> checkDistanceTriggers(({double lat, double lon}) currentLocation) async {
    if (_batchBuffer.isEmpty) {
      return; // No active batches to check
    }

    debugLog('[RX BATCH] Checking ${_batchBuffer.length} active batch(es) for distance trigger');
    
    final repeatersToFlush = <String>[];
    
    // Check each active batch
    for (final entry in _batchBuffer.entries) {
      final repeaterId = entry.key;
      final buffer = entry.value;
      
      final distance = _calculateHaversineDistance(
        currentLocation.lat,
        currentLocation.lon,
        buffer.firstLocation.lat,
        buffer.firstLocation.lon,
      );
      
      debugLog('[RX BATCH] Distance check for repeater $repeaterId: '
          '${distance.toStringAsFixed(2)}m from first observation '
          '(threshold=${batchDistanceMeters}m)');
      
      if (distance >= batchDistanceMeters) {
        debugLog('[RX BATCH] Distance threshold met for repeater $repeaterId, '
            'marking for flush');
        repeatersToFlush.add(repeaterId);
      }
    }
    
    // Flush all repeaters that met the distance threshold
    for (final repeaterId in repeatersToFlush) {
      await _flushRepeater(repeaterId);
    }
    
    if (repeatersToFlush.isNotEmpty) {
      debugLog('[RX BATCH] Flushed ${repeatersToFlush.length} repeater(s) '
          'due to GPS movement');
    }
  }

  /// Flush a single repeater's batch - post best observation to API
  Future<void> _flushRepeater(String repeaterId) async {
    debugLog('[RX BATCH] Flushing repeater $repeaterId');
    
    final buffer = _batchBuffer[repeaterId];
    if (buffer == null) {
      debugLog('[RX BATCH] No buffer to flush for repeater $repeaterId');
      return;
    }
    
    // Clear timeout timer if it exists
    buffer.timeoutTimer?.cancel();
    buffer.timeoutTimer = null;
    debugLog('[RX BATCH] Cleared timeout timer for repeater $repeaterId');
    
    final best = buffer.bestObservation;
    
    // Build API entry using BEST observation's location
    final entry = RxApiEntry(
      repeaterId: repeaterId,
      lat: best.lat,
      lon: best.lon,
      snr: best.snr,
      rssi: best.rssi,
      pathLength: best.pathLength,
      header: best.header,
      timestamp: best.timestamp,
      metadata: best.metadata,
    );
    
    debugLog('[RX BATCH] Posting repeater $repeaterId: snr=${best.snr}, '
        'location=${best.lat.toStringAsFixed(5)},${best.lon.toStringAsFixed(5)}');
    
    // Queue for API posting
    await onRxEntry(entry);
    
    // Remove from buffer
    _batchBuffer.remove(repeaterId);
    debugLog('[RX BATCH] Repeater $repeaterId removed from buffer');
  }

  /// Flush all active batches (called on session end, disconnect, etc.)
  Future<void> flushAllBatches({String trigger = 'session_end'}) async {
    debugLog('[RX BATCH] Flushing all repeaters, trigger=$trigger, '
        'active_repeaters=${_batchBuffer.length}');
    
    if (_batchBuffer.isEmpty) {
      debugLog('[RX BATCH] No repeaters to flush');
      return;
    }
    
    // Iterate all repeaters and flush each one
    final repeaterIds = _batchBuffer.keys.toList();
    for (final repeaterId in repeaterIds) {
      await _flushRepeater(repeaterId);
    }
    
    debugLog('[RX BATCH] All repeaters flushed: ${repeaterIds.length} total');
  }

  /// Calculate haversine distance between two GPS coordinates
  /// Returns distance in meters
  double _calculateHaversineDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusM = 6371000.0;
    
    final dLat = _degreesToRadians(lat2 - lat1);
    final dLon = _degreesToRadians(lon2 - lon1);
    
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_degreesToRadians(lat1)) *
            cos(_degreesToRadians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    
    return earthRadiusM * c;
  }

  double _degreesToRadians(double degrees) {
    return degrees * pi / 180.0;
  }

  /// Get current batch buffer stats
  Map<String, dynamic> getStats() {
    return {
      'activeRepeaters': _batchBuffer.length,
      'repeaterIds': _batchBuffer.keys.toList(),
    };
  }

  /// Dispose of resources
  void dispose() {
    debugLog('[RX LOG] Disposing RX Logger');
    
    // Cancel all timeout timers
    for (final buffer in _batchBuffer.values) {
      buffer.timeoutTimer?.cancel();
    }
    
    _batchBuffer.clear();
    isWardriving = false;
  }
}

/// Batch buffer for a single repeater
class RxBatch {
  final ({double lat, double lon}) firstLocation;
  RxObservation bestObservation;
  Timer? timeoutTimer;

  RxBatch({
    required this.firstLocation,
    required this.bestObservation,
    this.timeoutTimer,
  });
}

/// Single RX observation
class RxObservation {
  final String repeaterId; // Hex ID of the repeater
  final double? snr;       // Null for CARpeater pass-through
  final int? rssi;         // Null for CARpeater pass-through
  final int pathLength;
  final int header;
  final double lat;
  final double lon;
  final DateTime timestamp;
  final PacketMetadata metadata;

  RxObservation({
    required this.repeaterId,
    this.snr,
    this.rssi,
    required this.pathLength,
    required this.header,
    required this.lat,
    required this.lon,
    required this.timestamp,
    required this.metadata,
  });
}

/// API entry for RX observation
class RxApiEntry {
  final String repeaterId;
  final double lat;
  final double lon;
  final double? snr;   // Null for CARpeater pass-through
  final int? rssi;     // Null for CARpeater pass-through
  final int pathLength;
  final int header;
  final DateTime timestamp;
  final PacketMetadata metadata;

  RxApiEntry({
    required this.repeaterId,
    required this.lat,
    required this.lon,
    this.snr,
    this.rssi,
    required this.pathLength,
    required this.header,
    required this.timestamp,
    required this.metadata,
  });
}
