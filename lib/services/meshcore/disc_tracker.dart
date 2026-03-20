import 'dart:async';
import 'dart:typed_data';

import '../../utils/debug_logger_io.dart';
import 'packet_validator.dart';
import 'protocol_constants.dart';

/// Discovery response tracker for efficient repeater mapping
/// Listens for 0x8E PUSH_CODE_CONTROL_DATA packets during discovery window
/// Reference: MeshCore discovery protocol
class DiscTracker {
  bool isListening = false;
  DateTime? startTime;

  /// Map of repeaterId (hex) -> DiscoveredNode (best SNR)
  final Map<String, DiscoveredNode> nodes = {};

  Timer? _windowTimer;

  /// Callback to check if a repeater should be ignored (carpeater filter)
  final bool Function(String repeaterId)? shouldIgnoreRepeater;

  /// Callback for carpeater drops (for quiet error logging)
  /// Called with repeater ID and reason when a discovery response is dropped due to carpeater detection
  void Function(String repeaterId, String reason)? onCarpeaterDrop;

  /// Callback fired when a new node is discovered
  /// Parameters: (node, isNew) - isNew is true for first time seeing this node
  void Function(DiscoveredNode node, bool isNew)? onNodeDiscovered;

  DiscTracker({this.shouldIgnoreRepeater});

  /// Callback fired when discovery window completes
  void Function(List<DiscoveredNode> discoveredNodes)? onWindowComplete;

  /// Start tracking discovery responses
  ///
  /// @param tag - 4-byte random tag (for logging purposes)
  /// @param windowDuration - How long to listen (default 7 seconds)
  void startTracking({
    required Uint8List tag,
    Duration windowDuration = const Duration(seconds: 7),
  }) {
    debugLog('[DISC] Starting discovery tracking');
    debugLog('[DISC] Tag: ${tag.map((b) => b.toRadixString(16).padLeft(2, '0')).join('')}');

    isListening = true;
    startTime = DateTime.now();
    nodes.clear();

    // Start window timer
    _windowTimer?.cancel();
    _windowTimer = Timer(windowDuration, _endWindow);

    debugLog('[DISC] Discovery tracking window started (${windowDuration.inSeconds}s)');
  }

  /// Stop tracking and return collected nodes
  List<DiscoveredNode> stopTracking() {
    debugLog('[DISC] Stopping discovery tracking (discovered ${nodes.length} nodes)');

    final result = nodes.values.toList();

    isListening = false;
    _windowTimer?.cancel();
    _windowTimer = null;

    // Log final results
    if (nodes.isNotEmpty) {
      for (final entry in nodes.entries) {
        debugLog('[DISC] Final: ${entry.key} -> ${entry.value.nodeTypeName}, '
            'localSnr=${entry.value.localSnr}, remoteSnr=${entry.value.remoteSnr}');
      }
    }

    return result;
  }

  /// Handle discovery window completion
  void _endWindow() {
    debugLog('[DISC] Discovery window ended');

    final result = stopTracking();
    onWindowComplete?.call(result);
  }

