# Development Guide

This document provides comprehensive architecture documentation and development guidance for the MeshMapper Flutter App.

## Project Overview

MeshMapper Flutter App is a cross-platform wardriving application for MeshCore mesh network devices. It's a Flutter port of the [MeshMapper WebClient](https://github.com/MeshMapper/MeshMapper_WebClient), supporting Android, iOS, and Web (Chrome/Edge only).

**Purpose**: Connect to MeshCore devices via Bluetooth Low Energy, send GPS-tagged pings to the `#wardriving` channel, track repeater echoes, and post coverage data to the MeshMapper API for community mesh mapping.

**Tech Stack**: Flutter 3.2.0+, Dart 3.2.0+, Hive for local storage, Provider for state management

## Common Commands

### Development
```bash
# Install dependencies
flutter pub get

# Run code generation (for Hive models)
flutter pub run build_runner build --delete-conflicting-outputs

# Run the app (API_KEY required — never hardcoded in source)
flutter run --dart-define=API_KEY=<your-key>                    # Android/iOS
flutter run -d chrome --dart-define=API_KEY=<your-key>          # Web (Chrome required)
flutter run -d chrome --dart-define=API_KEY=<your-key> --web-browser-flag="--disable-web-security"  # Web + CORS

# Analyze code
flutter analyze

# Run tests
flutter test

# Run a single test file
flutter test test/services/gps_service_test.dart
```

### Building for Release
```bash
# Use Build.sh — prompts for API key and signing passwords
./Build.sh

# Or set API key via environment variable to skip prompt
MESHMAPPER_API_KEY=<your-key> ./Build.sh
```

### Debug Logging
- Web: Add `?debug=1` to URL to enable debug logging in browser console
- Mobile: Debug logging enabled in debug builds via `kDebugMode`; disabled in release builds

## Architecture

### Service-Oriented Architecture

The app uses a layered service architecture with clear separation of concerns:

**Bluetooth Abstraction Layer** (`lib/services/bluetooth/`):
- `BluetoothService`: Abstract interface for BLE operations
- `MobileBluetoothService`: Android/iOS implementation using `flutter_blue_plus`
- `WebBluetoothService`: Web implementation using `flutter_web_bluetooth`
- Platform selection happens at runtime in `main.dart` using `kIsWeb`

**MeshCore Protocol Layer** (`lib/services/meshcore/`):
- `MeshCoreConnection`: Implements the 9-step connection workflow and MeshCore companion protocol
- `PacketParser`: Binary packet parsing with BufferReader/Writer utilities
- `UnifiedRxHandler`: Routes ALL incoming BLE packets to TX tracking or RX logging
- `TxTracker`: Detects repeater echoes during 7-second window after TX ping
- `DiscTracker`: Detects discovery responses during 7-second window after discovery request
- `RxLogger`: Logs passive mesh observations, buffers by repeater ID
- `ChannelService`: Channel hash computation and management
- `CryptoService`: SHA-256 channel key derivation, AES-ECB message decryption

**Application Services** (`lib/services/`):
- `GpsService`: GPS tracking with server-side zone validation
- `PingService`: TX/RX/Discovery ping orchestration, coordinates with TxTracker/DiscTracker/RxLogger
- `ApiQueueService`: Hive-based persistent upload queue with batch POST and retry logic
- `ApiService`: HTTP client for MeshMapper API endpoints
- `DeviceModelService`: Loads `assets/device-models.json` for device identification and power reporting

**State Management** (`lib/providers/`):
- `AppStateProvider`: Single ChangeNotifier for all app state using Provider pattern
- All UI updates happen via `notifyListeners()` after state mutations

### 9-Step Connection Workflow

Critical safety: The connection sequence MUST complete in order.

