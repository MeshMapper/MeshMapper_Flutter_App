# Unified RX Handler Implementation Plan

## Overview

The Unified RX Handler is the core system for processing all incoming BLE packets from the MeshCore device. It routes packets to either TX tracking (for repeater echo detection during ping windows) or RX logging (for passive mesh observations).

**Reference**: `handleUnifiedRxLogEvent()` in MeshMapper_WebClient/content/wardrive.js (lines 3773-3810)

---

## Architecture

### High-Level Flow

```
BLE LogRxData Event
        ↓
Parse Packet Metadata (ONCE)
        ↓
   ┌────┴────┐
   ↓         ↓
TX Track?  RX Log?
(echo)    (passive)
   ↓         ↓
Validate  Validate
   ↓         ↓
 Track    Buffer
   ↓         ↓
  UI      API Queue
```

### Lifecycle

- **Starts**: Immediately after channel setup during connect (Step 7)
- **Stops**: Only on disconnect
- **Always-On**: Never stops during mode changes or page visibility

### Key Principle

Parse packet metadata **once** at entry point, then route to specialized handlers. No header filtering at entry - accept ALL packets.

---

## Components to Implement

### 1. Packet Metadata Parser

**File**: `lib/services/meshcore/packet_metadata.dart` (new)

**Purpose**: Extract structured metadata from raw BLE packet bytes

**Fields**:
```dart
class PacketMetadata {
  final int header;                    // Packet type (0x11 = GROUP_TEXT, 0x21 = ADVERT)
  final int pathLength;                // Number of hops
  final Uint8List path;                // Raw path bytes
  final int firstHop;                  // First repeater ID (for TX tracking)
  final int lastHop;                   // Last repeater ID (for RX logging)
  final int snr;                       // Signal-to-noise ratio (dB)
  final int rssi;                      // Received signal strength (dBm)
  final Uint8List encryptedPayload;   // Message payload (encrypted)
  final Uint8List raw;                 // Original raw bytes
}
```

**Methods**:
- `PacketMetadata.fromLogRxData(Map<String, dynamic> data)` - Parse from BLE event
- `int getChannelHash()` - Extract channel hash from payload (first byte)
- `bool isGroupText()` - Check if packet is GROUP_TEXT (0x11)
- `bool isAdvert()` - Check if packet is ADVERT (0x21)

**Reference**: `parseRxPacketMetadata()` in wardrive.js (lines 3259-3335)

---

### 2. Unified RX Handler Service

**File**: `lib/services/meshcore/unified_rx_handler.dart` (new)

**Purpose**: Route incoming packets to TX or RX handlers

**State**:
```dart
class UnifiedRxHandler {
  bool _isListening = false;          // Handler active
  bool _isWardriving = false;         // RX logging enabled
  StreamSubscription? _subscription;  // BLE event subscription
  
  final TxTracker _txTracker;         // TX echo tracking
  final RxLogger _rxLogger;           // Passive RX logging
  final CryptoService _crypto;
}
```

**Methods**:
- `void start(MeshCoreConnection connection)` - Idempotent start
- `void stop()` - Unsubscribe from BLE events
- `void enableWardriving()` - Enable RX logging
- `void disableWardriving()` - Disable RX logging
- `Future<void> _handleLogRxData(Map<String, dynamic> data)` - Main entry point

**Core Logic**:
```dart
Future<void> _handleLogRxData(Map data) async {
  // 1. Parse metadata ONCE
  final metadata = PacketMetadata.fromLogRxData(data);
  
  debugLog('[UNIFIED RX] Packet: header=0x${metadata.header.toRadixString(16)}, pathLength=${metadata.pathLength}');
  
  // 2. Route to TX tracking if active (7s echo window)
  if (_txTracker.isListening) {
    final wasEcho = await _txTracker.handlePacket(metadata);
    if (wasEcho) return;  // Don't process as RX if it was our echo
  }
  
  // 3. Route to RX logging if wardriving active
  if (_isWardriving) {
    await _rxLogger.handlePacket(metadata);
  }
  
  // If neither active, packet ignored (but listener stays on)
}
```

