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
- Mobile: Debug logging always enabled via `debugPrint()`

## Architecture

### Service-Oriented Architecture

The app uses a layered service architecture with clear separation of concerns:

**Bluetooth Abstraction Layer** (`lib/services/bluetooth/`):
- `BluetoothService`: Abstract interface for BLE operations
- `MobileBluetoothService`: Android/iOS implementation using `flutter_blue_plus`
- `WebBluetoothService`: Web implementation using `flutter_web_bluetooth`
- Platform selection happens at runtime in `main.dart` using `kIsWeb`

**MeshCore Protocol Layer** (`lib/services/meshcore/`):
- `MeshCoreConnection`: Implements the 10-step connection workflow and MeshCore companion protocol
- `PacketParser`: Binary packet parsing with BufferReader/Writer utilities
- `UnifiedRxHandler`: Routes ALL incoming BLE packets to TX tracking or RX logging
- `TxTracker`: Detects repeater echoes during 7-second window after sending ping
- `RxLogger`: Logs passive mesh observations, buffers by repeater ID
- `ChannelService`: Channel hash computation and management
- `CryptoService`: SHA-256 channel key derivation, AES-ECB message decryption

**Application Services** (`lib/services/`):
- `GpsService`: GPS tracking with 150km geofence from Ottawa (45.4215, -75.6972)
- `PingService`: TX/RX ping orchestration, coordinates with TxTracker/RxLogger
- `ApiQueueService`: Hive-based persistent upload queue with batch POST and retry logic
- `ApiService`: HTTP client for MeshMapper API endpoints
- `DeviceModelService`: Loads `assets/device-models.json` for device identification and power reporting

**State Management** (`lib/providers/`):
- `AppStateProvider`: Single ChangeNotifier for all app state using Provider pattern
- All UI updates happen via `notifyListeners()` after state mutations

### 10-Step Connection Workflow

Critical safety: The connection sequence MUST complete in order.

1. **BLE GATT Connect**: Platform-specific BLE connection
2. **Protocol Handshake**: `deviceQuery()` with protocol version
3. **Device Info**: `getDeviceName()`, `getPublicKey()`, `getDeviceSettings()`
4. **Device Identification**: Parse manufacturer string, match against `device-models.json` (does NOT modify radio settings)
5. **Time Sync**: `sendTime()` syncs device clock
6. **API Slot Acquisition**: POST to `/capacitycheck.php` to reserve API slot
7. **Channel Setup**: Create or use existing `#wardriving` channel
8. **GPS Init**: Acquire GPS lock
9. **Start Unified RX Handler**: Begin processing ALL incoming packets
10. **Connected State**: Ready for wardriving

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

### GPS & Geofencing

- Uses `geolocator` package with high accuracy and continuous tracking
- **Ottawa Geofence**: 150km radius from Parliament Hill (45.4215, -75.6972) - hard boundary enforced client-side AND server-side
- **Min Distance Filter**: 25m between pings prevents spam
- **GPS Freshness**: Manual pings tolerate 60s old GPS, auto pings require fresh acquisition

### API Queue System

Two independent data flows (TX pings, RX observations) merge into unified API batch queue:

- **Storage**: Hive-based persistent queue survives app restarts
- **Batch Size**: Max 50 messages, auto-flush at 10 items or 30 seconds
- **Payload Format**: `[{type:"TX"|"RX", lat, lon, who, power, heard, session_id, iatacode}]`
- **Authentication**: API key in JSON body (NOT query string)
- **Retry Logic**: Exponential backoff on failures

## Critical Protocol Details

### BLE Service UUIDs (MeshCore Companion Protocol)
- Service: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- RX Characteristic: `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` (write to device)
- TX Characteristic: `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` (notifications from device)

### Channel Key Derivation
- **Hashtag channels** (`#wardriving`, `#testing`, `#ottawa`, `#wartest`): SHA-256 hash of channel name
- **Public channel** (`Public`): Fixed key `8b3387e9c5cdea6ac9e5edbaa115cd72`
- Channel hash (PSK identifier) computed at startup for `#wardriving`
- Used for repeater echo detection and message decryption (AES-ECB via pointycastle)

