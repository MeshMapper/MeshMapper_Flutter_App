import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../utils/debug_logger_io.dart';
import 'crypto_service.dart';
import 'packet_metadata.dart';
import 'packet_validator.dart';

/// TX echo tracker for repeater detection during 5-second window
/// Reference: handleTxLogging() in wardrive.js (lines 3561-3710)
class TxTracker {
  bool isListening = false;
  DateTime? sentTimestamp;
  String? sentPayload;
  int? channelIndex;
  int? expectedChannelHash;
  Uint8List? channelKey;

  /// Map of repeaterId (hex) -> RepeaterEcho (direct 1-hop echoes)
  final Map<String, RepeaterEcho> repeaters = {};

  /// Map of repeaterId (hex) -> RepeaterEcho (multi-hop 2+ hop echoes)
  final Map<String, RepeaterEcho> multiHopRepeaters = {};

  Timer? _windowTimer;

  /// CARpeater prefix — when set, multi-hop packets with this firstHop are stripped
  /// to report the underlying repeater with null SNR/RSSI
  String? carpeaterPrefix;

  /// Callback fired when a direct echo is received (for real-time UI updates)
  /// Parameters: (repeaterId, snr, rssi, isNew) - isNew is true for first time seeing this repeater
  /// snr/rssi are nullable for CARpeater pass-through (signal data is meaningless)
  void Function(String repeaterId, double? snr, int? rssi, bool isNew)?
      onEchoReceived;

  /// Callback fired when a multi-hop echo is received (for real-time UI updates)
  void Function(String repeaterId, double? snr, int? rssi,
      List<String> pathHops, bool isNew)? onMultiHopEchoReceived;

  /// Callback for carpeater drops (for quiet error logging)
  /// Called with repeater ID and reason when an echo is dropped due to carpeater detection
  void Function(String repeaterId, String reason)? onCarpeaterDrop;

  /// Function to check if a repeater ID should be ignored (user carpeater filter)
  /// Returns true if the repeater should be filtered out
  bool Function(String repeaterId)? shouldIgnoreRepeater;

