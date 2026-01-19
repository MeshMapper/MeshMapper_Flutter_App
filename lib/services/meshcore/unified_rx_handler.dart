import 'dart:typed_data';

import '../../utils/debug_logger_io.dart';
import 'packet_metadata.dart';
import 'packet_validator.dart';
import 'rx_logger.dart';
import 'tx_tracker.dart';

/// Unified RX handler - orchestrates TX echo tracking and passive RX logging
/// Reference: handleUnifiedRxLogEvent() in wardrive.js (lines 3772-3810)
class UnifiedRxHandler {
  bool isListening = false;
  
  final TxTracker txTracker;
  final RxLogger rxLogger;
  final PacketValidator validator;
  
  /// Channel key for message decryption (injected for TX validation)
  Uint8List? channelKey;

  UnifiedRxHandler({
    required this.txTracker,
    required this.rxLogger,
    required this.validator,
  });

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
          'pathLength=${metadata.pathLength}');
      
      // Route to TX tracking if active (during 7s echo window)
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
