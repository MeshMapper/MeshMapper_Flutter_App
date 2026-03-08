import 'dart:convert';
import 'dart:typed_data';

import '../../utils/debug_logger_io.dart';
import 'crypto_service.dart';
import 'packet_metadata.dart';

/// Packet validation logic for RX wardriving
/// Reference: validateRxPacket() in wardrive.js (lines 3419-3515)
class PacketValidator {
  /// RSSI threshold for carpeater detection (-30 dBm)
  /// Packets stronger than this are likely from co-located repeaters
  /// Reference: MAX_RX_RSSI_THRESHOLD in wardrive.js
  static const int maxRssiThreshold = -30;
  
  /// Minimum printable character ratio (60%)
  /// Lowered from 90% to allow emojis and Unicode in messages
  /// Still filters out completely corrupted data
  static const double minPrintableRatio = 0.6;

  /// Allowed channels for validation
  final Map<int, ChannelInfo> allowedChannels;

  /// When true, skip RSSI carpeater check (user setting)
  final bool disableRssiFilter;

  PacketValidator({required this.allowedChannels, this.disableRssiFilter = false});

  /// Validate packet for RX wardriving
  /// Returns ValidationResult with success/failure and reason
  /// [skipRssiCheck] - When true, skip the RSSI carpeater check (used for CARpeater pass-through)
  Future<ValidationResult> validate(PacketMetadata metadata, {bool skipRssiCheck = false}) async {
    try {
      // Log packet for debugging
      final rawHex = metadata.raw
          .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');
      debugLog('[RX FILTER] ========== VALIDATING PACKET ==========');
      debugLog('[RX FILTER] Raw packet (${metadata.raw.length} bytes): $rawHex');
      debugLog('[RX FILTER] Header: 0x${metadata.header.toRadixString(16).padLeft(2, '0')} | '
          'PathHashCount: ${metadata.pathHashCount} | SNR: ${metadata.snr}');

      // VALIDATION 1: Check RSSI (carpeater filter)
      if (skipRssiCheck) {
        debugLog('[RX FILTER] RSSI check skipped (CARpeater pass-through)');
      } else if (disableRssiFilter) {
        debugLog('[RX FILTER] RSSI filter disabled by user, skipping carpeater check');
      } else if (isCarpeater(metadata.rssi)) {
        debugLog('[RX FILTER] ❌ DROPPED: RSSI too strong (${metadata.rssi} ≥ $maxRssiThreshold) - '
            'possible carpeater (RSSI failsafe)');
        return ValidationResult.failed('carpeater-rssi');
      } else {
        debugLog('[RX FILTER] ✓ RSSI OK (${metadata.rssi} < $maxRssiThreshold)');
      }

      // VALIDATION 2: Check packet type
      if (metadata.isGroupText) {
        return await _validateGroupText(metadata);
      } else if (metadata.isAdvert) {
        return _validateAdvert(metadata);
      } else {
        debugLog('[RX FILTER] ❌ DROPPED: unsupported ptype '
            '(header=0x${metadata.header.toRadixString(16).padLeft(2, '0')})');
        return ValidationResult.failed('unsupported ptype');
      }
    } catch (error, stackTrace) {
      debugError('[RX FILTER] ❌ Validation error: $error');
      debugError('[RX FILTER] Stack trace: $stackTrace');
      return ValidationResult.failed('validation error');
    }
  }