1. **BLE GATT Connect**: Platform-specific BLE connection
2. **Protocol Handshake**: `deviceQuery()` with protocol version
3. **Device Info**: `deviceQuery()` returns manufacturer string, then `getSelfInfo()` acquires device public key (required for geo-auth API authentication). If `getSelfInfo()` fails, the entire connection fails.
4. **Device Identification**: Parse manufacturer string, match against `device-models.json` (does NOT modify radio settings)
5. **Time Sync**: `sendTime()` syncs device clock
6. **Session Acquisition**: POST to `/wardrive-api.php/auth` for geo-auth session. Two-stage flow: first attempt with device public key, fallback to registration with signed contact URI if device not registered. Returns `session_id`, `tx_allowed`, `rx_allowed`, `expires_at`, and regional channels.
7. **Channel Setup**: Create or use existing `#wardriving` channel, plus any regional channels from auth response
8. **GPS Init**: Acquire GPS lock
9. **Connected State**: Ready for wardriving — Unified RX Handler starts processing ALL incoming packets, noise floor polling begins (5s interval)

**Important**: The app does NOT modify the radio's TX power settings. It only identifies the device model to determine what power level to report in API calls. Users configure their radio's actual TX power through the device firmware.

### Unified RX Handler Architecture

**Key Principle**: Accept ALL incoming BLE packets, parse metadata ONCE at entry point, then route to specialized handlers. Never filter by header at entry.

**Flow**:
```
BLE LogRxData Event
        ↓
UnifiedRxHandler._handleLogRxData()
        ↓
Parse PacketMetadata (ONCE)
        ↓
   ┌────┴────┐
   ↓         ↓
TX Track   RX Log
(echoes)  (passive)
   ↓         ↓
7s window  Buffer by repeater
   ↓         ↓
Update UI  Flush to API queue
```

**TX Tracking** (during 7-second window after ping):
- Validates: GROUP_TEXT header, RSSI < -30dBm, channel hash match, decrypted message match, path length > 0
- Deduplicates by first hop (repeater ID), keeps best SNR
- Updates UI with repeater counts

**RX Logging** (continuous passive monitoring):
- Validates: path length > 0, valid GPS, channel hash in allowed list, decrypts successfully, 90% printable chars, RSSI < -30dBm
- Buffers per repeater with GPS coordinates
- Flushes to API queue on 25m movement OR 30s timeout
- Maintains in-memory log (max 100 entries) for UI

### Discovery Pings

Discovery pings use the MeshCore control data protocol to directly query nearby repeaters and rooms, as opposed to TX pings which broadcast a channel message and listen for echoes.

**BLE Command**: `sendControlData()` (cmd 0x37) with `DISCOVER_REQ` flag (0x80), type filter for REPEATER|ROOM, and a random 4-byte tag.

**Response**: ControlData packets (0x8E) with `DISCOVER_RESP` flag (0x90), containing node type, remote SNR, and full 32-byte public key.

**Tracking**: `DiscTracker` manages a 7-second listening window (like `TxTracker`), validates responses, deduplicates by public key, and applies carpeater filtering (RSSI too strong = too close).

**API Payload**: Type `"DISC"` with fields: `lat`, `lon`, `repeater_id`, `node_type`, `local_snr`, `local_rssi`, `remote_snr`, `public_key`, `timestamp`, `external_antenna`, `noisefloor`.

### Auto-Ping Modes

Three auto-ping modes are available after connecting:

- **Active Mode**: Sends TX pings at user-configured interval (15s, 30s, or 60s). Each ping broadcasts a group channel message containing GPS location and radio power to `#wardriving`, then listens 7s for repeater echoes via `TxTracker`.
- **Passive Mode**: Sends discovery requests every 30s. No TX pings — only discovery request-response. Responses tracked via `DiscTracker`.
- **Hybrid Mode**: Alternates between discovery and TX pings at the user-configured interval. Discovery → TX → Discovery → TX...

All modes also passively listen for RX packets via `RxLogger`, adding additional free coverage data to MeshMapper from nearby mesh traffic.

### GPS & Zone Validation

- Uses `geolocator` package with high accuracy and continuous tracking
- **Zone Validation**: Server-side — client sends GPS coordinates to the API, server returns zone status (in-zone, nearest zone, or error)
- **Min Distance Filter**: 25m between pings prevents spam

### API Queue System

Three data flows (TX pings, RX observations, Discovery results) merge into unified API batch queue:

