import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../utils/debug_logger_io.dart';
import 'crypto_service.dart';
import 'packet_metadata.dart';
import 'packet_validator.dart';

/// TX echo tracker for repeater detection during 7-second window
/// Reference: handleTxLogging() in wardrive.js (lines 3561-3710)
class TxTracker {
  bool isListening = false;
  DateTime? sentTimestamp;
  String? sentPayload;
  int? channelIndex;
  int? expectedChannelHash;
  Uint8List? channelKey;

  /// Map of repeaterId (hex) -> RepeaterEcho
  final Map<String, RepeaterEcho> repeaters = {};

  Timer? _windowTimer;

  /// Callback fired when a new echo is received (for real-time UI updates)
  /// Parameters: (repeaterId, snr, rssi, isNew) - isNew is true for first time seeing this repeater
  void Function(String repeaterId, double snr, int rssi, bool isNew)? onEchoReceived;

  /// Callback for carpeater drops (for quiet error logging)
  /// Called with repeater ID and reason when an echo is dropped due to carpeater detection
  void Function(String repeaterId, String reason)? onCarpeaterDrop;

  /// Function to check if a repeater ID should be ignored (user carpeater filter)
  /// Returns true if the repeater should be filtered out
  bool Function(String repeaterId)? shouldIgnoreRepeater;

  /// Start tracking echoes for a sent ping
  /// 
  /// @param payload - The message text sent (for content verification)
  /// @param channelIdx - Channel index where ping was sent
  /// @param channelHash - Expected channel hash for validation
  /// @param channelKey - Key for message decryption
  /// @param windowDuration - How long to listen (default 7 seconds)
  void startTracking({
    required String payload,
    required int channelIdx,
    required int channelHash,
    required Uint8List channelKey,
    Duration windowDuration = const Duration(seconds: 7),
  }) {
    debugLog('[TX LOG] Starting echo tracking');
    debugLog('[TX LOG] Payload: "$payload"');
    debugLog('[TX LOG] Channel: $channelIdx, Hash: 0x${channelHash.toRadixString(16).padLeft(2, '0')}');
    
    isListening = true;
    sentTimestamp = DateTime.now();
    sentPayload = payload;
    channelIndex = channelIdx;
    expectedChannelHash = channelHash;
    this.channelKey = channelKey;
    repeaters.clear();
    
    // Start window timer
    _windowTimer?.cancel();
    _windowTimer = Timer(windowDuration, stopTracking);
    
    debugLog('[TX LOG] Echo tracking window started (${windowDuration.inSeconds}s)');
  }

  /// Stop tracking echoes
  void stopTracking() {
    debugLog('[TX LOG] Stopping echo tracking (heard ${repeaters.length} repeaters)');
    
    isListening = false;
    _windowTimer?.cancel();
    _windowTimer = null;
    
    // Log final results
    if (repeaters.isNotEmpty) {
      for (final entry in repeaters.entries) {
        debugLog('[TX LOG] Final: ${entry.key} -> SNR=${entry.value.snr}, seen=${entry.value.seenCount}x');
      }
    }
  }

