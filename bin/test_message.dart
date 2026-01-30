/// MeshMapper Packet Validation Test Script
///
/// Usage:
///   dart run bin/test_message.dart <hex_packet> [options]
///
/// Examples:
///   dart run bin/test_message.dart "15 01 AB CD EF 12..."
///   dart run bin/test_message.dart "15 01 AB CD..." --rssi=-85 --snr=8.5
///   dart run bin/test_message.dart "15 01 AB CD..." --channel="#wardriving"
///
/// Options:
///   --rssi=<value>    RSSI in dBm (default: -85)
///   --snr=<value>     SNR in dB (default: 8.0)
///   --channel=<name>  Channel name (default: #wardriving)
///                     Supported: #wardriving, #testing, #ottawa, #wartest, Public

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

// ============================================================================
// CONSTANTS (from protocol_constants.dart)
// ============================================================================

class PacketHeader {
  static const int routeMask = 0x03; // 2-bits
  static const int typeShift = 2;
  static const int typeMask = 0x0F; // 4-bits
  static const int verShift = 6;
  static const int verMask = 0x03; // 2-bits
}

class RouteType {
  static const int reserved1 = 0x00;
  static const int flood = 0x01;
  static const int direct = 0x02;
  static const int reserved2 = 0x03;

  static String getName(int type) {
    switch (type) {
      case flood:
        return 'FLOOD';
      case direct:
        return 'DIRECT';
      case reserved1:
        return 'TRANSPORT_FLOOD';
      case reserved2:
        return 'TRANSPORT_DIRECT';
      default:
        return 'UNKNOWN';
    }
  }
}

class PayloadType {
  static const int req = 0x00;
  static const int response = 0x01;
  static const int txtMsg = 0x02;
  static const int ack = 0x03;
  static const int advert = 0x04;
  static const int grpTxt = 0x05;
  static const int grpData = 0x06;
  static const int anonReq = 0x07;
  static const int path = 0x08;
  static const int trace = 0x09;
  static const int rawCustom = 0x0F;

  static String getName(int type) {
    switch (type) {
      case req:
        return 'REQ';
      case response:
        return 'RESPONSE';
      case txtMsg:
        return 'TXT_MSG';
      case ack:
        return 'ACK';
      case advert:
        return 'ADVERT';
      case grpTxt:
        return 'GRP_TXT';
      case grpData:
        return 'GRP_DATA';
      case anonReq:
        return 'ANON_REQ';
      case path:
        return 'PATH';
      case trace:
        return 'TRACE';
      case rawCustom:
        return 'RAW_CUSTOM';
      default:
        return 'UNKNOWN';
    }
  }
}

// ============================================================================
// CRYPTO SERVICE (from crypto_service.dart)
// ============================================================================

class CryptoService {
  /// Fixed key for "Public" channel
  static final Uint8List publicChannelFixedKey = Uint8List.fromList([
    0x8b, 0x33, 0x87, 0xe9, 0xc5, 0xcd, 0xea, 0x6a,
    0xc9, 0xe5, 0xed, 0xba, 0xa1, 0x15, 0xcd, 0x72,
  ]);

  /// Derive a 16-byte channel key from a hashtag channel name using SHA-256
  static Uint8List deriveChannelKey(String channelName) {
    if (!channelName.startsWith('#')) {
      throw FormatException(
          'Channel name must start with # (got: "$channelName")');
    }

    final normalizedName = channelName.toLowerCase();
    final bytes = utf8.encode(normalizedName);
    final digest = sha256.convert(bytes);

    return Uint8List.fromList(digest.bytes.sublist(0, 16));
  }

  /// Get channel key for any channel (handles both Public and hashtag channels)
  static Uint8List getChannelKey(String channelName) {
    if (channelName == 'Public') {
      return publicChannelFixedKey;
    } else {
      return deriveChannelKey(channelName);
    }
  }

  /// Compute channel hash from channel secret (first byte of SHA-256)
  static int computeChannelHash(Uint8List channelSecret) {
    final digest = sha256.convert(channelSecret);
    return digest.bytes[0];
  }

