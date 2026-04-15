import 'dart:typed_data';

import '../../utils/debug_logger_io.dart';
import 'protocol_constants.dart';

/// Packet metadata extracted from BLE LogRxData events
/// Reference: parseRxPacketMetadata() in wardrive.js (lines 3155-3195)
class PacketMetadata {
  /// Original raw packet bytes
  final Uint8List raw;

  /// Packet header byte (contains route type, payload type, version)
  final int header;

  /// Route type (FLOOD=0x01, DIRECT=0x02)
  final int routeType;

  /// Raw pathLen byte (encodes both hash size and hop count)
  final int pathLenRaw;

  /// Number of bytes per hop hash (1, 2, 3, or 4)
  final int pathHashSize;

  /// Number of hops in path (0-63)
  final int pathHashCount;

  /// Raw path bytes (repeater IDs, length = pathHashCount * pathHashSize)
  final Uint8List pathBytes;

  /// Signal-to-noise ratio (dB)
  final double snr;

  /// Received signal strength indicator (dBm)
  final int rssi;

  /// Encrypted payload (after header + path)
  final Uint8List encryptedPayload;

  PacketMetadata({
    required this.raw,
    required this.header,
    required this.routeType,
    required this.pathLenRaw,
    required this.pathHashSize,
    required this.pathHashCount,
    required this.pathBytes,
    required this.snr,
    required this.rssi,
    required this.encryptedPayload,
  });

  /// Parse packet metadata from BLE LogRxData event
  ///
  /// Event structure:
  /// ```dart
  /// {
  ///   'lastSnr': 11.5,      // double
  ///   'lastRssi': -85,      // int
  ///   'raw': Uint8List(...)  // packet bytes
  /// }
  /// ```
  factory PacketMetadata.fromLogRxData(Map<String, dynamic> data) {
    debugLog('[RX PARSE] Starting metadata parsing');

    final Uint8List raw = data['raw'] as Uint8List;
    final double snr = (data['lastSnr'] as num).toDouble();
    final int rssi = data['lastRssi'] as int;

    // Dump raw packet for debugging
    final rawHex = raw
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
    debugLog('[RX PARSE] RAW Packet (${raw.length} bytes): $rawHex');

    // Extract header byte from raw[0]
    final int header = raw[0];
    final int routeType = header & PacketHeader.routeMask;

    debugLog(
        '[RX PARSE] Header: 0x${header.toRadixString(16).padLeft(2, '0')}, Route type: $routeType');

    // Calculate offset for Path Length based on route type
    // Reference: wardrive.js lines 3168-3173
    int pathLengthOffset = 1;
    if (routeType == RouteType.reserved1 || routeType == RouteType.reserved2) {
      // TransportFlood or TransportDirect - has 4-byte transport codes
      pathLengthOffset = 5;
    }

    // Extract raw pathLen byte and decode multi-byte path encoding
    // pathHashSize = (pathLen >> 6) + 1  → 1, 2, 3, or 4
    // pathHashCount = pathLen & 63       → 0-63 hops
    final int pathLenRaw = raw[pathLengthOffset];
    final int pathHashSize = (pathLenRaw >> 6) + 1;
    final int pathHashCount = pathLenRaw & 63;
    final int pathByteLen = pathHashCount * pathHashSize;

    debugLog(
        '[RX PARSE] Path length offset: $pathLengthOffset, pathLenRaw: 0x${pathLenRaw.toRadixString(16).padLeft(2, '0')}, '
        'pathHashSize: $pathHashSize bytes/hop, pathHashCount: $pathHashCount hops, pathByteLen: $pathByteLen');

    // Path data starts after path length byte
    final int pathDataOffset = pathLengthOffset + 1;
    final Uint8List pathBytes = raw.sublist(
      pathDataOffset,
      (pathDataOffset + pathByteLen).clamp(0, raw.length),
    );

    // Extract encrypted payload after path data
    final int payloadOffset = pathDataOffset + pathByteLen;
    if (payloadOffset > raw.length) {
      throw RangeError(
          'Packet too short: payload offset $payloadOffset exceeds packet length ${raw.length}');
    }
    final Uint8List encryptedPayload = raw.sublist(payloadOffset);

    debugLog(
        '[RX PARSE] Parsed metadata: header=0x${header.toRadixString(16).padLeft(2, '0')}, '
        'pathHashSize=$pathHashSize, pathHashCount=$pathHashCount, '
        'firstHop=${pathHashCount > 0 ? _bytesToHexStatic(pathBytes.sublist(0, pathHashSize)) : 'null'}, '
        'lastHop=${pathHashCount > 0 ? _bytesToHexStatic(pathBytes.sublist(pathBytes.length - pathHashSize)) : 'null'}, '
        'SNR=$snr, RSSI=$rssi, '
        'payload=${encryptedPayload.length} bytes');

    return PacketMetadata(
      raw: raw,
      header: header,
      routeType: routeType,
      pathLenRaw: pathLenRaw,
      pathHashSize: pathHashSize,
      pathHashCount: pathHashCount,
      pathBytes: pathBytes,
      snr: snr,
      rssi: rssi,
      encryptedPayload: encryptedPayload,
    );
  }