  /// Validate GROUP_TEXT packet (channel message)
  Future<ValidationResult> _validateGroupText(PacketMetadata metadata) async {
    debugLog('[RX FILTER] Packet type: GRP_TXT (0x15)');

    // Check payload length
    if (metadata.encryptedPayload.length < 3) {
      debugLog('[RX FILTER] ❌ DROPPED: GRP_TXT payload too short '
          '(${metadata.encryptedPayload.length} bytes)');
      return ValidationResult.failed('payload too short');
    }

    // Extract channel hash
    final channelHash = metadata.channelHash!;
    debugLog('[RX FILTER] Channel hash: 0x${channelHash.toRadixString(16).padLeft(2, '0')}');

    // Check if channel is in allowed list
    final channelInfo = allowedChannels[channelHash];
    if (channelInfo == null) {
      debugLog('[RX FILTER] ❌ DROPPED: Unknown channel hash '
          '0x${channelHash.toRadixString(16).padLeft(2, '0')}');
      return ValidationResult.failed('unknown channel hash');
    }

    debugLog('[RX FILTER] ✓ Channel matched: ${channelInfo.channelName}');

    // Decrypt message
    // Payload structure: [1 byte channel_hash][2 bytes MAC][encrypted message]
    // Skip first 3 bytes to get the encrypted message
    final encryptedMessage = metadata.encryptedPayload.sublist(3);
    debugLog('[RX FILTER] Encrypted message: ${encryptedMessage.length} bytes');

    final decryptedBytes = CryptoService.decryptChannelMessage(
      encryptedMessage,
      channelInfo.key,
    );

    // Decrypted structure: [4 bytes timestamp][1 byte flags][message text]
    // Skip first 5 bytes to get the actual message
    if (decryptedBytes.length < 5) {
      debugLog('[RX FILTER] ❌ DROPPED: Decrypted data too short (${decryptedBytes.length} bytes, need 5+)');
      return ValidationResult.failed('decrypted too short');
    }

    final messageBytes = decryptedBytes.sublist(5);

    // Convert to string and strip null terminators
    String plaintext;
    try {
      plaintext = utf8.decode(messageBytes, allowMalformed: true);
      // Remove trailing nulls and trim
      plaintext = plaintext.replaceAll(RegExp(r'\x00+$'), '').trim();
    } catch (e) {
      debugLog('[RX FILTER] ❌ DROPPED: Failed to convert decrypted bytes to string');
      return ValidationResult.failed('decode failed');
    }

    // Sanitize for logging: remove replacement characters to avoid Flutter UTF-8 warnings
    final sanitizedForLog = plaintext
        .replaceAll('\uFFFD', '')  // Remove replacement characters
        .replaceAll(RegExp(r'[^\x20-\x7E]'), '');  // Keep only printable ASCII
    final logPreview = sanitizedForLog.substring(0, sanitizedForLog.length.clamp(0, 60));
    debugLog('[RX FILTER] Decrypted message (${plaintext.length} chars): '
        '"$logPreview${sanitizedForLog.length > 60 ? '...' : ''}"');

    // Check printable ratio
    final printableRatio = getPrintableRatio(plaintext);
    debugLog('[RX FILTER] Printable ratio: ${(printableRatio * 100).toFixed(1)}% '
        '(threshold: ${(minPrintableRatio * 100).toFixed(1)}%)');

    if (printableRatio < minPrintableRatio) {
      debugLog('[RX FILTER] ❌ DROPPED: plaintext not printable');
      return ValidationResult.failed('plaintext not printable');
    }

    debugLog('[RX FILTER] ✅ KEPT: GRP_TXT passed all validations');
    return ValidationResult.success(
      channelName: channelInfo.channelName,
      plaintext: plaintext,
    );
  }

  /// Validate ADVERT packet (node advertisement)
  static ValidationResult _validateAdvert(PacketMetadata metadata) {
    debugLog('[RX FILTER] Packet type: ADVERT (0x11)');

    // Parse ADVERT name
    final nameResult = parseAdvertName(metadata.encryptedPayload);

    if (!nameResult.valid) {
      debugLog('[RX FILTER] ❌ DROPPED: ${nameResult.reason}');
      return ValidationResult.failed(nameResult.reason);
    }

    debugLog('[RX FILTER] ✅ KEPT: ADVERT passed all validations (name="${nameResult.name}")');
    return ValidationResult.success();
  }

  /// Check if RSSI indicates carpeater (signal too strong)
  static bool isCarpeater(int rssi) {
    return rssi >= maxRssiThreshold;
  }