**Reference**: `handleUnifiedRxLogEvent()` in wardrive.js (lines 3773-3810)

---

### 3. TX Tracker (Repeater Echo Detection)

**File**: `lib/services/meshcore/tx_tracker.dart` (new)

**Purpose**: Track repeater echoes during 7-second window after sending ping

**State**:
```dart
class TxTracker {
  bool isListening = false;                    // Window active
  DateTime? sentTimestamp;                     // When ping sent
  String? sentPayload;                         // Message text sent
  int? channelIndex;                           // Channel used
  Map<String, RepeaterEcho> repeaters = {};   // repeaterId -> echo data
  Timer? windowTimer;                          // 7s timeout
}

class RepeaterEcho {
  final String repeaterId;   // Hex string
  int snr;                   // Best SNR seen
  int seenCount;             // Times observed
}
```

**Methods**:
- `void startTracking(String payload, int channelIdx)` - Begin 7s window
- `void stopTracking()` - End window, clear state
- `Future<bool> handlePacket(PacketMetadata metadata)` - Returns true if echo

**Validation Steps** (must pass ALL):
1. **Header check**: Must be GROUP_TEXT (0x11)
2. **RSSI check**: Must be < -30 dBm (carpeater failsafe)
3. **Channel hash check**: First payload byte matches #wardriving hash
4. **Message check**: Decrypt and verify matches sent payload
5. **Path check**: Path length > 0 (must route via repeater, not direct)

**Deduplication**:
- Key by first hop only (ignore full path)
- Keep highest SNR per repeater
- Increment seen count on duplicates

**Reference**: `handleTxLogging()` in wardrive.js (lines 3561-3710)

---

### 4. RX Logger (Passive Observations)

**File**: `lib/services/meshcore/rx_logger.dart` (new)

**Purpose**: Log all valid mesh packets heard via repeaters

**State**:
```dart
class RxLogger {
  int dropCount = 0;                       // Invalid packets
  int carpeaterIgnoreCount = 0;            // User-specified drops
  int carpeaterRssiCount = 0;              // RSSI failsafe drops
  List<RxLogEntry> entries = [];           // UI log (max 100)
}

class RxLogEntry {
  final String repeaterId;    // Last hop (hex)
  final int snr;
  final int rssi;
  final int pathLength;
  final double lat;
  final double lon;
  final DateTime timestamp;
}
```

**Methods**:
- `Future<void> handlePacket(PacketMetadata metadata)`
- `Future<ValidationResult> _validatePacket(metadata)` - Filter pipeline
- `void _addEntry(...)` - Add to UI log
- `void _bufferForApi(...)` - Queue for API post

