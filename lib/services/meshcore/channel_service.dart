import 'dart:typed_data';

import '../../utils/debug_logger_io.dart';
import 'connection.dart';
import 'crypto_service.dart';
import 'packet_parser.dart';

/// Channel management for MeshCore wardriving
/// Handles #wardriving channel creation, deletion, and lookup
class ChannelService {
  /// Pre-computed channel keys and hashes for allowed RX channels
  /// These are channels we monitor for passive RX wardriving
  static final Map<String, _ChannelData> _allowedChannels = {};

  /// Wardriving channel name
  static const String wardrivingChannelName = '#wardriving';

  /// Initialize ONLY Public channel (app startup)
  /// Regional channels are added after auth via setRegionalChannels()
  static Future<void> initializePublicChannel() async {
    debugLog('[CHANNEL] Initializing Public channel only');
    _allowedChannels.clear();

    final publicKey = CryptoService.publicChannelFixedKey;
    final publicHash = CryptoService.computeChannelHash(publicKey);
    _allowedChannels['Public'] = _ChannelData(key: publicKey, hash: publicHash);
    debugLog('[CHANNEL] Public channel initialized (hash=$publicHash)');
  }

  /// Set regional channels from API (after auth)
  /// Always includes #wardriving for TX, plus channels from API response
  static Future<void> setRegionalChannels(List<String> channelNames) async {
    debugLog('[CHANNEL] Setting regional channels: $channelNames');

    // Keep Public, clear regional
    _allowedChannels.removeWhere((key, _) => key != 'Public');

    // Always add #wardriving (required for TX)
    final wardrivingKey = CryptoService.getChannelKey(wardrivingChannelName);
    final wardrivingHash = CryptoService.computeChannelHash(wardrivingKey);
    _allowedChannels[wardrivingChannelName] =
        _ChannelData(key: wardrivingKey, hash: wardrivingHash);
    debugLog('[CHANNEL] Added: $wardrivingChannelName -> hash=$wardrivingHash');

    // Add regional channels from API
    for (final name in channelNames) {
      final channelName = name.toLowerCase() == 'public'
          ? 'Public'
          : name.startsWith('#')
              ? name
              : '#$name';

      // Skip if already added
      if (_allowedChannels.containsKey(channelName)) continue;

      final key = CryptoService.getChannelKey(channelName);
      final hash = CryptoService.computeChannelHash(key);
      _allowedChannels[channelName] = _ChannelData(key: key, hash: hash);
      debugLog('[CHANNEL] Added: $channelName -> hash=$hash');
    }

    debugLog('[CHANNEL] Total channels: ${_allowedChannels.length}');
  }

  /// Clear regional channels (disconnect)
  /// Keeps only Public channel
  static void clearRegionalChannels() {
    debugLog('[CHANNEL] Clearing regional channels');
    _allowedChannels.removeWhere((key, _) => key != 'Public');
  }

  /// Get regional channel names (for UI display)
  /// Excludes Public and #wardriving (those are always present)
  static List<String> getRegionalChannelNames() {
    return _allowedChannels.keys
        .where((name) => name != 'Public' && name != wardrivingChannelName)
        .toList();
  }

  /// Get channel key for a known channel
  static Uint8List? getChannelKey(String channelName) {
    return _allowedChannels[channelName]?.key;
  }

  /// Get channel hash for a known channel
  static int? getChannelHash(String channelName) {
    return _allowedChannels[channelName]?.hash;
  }

  /// Check if a channel hash matches any allowed channel
  static String? findChannelByHash(int hash) {
    for (final entry in _allowedChannels.entries) {
      if (entry.value.hash == hash) {
        return entry.key;
      }
    }
    return null;
  }

  /// Get all allowed channels for RX validation
  /// Returns a map of channel hash -> channel info for use with PacketValidator
  static Map<int, ({String channelName, Uint8List key, int hash})>
      getAllowedChannelsForValidator() {
    final result = <int, ({String channelName, Uint8List key, int hash})>{};
    for (final entry in _allowedChannels.entries) {
      result[entry.value.hash] = (
        channelName: entry.key,
        key: entry.value.key,
        hash: entry.value.hash,
      );
    }
    return result;
  }

  /// How long to wait before reading a failed channel slot a second time.
  static const Duration slotRetryDelay = Duration(milliseconds: 200);

  /// Highest slot index the command byte can carry. A radio that answered
  /// every index without ever saying ERR_CODE_NOT_FOUND would otherwise keep
  /// the scan going forever.
  static const int _maxSlotIndex = 255;

  /// Shown when the slot list could not be read in full. Kept clear of the
  /// words "timeout" and "timed out" so the connection screen shows it as is.
  static const String incompleteScanMessage =
      'Could not read the channel list from your radio. Please reconnect.';

  /// Shown when the radio answers the channel create with ERR.
  static const String createFailedMessage =
      'Your radio could not create the #wardriving channel. Please reconnect.';