  /// Decrypt channel message using AES-ECB mode
  static Uint8List decryptChannelMessage(
    Uint8List encryptedPayload,
    Uint8List channelKey,
  ) {
    if (channelKey.length != 16) {
      throw ArgumentError(
          'Channel key must be 16 bytes (got ${channelKey.length})');
    }

    final cipher = ECBBlockCipher(AESEngine());
    final params = KeyParameter(channelKey);
    cipher.init(false, params); // false = decrypt mode

    final decrypted = Uint8List(encryptedPayload.length);
    var offset = 0;

    while (offset < encryptedPayload.length) {
      cipher.processBlock(encryptedPayload, offset, decrypted, offset);
      offset += cipher.blockSize;
    }

    return decrypted;
  }
}

// ============================================================================
// CHANNEL INFO
// ============================================================================

class ChannelInfo {
  final String channelName;
  final Uint8List key;
  final int hash;

  const ChannelInfo({
    required this.channelName,
    required this.key,
    required this.hash,
  });
}

// ============================================================================
// PACKET METADATA (from packet_metadata.dart)
// ============================================================================

class PacketMetadata {
  final Uint8List raw;
  final int header;
  final int routeType;
  final int payloadType;
  final int protocolVersion;
  final int pathLength;
  final Uint8List pathBytes;
  final List<int> pathRepeaterIds;
  final int? firstHop;
  final int? lastHop;
  final double snr;
  final int rssi;
  final Uint8List encryptedPayload;

  PacketMetadata({
    required this.raw,
    required this.header,
    required this.routeType,
    required this.payloadType,
    required this.protocolVersion,
    required this.pathLength,
    required this.pathBytes,
    required this.pathRepeaterIds,
    required this.firstHop,
    required this.lastHop,
    required this.snr,
    required this.rssi,
    required this.encryptedPayload,
  });

  factory PacketMetadata.fromRawPacket({
    required Uint8List raw,
    required double snr,
    required int rssi,
  }) {
    if (raw.isEmpty) {
      throw ArgumentError('Packet is empty');
    }

    final int header = raw[0];
    final int routeType = header & PacketHeader.routeMask;
    final int payloadType = (header >> PacketHeader.typeShift) & PacketHeader.typeMask;
    final int protocolVersion = (header >> PacketHeader.verShift) & PacketHeader.verMask;

    // Calculate offset for Path Length based on route type
    int pathLengthOffset = 1;
    if (routeType == RouteType.reserved1 || routeType == RouteType.reserved2) {
      // TransportFlood or TransportDirect - has 4-byte transport codes
      pathLengthOffset = 5;
    }

    if (raw.length <= pathLengthOffset) {
      throw ArgumentError(
          'Packet too short for path length (need >${pathLengthOffset} bytes, got ${raw.length})');
    }

    final int pathLength = raw[pathLengthOffset];

    // Path data starts after path length byte
    final int pathDataOffset = pathLengthOffset + 1;
    final int pathDataEnd = (pathDataOffset + pathLength).clamp(0, raw.length);
    final Uint8List pathBytes = raw.sublist(pathDataOffset, pathDataEnd);

    // Parse repeater IDs (4 bytes each)
    final List<int> pathRepeaterIds = [];
    for (var i = 0; i + 3 < pathBytes.length; i += 4) {
      final id = (pathBytes[i] << 24) |
          (pathBytes[i + 1] << 16) |
          (pathBytes[i + 2] << 8) |
          pathBytes[i + 3];
      pathRepeaterIds.add(id);
    }

    // Derive first and last hops (single byte approach from original)
    final int? firstHop = pathBytes.isNotEmpty ? pathBytes.first : null;
    final int? lastHop = pathBytes.isNotEmpty ? pathBytes.last : null;

    // Extract encrypted payload after path data
    final int payloadOffset = pathDataOffset + pathLength;
    final Uint8List encryptedPayload =
        payloadOffset < raw.length ? raw.sublist(payloadOffset) : Uint8List(0);

    return PacketMetadata(
      raw: raw,
      header: header,
      routeType: routeType,
      payloadType: payloadType,
      protocolVersion: protocolVersion,
      pathLength: pathLength,
      pathBytes: pathBytes,
      pathRepeaterIds: pathRepeaterIds,
      firstHop: firstHop,
      lastHop: lastHop,
      snr: snr,
      rssi: rssi,
      encryptedPayload: encryptedPayload,
    );
  }

  int? get channelHash {
    if (encryptedPayload.isEmpty) return null;
    return encryptedPayload[0];
  }

  bool get isGroupText => payloadType == PayloadType.grpTxt;
  bool get isAdvert => payloadType == PayloadType.advert;
}