  /// Handle incoming packet, check if it's a discovery response
  /// Returns true if packet was a valid discovery response
  ///
  /// Discovery response format (0x8E PUSH_CODE_CONTROL_DATA):
  /// Byte 0: Status/padding byte (skip)
  /// Byte 1: Flags (upper 4 bits = 0x9 DISCOVER_RESP, lower 4 bits = node type)
  /// Byte 2: Remote SNR (signed byte, divide by 4 for dB)
  /// Bytes 3-6: Tag (4 bytes)
  /// Bytes 7-38: Public key (32 bytes)
  bool handlePacket(Uint8List rawBytes, double localSnr, int localRssi) {
    if (!isListening) return false;

    try {
      // Minimum packet length: 1 (status) + 1 (flags) + 1 (remoteSnr) + 4 (tag) + 32 (pubkey) = 39 bytes
      if (rawBytes.length < 39) {
        debugLog('[DISC] Packet too short: ${rawBytes.length} bytes (need 39)');
        return false;
      }

      // Skip first byte (status/padding), flags are at byte 1
      final flags = rawBytes[1];
      final upperNibble = flags & 0xF0;
      final lowerNibble = flags & 0x0F;

      // Check if this is a discovery response (upper nibble = 0x90)
      if (upperNibble != DiscoveryConstants.discoverRespFlag) {
        debugLog('[DISC] Not a discovery response: flags=0x${flags.toRadixString(16).padLeft(2, '0')}');
        return false;
      }

      // Check node type (lower nibble must be REPEATER=0x01 or ROOM=0x02)
      if (lowerNibble != DiscoveryConstants.nodeTypeRepeater &&
          lowerNibble != DiscoveryConstants.nodeTypeRoom) {
        debugLog('[DISC] Ignoring node type: 0x${lowerNibble.toRadixString(16)}');
        return false;
      }

      // Extract remote SNR (signed byte at offset 2, divide by 4 for dB)
      final remoteSnrRaw = rawBytes[2].toSigned(8);
      final remoteSnr = remoteSnrRaw / 4.0;

      // Skip tag (bytes 3-6) - we accept any response during the window

      // Extract public key (bytes 7-38)
      final pubkey = rawBytes.sublist(7, 39);
      final pubkeyHex = pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join('').toUpperCase();

      // Get repeater ID (first 2 hex chars = first byte)
      final repeaterId = pubkeyHex.substring(0, 2);

      // Check if this repeater should be ignored (user carpeater filter)
      if (shouldIgnoreRepeater != null && shouldIgnoreRepeater!(repeaterId)) {
        debugLog('[DISC] Ignoring repeater $repeaterId (user carpeater filter)');
        return false;
      }

      // Check RSSI (carpeater failsafe)
      if (PacketValidator.isCarpeater(localRssi)) {
        debugLog('[DISC] ❌ DROPPED: RSSI too strong ($localRssi ≥ ${PacketValidator.maxRssiThreshold}) '
            '- possible carpeater, repeater=$repeaterId');
        onCarpeaterDrop?.call(repeaterId, 'RSSI too strong ($localRssi dBm)');
        return false;
      }

      final nodeType = lowerNibble == DiscoveryConstants.nodeTypeRepeater ? 'REPEATER' : 'ROOM';

      debugLog('[DISC] Received response from $repeaterId ($nodeType): '
          'localSnr=${localSnr.toStringAsFixed(2)}, remoteSnr=${remoteSnr.toStringAsFixed(2)}, '
          'localRssi=$localRssi');

      // Check if we already have this node
      bool isNew = false;
      if (nodes.containsKey(repeaterId)) {
        final existing = nodes[repeaterId]!;
        // Keep the best (highest) local SNR
        if (localSnr > existing.localSnr) {
          debugLog('[DISC] Updating $repeaterId with better localSnr: '
              '${existing.localSnr.toStringAsFixed(2)} -> ${localSnr.toStringAsFixed(2)}');
          nodes[repeaterId] = DiscoveredNode(
            repeaterId: repeaterId,
            nodeType: lowerNibble,
            localSnr: localSnr,
            localRssi: localRssi,
            remoteSnr: remoteSnr,
            pubkeyFull: pubkeyHex,
          );
        }
      } else {
        // New node
        isNew = true;
        debugLog('[DISC] Adding new node: $repeaterId ($nodeType)');
        nodes[repeaterId] = DiscoveredNode(
          repeaterId: repeaterId,
          nodeType: lowerNibble,
          localSnr: localSnr,
          localRssi: localRssi,
          remoteSnr: remoteSnr,
          pubkeyFull: pubkeyHex,
        );
      }

      // Notify callback
      onNodeDiscovered?.call(nodes[repeaterId]!, isNew);

      return true;
    } catch (e, stackTrace) {
      debugError('[DISC] Error processing discovery response: $e');
      debugError('[DISC] Stack trace: $stackTrace');
      return false;
    }
  }

  /// Dispose of resources
  void dispose() {
    stopTracking();
  }
}

/// Discovered node data
class DiscoveredNode {
  final String repeaterId;     // First 2 hex chars of pubkey (e.g., "77", "4E")
  final int nodeType;          // 0x01 = REPEATER, 0x02 = ROOM
  final double localSnr;       // SNR as seen by local device (dB)
  final int localRssi;         // RSSI as seen by local device (dBm)
  final double remoteSnr;      // SNR as seen by remote node (dB)
  final String pubkeyFull;     // Full 32-byte public key as hex (local only, not sent to API)

  DiscoveredNode({
    required this.repeaterId,
    required this.nodeType,
    required this.localSnr,
    required this.localRssi,
    required this.remoteSnr,
    required this.pubkeyFull,
  });

  /// Get node type as display string
  String get nodeTypeName => nodeType == DiscoveryConstants.nodeTypeRepeater ? 'REPEATER' : 'ROOM';

  /// Get short display label: "(R)" for REPEATER, "(RM)" for ROOM
  String get nodeTypeLabel => nodeType == DiscoveryConstants.nodeTypeRepeater ? '(R)' : '(RM)';
}