- **Storage**: Hive-based persistent queue survives app restarts
- **Batch Size**: Max 50 messages, auto-flush at 10 items or 30 seconds
- **Payload Format**: `[{type:"TX"|"RX"|"DISC", ...}]` — TX/RX include `heard_repeats`; DISC includes `repeater_id`, `node_type`, `local_snr`, `local_rssi`, `remote_snr`, `public_key`
- **Authentication**: API key in JSON body (NOT query string)
- **Retry Logic**: Exponential backoff on failures

### Offline Mode

`OfflineSessionService` enables wardriving when the API is unavailable (no network, maintenance mode, etc.). Data accumulates locally and can be uploaded later.

- **Storage**: SharedPreferences with key `offline_sessions` — JSON-encoded list of session objects
- **Session Format**: Each session has a filename (`YYYY-MM-DD.json`), creation timestamp, ping count, device info, and the wardrive data payload
- **Upload**: Sessions can be uploaded via Settings screen when connectivity is restored
- **Non-persistent**: Offline mode is never persisted — always off on app restart. Users must re-enable if needed.
- **Maintenance integration**: When maintenance mode is detected while disconnected, the UI suggests using Offline Mode
- **File**: `lib/services/offline_session_service.dart`

### Background Service

Keeps BLE and GPS active when the app is backgrounded during auto-ping.

- **Android**: Foreground service via `flutter_background_service` with persistent low-importance notification (no sound/vibration). Notification shows live stats: `TX: N | RX: M | Queue: P` (Active/Hybrid) or `RX: M | Queue: P` (Passive). Foreground types: `location + connectedDevice`.
- **iOS**: Uses declared background modes (`bluetooth-central`, `location`). Users can enable "Background Location" in Settings to upgrade to "Always" location permission, which prevents iOS throttling during extended sessions. This must be manually enabled — a disclosure dialog explains the feature, then the system permission prompt appears.
- **Web**: No-op (Web Bluetooth requires active tab)
- **Lifecycle**: Lazy-initialized on first `startService()` call (triggered by auto-ping start), stopped on disconnect or auto-ping stop
- **Orphan cleanup**: `cleanupOrphanedService()` detects and stops stale foreground services from previous sessions
- **File**: `lib/services/background_service.dart`

### Noise Floor Measurement

Continuous RSSI measurement of the idle channel, providing ambient noise data for coverage analysis.

- **Polling**: 5-second interval via `MeshCoreConnection.getNoiseFloor()` (MeshCore stats request for radio stats, parses int16LE). Retries up to 3 consecutive failures before stopping.
- **Sessions**: `NoiseFloorSession` (HiveType 13) records samples + ping event markers over time. Each sample has a timestamp and noise floor value (dBm).
- **Event Markers**: `PingEventMarker` records ping events overlaid on the noise floor graph:
  - `txSuccess` (Green) — TX heard by repeater
  - `txFail` (Red) — TX not heard
  - `rx` (Blue) — Passive RX received
  - `discSuccess` (Purple) — Discovery got response
  - `discFail` (Grey) — Discovery no response
  - Each marker includes repeater info (ID, SNR, RSSI, optional public key for discovery)
- **Visualization**: Interactive chart (`NoiseFloorChart` widget) with:
  - Color-coded noise floor line: green (-120 to -100 dBm), orange (-100 to -90 dBm), red (-90+ dBm)
  - Pinch-to-zoom with focal point tracking, pan support, 10s minimum visible window
  - Tap markers to show detail sheet with event type, timestamp, interpolated noise floor, and repeater table
- **API Integration**: `noisefloor` field included in every TX/RX/DISC API payload
- **Files**: `lib/models/noise_floor_session.dart`, `lib/widgets/noise_floor_chart.dart`

### Carpeater Filtering

"Carpeater" = co-located repeater with very strong signal, indicating the device is too close for meaningful coverage data.

- **RSSI threshold**: Packets with RSSI >= -30 dBm are automatically dropped as carpeater (constant `maxRssiThreshold`)
- **User filter**: Optional repeater ID blocklist configured by the user — checked via `shouldIgnoreRepeater()` before RSSI validation
- **Applied in**: `PacketValidator` (shared validation used by TxTracker, DiscTracker, and RxLogger)
- **Validation pipeline**: RSSI check → packet type (GROUP_TEXT/ADVERT) → channel hash match → AES-ECB decryption → printable character ratio (60% minimum)
- **Logging**: Carpeater drops logged to error log without auto-switching tabs, using `[RX FILTER]` debug tag
- **File**: `lib/services/meshcore/packet_validator.dart`