  /// Ensure #wardriving channel exists (find or create)
  ///
  /// Reads the advertised number of slots. MeshCore and ZephCore report the
  /// same capacity field but return different errors beyond that boundary.
  /// Without a usable capacity, falls back to ERR_CODE_NOT_FOUND as the end.
  /// An empty slot is a normal reply with an empty name. Any failure within
  /// the advertised range is read once more; a second failure fails setup,
  /// because creating a channel after an incomplete scan could duplicate a
  /// #wardriving sitting past the failed slot.
  ///
  /// A slot holding the #wardriving key under another name counts as the
  /// existing channel and is used as is (never renamed).
  ///
  /// @param connection - Active MeshCore connection
  /// @returns ChannelInfo for the wardriving channel
  static Future<ChannelInfo> ensureWardrivingChannel(
      MeshCoreConnection connection) async {
    debugLog('[CHANNEL] Looking up channel: $wardrivingChannelName');
    final wardrivingKey = CryptoService.deriveChannelKey(wardrivingChannelName);

    final maxChannels = connection.deviceInfo?.maxChannels;
    int? firstEmptySlot;
    var channelIdx = 0;
    while (maxChannels == null || channelIdx < maxChannels) {
      if (channelIdx > _maxSlotIndex) {
        debugError('[CHANNEL] Radio answered past slot $_maxSlotIndex without '
            'ending the list, not creating a channel');
        throw Exception(incompleteScanMessage);
      }

      final ChannelInfo channel;
      try {
        final read = await _readSlot(connection, channelIdx,
            allowEndOfList: maxChannels == null);
        if (read == null) {
          // ERR_CODE_NOT_FOUND: the radio's end of list.
          debugLog('[CHANNEL] End of channel list at index $channelIdx');
          break;
        }
        channel = read;
      } on _SlotReadFailed {
        debugError('[CHANNEL] Slot $channelIdx failed twice, channel scan '
            'incomplete, not creating a channel');
        throw Exception(incompleteScanMessage);
      }

      if (channel.name == wardrivingChannelName) {
        debugLog(
            '[CHANNEL] Found existing channel at index ${channel.channelIndex} (scanned ${channelIdx + 1} channels)');
        return channel;
      }

      if (channel.name.isNotEmpty && _sameKey(channel.secret, wardrivingKey)) {
        debugLog('[CHANNEL] Slot $channelIdx "${channel.name}" holds the '
            '$wardrivingChannelName key, using it as the wardriving channel');
        return channel;
      }

      if (channel.name.isEmpty && firstEmptySlot == null) {
        // The reply's own index, never the loop counter: it is the slot the
        // radio actually described.
        firstEmptySlot = channel.channelIndex;
        debugLog('[CHANNEL] Found empty slot at index $firstEmptySlot');
        // Keep scanning: an orphaned #wardriving left by an unexpected
        // disconnect may sit further down, and must not be duplicated.
      }

      channelIdx++;
    }

    if (maxChannels != null) {
      debugLog('[CHANNEL] Read all $maxChannels advertised channel slots');
    }

    if (firstEmptySlot == null) {
      debugError(
          '[CHANNEL] No empty channel slots found in $channelIdx channels');
      throw Exception(
        'No empty channel slots available. Please free a channel slot on your companion first.',
      );
    }

    debugLog(
        '[CHANNEL] #wardriving not found in $channelIdx channels, creating at index $firstEmptySlot');
    try {
      await connection.setChannel(
          firstEmptySlot, wardrivingChannelName, wardrivingKey);
    } on CommandErrorException catch (e) {
      debugError('[CHANNEL] Radio refused to create $wardrivingChannelName '
          'at index $firstEmptySlot: $e');
      throw Exception(createFailedMessage);
    }
    debugLog(
        '[CHANNEL] Channel $wardrivingChannelName created successfully at index $firstEmptySlot');

    return ChannelInfo(
      channelIndex: firstEmptySlot,
      name: wardrivingChannelName,
      secret: wardrivingKey,
    );
  }

  /// Reads one slot, retrying once after [slotRetryDelay].
  ///
  /// Without advertised capacity, ERR_CODE_NOT_FOUND ends the list. Within
  /// advertised capacity it is a failed read, just like any other error.
  /// Throws [_SlotReadFailed] when both attempts fail.
  static Future<ChannelInfo?> _readSlot(
      MeshCoreConnection connection, int channelIdx,
      {required bool allowEndOfList}) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final channel = await connection.getChannel(channelIdx);
        if (channel.channelIndex == channelIdx) return channel;
        debugWarn('[CHANNEL] Slot $channelIdx read answered for slot '
            '${channel.channelIndex} (attempt $attempt)');
      } on CommandErrorException catch (e) {
        if (allowEndOfList && e.isNotFound) return null;
        debugWarn(
            '[CHANNEL] Slot $channelIdx read failed (attempt $attempt): $e');
      } catch (e) {
        debugWarn(
            '[CHANNEL] Slot $channelIdx read failed (attempt $attempt): $e');
      }
      if (attempt == 1) {
        debugLog('[CHANNEL] Retrying slot $channelIdx in '
            '${slotRetryDelay.inMilliseconds} ms');
        await Future<void>.delayed(slotRetryDelay);
      }
    }
    throw const _SlotReadFailed();
  }

  static bool _sameKey(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Delete #wardriving channel on disconnect
  ///
  /// @param connection - Active MeshCore connection
  /// @param channelIdx - Index of the channel to delete
  static Future<void> deleteWardrivingChannel(
    MeshCoreConnection connection,
    int channelIdx,
  ) async {
    try {
      debugLog('[CHANNEL] Deleting channel at index $channelIdx');
      await connection.deleteChannel(channelIdx);
      debugLog('[CHANNEL] Channel deleted successfully');
    } catch (e) {
      debugError('[CHANNEL] Failed to delete channel: $e');
      // Don't throw - disconnection should proceed even if channel deletion fails
    }
  }
}

/// A channel slot that could not be read on either attempt.
class _SlotReadFailed implements Exception {
  const _SlotReadFailed();
}

/// Internal class to store pre-computed channel data
class _ChannelData {
  final Uint8List key;
  final int hash;

  _ChannelData({required this.key, required this.hash});
}