// ============================================================================
// VALIDATION
// ============================================================================

class ValidationResult {
  final bool passed;
  final String message;
  final String? channelName;
  final String? plaintext;

  ValidationResult({
    required this.passed,
    required this.message,
    this.channelName,
    this.plaintext,
  });
}

class ValidationStep {
  final String name;
  final bool passed;
  final String details;

  ValidationStep({
    required this.name,
    required this.passed,
    required this.details,
  });
}

// ============================================================================
// MAIN SCRIPT
// ============================================================================

void main(List<String> arguments) {
  if (arguments.isEmpty) {
    printUsage();
    return;
  }

  // Parse arguments
  String? hexPacket;
  int rssi = -85;
  double snr = 8.0;
  // Note: targetChannel is parsed but currently unused - reserved for future filtering
  // String targetChannel = '#wardriving';

  for (final arg in arguments) {
    if (arg.startsWith('--rssi=')) {
      rssi = int.parse(arg.substring(7));
    } else if (arg.startsWith('--snr=')) {
      snr = double.parse(arg.substring(6));
    } else if (arg.startsWith('--channel=')) {
      // Reserved for future use
      // targetChannel = arg.substring(10);
    } else if (!arg.startsWith('-')) {
      hexPacket = arg;
    }
  }

  if (hexPacket == null) {
    print('Error: No hex packet provided');
    printUsage();
    return;
  }

  // Parse hex string to bytes
  Uint8List rawBytes;
  try {
    rawBytes = parseHex(hexPacket);
  } catch (e) {
    print('Error parsing hex: $e');
    return;
  }

  if (rawBytes.isEmpty) {
    print('Error: Empty packet');
    return;
  }

  // Set up allowed channels
  final channels = <int, ChannelInfo>{};

  // Public channel (fixed key)
  final publicKey = CryptoService.publicChannelFixedKey;
  final publicHash = CryptoService.computeChannelHash(publicKey);
  channels[publicHash] = ChannelInfo(
    channelName: 'Public',
    key: publicKey,
    hash: publicHash,
  );

  // Hashtag channels
  for (final name in ['#wardriving', '#testing', '#ottawa', '#wartest']) {
    final key = CryptoService.getChannelKey(name);
    final hash = CryptoService.computeChannelHash(key);
    channels[hash] = ChannelInfo(
      channelName: name,
      key: key,
      hash: hash,
    );
  }

  // Parse packet metadata
  PacketMetadata metadata;
  try {
    metadata = PacketMetadata.fromRawPacket(
      raw: rawBytes,
      snr: snr,
      rssi: rssi,
    );
  } catch (e) {
    print('Error parsing packet: $e');
    return;
  }

  // Print header
  print('');
  print('${'=' * 60}');
  print('              PACKET VALIDATION TEST');
  print('${'=' * 60}');
  print('');

  // Print input
  print('INPUT');
  print('  Hex: ${formatHex(rawBytes)}');
  print('  RSSI: $rssi dBm');
  print('  SNR: $snr dB');
  print('');

  // Print packet metadata
  print('PACKET METADATA');
  print('  Header: 0x${metadata.header.toRadixString(16).padLeft(2, '0').toUpperCase()}');
  print('    Route Type: ${RouteType.getName(metadata.routeType)} (0x${metadata.routeType.toRadixString(16).padLeft(2, '0')})');
  print('    Payload Type: ${PayloadType.getName(metadata.payloadType)} (0x${metadata.payloadType.toRadixString(16).padLeft(2, '0')})');
  print('    Protocol Version: ${metadata.protocolVersion}');
  print('  Path Length: ${metadata.pathLength} bytes');

  if (metadata.pathRepeaterIds.isNotEmpty) {
    final pathStr = metadata.pathRepeaterIds
        .map((id) => '0x${id.toRadixString(16).padLeft(8, '0').toUpperCase()}')
        .join(', ');
    print('  Path Repeater IDs: [$pathStr]');
  } else if (metadata.pathBytes.isNotEmpty) {
    print('  Path Bytes: ${formatHex(metadata.pathBytes)}');
  } else {
    print('  Path: (empty)');
  }

  print('  Encrypted Payload: ${formatHex(metadata.encryptedPayload)} (${metadata.encryptedPayload.length} bytes)');

  if (metadata.channelHash != null) {
    print('  Channel Hash: 0x${metadata.channelHash!.toRadixString(16).padLeft(2, '0').toUpperCase()}');
  }
  print('');

  // Run validations
  print('VALIDATION RESULTS');

  final List<ValidationStep> steps = [];
  String? decryptedPlaintext;
  String? matchedChannel;

  // VALIDATION 1: RSSI check (carpeater filter)
  const maxRssiThreshold = -30;
  final rssiPassed = rssi < maxRssiThreshold;
  steps.add(ValidationStep(
    name: 'RSSI Check',
    passed: rssiPassed,
    details: rssiPassed
        ? '$rssi < $maxRssiThreshold (passed carpeater filter)'
        : '$rssi >= $maxRssiThreshold (FAILED carpeater filter)',
  ));

  if (!rssiPassed) {
    printValidationResults(steps, false, 'RSSI too strong (carpeater)');
    return;
  }

  // VALIDATION 2: Payload length check
  final minPayloadLength = 3;
  final payloadPassed = metadata.encryptedPayload.length >= minPayloadLength;
  steps.add(ValidationStep(
    name: 'Payload Length',
    passed: payloadPassed,
    details: payloadPassed
        ? '${metadata.encryptedPayload.length} bytes >= $minPayloadLength bytes minimum'
        : '${metadata.encryptedPayload.length} bytes < $minPayloadLength bytes minimum',
  ));

  if (!payloadPassed) {
    printValidationResults(steps, false, 'Payload too short');
    return;
  }

  // VALIDATION 3: Channel hash lookup
  final channelHash = metadata.channelHash;
  ChannelInfo? channelInfo;
  if (channelHash != null) {
    channelInfo = channels[channelHash];
  }

  final channelPassed = channelInfo != null;
  final channelHashHex = channelHash != null
      ? '0x${channelHash.toRadixString(16).padLeft(2, '0').toUpperCase()}'
      : '0x00';
  steps.add(ValidationStep(
    name: 'Channel Lookup',
    passed: channelPassed,
    details: channelPassed
        ? 'Hash $channelHashHex -> ${channelInfo.channelName}'
        : 'Hash $channelHashHex not found in known channels',
  ));

  if (!channelPassed) {
    // Print known channel hashes for debugging
    print('');
    print('  Known channel hashes:');
    for (final entry in channels.entries) {
      print('    0x${entry.key.toRadixString(16).padLeft(2, '0').toUpperCase()} -> ${entry.value.channelName}');
    }
    printValidationResults(steps, false, 'Unknown channel hash');
    return;
  }

  matchedChannel = channelInfo.channelName;

  // VALIDATION 4: Decryption attempt
  bool decryptPassed = false;
  String decryptDetails = '';
  Uint8List? decryptedBytes;

  try {
    // Payload structure: [1 byte channel_hash][2 bytes MAC][encrypted message]
    if (metadata.encryptedPayload.length > 3) {
      final encryptedMessage = metadata.encryptedPayload.sublist(3);
      decryptedBytes = CryptoService.decryptChannelMessage(
        encryptedMessage,
        channelInfo.key,
      );

      // Decrypted structure: [4 bytes timestamp][1 byte flags][message text]
      if (decryptedBytes.length >= 5) {
        decryptPassed = true;
        decryptDetails = 'Success (${decryptedBytes.length} bytes decrypted)';
      } else {
        decryptDetails =
            'Decrypted data too short (${decryptedBytes.length} bytes, need 5+)';
      }
    } else {
      decryptDetails = 'Encrypted message too short';
    }
  } catch (e) {
    decryptDetails = 'Failed: $e';
  }

  steps.add(ValidationStep(
    name: 'Decryption',
    passed: decryptPassed,
    details: decryptDetails,
  ));

  if (!decryptPassed) {
    printValidationResults(steps, false, 'Decryption failed');
    return;
  }

  // Extract message text
  final messageBytes = decryptedBytes!.sublist(5);
  String plaintext;
  try {
    plaintext = utf8.decode(messageBytes, allowMalformed: true);
    plaintext = plaintext.replaceAll(RegExp(r'\x00+$'), '').trim();
  } catch (e) {
    steps.add(ValidationStep(
      name: 'Text Decode',
      passed: false,
      details: 'Failed to decode: $e',
    ));
    printValidationResults(steps, false, 'Text decode failed');
    return;
  }

  // VALIDATION 5: Printable ratio check
  const minPrintableRatio = 0.6;
  final printableRatio = getPrintableRatio(plaintext);
  final printablePassed = printableRatio >= minPrintableRatio;

  steps.add(ValidationStep(
    name: 'Printable Ratio',
    passed: printablePassed,
    details: printablePassed
        ? '${(printableRatio * 100).toStringAsFixed(1)}% >= ${(minPrintableRatio * 100).toStringAsFixed(1)}%'
        : '${(printableRatio * 100).toStringAsFixed(1)}% < ${(minPrintableRatio * 100).toStringAsFixed(1)}%',
  ));

  if (!printablePassed) {
    printValidationResults(steps, false, 'Plaintext not printable');
    // Still show the decoded message for debugging
    print('');
    print('DECRYPTED MESSAGE (failed validation)');
    print('  Channel: $matchedChannel');
    print('  Plaintext: "$plaintext"');
    print('  Length: ${plaintext.length} characters');
    return;
  }

  decryptedPlaintext = plaintext;

  // All validations passed
  printValidationResults(steps, true, null);

  // Print decrypted message
  print('');
  print('DECRYPTED MESSAGE');
  print('  Channel: $matchedChannel');
  print('  Plaintext: "$decryptedPlaintext"');
  print('  Length: ${decryptedPlaintext.length} characters');

  // Print timestamp and flags from decrypted data
  if (decryptedBytes.length >= 5) {
    final timestamp = (decryptedBytes[0] << 24) |
        (decryptedBytes[1] << 16) |
        (decryptedBytes[2] << 8) |
        decryptedBytes[3];
    final flags = decryptedBytes[4];
    final dateTime =
        DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true);
    print('  Timestamp: $timestamp (${dateTime.toIso8601String()})');
    print('  Flags: 0x${flags.toRadixString(16).padLeft(2, '0')}');
  }
  print('');
}