**Validation Pipeline**:
1. **Path check**: Path length > 0 (no direct transmissions)
2. **GPS check**: Must have valid GPS fix
3. **Channel check**: Hash must match allowed channels (#wardriving, #testing, etc.)
4. **Decrypt check**: Must decrypt successfully
5. **Printable check**: 90% of chars must be printable
6. **RSSI check**: Must be < -30 dBm (carpeater failsafe)
7. **User filter**: Check carpeater ignore list

**RX Batch Buffer** (for API):
- Key by repeater ID
- Buffer observations with GPS coordinates
- Flush triggers:
  - 25m movement from buffer start location
  - 30 seconds since buffer created
- Keep best SNR per repeater in batch

**Reference**: `handleRxLogging()` in wardrive.js (lines 3842-3892)

---

### 5. Packet Validator

**File**: `lib/services/meshcore/packet_validator.dart` (new)

**Purpose**: Shared validation logic for both TX and RX paths

**Methods**:

```dart
class PacketValidator {
  /// Check if RSSI indicates carpeater (too strong signal)
  static bool isCarpeater(int rssi) {
    return rssi >= -30;  // MAX_RX_RSSI_THRESHOLD
  }
  
  /// Validate channel hash matches allowed channels
  static Future<ValidationResult> validateChannelHash(
    PacketMetadata metadata,
    Map<int, ChannelInfo> allowedChannels
  );
  
  /// Decrypt and validate message content
  static Future<String?> decryptAndValidate(
    Uint8List encryptedPayload,
    Uint8List channelKey
  );
  
  /// Check printable character ratio
  static bool isPrintableText(String text) {
    final printableCount = text.runes.where((c) => 
      c >= 32 && c <= 126  // Printable ASCII
    ).length;
    return (printableCount / text.length) >= 0.9;
  }
  
  /// Parse ADVERT packet name
  static ValidationResult validateAdvert(Uint8List payload);
}
```

**Reference**: `validateRxPacket()` in wardrive.js (lines 3419-3515)

---

### 6. RX Batch Buffer

**File**: `lib/services/meshcore/rx_batch_buffer.dart` (new)

**Purpose**: Buffer RX observations per repeater, flush to API queue on triggers

**State**:
```dart
class RxBatchBuffer {
  Map<String, RepeaterBuffer> _buffers = {};  // repeaterId -> buffer
}

class RepeaterBuffer {
  final String repeaterId;
  Position firstLocation;        // GPS at buffer start
  RxObservation bestObservation; // Best SNR seen
  DateTime bufferedSince;        // Buffer creation time
  DateTime lastFlushed;          // Last API flush
  Timer? flushTimer;             // 30s timeout
}

class RxObservation {
  final int snr;
  final int rssi;
  final int pathLength;
  final int header;
  final Position position;
  final DateTime timestamp;
}
```

**Methods**:
- `void addObservation(String repeaterId, RxObservation obs, Position pos)`
- `void _checkFlushTriggers(String repeaterId, Position currentPos)`
- `Future<void> _flushBuffer(String repeaterId)`

**Flush Triggers**:
1. **Distance**: 25m movement from `firstLocation`
2. **Timeout**: 30 seconds since `bufferedSince`

**API Payload**:
```dart
{
  "type": "RX",
  "lat": firstLocation.latitude,
  "lon": firstLocation.longitude,
  "who": deviceId,
  "power": 0,  // RX has no power
  "heard": repeaterId,
  "session_id": sessionId,
  "iatacode": "YOW"
}
```

**Reference**: `handleRxBatching()` in wardrive.js (lines 4142-4235)

---

## Implementation Order

### Phase 1: Foundation (1-2 hours)
1. Create `PacketMetadata` class with parser
2. Add unit tests for packet parsing
3. Create `PacketValidator` with helper methods

### Phase 2: TX Tracker (2-3 hours)
1. Create `TxTracker` class
2. Implement 7-second window management
3. Add validation pipeline (header, RSSI, channel, message, path)
4. Implement deduplication logic
5. Connect to `PingService.sendTxPing()`

### Phase 3: RX Logger (2-3 hours)
1. Create `RxLogger` class
2. Implement validation pipeline
3. Create `RxBatchBuffer` for API queueing
4. Add flush triggers (distance, timeout)
5. Connect to `ApiQueueService`

### Phase 4: Unified Handler (1 hour)
1. Create `UnifiedRxHandler` service
2. Wire up BLE event subscription
3. Implement routing logic
4. Add to connection workflow (start after Step 7)
5. Add to disconnect cleanup

### Phase 5: Testing & Polish (1-2 hours)
1. Test with real hardware
2. Verify TX echo detection
3. Verify RX logging and batching
4. Verify API queue integration
5. Add debug logging throughout

**Total Estimate**: 7-11 hours

---

## Integration Points

### Connection Workflow
```dart
// In connection.dart, after Step 7 (channel setup):
_unifiedRxHandler.start(this);
debugLog('[CONN] Unified RX handler started');
```

### Disconnect Cleanup
```dart
// In disconnect():
_unifiedRxHandler.stop();
```

### Ping Service
```dart
// In sendTxPing(), after sending ping:
_txTracker.startTracking(payload, channelIndex);

// Start 7-second window timer:
_txWindowTimer = Timer(Duration(seconds: 7), () {
  _txTracker.stopTracking();
  debugLog('[PING] TX tracking window ended');
});
```

### Auto Mode
```dart
// In toggleAutoPing():
if (rxOnly) {
  _unifiedRxHandler.enableWardriving();
} else {
  _unifiedRxHandler.enableWardriving();  // Both modes log RX
}
```

---

## Testing Strategy

### Unit Tests
- `packet_metadata_test.dart` - Parse various packet types
- `packet_validator_test.dart` - Validation logic
- `tx_tracker_test.dart` - Echo detection, deduplication
- `rx_logger_test.dart` - Validation, buffering
- `rx_batch_buffer_test.dart` - Flush triggers

### Integration Tests
- Mock BLE events with real packet bytes
- Verify routing to TX vs RX paths
- Verify API queue population
- Test edge cases (direct transmissions, invalid packets)

### Manual Testing
- Connect to real MeshCore device
- Send manual ping, verify echo detection
- Enable RX Auto, verify passive logging
- Check API queue for TX and RX entries
- Verify session logs populate correctly

---

## Key Differences from WebClient

### Simplified Areas
1. **No session logs UI** (defer to future phase)
2. **No carpeater user ignore list** (just RSSI failsafe)
3. **No debug mode repeater metadata** (just basic tracking)
4. **No remote debug logging** (local only)

### Enhanced Areas
1. **Persistent API queue** (Hive vs in-memory)
2. **Better state management** (ChangeNotifier vs globals)
3. **Type safety** (Dart vs JavaScript)

---

## Future Enhancements

### Phase 2 Additions
- Session log UI (expandable bottom sheet)
- Carpeater user ignore list
- CSV export for RX logs
- Advanced packet filtering options

### Phase 3 Additions
- Multi-channel monitoring (#testing, #ottawa, etc.)
- ADVERT packet tracking (node discovery)
- Path visualization (multi-hop routes)
- SNR heatmap overlay

---

## References

### WebClient Files
- `content/wardrive.js` - Main implementation
  - Lines 3259-3335: `parseRxPacketMetadata()`
  - Lines 3419-3515: `validateRxPacket()`
  - Lines 3561-3710: `handleTxLogging()`
  - Lines 3773-3810: `handleUnifiedRxLogEvent()`
  - Lines 3842-3892: `handleRxLogging()`
  - Lines 4142-4235: `handleRxBatching()`

### Documentation
- `docs/FLOW_WARDRIVE_RX_DIAGRAM.md` - Visual flow
- `docs/PING_WORKFLOW.md` - TX/RX lifecycle

---

## Dependencies

### Existing Services
- `MeshCoreConnection` - BLE events (LogRxData)
- `CryptoService` - Message decryption
- `ChannelService` - Channel hash matching
- `GpsService` - Position for RX logging
- `ApiQueueService` - Batch API posting
- `PingService` - TX tracking coordination

### New Packages
- None required - uses existing crypto, geolocator

---

## Success Criteria

✅ **Functional**:
1. TX tracker detects repeater echoes during 7s window
2. RX logger captures passive observations
3. Validation pipeline filters invalid packets
4. API queue receives TX and RX entries
5. No memory leaks (buffers cleared properly)

✅ **Performance**:
1. Packet processing < 50ms per packet
2. No UI lag during high packet volume
3. Buffer memory bounded (max 100 entries)

✅ **Reliability**:
1. Handler survives page hidden/visible cycles
2. Idempotent start (safe to call multiple times)
3. Graceful handling of decrypt failures
4. No crashes on malformed packets