  /// Calculate ratio of printable ASCII characters (32-126)
  static double getPrintableRatio(String text) {
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


  /// Parse ADVERT packet name field
  /// Reference: parseAdvertName() in wardrive.js lines 3353-3419
  static AdvertNameResult parseAdvertName(Uint8List payload) {
    try {
      // ADVERT structure: [32 pubkey][4 timestamp][64 signature][appData...]
      // appData structure: [1 flags][optional 8 lat/lon][name if flag set]
      const pubkeySize = 32;
      const timestampSize = 4;
      const signatureSize = 64;
      const appDataOffset = pubkeySize + timestampSize + signatureSize; // 100

      if (payload.length <= appDataOffset) {
        return const AdvertNameResult(
          valid: false,
          reason: 'payload too short for appData',
          name: null,
        );
      }

      // Read flags byte from appData
      final flags = payload[appDataOffset];
      debugLog('[RX FILTER] ADVERT flags: 0x${flags.toRadixString(16).padLeft(2, '0')}');

      // Flag masks (from advert.js)
      const advNameMask = 0x80;
      const advLatlonMask = 0x10;

      // Check if name is present in flags
      if ((flags & advNameMask) == 0) {
        return const AdvertNameResult(
          valid: false,
          reason: 'no name in advert',
          name: null,
        );
      }

      // Calculate name offset: skip flags byte and optional lat/lon
      var nameOffset = appDataOffset + 1; // +1 for flags byte (offset 101)
      if ((flags & advLatlonMask) != 0) {
        nameOffset += 8; // Skip 4 bytes lat + 4 bytes lon (offset 109)
        debugLog('[RX FILTER] ADVERT has lat/lon, skipping 8 bytes');
      }

      if (payload.length <= nameOffset) {
        return const AdvertNameResult(
          valid: false,
          reason: 'no name data',
          name: null,
        );
      }

      // Extract name bytes (remaining data, null-terminated)
      final nameBytes = payload.sublist(nameOffset);

      // Decode and trim null characters
      var name = utf8.decode(nameBytes, allowMalformed: true);
      // Remove trailing nulls and whitespace
      name = name.replaceAll(RegExp(r'\x00+$'), '').trim();

      debugLog('[RX FILTER] ADVERT name extracted: "$name" (${name.length} chars)');

      if (name.isEmpty) {
        return const AdvertNameResult(
          valid: false,
          reason: 'name empty',
          name: null,
        );
      }

      // Check if name is printable (use same threshold as messages)
      final printableRatio = getPrintableRatio(name);
      debugLog('[RX FILTER] ADVERT name printable ratio: ${(printableRatio * 100).toFixed(1)}%');

      if (printableRatio < minPrintableRatio) {
        return AdvertNameResult(
          valid: false,
          reason: 'name not printable',
          name: name,
        );
      }

      return AdvertNameResult(
        valid: true,
        reason: 'valid',
        name: name,
      );
    } catch (e) {
      debugError('[RX FILTER] Error parsing ADVERT name: $e');
      return const AdvertNameResult(
        valid: false,
        reason: 'parse error',
        name: null,
      );
    }
  }
}

/// Validation result for RX packets
class ValidationResult {
  final bool valid;
  final String reason;
  final String? channelName;
  final String? plaintext;

  const ValidationResult({
    required this.valid,
    required this.reason,
    this.channelName,
    this.plaintext,
  });

  factory ValidationResult.success({String? channelName, String? plaintext}) {
    return ValidationResult(
      valid: true,
      reason: 'kept',
      channelName: channelName,
      plaintext: plaintext,
    );
  }

  factory ValidationResult.failed(String reason) {
    return ValidationResult(
      valid: false,
      reason: reason,
    );
  }
}

/// ADVERT name parsing result
class AdvertNameResult {
  final bool valid;
  final String reason;
  final String? name;

  const AdvertNameResult({
    required this.valid,
    required this.reason,
    required this.name,
  });
}

/// Channel info for validation
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

/// Extension for double precision formatting
extension on double {
  String toFixed(int decimals) {
    return toStringAsFixed(decimals);
  }
}
