import 'dart:async';
import 'dart:typed_data';

import '../../utils/debug_logger_io.dart';

/// Framing codec for TCP and USB Serial MeshCore companion connections.
///
/// TCP and Serial use identical byte-stream framing:
/// - Outgoing (app→device): [0x3C][len_lo][len_hi][payload]
/// - Incoming (device→app): [0x3E][len_lo][len_hi][payload]
///
/// BLE does NOT use this codec — GATT provides message boundaries natively.
class StreamFrameCodec {
  static const int outgoingMarker = 0x3C; // '<'
  static const int incomingMarker = 0x3E; // '>'
  static const int headerSize = 3;
  static const int maxTxPayload = 172; // firmware MAX_FRAME_SIZE
  static const int maxRxPayload = 300; // defensive limit (matches meshcore_py)

  final _frameController = StreamController<Uint8List>.broadcast();
  final _buffer = BytesBuilder(copy: true);

  Stream<Uint8List> get frames => _frameController.stream;

  /// Encode an outgoing payload with the frame header.
  static Uint8List encode(Uint8List payload) {
    assert(payload.length <= maxTxPayload,
        'Payload exceeds max TX size: ${payload.length} > $maxTxPayload');
    final frame = Uint8List(payload.length + headerSize);
    frame[0] = outgoingMarker;
    frame[1] = payload.length & 0xFF;
    frame[2] = (payload.length >> 8) & 0xFF;
    frame.setRange(headerSize, frame.length, payload);
    return frame;
  }

  /// Feed incoming raw bytes for frame reassembly.
  ///
  /// Handles: junk byte discard, partial headers across chunks,
  /// multiple frames in one chunk, zero-length and oversized frame rejection.
  void addBytes(Uint8List data) {
    if (data.isEmpty) return;
    _buffer.add(data);
    _processBuffer();
  }

  void _processBuffer() {
    while (true) {
      final bytes = _buffer.toBytes();
      if (bytes.length < headerSize) return;

      // Scan for incoming marker, discarding junk bytes before it
      int markerIndex = -1;
      for (int i = 0; i < bytes.length; i++) {
        if (bytes[i] == incomingMarker) {
          markerIndex = i;
          break;
        }
      }

      if (markerIndex == -1) {
        // No marker found — discard all bytes
        _buffer.clear();
        return;
      }

      if (markerIndex > 0) {
        // Discard junk bytes before marker
        _replaceBuffer(bytes.sublist(markerIndex));
        continue;
      }

      // Marker is at position 0 — check if we have the full header
      if (bytes.length < headerSize) return;

      final payloadLength = bytes[1] | (bytes[2] << 8);

      // Zero-length frame — skip the marker byte and rescan
      if (payloadLength == 0) {
        _replaceBuffer(bytes.sublist(1));
        continue;
      }

      // Oversized frame — treat marker as junk, skip it and rescan
      if (payloadLength > maxRxPayload) {
        debugWarn(
            '[CODEC] Oversized frame ($payloadLength bytes), skipping marker');
        _replaceBuffer(bytes.sublist(1));
        continue;
      }

      final totalFrameSize = headerSize + payloadLength;

      // Not enough data yet for the full frame — wait for more
      if (bytes.length < totalFrameSize) return;

      // Extract the payload (strip header)
      final payload = Uint8List.fromList(
          bytes.sublist(headerSize, totalFrameSize));

      // Remove consumed bytes, keep remainder
      if (bytes.length > totalFrameSize) {
        _replaceBuffer(bytes.sublist(totalFrameSize));
      } else {
        _buffer.clear();
      }

      // Emit the complete frame
      if (!_frameController.isClosed) {
        _frameController.add(payload);
      }
    }
  }

  void _replaceBuffer(List<int> remaining) {
    _buffer.clear();
    _buffer.add(remaining);
  }

  void reset() {
    _buffer.clear();
  }

  void dispose() {
    _buffer.clear();
    _frameController.close();
  }
}