### Packet Structure
- Custom binary protocol with header byte (0x11 = GROUP_TEXT, 0x21 = ADVERT)
- Path encoding: hop count + repeater IDs (4 bytes each)
- SNR/RSSI metadata in BLE event payload
- Encrypted message payload (AES-ECB with channel key)

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

## Development Workflow Requirements

### Debug Logging Convention (MANDATORY)
All debug log messages MUST include a tag in square brackets:

```dart
debugLog('[BLE] Connection established');
debugLog('[GPS] Fresh position acquired: lat=45.12345');
debugLog('[PING] Sending ping to channel 2');
debugLog('[RX] Buffering observation for repeater 0xABCD1234');
```

**Required Tags**: `[BLE]`, `[CONN]`, `[GPS]`, `[PING]`, `[API QUEUE]`, `[RX BATCH]`, `[RX]`, `[TX]`, `[DECRYPT]`, `[CRYPTO]`, `[UI]`, `[CHANNEL]`, `[TIMER]`, `[WAKE LOCK]`, `[GEOFENCE]`, `[CAPACITY]`, `[AUTO]`, `[INIT]`, `[MODEL]`, `[MAP]`

Never log without a tag. See `docs/DEVELOPMENT_REQUIREMENTS.md` for complete list.

### Documentation Update Requirements

When modifying code, you MUST also update relevant documentation:

1. **Architectural changes** → Update this file (`docs/DEVELOPMENT.md`)

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

2. **GPS freshness varies by context** - Manual pings tolerate 60s old GPS data, auto pings force fresh acquisition.

3. **Control locking during ping lifecycle** - `sendPing()` disables all controls until API post completes. Must call unlock in ALL code paths (success/error).

4. **Disconnect cleanup order matters** - Flush API queue → Release capacity → Delete channel → Close BLE → Clear timers/GPS/wake locks → Reset state. Out-of-order causes errors.

5. **Platform-specific Bluetooth imports** - Use conditional exports (bluetooth_service.dart exports platform-specific implementation). Never import platform-specific files directly.

6. **Hive model generation required** - After modifying `@HiveType` classes, run `flutter pub run build_runner build --delete-conflicting-outputs`.

7. **Web Bluetooth requires HTTPS** - Development uses `flutter run -d chrome` which works, but production deployment needs HTTPS.

## Key File Reference

- `lib/main.dart` - App entry point, platform detection, theme
- `lib/providers/app_state_provider.dart` - Global state management
- `lib/services/meshcore/connection.dart` - 10-step connection workflow, MeshCore protocol
- `lib/services/meshcore/unified_rx_handler.dart` - Packet routing (TX vs RX)
- `lib/services/meshcore/tx_tracker.dart` - Repeater echo detection (7s window)
- `lib/services/meshcore/rx_logger.dart` - Passive observation logging
- `lib/services/ping_service.dart` - TX/RX ping orchestration
- `lib/services/gps_service.dart` - GPS tracking and geofencing
- `lib/services/api_queue_service.dart` - Persistent upload queue
- `lib/services/device_model_service.dart` - Device model identification
- `assets/device-models.json` - Device database (30+ models)
- `docs/UNIFIED_RX_HANDLER_PLAN.md` - RX handler architecture
- `docs/DEVELOPMENT_REQUIREMENTS.md` - Coding standards

## Original WebClient Reference

This Flutter app is a port of the JavaScript-based [MeshMapper WebClient](https://github.com/MeshMapper/MeshMapper_WebClient). When implementing features:

1. Follow same architectural patterns (connection workflow, API queue, channel crypto)
2. Maintain feature parity where possible
3. Key differences:
   - Flutter uses Provider for state (not global state object)
   - Hive for persistent storage (not IndexedDB)
   - Platform-specific BLE implementations (not just Web Bluetooth)
   - Dart type safety (not dynamic JavaScript)
