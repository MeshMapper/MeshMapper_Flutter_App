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
    _allowedChannels[wardrivingChannelName] = _ChannelData(key: wardrivingKey, hash: wardrivingHash);
    debugLog('[CHANNEL] Added: $wardrivingChannelName -> hash=$wardrivingHash');

    // Add regional channels from API
    for (final name in channelNames) {
      final channelName = name.toLowerCase() == 'public' ? 'Public' :
                          name.startsWith('#') ? name : '#$name';

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

  /// @deprecated Use initializePublicChannel() instead
  /// Legacy initialize method - kept for backward compatibility
  static Future<void> initialize() async {
    debugLog('[CHANNEL] Legacy initialize called - forwarding to initializePublicChannel');
    await initializePublicChannel();
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
  static Map<int, ({String channelName, Uint8List key, int hash})> getAllowedChannelsForValidator() {
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

  /// Create #wardriving channel on the device
  ///
  /// Finds first empty channel slot and creates the channel with SHA-256 key
  ///
  /// @param connection - Active MeshCore connection
  /// @returns ChannelInfo for the created channel
  /// @throws Exception if no empty slots or creation fails
  static Future<ChannelInfo> createWardrivingChannel(MeshCoreConnection connection) async {
    debugLog('[CHANNEL] Attempting to create channel: $wardrivingChannelName');

    // Get all channels
    final channels = await connection.getChannels();
    debugLog('[CHANNEL] Retrieved ${channels.length} channels');

    // Find first empty channel slot
    int? emptyIdx;
    for (var i = 0; i < channels.length; i++) {
      if (channels[i].name.isEmpty) {
        emptyIdx = i;
        debugLog('[CHANNEL] Found empty channel slot at index: $emptyIdx');
        break;
      }
    }

    // Throw error if no free slots
    if (emptyIdx == null) {
      debugError('[CHANNEL] No empty channel slots available');
      throw Exception(
        'No empty channel slots available. Please free a channel slot on your companion first.',
      );
    }

    // Derive the channel key from the channel name
    final channelKey = CryptoService.deriveChannelKey(wardrivingChannelName);

    // Create the channel
    debugLog('[CHANNEL] Creating channel $wardrivingChannelName at index $emptyIdx');
    await connection.setChannel(emptyIdx, wardrivingChannelName, channelKey);
    debugLog('[CHANNEL] Channel $wardrivingChannelName created successfully at index $emptyIdx');

    // Return channel info
    return ChannelInfo(
      channelIndex: emptyIdx,
      name: wardrivingChannelName,
      secret: channelKey,
    );
  }

  /// Ensure #wardriving channel exists (find or create)
  ///
  /// Optimized to scan channels one-by-one and stop early when found
  ///
  /// @param connection - Active MeshCore connection
  /// @returns ChannelInfo for the wardriving channel
  static Future<ChannelInfo> ensureWardrivingChannel(MeshCoreConnection connection) async {
    debugLog('[CHANNEL] Looking up channel: $wardrivingChannelName');

    // Scan channels one-by-one to find #wardriving or first empty slot
    // This is much faster than scanning all 40+ channels
    int? firstEmptySlot;
    var channelIdx = 0;

    while (true) {
      try {
        // Retry mechanism for first channel (sometimes gets spurious OK responses)
        ChannelInfo? channel;
        if (channelIdx == 0) {
          // First channel might timeout due to spurious OK responses
          // Retry once if it fails
          try {
            channel = await connection.getChannel(channelIdx);
          } catch (e) {
            debugLog('[CHANNEL] First getChannel failed (likely spurious OK), retrying: $e');
            await Future.delayed(const Duration(milliseconds: 100));
            channel = await connection.getChannel(channelIdx);
          }
        } else {
          channel = await connection.getChannel(channelIdx);
        }

        // Found existing #wardriving channel - return immediately!
        if (channel.name == wardrivingChannelName) {
          debugLog('[CHANNEL] Found existing channel at index ${channel.channelIndex} (scanned ${channelIdx + 1} channels)');
          return channel;
        }

        // Track first empty slot for creating channel if needed
        if (channel.name.isEmpty && firstEmptySlot == null) {
          firstEmptySlot = channelIdx;
          debugLog('[CHANNEL] Found empty slot at index $firstEmptySlot');
          // Continue scanning 3 more channels to check if #wardriving exists elsewhere
          // This balances speed vs thoroughness
        } else if (firstEmptySlot != null && channelIdx >= firstEmptySlot + 3) {
          // We found empty slot and scanned 3 more channels - stop here
          debugLog('[CHANNEL] Stopping scan after ${channelIdx + 1} channels (checked 3 channels after empty slot)');
          break;
        }

        channelIdx++;
      } catch (e) {
        // Error getting channel (likely reached end)
        debugLog('[CHANNEL] Scan stopped at channel $channelIdx (error: $e)');
        break;
      }
    }

    // #wardriving not found - create it at first empty slot
    if (firstEmptySlot == null) {
      debugError('[CHANNEL] No empty channel slots found in first $channelIdx channels');
      throw Exception(
        'No empty channel slots available. Please free a channel slot on your companion first.',
      );
    }

    debugLog('[CHANNEL] #wardriving not found, creating at index $firstEmptySlot');
    final channelKey = CryptoService.deriveChannelKey(wardrivingChannelName);
    await connection.setChannel(firstEmptySlot, wardrivingChannelName, channelKey);
    debugLog('[CHANNEL] Channel $wardrivingChannelName created successfully at index $firstEmptySlot');

    return ChannelInfo(
      channelIndex: firstEmptySlot,
      name: wardrivingChannelName,
      secret: channelKey,
    );
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

/// Internal class to store pre-computed channel data
class _ChannelData {
  final Uint8List key;
  final int hash;

  _ChannelData({required this.key, required this.hash});
}