### Bug Report / Debug File System

Two-service system for capturing debug logs and submitting bug reports.

**DebugFileLogger**:
- Writes timestamped log files (`meshmapper-debug-{unix_timestamp}.txt`) to app documents directory
- Auto-rotation: max 10 files, max 4.5 MB per chunk (0.5 MB safety margin under 5 MB server limit)
- 5-second flush timer (critical for iOS background suspension)
- Non-persistent: always starts disabled on app launch
- Log format: `[ISO8601_timestamp] LEVEL: message`

**DebugSubmitService** — 4-step bug report workflow:
1. **Create Ticket** (0-20%): POST to `/debug/submitdebug.php/create-ticket` → returns `issue_number`, `issue_url`
2. **Request Upload** (per file, 20-90%): POST `/request-upload` → returns `upload_url`, `session_id`
3. **Upload File**: POST multipart to `upload_url` — splits large files at newline boundaries, uploads chunks sequentially with retry (3 attempts, exponential backoff)
4. **Complete Upload** (90-100%): POST `/upload-complete` with issue reference

- **Accessible via**: Settings screen
- **Files**: `lib/services/debug_file_logger.dart`, `lib/services/debug_submit_service.dart`

### Audio Service

Sound notifications for TX pings and RX observations, configurable on/off.

- **Sounds**: `assets/transmitted_packet.mp3` (TX/Discovery sent), `assets/received_packet.mp3` (repeater echo/RX received)
- **Storage**: Hive box `audio_preferences` with key `sound_enabled`
- **Audio focus**: Android uses transient focus with ducking (Android Auto compatible). iOS uses ambient category (plays alongside other audio).
- **Resilience**: 3-second timeout protection prevents indefinite hangs from audio session corruption. On timeout, resets session and reloads assets.
- **File**: `lib/services/audio_service.dart`

### Session Heartbeat

Prevents session timeout during long wardriving sessions by periodically refreshing the session expiry.

- **Trigger**: Enabled when auto-ping mode starts (`enableHeartbeat()`), disabled on disconnect or leaving auto mode
- **Timing**: Heartbeat fires **1 minute before** session `expires_at`. If already expired, sends immediately.
- **Mechanism**: POST to `/wardrive-api.php/wardrive` with `heartbeat: true` flag and optional GPS coordinates
- **Response**: Returns updated `expires_at`, which schedules the next heartbeat
- **Flow**: Auth response sets initial `expires_at` → each wardrive POST or heartbeat updates it → timer reschedules automatically

### External Antenna Flag

Two-flag system ensuring users explicitly declare their antenna configuration before wardriving.

- **`externalAntenna`** (bool): Whether an external antenna is connected
- **`externalAntennaSet`** (bool): Whether the user has explicitly configured this preference
- **Enforcement**: UI requires user to set this before first ping (`PingValidation.externalAntennaRequired`). Cannot be skipped.
- **API integration**: `external_antenna` field included in every TX/RX/DISC API payload
- **Persistence**: Stored per-device, restored on reconnect with same device, reset on reconnect failure

### Wake Lock Service

Keeps the screen on during auto-ping to prevent device sleep during wardriving sessions.

- **Enable**: Called when auto-ping starts
- **Disable**: Called when auto-ping stops or on disconnect
- **Package**: `wakelock_plus`
- **Platform**: Android and iOS only (Web N/A — always requires active tab)
- **File**: `lib/services/wakelock_service.dart`

## Critical Protocol Details

### BLE Service UUIDs (MeshCore Companion Protocol)
- Service: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- RX Characteristic: `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` (write to device)
- TX Characteristic: `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` (notifications from device)

