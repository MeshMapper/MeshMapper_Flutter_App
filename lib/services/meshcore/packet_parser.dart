import 'dart:typed_data';

import 'buffer_utils.dart';
import 'protocol_constants.dart';

/// MeshCore packet parser
/// Ported from content/mc/packet.js in WebClient repo
class Packet {
  final int header;
  final Uint8List path;
  final Uint8List payload;

  // Parsed info (cached)
  late final int routeType;
  late final String? routeTypeString;
  late final int payloadType;
  late final String? payloadTypeString;
  late final int payloadVersion;
  late final bool isMarkedDoNotRetransmit;

  Packet({
    required this.header,
    required this.path,
    required this.payload,
  }) {
    routeType = _getRouteType();
    routeTypeString = _getRouteTypeString();
    payloadType = _getPayloadType();
    payloadTypeString = _getPayloadTypeString();
    payloadVersion = _getPayloadVer();
    isMarkedDoNotRetransmit = header == 0xFF;
  }

  /// Parse packet from raw bytes
  factory Packet.fromBytes(List<int> bytes) {
    final reader = BufferReader(bytes);
    final header = reader.readByte();
    final pathLen = reader.readInt8();
    final path = reader.readBytes(pathLen.clamp(0, reader.remainingBytesCount));
    final payload = reader.readRemainingBytes();
    return Packet(header: header, path: path, payload: payload);
  }

  int _getRouteType() {
    return header & PacketHeader.routeMask;
  }

  String? _getRouteTypeString() {
    switch (routeType) {
      case RouteType.flood:
        return 'FLOOD';
      case RouteType.direct:
        return 'DIRECT';
      default:
        return null;
    }
  }

  bool get isRouteFlood => routeType == RouteType.flood;
  bool get isRouteDirect => routeType == RouteType.direct;

  int _getPayloadType() {
    return (header >> PacketHeader.typeShift) & PacketHeader.typeMask;
  }

  String? _getPayloadTypeString() {
    switch (payloadType) {
      case PayloadType.req:
        return 'REQ';
      case PayloadType.response:
        return 'RESPONSE';
      case PayloadType.txtMsg:
        return 'TXT_MSG';
      case PayloadType.ack:
        return 'ACK';
      case PayloadType.advert:
        return 'ADVERT';
      case PayloadType.grpTxt:
        return 'GRP_TXT';
      case PayloadType.grpData:
        return 'GRP_DATA';
      case PayloadType.anonReq:
        return 'ANON_REQ';
      case PayloadType.path:
        return 'PATH';
      case PayloadType.trace:
        return 'TRACE';
      case PayloadType.rawCustom:
        return 'RAW_CUSTOM';
      default:
        return null;
    }
  }

  int _getPayloadVer() {
    return (header >> PacketHeader.verShift) & PacketHeader.verMask;
  }

  /// Parse payload based on type
  Map<String, dynamic>? parsePayload() {
    switch (payloadType) {
      case PayloadType.path:
        return _parsePayloadTypePath();
      case PayloadType.req:
        return _parsePayloadTypeReq();
      case PayloadType.response:
        return _parsePayloadTypeResponse();
      case PayloadType.txtMsg:
        return _parsePayloadTypeTxtMsg();
      case PayloadType.ack:
        return _parsePayloadTypeAck();
      case PayloadType.advert:
        return _parsePayloadTypeAdvert();
      case PayloadType.anonReq:
        return _parsePayloadTypeAnonReq();
      default:
        return null;
    }
  }

  Map<String, dynamic> _parsePayloadTypePath() {
    final reader = BufferReader(payload);
    return {
      'dest': reader.readByte(),
      'src': reader.readByte(),
    };
  }

  Map<String, dynamic> _parsePayloadTypeReq() {
    final reader = BufferReader(payload);
    return {
      'dest': reader.readByte(),
      'src': reader.readByte(),
      'encrypted': reader.readRemainingBytes(),
    };
  }

  Map<String, dynamic> _parsePayloadTypeResponse() {
    final reader = BufferReader(payload);
    return {
      'dest': reader.readByte(),
      'src': reader.readByte(),
    };
  }

  Map<String, dynamic> _parsePayloadTypeTxtMsg() {
    final reader = BufferReader(payload);
    return {
      'dest': reader.readByte(),
      'src': reader.readByte(),
    };
  }

  Map<String, dynamic> _parsePayloadTypeAck() {
    return {
      'ack_code': payload,
    };
  }

  Map<String, dynamic> _parsePayloadTypeAdvert() {
    final reader = BufferReader(payload);
    return {
      'public_key': reader.readBytes(32),
      'timestamp': reader.hasMoreBytes ? reader.readUInt32LE() : 0,
    };
  }

  Map<String, dynamic> _parsePayloadTypeAnonReq() {
    final reader = BufferReader(payload);
    return {
      'dest': reader.readByte(),
      'src_public_key': reader.readBytes(32),
    };
  }

  @override
  String toString() {
    return 'Packet(type=$payloadTypeString, route=$routeTypeString, ver=$payloadVersion, pathLen=${path.length}, payloadLen=${payload.length})';
  }
}

/// Parsed channel message received from device
class ChannelMessage {
  final int channelIndex;
  final int senderTimestamp;
  final double snr;
  final int rssi;
  final String text;

  const ChannelMessage({
    required this.channelIndex,
    required this.senderTimestamp,
    required this.snr,
    required this.rssi,
    required this.text,
  });

  /// Check if this is a repeater echo (wardriving RX)
  /// Format: {MESHTASTIC:[repeater_id]}
  bool get isRepeaterEcho {
    return text.startsWith('{MESHTASTIC:') && text.endsWith('}');
  }

  /// Extract repeater ID from echo message
  String? get repeaterId {
    if (!isRepeaterEcho) return null;
    final start = text.indexOf(':') + 1;
    final end = text.lastIndexOf('}');
    if (start > 0 && end > start) {
      return text.substring(start, end);
    }
    return null;
  }
}

/// Device info response
class DeviceInfo {
  final int protocolVersion;
  final String manufacturer;
  final Uint8List publicKey;
  final int timestamp;

  const DeviceInfo({
    required this.protocolVersion,
    required this.manufacturer,
    required this.publicKey,
    required this.timestamp,
  });

  factory DeviceInfo.fromReader(BufferReader reader) {
    return DeviceInfo(
      protocolVersion: reader.readByte(),
      manufacturer: reader.readCString(64),
      publicKey: reader.readBytes(32),
      timestamp: reader.hasMoreBytes ? reader.readUInt32LE() : 0,
    );
  }
}

/// Channel info response
class ChannelInfo {
  final int channelIndex;
  final String name;
  final Uint8List secret;

  const ChannelInfo({
    required this.channelIndex,
    required this.name,
    required this.secret,
  });

  factory ChannelInfo.fromReader(BufferReader reader) {
    return ChannelInfo(
      channelIndex: reader.readByte(),
      name: reader.readCString(32),
      secret: reader.readBytes(32),
    );
  }
}