  /// Parse packet metadata from raw packet bytes with SNR/RSSI
  /// Used by UnifiedRxHandler when receiving LogRxData stream
  factory PacketMetadata.fromRawPacket({
    required Uint8List raw,
    required double snr,
    required int rssi,
  }) {
    // Reuse the LogRxData factory by wrapping in map structure
    return PacketMetadata.fromLogRxData({
      'raw': raw,
      'lastSnr': snr,
      'lastRssi': rssi,
    });
  }

  /// Get channel hash from encrypted payload (first byte)
  /// Channel message structure: [1 byte channel_hash][2 bytes MAC][encrypted message]
  int? get channelHash {
    if (encryptedPayload.isEmpty) return null;
    return encryptedPayload[0];
  }

  /// Check if packet is GROUP_TEXT (channel message, header 0x15)
  bool get isGroupText {
    // Extract payload type from header
    final payloadType =
        (header >> PacketHeader.typeShift) & PacketHeader.typeMask;
    return payloadType == PayloadType.grpTxt;
  }

  /// Check if packet is ADVERT (node advertisement, header 0x11)
  bool get isAdvert {
    final payloadType =
        (header >> PacketHeader.typeShift) & PacketHeader.typeMask;
    return payloadType == PayloadType.advert;
  }

  /// Check if packet is TRACE (trace path response, header 0x26)
  bool get isTrace {
    final payloadType =
        (header >> PacketHeader.typeShift) & PacketHeader.typeMask;
    return payloadType == PayloadType.trace;
  }

  /// Get first hop as hex string (for TX tracking keys)
  /// Returns multi-byte hex (2/4/6/8 chars depending on pathHashSize)
  String? get firstHopHex {
    if (pathHashCount == 0) return null;
    return _bytesToHex(pathBytes.sublist(0, pathHashSize));
  }

  /// Get last hop as hex string (for RX logging keys)
  /// Returns multi-byte hex (2/4/6/8 chars depending on pathHashSize)
  String? get lastHopHex {
    if (pathHashCount == 0) return null;
    return _bytesToHex(pathBytes.sublist(pathBytes.length - pathHashSize));
  }

  /// Get any hop by index as hex string
  /// @param hopIndex 0-based hop index (0 = first hop)
  String? getHopHex(int hopIndex) {
    if (hopIndex < 0 || hopIndex >= pathHashCount) return null;
    final offset = hopIndex * pathHashSize;
    return _bytesToHex(pathBytes.sublist(offset, offset + pathHashSize));
  }

  /// Convert N bytes to uppercase hex string
  String _bytesToHex(Uint8List bytes) {
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join('')
        .toUpperCase();
  }

  /// Static version for use in factory constructor
  static String _bytesToHexStatic(Uint8List bytes) {
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join('')
        .toUpperCase();
  }

  @override
  String toString() {
    return 'PacketMetadata(header=0x${header.toRadixString(16).padLeft(2, '0')}, '
        'pathHashSize=$pathHashSize, pathHashCount=$pathHashCount, '
        'firstHop=$firstHopHex, lastHop=$lastHopHex, '
        'SNR=$snr, RSSI=$rssi)';
  }
}