### Channel Key Derivation
- **Default channels**: `Public` (fixed key `8b3387e9c5cdea6ac9e5edbaa115cd72`) and `#wardriving` (SHA-256 hash of channel name)
- **Regional channels**: Additional channels (e.g., `#ottawa`, `#testing`) delivered by the API after auth, based on the user's zone
- Channel hash (PSK identifier) used for repeater echo detection and message decryption (AES-ECB via pointycastle)

### Packet Structure
- Custom binary protocol with header byte (0x11 = GROUP_TEXT, 0x21 = ADVERT)
- Path encoding: `pathLen` byte encodes hash size (top 2 bits) + hop count (bottom 6 bits), followed by `hopCount * hashSize` path bytes
  - `pathHashSize = (pathLen >> 6) + 1` → 1, 2, 3, or 4 bytes per hop
  - `pathHashCount = pathLen & 63` → 0-63 hops
- SNR/RSSI metadata in BLE event payload
- Encrypted message payload (AES-ECB with channel key)

### Multi-Byte Path Support (v1.14.0+)
- **Purpose**: Expands repeater ID space from 256 (1-byte) to 65K (2-byte) or 16M (3-byte) unique IDs
- **TX mode**: Configured via `CMD_SET_PATH_HASH_MODE = 61 (0x3D)` — `[0x3D][0x00][mode]` where mode=0→1-byte, 1→2-byte, 2→3-byte
- **RX auto-detect**: Each received packet's `pathLen` byte is decoded to determine hash size, regardless of the user's TX setting
- **DeviceInfo**: v10+ firmware includes `path_hash_mode` byte after manufacturer + firmware version fields
- **API enforcement**: Auth response may include `hop_bytes` (1/2/3) to enforce regional path byte size
- **Lifecycle**: Radio mode is set during connection and restored to original on clean disconnect. Unclean disconnect leaves radio in configured mode.
- **Discovery pings**: NOT affected — multi-byte paths apply only to TX/RX channel messages

## Platform-Specific Notes

### Web (Chrome/Edge only)
- Safari NOT supported (no Web Bluetooth API)
- Uses `flutter_web_bluetooth` package
- Debug logging enabled via URL parameter `?debug=1`
- CORS issues during local development - use `--web-browser-flag="--disable-web-security"`

### Android
- Requires permissions: Bluetooth, Location (for BLE scanning)
- minSdkVersion: 21 (Android 5.0+)
- Background location permission for continuous tracking
- Uses `flutter_blue_plus` package

### iOS
- Requires Info.plist entries: NSBluetoothAlwaysUsageDescription, NSLocationWhenInUseUsageDescription
- Deployment target: 12.0+
- Background modes: bluetooth-central, location
- Uses `flutter_blue_plus` package

## Dependencies

Key packages used in this project:

- `flutter_blue_plus`: Mobile Bluetooth (Android/iOS)
- `flutter_web_bluetooth`: Web Bluetooth (Chrome/Edge)
- `geolocator`: GPS/Location
- `maplibre_gl`: Map rendering (MapLibre GL vector tiles via OpenFreeMap)
- `hive`: Local storage
- `provider`: State management
- `http`: API requests
- `pointycastle`: Encryption (AES-ECB, SHA-256)

## Development Workflow Requirements

### Debug Logging Convention (MANDATORY)

All debug log messages MUST include a tag in square brackets. Use the debug helper functions from `utils/debug_logger_io.dart`:

- `debugLog(message)` — General debug information
- `debugWarn(message)` — Warning conditions
- `debugError(message)` — Error conditions

```dart
debugLog('[BLE] Connection established');
debugLog('[GPS] Fresh position acquired: lat=45.12345');
debugWarn('[PING] GPS data is stale, requesting fresh position');
debugError('[API] Failed to post batch: $error');
```

**Required Tags:**