  /// Handle incoming packet, check if it's an echo
  /// Returns true if packet was an echo and tracked
  Future<bool> handlePacket(PacketMetadata metadata) async {
    if (!isListening) return false;
    
    final originalPayload = sentPayload;
    final expectedHash = expectedChannelHash;
    
    try {
      debugLog('[TX LOG] Processing rx_log entry: SNR=${metadata.snr}, RSSI=${metadata.rssi}');

      // VALIDATION STEP 1: Header validation (must be GROUP_TEXT)
      if (!metadata.isGroupText) {
        debugLog('[TX LOG] Ignoring: header validation failed '
            '(header=0x${metadata.header.toRadixString(16).padLeft(2, '0')})');
        return false;
      }
      debugLog('[TX LOG] Header validation passed: 0x${metadata.header.toRadixString(16).padLeft(2, '0')}');

      // VALIDATION STEP 1.5: Path length check (must have hops to identify repeater)
      // Moved before RSSI check so we can log the repeater ID on carpeater drops
      if (metadata.pathLength == 0) {
        debugLog('[TX LOG] Ignoring: no path (direct transmission, not a repeater echo)');
        return false;
      }

      // Extract first hop (first repeater) for use in validation and logging
      final firstHopId = metadata.firstHop!;
      final pathHex = firstHopId.toRadixString(16).padLeft(2, '0');

      // VALIDATION STEP 2: Check RSSI (carpeater failsafe)
      if (PacketValidator.isCarpeater(metadata.rssi)) {
        debugLog('[TX LOG] ❌ DROPPED: RSSI too strong (${metadata.rssi} ≥ ${PacketValidator.maxRssiThreshold}) '
            '- possible carpeater (RSSI failsafe), repeater=$pathHex');
        debugLog('[TX LOG] onCarpeaterDrop callback is ${onCarpeaterDrop != null ? "SET" : "NULL"}');
        onCarpeaterDrop?.call(pathHex, 'RSSI too strong (${metadata.rssi} dBm)');
        return false; // Mark as handled (dropped)
      }
      debugLog('[TX LOG] ✓ RSSI OK (${metadata.rssi} < ${PacketValidator.maxRssiThreshold})');

      // VALIDATION STEP 2.5: Check user carpeater filter
      if (shouldIgnoreRepeater != null && shouldIgnoreRepeater!(pathHex.toUpperCase())) {
        debugLog('[TX LOG] ❌ DROPPED: Repeater $pathHex ignored by user carpeater filter');
        return false;
      }

      // VALIDATION STEP 3: Channel hash validation
      if (metadata.encryptedPayload.length < 3) {
        debugLog('[TX LOG] Ignoring: payload too short to contain channel hash');
        return false;
      }

      final packetChannelHash = metadata.channelHash!;
      debugLog('[TX LOG] Message correlation check: '
          'packet_channel_hash=0x${packetChannelHash.toRadixString(16).padLeft(2, '0')}, '
          'expected=0x${expectedHash?.toRadixString(16).padLeft(2, '0')}');

      if (packetChannelHash != expectedHash) {
        debugLog('[TX LOG] Ignoring: channel hash mismatch');
        return false;
      }
      debugLog('[TX LOG] Channel hash match confirmed - this is a message on our channel');

      // VALIDATION STEP 3: Message content verification
      if (channelKey != null && originalPayload != null) {
        debugLog('[MESSAGE_CORRELATION] Channel key available, attempting decryption...');

        try {
          // Payload structure: [1 byte channel_hash][2 bytes MAC][encrypted message]
          // Skip first 3 bytes to get the encrypted message
          final encryptedMessage = metadata.encryptedPayload.sublist(3);
          final decryptedBytes = CryptoService.decryptChannelMessage(
            encryptedMessage,
            channelKey!,
          );

          // Decrypted structure: [4 bytes timestamp][1 byte flags][message text]
          // Skip first 5 bytes to get the actual message
          if (decryptedBytes.length < 5) {
            debugLog('[MESSAGE_CORRELATION] ❌ REJECT: Decrypted data too short');
            return false;
          }
          final messageBytes = decryptedBytes.sublist(5);

          // Convert bytes to string and strip null terminators
          var decryptedMessage = utf8.decode(messageBytes, allowMalformed: true);
          decryptedMessage = decryptedMessage.replaceAll(RegExp(r'\x00+$'), '').trim();

          debugLog('[MESSAGE_CORRELATION] Decryption successful, comparing content...');
          debugLog('[MESSAGE_CORRELATION] Decrypted: "$decryptedMessage" (${decryptedMessage.length} chars)');
          debugLog('[MESSAGE_CORRELATION] Expected:  "$originalPayload" (${originalPayload.length} chars)');

          // Check if our expected message is contained in the decrypted text
          // This handles both exact matches and messages with sender prefixes
          final messageMatches = decryptedMessage == originalPayload ||
              decryptedMessage.contains(originalPayload);

          if (!messageMatches) {
            debugLog('[MESSAGE_CORRELATION] ❌ REJECT: Message content mismatch (not an echo of our ping)');
            debugLog('[MESSAGE_CORRELATION] This is a different message on the same channel');
            return false;
          }

          if (decryptedMessage == originalPayload) {
            debugLog('[MESSAGE_CORRELATION] ✅ Exact message match confirmed - this is an echo of our ping!');
          } else {
            debugLog('[MESSAGE_CORRELATION] ✅ Message contained in decrypted text (with sender prefix) '
                '- this is an echo of our ping!');
          }
        } catch (e) {
          debugLog('[MESSAGE_CORRELATION] ❌ REJECT: Failed to decrypt message: $e');
          return false;
        }
      } else {
        debugWarn('[MESSAGE_CORRELATION] ⚠️ WARNING: Cannot verify message content - channel key not available');
        debugWarn('[MESSAGE_CORRELATION] Proceeding without message content verification (less reliable)');
      }

      // Path length and first hop already validated/extracted earlier (before RSSI check)

      debugLog('[PING] Repeater echo accepted: first_hop=$pathHex, SNR=${metadata.snr}, '
          'full_path_length=${metadata.pathLength}');

      // Deduplication: check if we already have this repeater
      bool isNewRepeater = false;
      if (repeaters.containsKey(pathHex)) {
        final existing = repeaters[pathHex]!;
        debugLog('[PING] Deduplication: path $pathHex already seen '
            '(existing SNR=${existing.snr}, new SNR=${metadata.snr})');

        // Keep the best (highest) SNR
        if (metadata.snr > existing.snr) {
          debugLog('[PING] Deduplication decision: updating path $pathHex with better SNR: '
              '${existing.snr} -> ${metadata.snr}');
          repeaters[pathHex] = RepeaterEcho(
            repeaterId: pathHex,
            snr: metadata.snr,
            rssi: metadata.rssi,
            seenCount: existing.seenCount + 1,
          );
        } else {
          debugLog('[PING] Deduplication decision: keeping existing SNR for path $pathHex '
              '(existing ${existing.snr} >= new ${metadata.snr})');
          // Still increment seen count
          existing.seenCount++;
        }
      } else {
        // New repeater
        isNewRepeater = true;
        debugLog('[PING] Adding new repeater echo: path=$pathHex, SNR=${metadata.snr}, RSSI=${metadata.rssi}');
        repeaters[pathHex] = RepeaterEcho(
          repeaterId: pathHex,
          snr: metadata.snr,
          rssi: metadata.rssi,
          seenCount: 1,
        );
      }

      // Notify callback for real-time UI updates
      final bestSnr = repeaters[pathHex]!.snr;
      final rssi = repeaters[pathHex]!.rssi;
      debugLog('[TX LOG] Invoking onEchoReceived callback (callback=${onEchoReceived != null ? "SET" : "NULL"})');
      if (onEchoReceived != null) {
        onEchoReceived!(pathHex, bestSnr, rssi, isNewRepeater);
        debugLog('[TX LOG] onEchoReceived callback invoked successfully');
      }

      debugLog('[TX LOG] ✅ Echo tracked successfully');
      return true;
    } catch (error, stackTrace) {
      debugError('[TX LOG] Error processing rx_log entry: $error');
      debugError('[TX LOG] Stack trace: $stackTrace');
      return false;
    }
  }

  /// Dispose of resources
  void dispose() {
    stopTracking();
  }
}

/// Repeater echo data
class RepeaterEcho {
  final String repeaterId;  // Hex string
  double snr;               // Best SNR seen
  int rssi;                 // RSSI value (dBm)
  int seenCount;            // Times observed

  RepeaterEcho({
    required this.repeaterId,
    required this.snr,
    required this.rssi,
    this.seenCount = 1,
  });
}