  /// When true, skip RSSI carpeater check (user setting)
  bool disableRssiFilter = false;

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
    Duration windowDuration = const Duration(seconds: 5),
  }) {
    debugLog('[TX LOG] Starting echo tracking');
    debugLog('[TX LOG] Payload: "$payload"');
    debugLog(
        '[TX LOG] Channel: $channelIdx, Hash: 0x${channelHash.toRadixString(16).padLeft(2, '0')}');

    isListening = true;
    sentTimestamp = DateTime.now();
    sentPayload = payload;
    channelIndex = channelIdx;
    expectedChannelHash = channelHash;
    this.channelKey = channelKey;
    repeaters.clear();
    multiHopRepeaters.clear();

    // Start window timer
    _windowTimer?.cancel();
    _windowTimer = Timer(windowDuration, stopTracking);

    debugLog(
        '[TX LOG] Echo tracking window started (${windowDuration.inSeconds}s)');
  }

  /// Stop tracking echoes
  void stopTracking() {
    debugLog(
        '[TX LOG] Stopping echo tracking (heard ${repeaters.length} direct, '
        '${multiHopRepeaters.length} multi-hop repeaters)');

    isListening = false;
    _windowTimer?.cancel();
    _windowTimer = null;

    // Log final results
    if (repeaters.isNotEmpty) {
      for (final entry in repeaters.entries) {
        debugLog(
            '[TX LOG] Final direct: ${entry.key} -> SNR=${entry.value.snr ?? 'null'}, seen=${entry.value.seenCount}x');
      }
    }
    if (multiHopRepeaters.isNotEmpty) {
      for (final entry in multiHopRepeaters.entries) {
        debugLog(
            '[TX LOG] Final multi-hop: ${entry.key} -> SNR=${entry.value.snr ?? 'null'}, '
            'hops=${entry.value.pathHops.length}, seen=${entry.value.seenCount}x');
      }
    }
  }

  /// Handle incoming packet, check if it's an echo
  /// Returns TxEchoResult indicating whether packet was consumed and how
  Future<TxEchoResult> handlePacket(PacketMetadata metadata) async {
    if (!isListening) return TxEchoResult.notEcho;

    final originalPayload = sentPayload;
    final expectedHash = expectedChannelHash;

    try {
      debugLog(
          '[TX LOG] Processing rx_log entry: SNR=${metadata.snr}, RSSI=${metadata.rssi}');

      // VALIDATION STEP 1: Header validation (must be GROUP_TEXT)
      if (!metadata.isGroupText) {
        debugLog('[TX LOG] Ignoring: header validation failed '
            '(header=0x${metadata.header.toRadixString(16).padLeft(2, '0')})');
        return TxEchoResult.notEcho;
      }
      debugLog(
          '[TX LOG] Header validation passed: 0x${metadata.header.toRadixString(16).padLeft(2, '0')}');

      // VALIDATION STEP 1.5: Path length check (must have hops to identify repeater)
      if (metadata.pathHashCount == 0) {
        debugLog(
            '[TX LOG] Ignoring: no path (direct transmission, not a repeater echo)');
        return TxEchoResult.notEcho;
      }

      // Extract first hop (first repeater) for use in validation and logging
      var pathHex = metadata.firstHopHex!;

      // CARpeater pass-through: strip CARpeater hop and report underlying repeater
      bool carpeaterStripped = false;
      double? reportedSnr = metadata.snr;
      int? reportedRssi = metadata.rssi;

      if (carpeaterPrefix != null &&
          PacketValidator.isCarpeaterIdMatch(pathHex, carpeaterPrefix!)) {
        if (metadata.pathHashCount < 2) {
          debugLog('[TX LOG] CARpeater pass-through: single-hop, dropping');
          return TxEchoResult.notEcho;
        }
        // Multi-hop: strip CARpeater, report underlying repeater (second hop)
        final underlyingHex = metadata.getHopHex(1)!;
        debugLog(
            '[TX LOG] CARpeater pass-through: stripped $pathHex, reporting underlying repeater $underlyingHex');
        pathHex = underlyingHex;
        carpeaterStripped = true;
        reportedSnr = null;
        reportedRssi = null;
      }

      // Determine if this is a multi-hop echo (2+ hops, not CARpeater-stripped)
      final bool isMultiHop = !carpeaterStripped && metadata.pathHashCount > 1;

      // For multi-hop: use lastHop as reporting repeater, build display path
      List<String> displayHops = const [];
      if (isMultiHop) {
        pathHex = metadata.lastHopHex!;
        displayHops = [
          for (var i = 0; i < metadata.pathHashCount; i++)
            metadata.getHopHex(i)!,
        ];
        debugLog(
            '[TX LOG] Multi-hop echo (pathHashCount=${metadata.pathHashCount}): '
            'reporting repeater=$pathHex, path=${displayHops.join(' → ')}');
      }

      // VALIDATION STEP 2: Check user carpeater filter
      if (!carpeaterStripped &&
          shouldIgnoreRepeater != null &&
          shouldIgnoreRepeater!(pathHex.toUpperCase())) {
        debugLog(
            '[TX LOG] ❌ DROPPED: Repeater $pathHex ignored by user carpeater filter');
        return TxEchoResult.notEcho;
      }

      // VALIDATION STEP 2.5: Check RSSI (carpeater failsafe)
      if (carpeaterStripped) {
        debugLog('[TX LOG] RSSI check skipped (CARpeater pass-through)');
      } else if (disableRssiFilter) {
        debugLog(
            '[TX LOG] RSSI filter disabled by user, skipping carpeater check');
      } else if (PacketValidator.isCarpeater(metadata.rssi)) {
        debugLog(
            '[TX LOG] ❌ DROPPED: RSSI too strong (${metadata.rssi} ≥ ${PacketValidator.maxRssiThreshold}) '
            '- possible carpeater (RSSI failsafe), repeater=$pathHex');
        debugLog(
            '[TX LOG] onCarpeaterDrop callback is ${onCarpeaterDrop != null ? "SET" : "NULL"}');
        onCarpeaterDrop?.call(
            pathHex, 'RSSI too strong (${metadata.rssi} dBm)');
        return TxEchoResult.notEcho;
      } else {
        debugLog(
            '[TX LOG] ✓ RSSI OK (${metadata.rssi} < ${PacketValidator.maxRssiThreshold})');
      }

      // VALIDATION STEP 3: Channel hash validation
      if (metadata.encryptedPayload.length < 3) {
        debugLog(
            '[TX LOG] Ignoring: payload too short to contain channel hash');
        return TxEchoResult.notEcho;
      }

      final packetChannelHash = metadata.channelHash!;
      debugLog('[TX LOG] Message correlation check: '
          'packet_channel_hash=0x${packetChannelHash.toRadixString(16).padLeft(2, '0')}, '
          'expected=0x${expectedHash?.toRadixString(16).padLeft(2, '0')}');

      if (packetChannelHash != expectedHash) {
        debugLog('[TX LOG] Ignoring: channel hash mismatch');
        return TxEchoResult.notEcho;
      }
      debugLog(
          '[TX LOG] Channel hash match confirmed - this is a message on our channel');

      // VALIDATION STEP 4: Message content verification
      if (channelKey != null && originalPayload != null) {
        debugLog(
            '[MESSAGE_CORRELATION] Channel key available, attempting decryption...');

        try {
          final encryptedMessage = metadata.encryptedPayload.sublist(3);
          final decryptedBytes = CryptoService.decryptChannelMessage(
            encryptedMessage,
            channelKey!,
          );

          if (decryptedBytes.length < 5) {
            debugLog(
                '[MESSAGE_CORRELATION] ❌ REJECT: Decrypted data too short');
            return TxEchoResult.notEcho;
          }
          final messageBytes = decryptedBytes.sublist(5);

          var decryptedMessage =
              utf8.decode(messageBytes, allowMalformed: true);
          decryptedMessage =
              decryptedMessage.replaceAll(RegExp(r'\x00+$'), '').trim();

          debugLog(
              '[MESSAGE_CORRELATION] Decryption successful, comparing content...');
          debugLog(
              '[MESSAGE_CORRELATION] Decrypted: "$decryptedMessage" (${decryptedMessage.length} chars)');
          debugLog(
              '[MESSAGE_CORRELATION] Expected:  "$originalPayload" (${originalPayload.length} chars)');

          final messageMatches = decryptedMessage == originalPayload ||
              decryptedMessage.contains(originalPayload);

          if (!messageMatches) {
            debugLog(
                '[MESSAGE_CORRELATION] ❌ REJECT: Message content mismatch (not an echo of our ping)');
            debugLog(
                '[MESSAGE_CORRELATION] This is a different message on the same channel');
            return TxEchoResult.notEcho;
          }

          if (decryptedMessage == originalPayload) {
            debugLog(
                '[MESSAGE_CORRELATION] ✅ Exact message match confirmed - this is an echo of our ping!');
          } else {
            debugLog(
                '[MESSAGE_CORRELATION] ✅ Message contained in decrypted text (with sender prefix) '
                '- this is an echo of our ping!');
          }
        } catch (e) {
          debugLog(
              '[MESSAGE_CORRELATION] ❌ REJECT: Failed to decrypt message: $e');
          return TxEchoResult.notEcho;
        }
      } else {
        debugWarn(
            '[MESSAGE_CORRELATION] ⚠️ WARNING: Cannot verify message content - channel key not available');
        debugWarn(
            '[MESSAGE_CORRELATION] Proceeding without message content verification (less reliable)');
      }

      // --- Validation passed, store the echo ---

      final targetMap = isMultiHop ? multiHopRepeaters : repeaters;
      final echoType = isMultiHop ? 'multi-hop' : 'direct';

      debugLog(
          '[PING] Repeater echo accepted ($echoType): repeater=$pathHex, SNR=$reportedSnr, '
          'full_path_length=${metadata.pathHashCount}${carpeaterStripped ? ' (CARpeater stripped)' : ''}');

      // Deduplication: check if we already have this repeater
      bool isNewRepeater = false;
      if (targetMap.containsKey(pathHex)) {
        final existing = targetMap[pathHex]!;
        debugLog('[PING] Deduplication ($echoType): path $pathHex already seen '
            '(existing SNR=${existing.snr}, new SNR=$reportedSnr)');

        final shouldUpdate = reportedSnr != null && existing.snr != null
            ? reportedSnr > existing.snr!
            : reportedSnr != null && existing.snr == null;
        if (shouldUpdate) {
          debugLog(
              '[PING] Deduplication decision: updating path $pathHex with better SNR: '
              '${existing.snr} -> $reportedSnr');
          targetMap[pathHex] = RepeaterEcho(
            repeaterId: pathHex,
            snr: reportedSnr,
            rssi: reportedRssi,
            seenCount: existing.seenCount + 1,
            isMultiHop: isMultiHop,
            pathHops: displayHops,
          );
        } else {
          debugLog(
              '[PING] Deduplication decision: keeping existing SNR for path $pathHex '
              '(existing ${existing.snr} >= new $reportedSnr)');
          existing.seenCount++;
        }
      } else {
        isNewRepeater = true;
        debugLog(
            '[PING] Adding new $echoType echo: path=$pathHex, SNR=$reportedSnr, RSSI=$reportedRssi');
        targetMap[pathHex] = RepeaterEcho(
          repeaterId: pathHex,
          snr: reportedSnr,
          rssi: reportedRssi,
          seenCount: 1,
          isMultiHop: isMultiHop,
          pathHops: displayHops,
        );
      }

      // Notify appropriate callback
      final best = targetMap[pathHex]!;
      if (isMultiHop) {
        debugLog('[TX LOG] Invoking onMultiHopEchoReceived callback');
        onMultiHopEchoReceived?.call(
            pathHex, best.snr, best.rssi, displayHops, isNewRepeater);
      } else {
        debugLog(
            '[TX LOG] Invoking onEchoReceived callback (callback=${onEchoReceived != null ? "SET" : "NULL"})');
        if (onEchoReceived != null) {
          onEchoReceived!(pathHex, best.snr, best.rssi, isNewRepeater);
          debugLog('[TX LOG] onEchoReceived callback invoked successfully');
        }
      }

      debugLog('[TX LOG] ✅ Echo tracked successfully ($echoType)');
      return isMultiHop ? TxEchoResult.multiHopEcho : TxEchoResult.directEcho;
    } catch (error, stackTrace) {
      debugError('[TX LOG] Error processing rx_log entry: $error');
      debugError('[TX LOG] Stack trace: $stackTrace');
      return TxEchoResult.notEcho;
    }
  }

  /// Dispose of resources
  void dispose() {
    stopTracking();
  }
}

/// Result of TxTracker.handlePacket()
enum TxEchoResultType { notEcho, directEcho, multiHopEcho }

class TxEchoResult {
  final TxEchoResultType type;

  const TxEchoResult._(this.type);
  static const notEcho = TxEchoResult._(TxEchoResultType.notEcho);
  static const directEcho = TxEchoResult._(TxEchoResultType.directEcho);
  static const multiHopEcho = TxEchoResult._(TxEchoResultType.multiHopEcho);
}

/// Repeater echo data
class RepeaterEcho {
  final String repeaterId; // Hex string
  double? snr; // Best SNR seen (null for CARpeater pass-through)
  int? rssi; // RSSI value (dBm) (null for CARpeater pass-through)
  int seenCount; // Times observed
  final bool isMultiHop;
  final List<String> pathHops;

  RepeaterEcho({
    required this.repeaterId,
    this.snr,
    this.rssi,
    this.seenCount = 1,
    this.isMultiHop = false,
    this.pathHops = const [],
  });
}
