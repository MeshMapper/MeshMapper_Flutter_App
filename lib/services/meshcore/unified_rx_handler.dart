import 'dart:typed_data';

import '../../utils/debug_logger_io.dart';
import 'packet_metadata.dart';
import 'packet_validator.dart';
import 'rx_logger.dart';
import 'trace_tracker.dart';
import 'tx_tracker.dart';

/// Unified RX handler - orchestrates TX echo tracking and passive RX logging
/// Reference: handleUnifiedRxLogEvent() in wardrive.js (lines 3772-3810)
class UnifiedRxHandler {
  bool isListening = false;

  final TxTracker txTracker;
  final RxLogger rxLogger;
  PacketValidator _validator;

  /// Get current validator
  PacketValidator get validator => _validator;

  /// Trace tracker for targeted ping mode (set by PingService when active)
  TraceTracker? traceTracker;

  /// Channel key for message decryption (injected for TX validation)
  Uint8List? channelKey;

  UnifiedRxHandler({
    required this.txTracker,
    required this.rxLogger,
    required PacketValidator validator,
  }) : _validator = validator;

  /// Update validator with new channel configuration
  /// Called when regional channels change (after auth)
  void updateValidator(PacketValidator newValidator) {
    _validator = newValidator;
    debugLog('[UNIFIED RX] Validator updated with new channel configuration');
  }

  /// Start unified RX listening
  void startListening() {
    if (isListening) return;
    
    debugLog('[UNIFIED RX] Starting unified RX listening');
    isListening = true;
    debugLog('[UNIFIED RX] ✅ Unified listening started successfully');
  }

  /// Stop unified RX listening
  void stopListening() {
    if (!isListening) return;
    
    debugLog('[UNIFIED RX] Stopping unified RX listening');
    isListening = false;
    debugLog('[UNIFIED RX] ✅ Unified listening stopped');
  }

  /// Handle incoming LogRxData packet
  /// Routes to TX tracker (if active) then RX logger (if active)
  Future<void> handlePacket(Uint8List rawPacket, double snr, int rssi) async {
    try {
      // Defensive check: ensure listener is marked as active
      if (!isListening) {
        debugWarn('[UNIFIED RX] Received event but listener marked inactive - reactivating');
        isListening = true;
      }
      
      // Parse metadata ONCE
      final metadata = PacketMetadata.fromRawPacket(
        raw: rawPacket,
        snr: snr,
        rssi: rssi,
      );
      
      debugLog('[UNIFIED RX] Packet received: '
          'header=0x${metadata.header.toRadixString(16)}, '
          'pathHashSize=${metadata.pathHashSize}, pathHashCount=${metadata.pathHashCount}');

      // Store BLE metadata from 0x88 LogRxData for trace packets.
      // The actual trace payload arrives separately via 0x89 TraceData stream.
      // We only store RSSI/SNR here — the 0x89 handler combines them.
      if (metadata.isTrace) {
        final tt = traceTracker;
        if (tt != null && tt.isListening) {
          debugLog('[UNIFIED RX] Trace packet in 0x88 - storing BLE metadata for 0x89 handler');
          tt.pendingBleSnr = metadata.snr;
          tt.pendingBleRssi = metadata.rssi;
        }
        return; // Trace packets don't go to TX tracker or RX logger
      }

      // Route to TX tracking if active (during 5s echo window)
      if (txTracker.isListening) {
        debugLog('[UNIFIED RX] TX tracking active - checking for echo');
        final wasEcho = await txTracker.handlePacket(metadata);
        if (wasEcho) {
          debugLog('[UNIFIED RX] Packet was TX echo, done');
          return;
        }
      }
      
      // Route to RX wardriving if active
      if (rxLogger.isWardriving) {
        debugLog('[UNIFIED RX] RX wardriving active - logging observation');
        await rxLogger.handlePacket(metadata, validator);
      }
      
      // If neither active, packet is received but ignored
      // Listener stays on, just not processing for wardriving
      
    } catch (error, stackTrace) {
      debugError('[UNIFIED RX] Error processing rx_log entry: $error');
      debugError('[UNIFIED RX] Stack trace: $stackTrace');
    }
  }

  /// Get current state summary
  Map<String, dynamic> getStats() {
    return {
      'isListening': isListening,
      'txTracking': {
        'isListening': txTracker.isListening,
        'repeatersHeard': txTracker.repeaters.length,
      },
      'rxLogging': {
        'isWardriving': rxLogger.isWardriving,
        'activeRepeaters': rxLogger.getStats()['activeRepeaters'],
      },
    };
  }

  /// Dispose of resources
  void dispose() {
    debugLog('[UNIFIED RX] Disposing unified handler');
    stopListening();
    txTracker.dispose();
    rxLogger.dispose();
  }
}