void printUsage() {
  print('''
MeshMapper Packet Validation Test Script

Usage:
  dart run bin/test_message.dart <hex_packet> [options]

Arguments:
  <hex_packet>        Hex string (spaces optional)

Options:
  --rssi=<value>      RSSI in dBm (default: -85)
  --snr=<value>       SNR in dB (default: 8.0)
  --channel=<name>    Channel name for reference (default: #wardriving)

Examples:
  dart run bin/test_message.dart "15 01 AB CD EF 12..."
  dart run bin/test_message.dart "15 01 AB CD..." --rssi=-85 --snr=8.5
  dart run bin/test_message.dart "1501ABCD..." --channel="#testing"

Supported channels: #wardriving, #testing, #ottawa, #wartest, Public
''');
}

void printValidationResults(
    List<ValidationStep> steps, bool allPassed, String? failReason) {
  for (final step in steps) {
    final icon = step.passed ? '[+]' : '[X]';
    print('  $icon ${step.name}: ${step.details}');
  }

  print('');
  print('${'=' * 60}');
  if (allPassed) {
    print('  RESULT: + PASSED');
  } else {
    print('  RESULT: X FAILED - $failReason');
  }
  print('${'=' * 60}');
}

Uint8List parseHex(String hex) {
  // Remove spaces, tabs, newlines
  final clean = hex.replaceAll(RegExp(r'\s+'), '');

  // Validate hex characters
  if (!RegExp(r'^[0-9A-Fa-f]*$').hasMatch(clean)) {
    throw FormatException('Invalid hex characters in: $hex');
  }

  if (clean.length % 2 != 0) {
    throw FormatException('Hex string must have even length');
  }

  final bytes = <int>[];
  for (var i = 0; i < clean.length; i += 2) {
    bytes.add(int.parse(clean.substring(i, i + 2), radix: 16));
  }
  return Uint8List.fromList(bytes);
}

String formatHex(Uint8List bytes, {int maxBytes = 32}) {
  if (bytes.isEmpty) return '(empty)';

  final display = bytes.length > maxBytes ? bytes.sublist(0, maxBytes) : bytes;
  final hex = display
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');

  if (bytes.length > maxBytes) {
    return '$hex ... (+${bytes.length - maxBytes} more)';
  }
  return hex;
}

double getPrintableRatio(String text) {
  if (text.isEmpty) return 0.0;

  int printableCount = 0;
  for (int i = 0; i < text.length; i++) {
    final code = text.codeUnitAt(i);
    if (code >= 32 && code <= 126) {
      printableCount++;
    }
  }

  return printableCount / text.length;
}