| Tag | Description |
|-----|-------------|
| `[BLE]` | Bluetooth connection and device communication |
| `[CONN]` | MeshCore connection protocol operations |
| `[GPS]` | GPS/geolocation operations |
| `[PING]` | Ping sending and validation |
| `[API QUEUE]` | API queue operations (batch posting) |
| `[RX BATCH]` | RX batch buffer operations |
| `[RX]` | RX packet handling and logging |
| `[TX]` | TX packet handling and logging |
| `[DECRYPT]` | Message decryption |
| `[CRYPTO]` | Cryptographic operations (SHA-256, AES) |
| `[UI]` | General UI updates (status bar, buttons, etc.) |
| `[CHANNEL]` | Channel setup and management |
| `[TIMER]` | Timer and countdown operations |
| `[WAKE LOCK]` | Wake lock acquisition/release (legacy, prefer `[WAKELOCK]`) |
| `[GEOFENCE]` | Geofence and distance validation |
| `[CAPACITY]` | Capacity check API calls |
| `[AUTO]` | Auto mode operations (TX/RX or RX-only) |
| `[INIT]` | Initialization and setup |
| `[AUTH]` | Authentication API operations |
| `[HEARTBEAT]` | Session heartbeat operations |
| `[API]` | General API operations |
| `[MODEL]` | Device model identification and power reporting |
| `[MAP]` | Map widget operations |
| `[DISC]` | Discovery ping operations |
| `[MAINTENANCE]` | Maintenance mode handling |
| `[RX FILTER]` | RX packet validation and carpeater filtering |
| `[AUDIO]` | Audio/sound notification operations |
| `[BACKGROUND]` | Background mode and foreground service |
| `[DEBUG]` | Debug file logging and submission |
| `[GRAPH]` | Noise floor graph operations |
| `[HYBRID]` | Hybrid mode ping alternation |
| `[OFFLINE]` | Offline mode operations |
| `[SCAN]` | BLE device scanning |
| `[WAKELOCK]` | Wake lock acquisition/release |

Never log without a tag.

### Status Message Conventions

Use the status update methods in `AppStateProvider` for all UI status updates. Available status types:

- `idle` — Default/waiting state
- `success` — Successful operations
- `warning` — Warning conditions
- `error` — Error states
- `info` — Informational/in-progress states

### Documentation Update Requirements

When modifying code, update `DEVELOPMENT.md` (this file) for architectural changes.

### Documentation Checklist

- [ ] Added debug logging with tags to new code
- [ ] Updated `DEVELOPMENT.md` if architecture changed
- [ ] Added inline comments for complex logic
- [ ] Added Dart doc comments (`///`) for public APIs

### Code Style
- Use Dart documentation comments (`///`) for public classes and methods
- Prefer `async`/`await` over `.then()` chains
- Always wrap async operations in `try`/`catch` blocks
- Use `debugError()` for logging errors before handling
- State mutations via `AppStateProvider` with `notifyListeners()`

## Device Model Database

**File**: `assets/device-models.json`

Contains 30+ MeshCore device variants with manufacturer strings, TX power levels, and platform info:
- **Ikoka**: Stick, Nano, Handheld (22dBm, 30dBm, 33dBm variants)
- **Heltec**: V2, V3, V4, Wireless Tracker, MeshPocket
- **RAK**: 4631, 3x72
- **LilyGo**: T-Echo, T-Deck, T-Beam, T-LoRa
- **Seeed**: Wio E5, T1000, Xiao variants

**Detection Flow**:
1. `deviceQuery()` returns manufacturer string (e.g., "Ikoka Stick-E22-30dBm (Xiao_nrf52)nightly-e31c46f")
2. `parseDeviceModel()` strips build suffix ("nightly-COMMIT")
3. `findDeviceConfig()` searches database for exact/partial match
4. `autoSetPowerLevel()` configures radio power automatically

**Critical Safety**: PA amplifier models MUST use specific power values:
- 33dBm models: txPower=9, power=2.0
- 30dBm models: txPower=20, power=1.0
- Standard (22dBm): txPower=22, power=0.3

## MeshMapper API Endpoints

**Base URL**: `https://meshmapper.net/`

**API Key**: Injected at build time via `--dart-define=API_KEY=...`. Never hardcoded in source. `Build.sh` prompts for it, or set `MESHMAPPER_API_KEY` env var.

- **POST /wardrive-api.php/status**: Check zone status (geo-auth)
- **POST /wardrive-api.php/auth**: Acquire/release session (geo-auth)
- **POST /wardrive-api.php/wardrive**: Submit wardrive data + heartbeat
- Auth: API key in JSON body (`key` field), NOT query string

