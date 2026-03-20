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
  
  /// Number of hops in path
  final int pathLength;
  
  /// Raw path bytes (repeater IDs)
  final Uint8List pathBytes;
  
  /// First hop (first repeater ID) - used for TX tracking
  final int? firstHop;
  
  /// Last hop (last repeater ID) - used for RX logging
  final int? lastHop;
  
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
    required this.pathLength,
    required this.pathBytes,
    required this.firstHop,
    required this.lastHop,
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
    final rawHex = raw.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
    debugLog('[RX PARSE] RAW Packet (${raw.length} bytes): $rawHex');
    
    // Extract header byte from raw[0]
    final int header = raw[0];
    final int routeType = header & PacketHeader.routeMask;
    
    debugLog('[RX PARSE] Header: 0x${header.toRadixString(16).padLeft(2, '0')}, Route type: $routeType');
    
    // Calculate offset for Path Length based on route type
    // Reference: wardrive.js lines 3168-3173
    int pathLengthOffset = 1;
    if (routeType == RouteType.reserved1 || routeType == RouteType.reserved2) {
      // TransportFlood or TransportDirect - has 4-byte transport codes
      pathLengthOffset = 5;
    }
    
    // Extract path length from calculated offset
    final int pathLength = raw[pathLengthOffset];
    
    debugLog('[RX PARSE] Path length offset: $pathLengthOffset, Path length: $pathLength');
    
    // Path data starts after path length byte
    final int pathDataOffset = pathLengthOffset + 1;
    final Uint8List pathBytes = raw.sublist(
      pathDataOffset,
      (pathDataOffset + pathLength).clamp(0, raw.length),
    );
    
    // Derive first and last hops
    final int? firstHop = pathBytes.isNotEmpty ? pathBytes.first : null;
    final int? lastHop = pathBytes.isNotEmpty ? pathBytes.last : null;
    
    // Extract encrypted payload after path data
    final int payloadOffset = pathDataOffset + pathLength;
    final Uint8List encryptedPayload = raw.sublist(payloadOffset);
    
    debugLog('[RX PARSE] Parsed metadata: header=0x${header.toRadixString(16).padLeft(2, '0')}, '
        'pathLength=$pathLength, '
        'firstHop=${firstHop != null ? '0x${firstHop.toRadixString(16).padLeft(2, '0')}' : 'null'}, '
        'lastHop=${lastHop != null ? '0x${lastHop.toRadixString(16).padLeft(2, '0')}' : 'null'}, '
        'SNR=$snr, RSSI=$rssi, '
        'payload=${encryptedPayload.length} bytes');
    
    return PacketMetadata(
      raw: raw,
      header: header,
      routeType: routeType,
      pathLength: pathLength,
      pathBytes: pathBytes,
      firstHop: firstHop,
      lastHop: lastHop,
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
    final payloadType = (header >> PacketHeader.typeShift) & PacketHeader.typeMask;
    return payloadType == PayloadType.grpTxt;
  }

  /// Check if packet is ADVERT (node advertisement, header 0x11)
  bool get isAdvert {
    final payloadType = (header >> PacketHeader.typeShift) & PacketHeader.typeMask;
    return payloadType == PayloadType.advert;
  }

  /// Get first hop as hex string (for TX tracking keys)
  String? get firstHopHex {
    return firstHop?.toRadixString(16).padLeft(2, '0');
  }

  /// Get last hop as hex string (for RX logging keys)
  String? get lastHopHex {
    return lastHop?.toRadixString(16).padLeft(2, '0');
  }

  @override
  String toString() {
    return 'PacketMetadata(header=0x${header.toRadixString(16).padLeft(2, '0')}, '
        'pathLength=$pathLength, firstHop=$firstHopHex, lastHop=$lastHopHex, '
        'SNR=$snr, RSSI=$rssi)';
  }
}
