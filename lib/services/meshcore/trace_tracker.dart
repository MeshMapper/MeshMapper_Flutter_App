import 'dart:async';
import 'dart:typed_data';

import '../../utils/debug_logger_io.dart';

/// Result of a trace path probe to a specific repeater
class TraceResult {
  final String targetRepeaterId;
  final double localSnr; // SNR we measured on the return (path_snrs[1] / 4.0)
  final int localRssi; // RSSI from BLE event metadata
  final double remoteSnr; // SNR the repeater measured (path_snrs[0] / 4.0)
  final bool success;

  const TraceResult({
    required this.targetRepeaterId,
    required this.localSnr,
    required this.localRssi,
    required this.remoteSnr,
    required this.success,
  });
}

/// Trace path tracker for targeted ping (zero-hop trace)
/// Sends CMD_SEND_TRACE_PATH (0x24) to a specific repeater and listens
/// for the trace response (PUSH_CODE_TRACE_DATA, 0x89).
///
/// Follows the DiscTracker pattern but simpler: expects exactly 1 response.
class TraceTracker {
  bool isListening = false;
  Uint8List? _expectedTag;
  String _targetRepeaterId = '';
  TraceResult? _result;
  Timer? _windowTimer;

  /// BLE metadata from the 0x88 LogRxData event that arrives before the 0x89 TraceData.
  /// Set by UnifiedRxHandler when it sees a trace packet in the LogRxData stream.
  double pendingBleSnr = 0.0;
  int pendingBleRssi = 0;

  /// Fired when a trace response is received during the window
  void Function(TraceResult)? onTraceReceived;

  /// Fired when the listening window ends (result is null if no response)
  void Function(TraceResult?)? onWindowComplete;

  TraceTracker();

  /// Start tracking trace responses
  void startTracking({
    required Uint8List tag,
    required String targetRepeaterId,
    Duration windowDuration = const Duration(seconds: 7),
  }) {
    debugLog('[TRACE] Starting trace tracking for repeater $targetRepeaterId');
    debugLog(
        '[TRACE] Tag: ${tag.map((b) => b.toRadixString(16).padLeft(2, '0')).join('')}');

    isListening = true;
    _expectedTag = tag;
    _targetRepeaterId = targetRepeaterId;
    _result = null;
    pendingBleSnr = 0.0;
    pendingBleRssi = 0;

    // Start window timer
    _windowTimer?.cancel();
    _windowTimer = Timer(windowDuration, _endWindow);

    debugLog(
        '[TRACE] Trace tracking window started (${windowDuration.inSeconds}s)');
  }

  /// Handle incoming trace data packet (0x89)
  /// Returns true if the packet was a valid trace response
  ///
  /// Trace response format (per meshcore_py reference):
  /// Byte 0: reserved (skip)
  /// Byte 1: path_len (raw byte count of path hashes, NOT LogRxData encoding)
  /// Byte 2: flags → hashSize = 1 << (flags & 3)
  /// Bytes 3-6: tag → match against _expectedTag
  /// Bytes 7-10: auth_code (skip)
  /// Bytes 11 to 11+path_len: path_hashes → extract repeater ID
  /// Next hopCount+1 bytes: path_snrs → each is signedInt8 / 4.0 for dB
  /// For zero-hop (hopCount=1): remoteSnr = snrs[0], localSnr = snrs[1]
  bool handlePacket(Uint8List rawBytes, double bleSnr, int bleRssi) {
    if (!isListening) return false;

    try {
      // Minimum: 1 (reserved) + 1 (path_len) + 1 (flags) + 4 (tag) + 4 (auth) = 11 bytes
      if (rawBytes.length < 11) {
        debugLog(
            '[TRACE] Packet too short: ${rawBytes.length} bytes (need at least 11)');
        return false;
      }

      // Skip byte 0 (reserved)
      final pathLen = rawBytes[1]; // Raw byte count of path hashes
      final flags = rawBytes[2];

      // Decode per 0x89 trace format (meshcore_py reference):
      // hash size from flags, hop count from path_len / hash_size
      final hashSize = 1 << (flags & 3); // 1, 2, 4, or 8 bytes per hop
      final hopCount = hashSize > 0 ? pathLen ~/ hashSize : 0;

      debugLog(
          '[TRACE] pathLen=0x${pathLen.toRadixString(16)}, hashSize=$hashSize, hopCount=$hopCount');

      // Extract tag (bytes 3-6)
      final tag = rawBytes.sublist(3, 7);

      // Match tag against expected
      final expectedTag = _expectedTag;
      if (expectedTag != null) {
        bool tagMatch = true;
        for (int i = 0; i < 4; i++) {
          if (tag[i] != expectedTag[i]) {
            tagMatch = false;
            break;
          }
        }
        if (!tagMatch) {
          debugLog('[TRACE] Tag mismatch, ignoring packet');
          return false;
        }
      }

      // Skip auth_code (bytes 7-10)

      // Extract path hashes (bytes 11 to 11 + hopCount*hashSize)
      const pathStart = 11;
      final pathEnd = pathStart + (hopCount * hashSize);

      if (rawBytes.length < pathEnd) {
        debugLog(
            '[TRACE] Packet too short for path hashes: need $pathEnd, have ${rawBytes.length}');
        return false;
      }

      // Extract repeater ID from first hop in path
      String repeaterId = '';
      if (hopCount > 0) {
        final idBytes = rawBytes.sublist(pathStart, pathStart + hashSize);
        repeaterId = idBytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join('')
            .toUpperCase();
      }

      // Extract path SNRs (hopCount+1 bytes after path hashes)
      final snrStart = pathEnd;
      final snrEnd = snrStart + hopCount + 1;

      double remoteSnr = 0.0;
      double localSnr = bleSnr; // Default to BLE metadata SNR

      if (rawBytes.length >= snrEnd && hopCount >= 1) {
        // Each SNR byte is signed int8, divide by 4.0 for dB
        remoteSnr = rawBytes[snrStart].toSigned(8) / 4.0;
        if (hopCount + 1 >= 2) {
          localSnr = rawBytes[snrStart + 1].toSigned(8) / 4.0;
        }
      }

      debugLog('[TRACE] Trace response from $repeaterId: '
          'localSnr=${localSnr.toStringAsFixed(2)}, '
          'remoteSnr=${remoteSnr.toStringAsFixed(2)}, '
          'bleRssi=$bleRssi');

      _result = TraceResult(
        targetRepeaterId: _targetRepeaterId,
        localSnr: localSnr,
        localRssi: bleRssi,
        remoteSnr: remoteSnr,
        success: true,
      );

      // Notify callback
      onTraceReceived?.call(_result!);

      return true;
    } catch (e, stackTrace) {
      debugError('[TRACE] Error processing trace response: $e');
      debugError('[TRACE] Stack trace: $stackTrace');
      return false;
    }
  }

  /// Stop tracking and return result
  TraceResult? stopTracking() {
    debugLog(
        '[TRACE] Stopping trace tracking (result: ${_result != null ? 'received' : 'none'})');

    final result = _result;
    isListening = false;
    _windowTimer?.cancel();
    _windowTimer = null;
    _expectedTag = null;

    return result;
  }

  /// Handle trace window completion
  void _endWindow() {
    debugLog(
        '[TRACE] Trace window ended (result: ${_result != null ? 'success' : 'no response'})');

    final result = _result;
    isListening = false;
    _windowTimer = null;
    _expectedTag = null;
    pendingBleSnr = 0.0;
    pendingBleRssi = 0;

    onWindowComplete?.call(result);
  }

  /// Dispose of resources
  void dispose() {
    stopTracking();
  }
}