### Maintenance Mode Response

All API endpoints may return maintenance mode:
```json
{
  "maintenance": true,
  "maintenance_message": "Scheduled maintenance until 3:00 PM EST",
  "maintenance_url": "https://meshmapper.net/status"
}
```
- **Disconnected**: Blocks connecting, shows maintenance message on Connection screen with suggestion to use Offline Mode
- **Connected**: Ends session, logs to error log, navigates to error log tab
- **Offline Mode**: Users can still wardrive in Offline Mode during maintenance and upload data later when service is restored

## Common Pitfalls

1. **Unified RX Handler accepts ALL packets** - No header filtering at entry point. Session log tracking filters headers internally.

2. **GPS freshness** - The client doesn't enforce GPS freshness for pings (25m movement check is sufficient), but zone status checks require GPS < 60s old and < 50m accuracy. The server also enforces fresh GPS on submitted wardrive data.

3. **Control locking during ping lifecycle** - `sendPing()` disables all controls until API post completes. Must call unlock in ALL code paths (success/error).

4. **Disconnect cleanup has 3 different flows**:
   - **User disconnect**: Full cleanup — stop auto-ping → end noise floor session → stop background service → flush RX logger → clear API queue → release session (`/auth` with `reason: disconnect`) → delete wardriving channel (while BLE still connected) → close BLE → dispose all services → reset state
   - **Unexpected BLE disconnect**: Partial cleanup — preserves API session, API queue, and noise floor session for reconnection. Stops timers and background service, disposes BLE-dependent objects, then starts auto-reconnect with exponential backoff (max 30s timeout). On reconnect success, restores auto-ping if it was active.
   - **Reconnect failure / abandoned**: Falls back to full disconnect cleanup — flushes and clears API queue, releases session, resets antenna preference (user must re-select)

   Critical: Channel deletion MUST happen while BLE is still connected to avoid GATT errors. API queue is cleared on user disconnect (pings won't have valid session) but preserved during auto-reconnect.

5. **Platform-specific Bluetooth imports** - Use conditional exports (bluetooth_service.dart exports platform-specific implementation). Never import platform-specific files directly.

6. **Hive model generation required** - After modifying `@HiveType` classes, run `flutter pub run build_runner build --delete-conflicting-outputs`.

7. **Web Bluetooth requires HTTPS** - Development uses `flutter run -d chrome` which works, but production deployment needs HTTPS.

## Key File Reference

- `lib/main.dart` - App entry point, platform detection, theme
- `lib/providers/app_state_provider.dart` - Global state management
- `lib/services/meshcore/connection.dart` - 9-step connection workflow, MeshCore protocol
- `lib/services/meshcore/unified_rx_handler.dart` - Packet routing (TX vs RX)
- `lib/services/meshcore/tx_tracker.dart` - Repeater echo detection (7s window)
- `lib/services/meshcore/disc_tracker.dart` - Discovery response tracking (7s window)
- `lib/services/meshcore/rx_logger.dart` - Passive observation logging
- `lib/services/ping_service.dart` - TX/RX/Discovery ping orchestration
- `lib/services/gps_service.dart` - GPS tracking and geofencing
- `lib/services/api_queue_service.dart` - Persistent upload queue
- `lib/services/device_model_service.dart` - Device model identification
- `lib/services/background_service.dart` - Background operation (Android foreground service, iOS background modes)
- `lib/services/audio_service.dart` - Sound notifications for TX/RX events
- `lib/services/offline_session_service.dart` - Offline wardriving session storage
- `lib/services/debug_file_logger.dart` - Debug log file rotation and upload
- `lib/services/debug_submit_service.dart` - Bug report submission (4-step workflow)
- `lib/services/gps_simulator_service.dart` - GPS simulation for testing
- `lib/services/wakelock_service.dart` - Screen wake lock during auto-ping
- `lib/services/meshcore/packet_validator.dart` - Packet validation and carpeater filtering
- `lib/models/noise_floor_session.dart` - Noise floor session data models
- `lib/widgets/noise_floor_chart.dart` - Noise floor graph visualization
- `assets/device-models.json` - Device database (30+ models)
