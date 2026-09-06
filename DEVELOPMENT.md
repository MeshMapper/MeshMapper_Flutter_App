# Development Guide

This document provides comprehensive architecture documentation and development guidance for the MeshMapper Flutter App.

## Project Overview

MeshMapper Flutter App is a cross-platform wardriving application for MeshCore mesh network devices. It's a Flutter port of the [MeshMapper WebClient](https://github.com/MeshMapper/MeshMapper_WebClient), supporting Android and iOS. The web (Chrome/Edge) target's code is retained in the codebase but the web app is no longer built or published.

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

# Watch wire rules — snapshot ordering, cue presentation, staleness.
# Plain SwiftPM over Foundation-only sources: no Xcode project, no simulator,
# no signing. macOS only.
(cd ios/WatchLogicTests && swift test)

# Type-check every watch source against the watchOS SDK, without building
xcrun --sdk watchos swiftc -typecheck -target arm64_32-apple-watchos11.0 \
  ios/MeshMapperWatch/*.swift ios/Shared/MeshMapperWatchPayload.swift
```

**What the watch is and is not covered by.** `WatchWireRules` in
`ios/Shared/MeshMapperWatchPayload.swift` holds the decisions that pick what the
wearer sees, deliberately kept Foundation-only and free of `WCSession` so they
can be tested at all — `WatchSessionClient` is `@Observable`, `@MainActor`, and
reaches `WCSession.default` through a computed property with no injection point.
Logic that belongs to the wire goes there; the client keeps observable state and
timers. `ios/WatchLogicTests` compiles the shipping file through a symlink, so
there is no copy to drift.

That covers the rules and, via the type-check, a Swift compile break. It does
**not** cover WatchConnectivity delivery, SwiftUI, MapKit, or anything about
target membership: a file added to `ios/MeshMapperWatch/` but never added to the
target type-checks here and still fails to build in Xcode, as do embed-phase,
entitlement and signing mistakes. Those still need a real build, and the
delivery races still need a wrist.

### Building for Release
```bash
# Use Build.sh — prompts for API key and signing passwords
./Build.sh

# Or set API key via environment variable to skip prompt
MESHMAPPER_API_KEY=<your-key> ./Build.sh

# Non-interactive (secrets from ~/.meshmapper_release.env or env vars)
./Build.sh --type prod --version 1.3.1                # or --type dev
./Build.sh --type prod --version 1.3.1 --dry-run      # print resolved plan, build nothing

# Upload the built iOS archive to App Store Connect (needs ASC API key, see upload_ios.sh)
./upload_ios.sh

# Set the TestFlight "What to Test" text on the uploaded build (same ASC API key).
# This cannot ride along with the upload, so it is a separate leg that waits for
# App Store Connect to register the build.
./set_whats_new.sh --notes-file notes.txt
```

The upload export uses explicit App Store profiles from
`ios/ExportOptionsUpload.plist`. The Runner profile must include the App Group
entitlement, and the App Intents extension needs its own profile with the same
group. When either target's capabilities change, regenerate and reinstall the
named profiles before exporting; an existing profile is not automatically
updated by adding the developer-portal capability.

### Debug Logging
- Web: Add `?debug=1` to URL to enable debug logging in browser console
- Mobile: Debug logging enabled in debug builds via `kDebugMode`; disabled in release builds

## Architecture

### Service-Oriented Architecture

The app uses a layered service architecture with clear separation of concerns:

**Bluetooth Abstraction Layer** (`lib/services/bluetooth/`):
- `BluetoothService`: Abstract interface for BLE operations, implements `CompanionTransport`
- `MobileBluetoothService`: Android/iOS implementation using `flutter_blue_plus`
- `WebBluetoothService`: Web implementation using `flutter_web_bluetooth`
- Platform selection happens at runtime in `main.dart` using `kIsWeb`

**Transport Layer** (`lib/services/transport/`):
- `CompanionTransport`: Transport-agnostic interface for MeshCore companion connections (BLE, TCP, USB Serial)
- `StreamFrameCodec`: Framing codec for TCP/USB Serial (`[0x3C][len_lo][len_hi][payload]` out, `[0x3E][len_lo][len_hi][payload]` in)
- `StreamTransportBase`: Abstract base for TCP and USB Serial transports, owns codec and connection lifecycle
- `TcpService`: TCP socket transport with saved connections persistence (Android/iOS)
- `AndroidSerialService`: USB Serial via USB OTG on Android using `usb_serial` package
- `WebSerialService`: USB Serial via Web Serial API (Chrome/Edge) using `dart:js_interop`
- Platform matrix: BLE (all platforms), TCP (Android/iOS), USB Serial (Android/Web)

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

### Map Rebuild Isolation

The MapLibre `MapWidget` is by far the most expensive subtree. It is therefore
**not** subscribed to the whole provider — that previously made it rebuild on
every `notifyListeners()` (including noise-floor/battery/stats every few seconds
and the dense-mesh passive-RX pin storm at 10–20×/sec), which pinned the CPU/GPU
and overheated the device during wardriving.

Instead the map is isolated:
- `AppStateProvider` exposes `mapRevision`, an integer bumped only when
  **map-rendered** state changes (TX/RX/disc/trace markers, echoes, zone
  repeater load, history view, marker/log clears, marker-style prefs).
- Two helpers drive it: `_notifyMapNow()` (bump + immediate notify, for
  low-frequency changes) and `_notifyMapThrottled()` (bump + ~250 ms
  leading+trailing coalescing, for the high-frequency RX/echo storm — caps map
  rebuilds at ~4/sec while pin data updates immediately).
- `MapWidget` is wrapped in a `Selector` (`home_screen.dart` `_buildMapSelector`)
  keyed on `(mapRevision, focus, history, padding, controls)` and uses
  `context.read` internally, so it is cached across all UI-only notifies.
- UI-only state (noise floor, battery, live stats) calls plain
  `notifyListeners()` and leaves `mapRevision` untouched, so the status bar
  updates without rebuilding the map.

**The GPS chip has its own Selector.** `GpsInfoChip` (`lib/widgets/gps_info_chip.dart`) is wrapped in a `Selector` on `GpsChipReadings` (accuracy, altitude, distance since last ping, units), so it refreshes on every fix while the map around it stays cached. Without it the chip only refreshed on a `mapRevision` bump and sat frozen between pings while disconnected.

**GPS position does NOT bump `mapRevision`.** Position updates ~1–2×/sec while
driving; rebuilding the map that often relayouts the iOS platform view (~24 ms
each) — a dominant heat source. Instead, the GPS listener calls plain
`notifyListeners()`, and `MapWidget` drives camera-follow, derived heading, and
the GPS puck from a **direct provider listener** (`_onPositionNotify` →
`_handleGpsPosition`) that calls the native controller (`animateCamera` /
`updateSymbol`) every tick — real-time nav, no widget rebuild. The GPS-info
overlay rebuilds only when the map itself does.

**Coverage overlay opacity does NOT bump `mapRevision`.** It is UI-only state,
so bumping the revision would relayout the platform view once per slider step.
`MapWidget` applies it through a **direct provider listener**
(`_onCoverageOpacityNotify`) that pushes the value into the live fill layers via
`setLayerProperties`. A `build()` watcher cannot serve this: the map is behind
the `mapRevision` Selector and never rebuilds on an opacity change, so the value
only reached MapLibre on the next full overlay rebuild.

**The Selector MUST be memoized (identity-stable).** `HomeScreen.build()` uses
`context.watch`, so it rebuilds on every notify (incl. the 2 Hz GPS one).
provider's `Selector` invalidates its cache whenever `oldWidget != widget`
(`selector.dart:77`), so a fresh inline `Selector(...)` instance each build
forces `MapWidget` to rebuild **before** the value comparison ever runs —
silently defeating the isolation. `_buildMapSelector` therefore caches the
`Selector` instance, keyed only on the State fields its closures capture
(`isLandscape` / `_isControlsMinimized` / `_mapControlsExpanded`), so its
identity survives parent rebuilds and the value comparison actually gates the
map.

### 9-Step Connection Workflow

Critical safety: The connection sequence MUST complete in order.

1. **Transport Connect**: Platform-specific transport connection (BLE GATT, TCP socket, or USB Serial port)
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
- **Airborne block** (`GpsService.positionLooksAirborne`): a fix counts as in the air when its altitude, less its own vertical accuracy, is above 6,000 m (higher than any road on Earth, below airliner cruise) OR its ground speed is above 250 km/h (catches take-off, approach and most small aircraft; a high-speed train trips it too, by design). Three consecutive airborne fixes set `GpsService.isAirborne`, three consecutive ground fixes clear it, and one fix of the other kind restarts the count. The latch records which test fired (`airborneGate`) and BOTH readings of the fix that set it (`airborneAltitude`, `airborneSpeed`, each null when unknown; `speedOrNull` mirrors `altitudeOrNull`), and reports every flip once through `onAirborneChanged`. Unknown altitude and speed arrive from geolocator as 0.0 and never qualify (fail open). Every accepted fix feeds the latch (`trackAirborne`): the position stream, the simulator and `getFreshPosition()`, which TX, discovery and trace sends all take. A fix handed over twice (stream plus fresh read, same platform timestamp) counts once, so the streak really is three distinct fixes. The latch resets whenever the fix source restarts (`startWatching`, `enableSimulator`), because the stream only fires on movement and a phone left on a desk after a simulated flight would otherwise stay locked out. `GpsService.altitudeOrNull` is the shared "does this fix know its altitude" test (only the 0.0/0.0 pair means unknown; Android omits the accuracy on fixes that do carry an altitude).
- **What the block does**: `AppStateProvider._checkAirborne()` is level-triggered from the position listener and from the auto-ping scheduling hook (on iOS the position stream is quiet in the background, so the fresh fix each ping takes is the only sample then). With a live session it calls `_endSessionForAirborne()`: disconnect alert, error-log entry with the altitude or speed in the user's units, then `disconnect(closeApp: false, releaseExtras: ...)`, the normal user-disconnect path (auto-ping off, RX logging off, queue cleared, offline session kept in Offline Mode, API session released, no auto-reconnect). It defers while a zone transfer is in progress, since that flow re-acquires a session after its awaits with no cancellation check. The listener returns early on that tick so it cannot run a zone check on the way out, and the 100 m zone recheck while disconnected is skipped while airborne (a flight would otherwise POST once a second for hours). The four connect entry points refuse via `_refuseConnectIfAirborne()` (which sets no `connectionError`: the Connection screen's Airborne panel outranks the error card, and a message set there would survive the landing until the next attempt), the Connection screen disables Connect and shows "Airborne" with the reading that set the latch (`airborneCause`, "Your altitude is 10000m." or "You are moving at 300 km/h."), the map's GPS chip shows the fix's altitude when known, `PingValidation.airborne` blocks all three validators, Siri and the watch get `ExternalCommandReasonCode.airborne`, and auto-reconnect abandons instead of retrying into a flight (same alert, error-log entry and release telemetry, preserved queue dropped; the check sits below the reconnect prep so the foreground service and RX-side objects are torn down first). The check skips while `_isConnecting`, because the step flips to connected before `_postConnectionSetup` finishes and a disconnect inside that window would null objects the setup still uses; the next fix catches it. The release call carries `disconnect_cause: airborne`, `airborne_gate` (the test that fired) and `airborne_value` (its reading, raw meters or km/h), plus `airborne_alt_m` and `airborne_speed_kmh`, BOTH readings of the fix that set the latch (each omitted when the platform did not know it, metric ints regardless of the unit setting), so a speed-gate fire can be told apart from a high-speed train; built by the pure `airborneReleaseInfo` in `lib/services/airborne_release.dart` and logged by the server. In Offline Mode the offline recording is paused for as long as the latch is set (`ApiQueueService.setOfflineRecordingPaused`, driven by `GpsService.onAirborneChanged`, logged once on pause and once on resume), so the RX flush at disconnect and any straggler row cannot land in the offline file; the server owner chose the app as the only control on that path. Known gaps: a small aircraft below both limits passes. Thresholds are compiled in (server-delivered limits and a server-side guard were considered and left out). Logged under `[GPS]`, `[APP]`, `[CONN]`.

### Smart Pinging

Auto mode skips TX pings and discovery requests in a grid square that already has a recent
bidir (green) or disc (cyan) result. RX logging is never skipped (it is free). Manual pings,
Trace mode and the auto-mode start check are untouched. On by default with a 14 day window.

- **Settings** (Settings → Wardriving → Auto-Ping): `smartPingEnabled` (default true) and `smartPingDays`
  (any whole number of days from 1 to 365, typed into a number field; default 14; bounds in
  `SmartPingDays`). A stored value outside the range falls back to 14. The window tile is
  hidden while the switch is off.
- **Enforcement**: `/auth` carries `smart_ping` (bool) and `smart_ping_days` (int). When
  `smart_ping` is true the switch is locked on and the window is the server's; otherwise the
  user's own values apply. The preference is never overwritten: `AppStateProvider`
  exposes effective getters (`smartPingEnabled`, `smartPingDays`, `enforceSmartPing`), the
  `discDropEnabled` pattern. A missing or invalid field means not enforced, 14 days
  (`ApiService.enforceSmartPing`, `apiSmartPingDays`).
- **Data source**: `vector_tile.php?z=13&gsize=<grid>&f_days=<days>&f_types=green,cyan`
  (`ApiService.fetchRecentCoverageTile`), decoded by `decodeCoverageCells`. The square is the
  cell of the user's Coverage Grid setting (300 m or 100 m), so what is skipped matches what
  is painted, including the Detailed 3 by 3 smear. The tap API (`app_coverage.php`) is not used.
- **Lookup** (`RecentCoverageService`, `lib/services/recent_coverage_service.dart`): keeps
  every z13 tile within 500 m of the phone loaded (one tile mid-tile, up to four at a corner),
  re-evaluated after 100 m of movement, refetched after 5 minutes at the next 100 m of movement
  (a stationary phone does not refresh), one fetch in flight at a
  time, an exception from the fetch or the decoder is caught and treated as a failed fetch,
  failed fetches retried no sooner than 30 s and never clearing a loaded tile. A tile that comes
  back carrying any cell other than green or cyan is treated as unfiltered (a region server
  without the `f_*` filter support) and ignored, so the lookup stays `unknown` there. Cells this
  session covered itself (a heard TX, an answered discovery) are marked covered at once
  (`markCovered`). `isCovered` is synchronous and returns `covered`, `clear` or `unknown`.
- **Fail open**: `unknown` (no tile yet), a fetch failure, Offline Mode, no zone, or the
  feature off all let the ping go out.
- **The skip**: `PingService.checkRecentCoverage` (wired to `isCovered`) is consulted by
  `canPing()` after the distance check (too close wins) and by the auto discovery path next to
  its distance check. It yields `PingValidation.recentlyCovered` and the skip reason
  `'recently covered'`, which rides the existing `onAutoPingScheduled` hook: the countdown
  shows "Skipped", the Live Activity detail reads "Recently covered, skipped", and the next
  attempt is scheduled at the normal interval.
- **Lifecycle**: `_syncRecentCoverage()` runs at connect, on zone transfer, on every
  preference change (switch, window, coverage grid), on the Offline Mode switch in either
  direction, and on every zone check, and switched off on every terminal
  disconnect path (`_syncRecentCoverage(sessionEnded: true)` in the user-disconnect reset and
  in `_fullDisconnectCleanupImpl`), which also empties the cache. The sync gates on
  `hasApiSession` rather than `isConnected`, because the connected step is mirrored
  asynchronously from the connection's step stream and may not have landed when the
  post-connection setup runs. The GPS position stream never stops, so a lookup left active
  after disconnect would keep fetching tiles with no session. Auto-reconnect keeps the session
  and re-syncs through `_postConnectionSetup`, so the cache survives a BLE flap. Positions come
  from the GPS listener and from the auto-ping hook (iOS background).
- Logged under `[COVERAGE]` (tiles, session marks) and `[PING]` / `[DISC]` (skips).

### API Queue System

Three data flows (TX pings, RX observations, Discovery results) merge into unified API batch queue:

- **Storage**: Hive-based persistent queue survives app restarts
- **Batch Size**: Max 50 messages, auto-flush at 10 items or 30 seconds
- **Payload Format**: `[{type:"TX"|"RX"|"DISC"|"TRACE", ...}]`. TX/RX include `heard_repeats`; DISC includes `repeater_id`, `node_type`, `local_snr`, `local_rssi`, `remote_snr`, `public_key`; TRACE includes `repeater_id`, `local_snr`, `local_rssi`, `remote_snr`. Every type also carries `altitude` (whole meters, omitted when the phone did not know it; iOS reports height above mean sea level; Android usually reports height above the WGS84 ellipsoid, but Android 14+ substitutes mean sea level when the fix carries it, so one device can report either. The two references differ by the local geoid separation, up to ~100 m)
- **Authentication**: API key in JSON body (NOT query string)
- **Retry Logic**: Exponential backoff on failures. A 429 storm-brake answer holds the whole queue for the server's `Retry-After` without spending a retry (see Session Heartbeat)

### Offline Mode

`OfflineSessionService` enables wardriving when the API is unavailable (no network, maintenance mode, etc.). Data accumulates locally and can be uploaded later.

- **Storage**: SharedPreferences with key `offline_sessions` — JSON-encoded list of session objects
- **Session Format**: Each session has a filename (`YYYY-MM-DD.json`), creation timestamp, ping count, device info, and the wardrive data payload
- **Upload**: Sessions can be uploaded from Settings → Data when connectivity is restored
- **Non-persistent**: Offline mode is never persisted — always off on app restart. Users must re-enable if needed.
- **Maintenance integration**: When maintenance mode is detected while disconnected, the UI suggests using Offline Mode
- **Airborne pause**: while the airborne latch is set, no fix is appended to the offline recording (`ApiQueueService.setOfflineRecordingPaused`); the session itself ends through the normal airborne block. See GPS & Zone Validation.
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

"Carpeater" = co-located repeater with very strong signal, indicating the device is too close for meaningful coverage data. Three layers, checked in `TxTracker` and `RxLogger` in this order, and in `DiscTracker` with the regional check first:

- **The user's own CARpeater** (`UserPreferences.carpeaterPublicKey`, a full upper-case 64-hex public key, on while `ignoreCarpeater` is set; entered in Settings by the trace repeater picker or a validated text field). Pass-through: a TX echo or RX packet whose hop matches is stripped and the repeater behind it is credited with null SNR/RSSI; a single-hop packet via it is dropped; a discovery response from it is dropped. The hop is compared at its own width (2 to 8 hex) via `PacketValidator.isCarpeaterIdMatch`. The pre-share 6-hex prefix is wiped at load (`UserPreferences.stripLegacyCarpeater`), never migrated, and a persisted `carpeater_reentry_pending` flag makes `MainScaffold` prompt for the full key after the next connect (with a button to the Wardriving settings page; "Not now" repeats after the next connect, "I don't use a CARpeater" clears it, so does setting a key).
- **Regional CARpeaters** (`RegionalCarpeaterFilter`, `lib/services/meshcore/regional_carpeater_filter.dart`): the region's shared list. The app sends its own key as `carpeater` on connect and register auths (never on an offline-mode auth) and every auth answer carries `carpeaters`, which replaces the Hive cache (`user_preferences` box, key `regional_carpeaters`) in full, so an entry an admin deleted or retention aged out leaves the phone at the next auth and Offline Mode keeps the last copy. A missing field is an empty list. The filter excludes the user's own key while their switch is on; every other key is a plain drop, always, even with the user's filter off: someone else's CARpeater is in someone else's car, so neither it nor the repeater behind it may be credited. TX checks the first hop and the credited hop, RX the credited hop, both AFTER the own-CARpeater strip; discovery matches the full key. Regional drops are debug-log only (`[TX LOG]`, `[RX LOG]`, `[DISC]`), never error-log entries. Settings shows "Filtering N regional CARpeaters" with a list. The server caps one radio at 5 live tags per zone; `carpeater_error: max_reached` becomes an error-log entry plus a toast and never affects the connection. Contract: `MeshMapper_Server/docs/HANDOFF-app-regional-carpeaters.md`.
- **RSSI threshold**: Packets with RSSI >= -30 dBm are dropped as carpeater (constant `maxRssiThreshold`), skipped for an own-CARpeater pass-through; logged to the error log without auto-switching tabs under `[RX FILTER]`.
- **Validation pipeline**: RSSI check → packet type (GROUP_TEXT/ADVERT) → channel hash match → AES-ECB decryption → printable character ratio (60% minimum)
- **Files**: `lib/services/meshcore/packet_validator.dart`, `lib/services/meshcore/regional_carpeater_filter.dart`, `lib/utils/public_key.dart`

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

- **Accessible via**: Settings → About & Support
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
- **Timing**: Heartbeat fires **1 minute before** session `expires_at`. If already expired, sends immediately, but never more than one send per 30s (`minHeartbeatSpacing`). The floor matters because `expires_at` is server-clock while the delay math runs on the device clock: a device clock 4+ minutes fast (server TTL is 300s) makes every fresh expiry read as already due, and without the floor the "send immediately" path re-fired one POST per network round trip (the 2026-08-29 storm: 361k POSTs in 64 minutes from one device). An in-flight guard keeps re-entrant `scheduleHeartbeat` callers (upload success, per-ping session check) from stacking concurrent send chains, and a circuit breaker (`maxHeartbeatsPerMinute` = 6) pauses the lane for 60s as a backstop. Regression tests: `test/services/api_service_heartbeat_test.dart`.
- **Storm brake (429)**: a `rate_limited` answer from `/wardrive` carries `Retry-After` (75s by default) and keeps the session valid (server contract: `docs/APP_API.md` Appendix C item 9, "a 429 is not a sign-out"). `ApiService` parses it into one per-session hold, `wardriveBackoff`, that every sender on that door respects: `uploadBatch` returns `UploadResult.held` (no retry spent), `checkSessionValid` skips the post and reports the last known verdict so the ping itself proceeds, and the keepalive reschedules after the hold instead of going quiet. The brake re-arms its penalty on every blocked hit, so one lane knocking through it would keep all of them locked out. Without the keepalive reschedule, a braked session lapsed while the car was stopped (no ping or upload restarted the lane), the next post got a 401 and the app re-minted a fresh session id, which is exactly what the brake must not cause (VLC-20260903-0002). A new session id drops the hold. Tests: `test/services/api_service_rate_limit_test.dart`.
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

### MyMeshMapper Account + Companion Linking

Signs the user in to their portal account and offers to bind each connected
radio's Ed25519 pubkey to it, so their wardriving counts toward that account.
**Linking is strictly non-fatal — no failure may surface as an error or affect
a connection.** Mobile only (`!kIsWeb`). Server contract:
`MeshMapper_Server/docs/SPEC-app-portal-link.md`.

- **Sign-in**: system-browser PKCE (S256 only). `PkcePair` (`lib/utils/pkce.dart`)
  mints a 43-char verifier + challenge + independent `state`; the app opens
  `portal.php?app_authorize=1&…` with `LaunchMode.externalApplication` (an in-app
  WebView would see the user's password) and the portal deep-links back
  `meshmapper-auth://callback?code=…&state=…`. The exchange answers with the
  identity but NOT the linked pubkeys, so it is followed by one `me` call:
  without it the Settings account page lists no companions and no overview
  until the next radio connect happens to refresh it. That call runs AFTER
  `onSignInComplete`, so a device list that fails never colours the sign-in.
- **Scheme**: `meshmapper-auth` (host `callback`), registered in
  `ios/Runner/Info.plist` `CFBundleURLTypes` and the `MainActivity`
  VIEW/BROWSABLE intent-filter. Deliberately NOT the bare `meshmapper` scheme —
  that is a paste-only clipboard format (`docs/CUSTOM_API_ENDPOINT.md`,
  `meshmapper://custom-api?…`) and registering it would hijack those links.
- **Token**: 64-hex bearer in `flutter_secure_storage`
  (`SecureTokenStore`, keys `portal_app_token` / `portal_pending_pkce`;
  iOS `first_unlock_this_device`, Android EncryptedSharedPreferences in
  `MeshMapperSecure`). Reads NEVER throw — a restored Android backup carries
  ciphertext without the Keystore key, so the store wipes itself and reports
  signed-out. The secure-prefs file is excluded from backup in
  `res/xml/backup_rules.xml` and `res/xml/data_extraction_rules.xml`.
- **The PKCE pair is PERSISTED**, not held in memory: iOS routinely kills the
  backgrounded app while the user types their password in Safari. 10-minute TTL,
  burned after one exchange attempt, and the `code` is deduped because
  `app_links` 6.x delivers the cold-start URI on both `getInitialLink()` and
  `uriLinkStream`. That dedupe is a **claim/release pair**: `Set.add` is the
  atomic test-and-set at the guard (it must sit ahead of the first `await`), and
  the claim is released again on every path that declines to exchange — no
  pending pair, expired pair, state mismatch — so the genuine callback carrying
  that same code is never locked out.
- **An `error=` callback is honoured only when it answers a live attempt**: a
  pending pair must exist and its `state` must match, and the code is allowlisted
  (`^[a-z_]{1,32}$`, anything else collapses to `denied`). A deep link is
  unauthenticated — any app on the device can fire
  `meshmapper-auth://callback?error=x`, which would otherwise destroy a
  legitimate in-flight pair and push an arbitrary string into the UI.
- **A failed sign-in is reported by `MainScaffold`, not by the call site**: the
  browser round trip outlives the Settings tap that started it, so
  `onSignInComplete` lands with no live caller left to answer. The provider
  parks the sanitized code in `portalSignInError`; the scaffold drains it on the
  next frame, maps it to user-facing copy and calls `clearPortalSignInError()`.
  Only failures attributable to an attempt THIS app started get that far — an
  unsolicited callback (no pending pair, state mismatch) still returns silently
  by design, for the same reason the `error=` rule above exists.
- **Linking**: `requestNonce(pubkey)` → the app validates the answer is exactly
  64 hex / 32 bytes → `MeshCoreConnection.sign()` has the radio Ed25519-sign the
  **raw 32 bytes** → `linkDevice(pubkey, nonce, signature, label)` binds it. The
  app lane NEVER auto-adopts placeholders: `adoption_required` shows a dialog
  pointing at the browser portal.
- **The sign write gate**: `CMD_SIGN_DATA` is acked by a bare `OK (0x00)`, and so
  are `setFloodScope`, `setChannel`, `setPathHashMode`, `setAdvertName` and
  `setTxPower`. Every outbound frame in `connection.dart` therefore funnels
  through one private `_write(bytes, {isSignFrame})`, which queues non-sign
  frames behind `_signGate` for the few hundred ms a sign takes. `getChannel()`
  used to bypass `_sendToRadio` with a direct `_transport.write` — it now goes
  through the gate too. `disconnect()`, `deleteWardrivingChannelEarly()` and
  `dispose()` all call `_abortPendingSign()`, and the provider's user-initiated
  `disconnect()` calls the public `abortPendingSign()` **first**, before any
  teardown write, so a live sign can never park the advert-name/path-hash
  restore or the channel deletion behind its timeout.
- **When the prompt appears**: pure `decideLinkFlow()`
  (`lib/services/link_decision.dart`) — signed in, not offline, not anonymous,
  not auto-pinging, not auto-reconnecting, a pubkey exists, not declined, not
  already linked, firmware can sign, and not already asked **this app session**
  (per pubkey, so a BLE flap mid-drive cannot re-ask). Time-dependent backoff
  and the 5-attempt cap live in `AppStateProvider` just before that call; the
  dialog additionally gates on `isConnected`, since a pending prompt survives a
  disconnect but the handshake needs a radio to sign. Control flow reads
  `isPortalLoggedIn` (the live token), never `portalAccount != null` — the
  cached account is a display name that outlives the token.
- **Two strikes before a radio is written off**: an `unsupported` SignException
  bumps an in-memory strike and is persisted to `portal_sign_unsupported_devices`
  only on the SECOND one, because a stats/battery poller ERR already in flight
  when the sign starts is misattributed as `unsupported`. A server
  `bad_signature` has its own dedicated 2-strike counter (the generic attempt
  counter also holds nonce and network failures, so it cannot stand in). A local
  sign that succeeds clears the unsupported strike; a `LinkSuccess` clears BOTH
  counters and the persisted verdict.
- **A 429 is terminal and always carries `Retry-After`**: the portal's buckets
  slide and a blocked request does NOT reset the count, it re-arms a FRESH
  penalty (`me` is 12/hour with a 600s penalty, so a user who keeps tapping
  extends their own lockout). `_postWithToken` parses the header (delta-seconds,
  clamped to 1 hour, `PortalApi.defaultRetryAfter` = 5 min when it is missing or
  unparseable) into a per-route block, readable as `rateLimitBackoff(route)` and
  `linkLaneBackoff` (the longer of nonce/link). Three consumers:
  `refreshMe(force: true)` skips the LOCAL hourly throttle but NEVER a server
  block, and the Settings refresh button says how long to wait instead of
  claiming a refresh that never happened; `logout` does not retry into a 429
  and accepts the orphaned server token; `_recordLinkFailure` takes the longer
  of its own 30s..8m ladder and the server's value. A 429 is never a sign-out:
  401 + `token_invalid` stays the only signed-out signal.
- **Account page overview**: `me` also answers `overview: {points, weekly, grid,
  awards:[{name, description}]}`, the portal Overview tab's numbers, summed
  server-side over each companion's primary so a grouped radio counts once. The
  app never adds up the per-companion points itself. The block is absent on a
  server that predates it; the app reads that as unknown (`PortalOverview`
  null) and hides the Overview card rather than show zeros. The Account page
  lists every linked companion from `portalCompanions` (name, else label, else
  "Companion"; the key; a points pill above zero), runs the throttled `refreshMe`
  when opened, and forces one after a successful link so the totals catch up.
  `AppStateProvider.refreshPortalAccount` returns true only when the portal
  answered and the cache was replaced, so the app bar refresh says "Account
  refreshed" on true and "Could not refresh right now" otherwise, with the
  rate-limit toast still taking precedence. Widgets:
  `lib/screens/settings/account_overview_widgets.dart`.
- **Persistence** (Hive `user_preferences`): `portal_account_info`,
  `portal_linked_pubkeys` (UPPER hex), `portal_companions` (the same radios with
  label, name and points), `portal_overview`, `portal_link_declined_devices`,
  `portal_sign_unsupported_devices`. Sign-out clears the first four and keeps the
  last two, which are device preferences, not account data. On the first launch
  after the update only `portal_linked_pubkeys` exists; the load falls back to
  it and the next `me` fills the rest.
- **Logging**: everything is `[ACCOUNT]`, routed through a redactor that strips
  any live token / verifier / state / code, and `DebugFileLogger.scrubSecrets()`
  strips credential shapes from every line written to a log FILE (debug logging
  is on in release builds and those files ship with bug reports). Public keys
  appear as an 8-char prefix only.
- **Files**: `lib/utils/pkce.dart`, `lib/services/portal_token_store.dart`,
  `lib/services/portal_account_service.dart`, `lib/services/link_decision.dart`,
  `lib/services/meshcore/connection.dart` (`sign()`, `_write()`),
  `lib/providers/app_state_provider.dart`, `lib/screens/main_scaffold.dart`,
  `lib/screens/settings/account_settings_page.dart`.

### Coverage Overlay (vector tiles)

The MeshMapper coverage layer is rendered from the region server's vector tiles
(`vector_tile.php`, z7–14, overzoom beyond) as a MapLibre source+layer pair. The app is
vector-only — every region server must serve `vector_tile.php` (the legacy raster
`tiles.php` overlay was removed from the app 2026-06). Contract reference:
`MeshMapper_Server/docs/VECTOR_TILES.md`.

- **Styling is client-side**: each cell carries an integer status category `st`; colours
  come from `match` expressions built by `lib/utils/coverage_tile_palette.dart` (kept in
  sync with the server's `dev/cvd_palettes.php`, including all colour-vision palettes).
- **Coverage Grid preference (`prefs.coverageGridSize`)**: Simplified (300 m, default) or
  Detailed (100 m + blob), mirroring the web's Grid Mode; baked into the tile URL. The
  grid is locked to the chosen preset at every zoom — cells never resize.
- **Post-wardrive live refresh**: on upload success the queue hands the uploaded items to
  `AppStateProvider`; +7 s later the server re-renders the affected tiles at z11–14
  (`fresh=1`, incl. neighbouring tiles within ~0.005° — blob/border spill lands in the
  next tile over), and the user's own cells are decoded from the fresh z14 bodies
  (`lib/utils/mvt_cells.dart`) into a session **patch layer**: a GeoJSON source updated
  in place above the base layer, with the base layer's copies hidden via `setFilter`.
  The base source is never swapped — nothing visibly changes except the changed cells.
  A second check runs at +10 s only when the first found no changes. Logged under
  `[COVERAGE]`.
- **GOTCHA — never partial-update a fill layer**: `setLayerProperties` serializes with
  `skipNulls: false`; any `FillLayerProperties` field left null is RESET to its
  style-spec default on iOS/web (`fill-color` → black). Always resend the full colour
  expressions with an opacity change (see `_applyCoverageOverlayOpacity`).
- **GOTCHA — feature ids don't survive Android's filter bridge**: the platform converter
  parses filter JSON numbers as float32, which rounds the 42-bit cell ids. Filter on the
  small-int `i`/`j` properties (as an `"i_j"` string) instead — see
  `_applyBasePatchFilter`.
- **Files**: `lib/widgets/map_widget.dart` (`_addCoverageOverlay`, `_applyCoveragePatch`),
  `lib/providers/app_state_provider.dart` (`_freshenAffectedVectorTiles`),
  `lib/services/api_service.dart` (`freshenVectorTile`),
  `lib/utils/coverage_tile_palette.dart`, `lib/utils/mvt_cells.dart`.

### Coverage Connection Lines (tap-to-inspect)

Tapping coverage data draws connection lines from points the tap flow ALREADY
fetches (no extra network calls), matching the web client's exact matching +
fan-out logic (`MeshMapper_Server/dev/index.php`):

- **Tap a coverage tile (Feature A)**: fans out a theme-aware blue dashed line
  from the cell centre to every UNIQUE repeater that heard the cell's pings (with
  a distance pill per line) and hides the repeaters that didn't. Hooks the
  blob-filtered points already computed in `_showCellSummary`. Port of
  `updateAllActiveLines`/`updateActiveLinesInternal` via `heardEndpointsForCell`.
- **Tap a repeater (Feature B)**: draws the repeater's matched coverage cells
  (status/tile-coloured fills, deduped per grid cell with highest-priority status
  winning, red/DROP hidden) plus a status-coloured dashed line from the repeater
  to each cell centre. The base coverage tiles DIM and every OTHER repeater is
  hidden so the focused repeater's cells/lines pop (web `setSoloCircle` +
  tile-dim parity); both restored on close.
  Reuses the points fetched in `_showRepeaterDetails`. Port of
  `buildChartFromPoints` (`RepeaterStats.fromCoverageWithPoints`) +
  `drawRepeaterCoverageFromCache` (`repeaterCoverageCells`).
- **Volume cap**: both cap at the farthest 250 lines/cells (longest reach kept),
  logged under `[COVERAGE]` when truncated.
- **Layers** (`map_widget.dart`): `coverage-lines-layer` (shared A/B, per-feature
  `color`) and `coverage-cells-layer` (per-feature fill) — install-once empty,
  updated via `setGeoJsonSource`, kept separate from the focus-mode lines so the
  two features never wipe each other. Imperative draws (no `mapRevision` bump).
  Teardown funnels through `_clearCellHighlight` (A) and `_clearRepeaterIsolation`
  (B), which also restore the dimmed backdrop and the hidden/all repeaters.
- **Files**: `lib/widgets/map_widget.dart` (`_updateCoverageLines`,
  `_updateCoverageCells`, `_drawRepeaterCoverage`, `_syncCoverageDistanceLabels`),
  `lib/utils/coverage_summary.dart` (`heardEndpointsForCell`,
  `repeaterCoverageCells`, `RepeaterStats.fromCoverageWithPoints`),
  `lib/utils/coverage_tile_palette.dart` (`colorsForStatus`).

### Apple Companion Surfaces (Watch + Live Activity)

Both surfaces are **projections of phone-owned state**. The phone keeps the
MeshCore connection, the GPS fix, the session lifecycle, the transmit policy and
command admission; the wrist and the Live Activity render that state and send
intent back. Nothing on either surface may decide that a transmit is legal.

`docs/LIVE_ACTIVITIES.md` covers the ActivityKit half. The invariants below
belong to the watch bridge, and breaking one of them costs battery on two
devices or puts a packet on air from the wrong place.

**Delivery and suppression** (`lib/services/watch/watch_bridge_service.dart`)

Every gate runs before the next, and each exists for a different failure:

1. **Debounce** — 200 ms. Coalesces a burst of `notifyListeners()`.
2. **Urgency preflight** — the flush decides whether it may wait *before*
   building anything. `WatchSnapshot.buildUrgencyKey` is a small scalar
   projection (session, mode, phase, connection, control enablement, cue ID,
   map-geo inclusion); if it hasn't moved, the 2 s floor applies and no
   geography is constructed, sorted or encoded. `LiveActivityService` mirrors
   this with `LiveActivitySnapshot.buildPreflightUrgencyKey` and a 15 s floor.
   **Sustained per-tick work is the thing to avoid here** — the countdown
   timers drive a flush at ~2 Hz for a whole session, and this app has a
   wardriving overheat history.
3. **Payload fingerprint** — JSON of the payload minus `updatedAtMs`. Timestamp
   metadata must never defeat dedupe; the watch renders countdowns from the
   absolute `phaseEndsAt` deadline instead. An explicit `forceRefresh` is the
   one thing that may send an identical payload again.
4. **Movement gate** — `WatchWire.minMoveMeters` (15 m). Expressed as "nothing
   but the fix changed, and the fix didn't move far enough", measured against
   the fix the watch last *received*. A refused or dropped send must not
   consume the wearer's next 15 m.
5. **Send throttle** — the same 2 s floor, applied to delivery. A forced
   refresh outlives a deferral rather than being dropped.

Urgent updates use `sendMessage` and *always* fall through to
`updateApplicationContext`, so a missed message can't strand the watch.

**The two paths are not ordered against each other, and the watch enforces
that.** `sendMessage` does not populate `receivedApplicationContext`, so the
retained context can hold a payload the watch already superseded live — and
`resume` ingests that context on every wrist raise. `WatchSessionClient.apply`
therefore refuses anything whose `updatedAt` predates what is already rendered.
Both stamps come from the one phone clock, so they compare raw. The refusal is
lifted once the held snapshot is stale, which bounds a backwards clock step to
90 seconds of refusal instead of the life of the process. There is deliberately
no wire `seq`: a counter restarting at zero is indistinguishable from an ancient
one without a process identity beside it, which is a version conversation for
behaviour this already has.

**Cache invalidation.** Dart's dedupe caches mirror native's `lastContextData`.
Native clears that only in `sessionWatchStateDidChange` and on `clear`, and says
so with `nativeCacheCleared` on the `availabilityChanged` push. Reachability
flips on every wrist raise and lower — treating those as invalidation forces a
full context resend per glance and voids the map-geo lease.

**Map-geo lease.** While the map isn't visible the watch asks the phone to omit
geography. The phone treats that as a *lease*, not a latch: suppression expires
after `_mapGeoClaimFreshFor` (10 min) back to full geography, and the watch
renews it every 5 minutes. A lost command therefore fails safe — toward sending
too much rather than a permanently blank map. Renewals are deduplicatable;
only a stated `forceRefresh` defeats the payload fingerprint.

**Command admission.** Wrist commands are intent, revalidated by the phone.
`transferUserInfo` is the *only* transport — there is deliberately no
`sendMessage` path into admission, because that can execute a command and still
fail its reply as undeliverable, leaving the wrist unable to tell a refusal from
a lost ack.

- IDs make WatchConnectivity's redelivery idempotent. A *queued* command refused
  once stays remembered — redelivery after conditions change must never turn
  yesterday's tap into a transmit. Only an untimestamped command forgets, since
  it cannot be aged and its sender may legitimately retry.
- A redelivery is answered with the **outcome recorded the first time**, not a
  blanket acceptance. Replying "accepted" to the redelivery of something the
  bridge refused describes a transmit that never happened.
- Timestamped commands must land inside `_maximumCommandAge` (30 s), with
  `_clockTolerance` (5 s) of slack in both directions.
- **The two devices do not share a clock, and that is a normal condition.**
  `issuedAtMs` is stamped in the watch's clock and the command carries
  `clockOffsetMs` beside it, so the phone measures a real elapsed age rather
  than an age plus the skew. The watch learns that offset only from a live
  `sendMessage`, whose transit is milliseconds; an application context may have
  sat retained for hours and says nothing about the current offset. Absent
  offset means zero, which is the old behaviour exactly. `_clockTolerance` now
  covers the residual — transit and measurement error — not the skew itself.
  The offset is *not* folded into `issuedAtMs`, because that value doubles as
  the ordering key for map-geo suppression claims and rewriting it would make
  the key jump backwards the first time an offset is learned.
- `requestSnapshot` and `stopSession` are exempt from the age window: one
  transmits nothing, and the other takes the radio *off* air, so lateness can
  only make refusing it worse. **A stop therefore names its session**, from the
  snapshot the wearer was looking at when they tapped, and is refused if the
  phone has since moved on. Without that the exemption assumed one session was
  as good as another, and a stop queued against A could silently end B. The
  field is optional: absent means an older watch build and is admitted as
  before, because refusing those would strand a wearer whose Stop button the
  phone had quietly stopped honouring.
- `resolveSessionStartAvailability` is the single start gate for both the
  offered button and the admitted command. **Passive counts as transmitting** —
  it sends a discovery request on start and every 30 s — so the manual-ping,
  RX-window and cooldown guards apply to every mode. Only offline mode,
  passive-only zones, flood traffic being off, and TX validation are
  transmit-only.
- **Flood traffic is an existence policy, not a preference.** The phone builds
  Send Ping and the Active/Hybrid button inside
  `if (!txNotAllowed && floodTrafficVisible)`, so with flood off those controls
  do not exist — and `floodTrafficEnabled` folds in the regional
  `flood_disabled` veto a zone admin sets. It gates the wrist on both sides:
  `resolveAvailableWatchStartModes` withdraws Hybrid, and
  `resolveSessionStartAvailability` plus `_manualPingAvailability` refuse with
  'Flood Traffic Off'. The preference **defaults off**, so a wrist that skips
  this admits the common configuration rather than an edge one.

**Failure cues.** A one-shot cue rides *every* snapshot until it is older than
`WatchWire.cueReadableFor` (90 s), which mirrors `WatchSessionClient.staleAfter`.
It is deliberately **not** dropped when native accepts a payload carrying it:
that reply means `updateApplicationContext` took the blob, not that the watch
ingested it, and the wearer's wrist is usually down at that moment. Because the
cue ID is in the urgency key, dropping it there made the very next flush urgent
and overwrote the retained context with a cue-less payload — so a suspended
watch woke to idle UI and no account of the failure. Re-attaching is free: the
watch keys haptics on `presentedCueIDs` and drops the cue itself past the
boundary rather than asserting a dead failure as current.

`presentedCueIDs` is process-local, so that de-duplication covers WatchConnectivity
redelivery but **not** a watch process that dies and relaunches. Launch ingests
the retained context, and a cue still inside `cueFreshFor` (30 s) buzzes again
against an empty set. Widening the attachment window from about a second to 90 s
widened that case with it — deliberately. One duplicate haptic after a relaunch
is a far smaller failure than the silence it replaced, and closing it properly
means persisting presented IDs across launches for a payload the watch is
already re-reading on purpose.

**Wire versioning** (`WatchWire.version`, mirrored in
`ios/Shared/MeshMapperWatchPayload.swift`)

Bump only when a field **changes meaning or is removed**. Additive optional
fields must not bump it: a bump strands compatible pairs, and older peers are
required to default absent fields safely. The watch reads `wireVersion` with a
minimal probe struct *before* attempting the full decode, so a payload that a
future breaking change makes undecodable still reaches the "update the iPhone
app" prompt instead of going silently stale.

**One heard list.** The map's Top Heard box (`_topRepeatersOverlay`, the
latest ping's top three by SNR, plus the passive RX slot) is the single source
for the watch's heard rows (`ExternalSurfaceGeoBuilder.buildHeard`) and the
Live Activity's rows (`buildLiveActivityHeard` in
`lib/services/live_activity/live_activity_heard.dart`). It is replaced only by a
ping that heard something (direct TX echoes, discovery nodes, a successful trace
at its window's close), so a silent ping leaves the last heard set in place on
all three; the Live Activity marks rows from before the latest send as last
heard rather than wiping them. Multi-hop echoes are not in it. The Live Activity
used to keep a private list with other rules and drifted from the map.

**Geography caps** — `maxPings` 60, `maxRepeaters` 20, `maxHeard` 4. Applied by
`WatchGeoBuilder` on the sending side, after merging every source and sorting by
recency, so a busy TX history cannot erase discovery or trace markers.

**Heard-row names** resolve from the fullest identity each row arrived with,
via `WatchGeoBuilder.resolveOverlayRepeaters`. A path hash is 1–3 bytes and in a
busy zone routinely matches several repeaters, where naming one would be a coin
flip — but the phone often knows exactly who answered: a discovery response
carries the responder's full 64-character public key, and a trace carries its
4-byte target. Those identities travel beside the overlay rows in
`_overlayIdentityById`, **replaced wholesale per ping and never merged**, because
a hash that meant one repeater in a discovery response says nothing about who a
later TX echo under the same hash was.

TX echoes and passive RX carry only the path byte, so they fall back to prefix
matching and keep refusing to guess. That fallback indexes per *distinct*
prefix length: the RX slot's hash can be a different width than the top rows',
so a single-length index silently drops the odd row's name and distance.

Uniqueness is required at every step. A longer identity makes a collision
vanishingly unlikely, not impossible, and a confidently wrong name stays worse
than none. **Never resolve names on the watch** — it holds only the nearest 20
repeaters, so it would name rows the phone refused as ambiguous across the full
catalogue.

**Live Activity host support.** ActivityKit answers `sync` with `true`, `false`,
or `"unsupported"`. `false` means *not right now* — authorization is off, or
`Activity.request` was refused because the app is backgrounded — and earns the
30 s backoff. `"unsupported"` (and a `MissingPluginException`) means this host
can never show one, and Dart stops asking for the rest of the process rather
than running a guaranteed-fail retry loop all session.

**App Intents, Siri, and future Apple surfaces.** Every App Intent in this app
is iOS 26+: the extension has a 26.0 deployment target and the Runner intent
types are annotated `@available(iOS 26.0, *)`. Devices below that get none of
these Siri actions, and none of the app's other surfaces depend on them.

Mutation intents live in the
Runner process because session and connection changes must pass through the
same phone-owned admission path as the watch. Read-only intents *run* in a
separate extension against the bounded App Group snapshot in
`ios/Shared/AppIntents/`; they must not launch Flutter.

**There is exactly one `AppShortcutsProvider`, `MeshMapperAppShortcuts`, and it
lives in the Runner target.** App Shortcuts are indexed from the app, so a
provider inside the App Intents extension is never registered and its phrases
silently do nothing when spoken: no error, just a pause and no result. Apple
additionally requires that every intent a provider names is a member of the
*same* target as the provider, which is why the read intents and their entities
(`MeshMapperReadIntents.swift`, `RepeaterEntity.swift`,
`HeardRepeaterEntity.swift`) are compiled into Runner **and** the extension.
Dual target membership is Apple's documented arrangement for an intent that
backs an App Shortcut and must also run in an extension; a shared framework is
explicitly not an option for these. The provider is capped at ten shortcuts
(five are used), and exceeding it is a compile error.

When adding a read intent: add its file to both targets, and add the shortcut to
`MeshMapperAppShortcuts`, never to a second provider. Despite its historical `Siri` type names and
`siri-snapshot.json` filename, that Foundation-only snapshot is the reusable
low-frequency contract for future native glance surfaces.

Keep future targets separated by lifecycle:

- A widget may read the App Group snapshot directly and add only optional,
  bounded fields to wire version 1. A meaning change or removal requires a
  coordinated version bump.
- The last valid snapshot deliberately survives Runner termination. Read
  intents qualify it by age; process teardown is not proof that a background
  session stopped, and `dispose()` is not a reliable iOS lifecycle callback.
- Adopt `IndexedEntity` only with an explicit owner that calls
  `indexAppEntities` and removes stale entries. Conformance alone does not put
  repeaters in Spotlight.
- A CarPlay map scene needs its own native scene/target, entitlement and
  foreground lifecycle. It may bootstrap from the shared snapshot, but live
  location/map updates need a dedicated bridge rather than polling the Siri
  file or importing `SiriIntentCoordinator`.
- Every added target gets its own bundle ID, App Group entitlement and explicit
  App Store provisioning-profile entry. Do not put target-specific frameworks
  or lifecycle into the shared snapshot model.
- Native controls express intent; Dart remains the owner of connection,
  session and radio-policy admission.

**One deadline, both sides.** `SiriIntentCoordinator` stops waiting after
`SiriCommand.responseTimeout` (10 s, or 30 s for Connect) and tells the person
it failed. That same instant travels to Dart as `expiresAtMs`, so giving up is
one decision rather than two, and it is rechecked at three points:

1. Admission refuses an already-expired command outright.
2. `toggleAutoPing`/`sendPing` recheck after the awaited session check, before
   any existing mode is torn down.
3. `PingService` rechecks in `sendTxPing` and `_sendDiscoveryRequest` after
   **both** of the unbounded waits that precede a transmission, and before any
   of the early returns that follow, not just before the BLE call. Nothing
   between that check and the wire awaits, so it is the send instant in
   wall-clock terms while leaving no `TxPing`/`DiscLogEntry` record and no
   consumed wire-tag counter behind for a transmission never made.

   Both details are load-bearing, and each was got wrong once:

   - **Ahead of the early returns.** The `null`-position and "too close to last
     discovery" returns call `_scheduleNextDiscovery()` and report success, so a
     check below them lets a GPS fix that crossed the deadline start a session
     that transmits on the next tick anyway.
   - **After the write gate, not just after GPS.** `MeshCoreConnection._write`
     parks non-sign frames behind an in-progress `CMD_SIGN` (five seconds per
     phase, chunk phase looping), and that wait is unbounded by design ("delayed,
     never failed"). It sits *inside* the send call, past everything a caller can
     check. `awaitWritableState()` exists so a deadline-carrying caller takes
     that wait where abandoning is still free; it is awaited only on that path,
     so ordinary pings keep queuing exactly as before.

Point 3 is the one that matters: Passive and Hybrid await a GPS fix *inside*
`enableAutoPing`, so points 1 and 2 alone would let the radio key up after Siri
had already reported cancellation. When the gate fires there,
`_abandonAutoPingStart()` unwinds the half-started session and `enableAutoPing`
returns false, so the session does not come up either. Active mode's initial
ping is awaited only when a gate is supplied, so the ordinary start path keeps
its existing fire-and-forget timing.

`PingService.transmitAbortedByDeadline` distinguishes "the caller had already
given up" from the ordinary reasons a send is skipped: cooldown, failed
validation, no GPS. It is reset on entry to every gated path, and both the start
and the manual-ping paths read it so the refusal says the request arrived too
late rather than the generic "couldn't send the ping".

The gate reaches only the session's *first* transmission; later pings come from
timers and belong to the session, not to the surface that started it. Checks 2
and 3 also close `externalCommandCommitMargin` early, because work that has not
begun cannot finish inside a deadline that is nearly gone; check 1 applies no
margin and refuses only a command that has already expired. Stop stays exempt
throughout; stopping is the safe direction, and a safe-direction command must
never be abandoned because a voice request timed out. A surface that sends no
`expiresAtMs`, such as the watch, still falls back to the shared 30-second
`maximumExternalCommandAge`.

**Connect's 30 seconds is a response deadline, not a cancellation guarantee.**
This is the one mutation where the two differ, and the difference is deliberate.

Up to the point of dialling, Connect behaves like the rest:
`_connectToLastCompanion` checks the deadline as soon as the 10-second readiness
wait ends (a cold launch can spend that whole budget before admission has even
run), `resolveLastCompanionConnection` then checks `expiresAt` ahead of the age
rule and ahead of every state-based refusal, and it requires
`externalCommandCommitMargin` before dialling. Refusing there is free and avoids
pointless transport churn.

Once dialling starts there is no way back: `connectToDevice`/`connectViaTcp`
have no cancellation seam, and a BLE GATT phase alone may run 15 seconds before
protocol setup and authentication. A reconnect begun with ~20 seconds left can
therefore finish after the intent has given up; that is ordinary, not an edge
case, which is why the preflight margin is a sanity check rather than a
guarantee. Such a reconnect is deliberately left connected: it transmits nothing
on the mesh, starts no session, and is what the person asked for; tearing it
down would only make them wait out another cold reconnect.

Because of that, `SiriCommand.Kind.timeoutMessage` is per-kind, and the rule is
that only a kind which really is cancelled may say so:

| Kind | On timeout | Why |
| --- | --- | --- |
| Start, Manual Ping | "…the request was cancelled" | True: Dart holds the same deadline and checks it before every RF send. |
| Connect | "…may still be connecting" | No cancellation seam once a transport is dialling. |
| Stop | "…may still be stopping" | Deliberately deadline-exempt, and teardown may queue a pending disable behind an RX window. |

**Adding a kind means deciding which column it belongs in.** Connect earns the
first wording only if `connectToDevice`/`connectViaTcp` gain a cancellation
seam; Stop only if it is made cancellable, which it should not be. Until then,
do not change either message back.

**"Current session" needs a session boundary.** The observation history is
bounded at two hours, which routinely spans several sessions. `session.startedAt`
carries the running session's start so the Recent Repeaters intent can filter
against it, and `uniqueRepeatersHeard` counts only observations at or after it;
with nothing running both report empty rather than borrowing the previous
session's results.

The boundary must be captured *before* the session's first transmission, not
after it: `enableAutoPing()` sends and records the opening discovery before it
returns, so taking the timestamp afterwards would push a Passive or Hybrid
session's own first observation outside its boundary. `toggleAutoPing` therefore
reads the clock before the call and passes it to `_startLiveActivitySession`,
and the filter is inclusive of that instant. A manual ping that is later upgraded
to an automatic mode deliberately keeps its original boundary: that is one
session under one ID, and the manual ping and its RX window are that session's
own results. Any surface that says "current" or "this session" must also
check `updatedAt` against `MeshMapperSnapshotFreshness.currentClaimLimit`; the
snapshot deliberately outlives Runner and can be days old.

The snapshot contains at most 64 recent observations and 64 repeaters. That
catalogue bound is also the entity-lookup bound: `RepeaterEntityQuery` searches
only the cached active/recent entries, never the full loaded repeater set, which
is why the intent is named "Find Recent MeshMapper Repeater". Widening the
lookup means widening the catalogue or adding a separate compact index. Do not
leave a broad name over a narrow index, and keep that in mind when reviving the
withdrawn phrase, since an empty or stale catalogue is one candidate cause of
the lookup failure. Recent
observations are ranked and truncated before catalogue identity resolution, so
large histories do not multiply the resolution work. A cheap scalar/revision
preflight key suppresses rebuilds when provider notifications do not change
the native projection. Preserve both bounds and the preflight path when adding
fields for another Apple surface.

The built-in voice phrases are refreshed at app launch. After installing an
update, open MeshMapper once, then use any of these forms (the app name is part
of every registered phrase):

- `Siri, reconnect MeshMapper` or `Siri, connect MeshMapper to the last device`.
- `Siri, start MeshMapper` defaults to Passive Discovery.
- `Siri, start a Passive Discovery session in MeshMapper`.
- `Siri, start Active mode in MeshMapper`.
- `Siri, start Hybrid mapping with MeshMapper`.
- `Siri, stop MeshMapper`.
- `Siri, what is MeshMapper doing?` or `Siri, get MeshMapper status`.
- `Siri, what has MeshMapper heard?` or `Siri, recent repeaters in MeshMapper`.

Repeater lookup by name has no spoken phrase. `FindMeshMapperRepeaterIntent`
ships and can be used from the Shortcuts app, but spoken lookup did not work on
device and its `AppShortcut` is withdrawn until it does (see the TODO on the
intent). Adding the phrase back means adding the bullet back here.

Mutation intents return their completion message both as Siri dialog and as a
text output. A user-created Shortcut can pass that Result to a `Speak Text`
action when explicit audio is required. Direct Siri invocations normally speak
the dialog, but iOS still honors the system Siri Responses setting; select
Prefer Spoken Responses when voice feedback is required even in Silent mode.

Connect and Start require device authentication and may bring the app forward.
Connect reuses the last remembered BLE/TCP companion; USB still requires an
in-app selection. Connect can also outlast Siri's 30-second wait: a slow radio
may finish connecting after Siri has stopped listening, which is why its timeout
says the app may still be connecting rather than that the request was cancelled.
Starting does not silently change companions or reconnect; ask to connect first
when MeshMapper is disconnected.

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
- minSdkVersion: 24 (Flutter's `flutter.minSdkVersion` default; MapLibre GL needs 23+)
- Supports Android Auto. Testing needs Desktop Head Unit, and can not be tested against a physical head unit.
- Background location permission for continuous tracking
- Uses `flutter_blue_plus` package
- URL scheme `meshmapper-auth` (host `callback`) registered on MainActivity via a VIEW/DEFAULT/BROWSABLE intent-filter — the portal sign-in return. The bare `meshmapper://` scheme is deliberately NOT registered: it is a paste-only clipboard format (`docs/CUSTOM_API_ENDPOINT.md`).
- `android:fullBackupContent` / `android:dataExtractionRules` exclude the `MeshMapperSecure` secure-prefs file from backup

### iOS
- Requires Info.plist entries: NSBluetoothAlwaysUsageDescription, NSLocationWhenInUseUsageDescription
- Deployment target: 13.0
- Background modes: bluetooth-central, location
- Uses `flutter_blue_plus` package
- `CFBundleURLTypes` registers the `meshmapper-auth` scheme (name `net.meshmapper.app.auth`) for the portal sign-in return

## Dependencies

Key packages used in this project:

- `flutter_blue_plus`: Mobile Bluetooth (Android/iOS)
- `flutter_web_bluetooth`: Web Bluetooth (Chrome/Edge)
- `flutter_carplay`: Android Auto templates — **vendored & patched**, see below
- `geolocator`: GPS/Location
- `maplibre_gl`: Map rendering (MapLibre GL vector tiles via OpenFreeMap) — **vendored & patched**, see below
- `hive`: Local storage
- `provider`: State management
- `http`: API requests
- `pointycastle`: Encryption (AES-ECB, SHA-256)
- `usb_serial`: USB Serial communication on Android (USB OTG)
- `app_links`: Custom-scheme deep links (`meshmapper-auth://callback`) for the portal sign-in return
- `flutter_secure_storage`: Keychain / Android Keystore storage for the portal app token

### Vendored `maplibre_gl` (`third_party/maplibre_gl`)

`maplibre_gl` is consumed from an in-repo copy of the pub.dev `0.25.0` release via
`dependency_overrides` in `pubspec.yaml`, **not** from pub. The ONLY delta from upstream is a
native camera-viewport guard.

**Why:** MapLibre's transform unprojects against the live viewport. When the GL surface is
degenerate/zero-sized (e.g. a launch where tiles never finish loading, so the surface never renders
a real frame), the very first animated `flyTo`/`setCamera` makes `unproject` produce NaN, and
`mbgl::LatLng`'s constructor throws an **uncaught C++ `std::domain_error` → SIGABRT**. That throw
crosses the Obj-C++→Swift/JNI boundary and **cannot be caught from Dart**, so the only place it can
be reliably stopped is inside the plugin's camera handlers.

**The patch:** the `camera#animate` / `camera#move` / `camera#ease` cases in
`MapLibreMapController.swift` (iOS) and `MapLibreMapController.java` (Android) bail (completing the
method-channel result so the Dart `await` returns) when the map view has no usable size
(`bounds.width/height < 1` / `getWidth()/getHeight() < 1`). Search the patch with the tag
`MESHMAPPER GUARD`.

The Dart side (`map_widget.dart`) is defense-in-depth: `_mapHasRenderedOnce` (set on the first
`onMapIdle`) is folded into `_canAnimateCamera`, so no programmatic camera move is even attempted
until the map has rendered once; the one-shot initial GPS zoom re-attempts on later ticks instead of
burning. See the `_canAnimateCamera` getter and `_onMapIdle`.

**On upgrade:** re-apply the `MESHMAPPER GUARD` blocks to the new plugin version (or drop the
override if upstream gains an equivalent guard).

### Vendored `flutter_carplay` (`third_party/flutter_carplay`)

Consumed from an in-repo copy of the pub.dev `1.6.5` release via `dependency_overrides`, **not**
from pub. Despite the name it is used for its **Android Auto** half only — CarPlay is not shipped.
Three deltas from upstream, each tagged `DELTA` in the vendored source:

- **DELTA A** (`third_party/flutter_carplay/pubspec.yaml`): the `ios:` plugin platform entry and
  the whole `ios/` directory are removed. Upstream would link `SwiftFlutterCarplayPlugin` into the
  App Store build — a CarPlay scene-delegate and entitlement surface we neither want nor hold
  Apple's CarPlay entitlement for. The Dart `AA*` classes are pure Dart plus a MethodChannel and
  still compile on iOS, where `AndroidAutoService.isSupportedPlatform` is false.
- **DELTA B** (`AndroidAutoService.kt`): adds `FAAEngineProvider`, letting the host app supply the
  engine. Upstream builds a bare headless `FlutterEngine` whenever the cache is empty, which in
  this app is the **wrong** engine — ours owns the USB serial and tile cache channels (see
  `MeshMapperEngine.kt`), and two engines means two copies of every plugin fighting over this
  plugin's own static template state.
- **DELTA C** (`AndroidAutoService.kt`): `createHostValidator()` no longer returns
  `ALLOW_ALL_HOSTS_VALIDATOR` unconditionally. Android documents that as debug-only — it lets any
  app on the device bind the service and drive the car surface — so release builds validate against
  the car-app library's bundled host allowlist. Debug builds keep the permissive path, which is
  what the Desktop Head Unit needs.
- **DELTA D** (`FlutterAndroidAutoPlugin.kt`, `AndroidAutoService.kt`, `Session.kt`,
  `lib/aa_models/map/`): adds `MapWithContentTemplate`, its map action strip
  (`MapController` + `AAMapAction` + an `onMapActionPressed` event), and a `FAASurfaceProvider`
  hook. It also makes `AAPaneTemplate`'s title optional: upstream requires a
  non-empty one, but `PaneTemplate.Builder.build()` does not — it validates only rows and
  actions — and the title is what draws the header. Upstream
  supports six templates, none of which can show a map. The hook lets the host app supply the
  `SurfaceCallback`, so MeshMapper's MapLibre renderer lives in the app rather than teaching the
  plugin about a map SDK — the same shape as DELTA B.

`example/`, `previews/` and `test/` are not vendored.

**On upgrade:** re-apply all three deltas.

### Android Auto (`lib/services/auto/`)

The coverage map on the head unit, plus a glance at session state, counters, and one-touch
start/stop. Category is **POI** (`androidx.car.app.category.POI`), because drawing a map is limited
to the navigation, POI and weather categories.

```bash
adb shell cmd package query-services -a androidx.car.app.CarAppService | grep -A3 meshmapper
```

Expect `AndroidAutoService`, `exported=true`, `enabled=true`, and
`Category: "androidx.car.app.category.IOT"`.

**One-time phone setup.** In the Android Auto settings screen, tap the version header 10× to unlock
developer mode, then from the ⋮ menu:

- **Unknown sources** — ON. Required. An unpublished car app is *not listed at all* without it.
- **Start head unit server**.

**After every install of a changed build** — including every `flutter run` — restart the Android
Auto session so it rescans:

```bash
adb shell am force-stop com.google.android.projection.gearhead
```

Not a superstition. Android Auto builds its car-app list by querying `PackageManager` when a
session starts and caches it; `dumpsys package com.google.android.projection.gearhead` shows it
registers only `MY_PACKAGE_REPLACED` (for itself) and **no** `PACKAGE_ADDED`/`PACKAGE_CHANGED`
receiver for other packages. It therefore cannot notice a car app installed after it started. A
freshly installed or updated MeshMapper stays invisible until Android Auto is restarted.

**Connect:**

```bash
adb forward tcp:5277 tcp:5277
$ANDROID_HOME/extras/google/auto/desktop-head-unit   # ~/Android/Sdk/extras/google/auto/
```

The phone screen must be unlocked. MeshMapper appears in the DHU launcher and opens to the four-row
pane — briefly a loading spinner first if Dart has not published a template yet, since the plugin's
`MainScreen.onGetTemplate` falls back to a loading `ListTemplate`.

**`flutter run` and the DHU.** The DHU is **not** a Flutter device: it never appears in
`flutter devices` and is never a `flutter run` target. `flutter run` targets the phone; the car pane
is drawn by that same isolate.

**Order matters.** Run `flutter run` *first*, then connect the DHU: `MainActivity` creates the
engine, `flutter run` attaches to it, and `FAAEngineProvider` (DELTA B) hands that same engine to
the car service — so **hot reload reaches the pane**. Connect the DHU first and Dart starts headless
in a process `flutter run` never launched; use `flutter attach` to pick it up.

Debug builds accept any car host, because DELTA C keeps `ALLOW_ALL_HOSTS_VALIDATOR` for debuggable
builds — that is what lets the DHU bind. Release builds validate against the car-app library's
bundled allowlist, which Android Auto is on, so the DHU works there too.

**The two checks that matter:**

- **Template quota.** Turn on **Developer settings → Enable debug overlay** and watch the template
  counter across a full auto-ping session. If counter updates consume steps, the row layout is
  wrong — see the fixed-layout contract above.
- **One engine.** Cold start with `adb shell am force-stop net.meshmapper.app`, then connect.
  `[APP] MeshMapper starting...` must appear in logcat **exactly once**. Twice means a second engine
  and the `MeshMapperEngine` ownership rule has a hole.

**Logs:** `adb logcat -s CarApp.H CarApp.H.Dis flutter`, after
`adb shell setprop log.tag.CarApp.H.Dis VERBOSE`.

**Play submission:** car support needs Google's Android Auto review, declared in Play Console →
*Declare car compatibility* → POI. While a car submission is under review, subsequent app updates
are blocked — so ship it in its own release, not bundled with an urgent fix. Everything
car-specific is one `<service>` block in the manifest plus `lib/services/auto/`; deleting the
service element disables the surface without touching Dart.

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
| `[SIRI]` | Siri App Intents bridge and snapshot publishing |
| `[EXTERNAL]` | External command execution (shared Siri/watch lane) |
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
| `[WATCH]` | WatchConnectivity bridge: availability, snapshot delivery, wrist commands |
| `[LIVE ACTIVITY]` | ActivityKit bridge: sync, end, authorization failures, one line per publish and per held window |
| `[ACCOUNT]` | MyMeshMapper portal sign-in and companion device linking |

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
- `lib/screens/settings_screen.dart` - Settings tab: one row per settings folder, each opening a page under `lib/screens/settings/`
- `lib/screens/settings/` - Settings folder pages (General, Map, Wardriving, Data, MeshMapper Account, API Endpoints, About & Support, Developer Tools) plus the shared section card and auto-ping lock banner
- `lib/services/meshcore/connection.dart` - 9-step connection workflow, MeshCore protocol
- `lib/services/meshcore/unified_rx_handler.dart` - Packet routing (TX vs RX)
- `lib/services/meshcore/tx_tracker.dart` - Repeater echo detection (7s window)
- `lib/services/meshcore/disc_tracker.dart` - Discovery response tracking (7s window)
- `lib/services/meshcore/rx_logger.dart` - Passive observation logging
- `lib/services/transport/companion_transport.dart` - Transport-agnostic interface for companion connections
- `lib/services/transport/stream_frame_codec.dart` - TCP/USB Serial framing codec
- `lib/services/transport/stream_transport_base.dart` - Shared base for TCP/USB Serial transports
- `lib/services/transport/tcp_service.dart` - TCP socket transport with saved connections
- `lib/services/transport/android_serial_service.dart` - USB Serial transport for Android (USB OTG)
- `lib/services/transport/web_serial_service.dart` - USB Serial transport for Web (Web Serial API)
- `lib/services/ping_service.dart` - TX/RX/Discovery ping orchestration
- `lib/services/gps_service.dart` - GPS tracking and geofencing
- `lib/services/recent_coverage_service.dart` - Smart Pinging lookup: recently covered cells from filtered z13 tiles
- `lib/services/airborne_release.dart` - Pure builder for the airborne session-end text and release telemetry
- `lib/services/api_queue_service.dart` - Persistent upload queue
- `lib/services/device_model_service.dart` - Device model identification
- `lib/services/background_service.dart` - Background operation (Android foreground service, iOS background modes)
- `lib/services/audio_service.dart` - Sound notifications for TX/RX events
- `lib/services/offline_session_service.dart` - Offline wardriving session storage
- `lib/services/debug_file_logger.dart` - Debug log file rotation and upload
- `lib/services/debug_submit_service.dart` - Bug report submission (4-step workflow)
- `lib/services/gps_simulator_service.dart` - GPS simulation for testing
- `lib/services/wakelock_service.dart` - Screen wake lock during auto-ping
- `lib/services/portal_account_service.dart` - MyMeshMapper portal lane (PKCE sign-in, nonce/link/unlink/me/logout)
- `lib/services/portal_token_store.dart` - Keychain/Keystore storage for the portal token and pending PKCE pair
- `lib/services/link_decision.dart` - Pure decision for whether to offer a device link
- `lib/utils/pkce.dart` - RFC 7636 S256 PKCE pair generation
- `lib/services/watch/watch_bridge_service.dart` - WatchConnectivity transport: throttle, dedupe, movement gate, map-geo lease, command admission
- `lib/services/watch/watch_models.dart` - Watch wire contract and shared start-admission resolver
- `lib/services/watch/watch_geo_builder.dart` - Ping/repeater/heard geography for the wrist, with wire caps
- `lib/services/watch/watch_color.dart` - Wire colour projection shared with the phone map
- `lib/services/live_activity/live_activity_service.dart` - ActivityKit bridge: preflight urgency, throttle, dedupe, unavailable backoff
- `lib/services/live_activity/live_activity_heard.dart` - The Live Activity's heard rows, read from the map's Top Heard box (shared with the watch)
- `lib/services/live_activity/live_activity_models.dart` - Live Activity snapshot model and urgency keys
- `lib/services/external_surfaces/external_surface_publisher.dart` - Shared publish pipeline (preflight dedupe, throttle, retry) behind watch, Live Activity, Siri snapshots, and the Android Auto pane
- `lib/services/external_surfaces/geo/external_surface_geo_builder.dart` - Ping/repeater/heard geography for external surfaces, with wire caps (was watch_geo_builder)
- `lib/services/external_commands/external_session_commands.dart` - Shared Siri/watch/car session-command admission and deadline rules
- `lib/services/external_commands/external_command_models.dart` - External command wire model, refusal reasons, and voice copy
- `lib/services/app_intents/app_intent_bridge_service.dart` - Siri method channel: command decode, dedupe, snapshot publish
- `lib/services/app_intents/siri_snapshot_builder.dart` - App Group snapshot content (recent heard, repeater catalogue, counts)
- `lib/services/app_intents/last_companion_connection.dart` - Connect-last-companion admission for the Siri intent
- `lib/services/auto/android_auto_service.dart` - Android Auto surface: connection lifecycle, pane publisher, serialized map sync, action routing
- `lib/services/auto/auto_glance_view.dart` - Pure WatchSnapshot to head-unit-pane projection (fixed 4-row layout)
- `lib/services/auto/car_map_channel.dart` - Dart side of the car map: camera, style and coverage overlay, deduped
- `android/app/src/main/kotlin/net/meshmapper/app/MeshMapperCarMap.kt` - Native MapLibre map on the car Surface (VirtualDisplay + Presentation)
- `android/app/src/main/kotlin/net/meshmapper/app/MeshMapperCarMapChannel.kt` - Holds the renderer and bridges it to Dart
- `android/app/src/main/kotlin/net/meshmapper/app/CarMapCoverage.kt` - Tile URL plus finished paint expressions, as Dart describes them
- `android/app/src/main/kotlin/net/meshmapper/app/CarMapTimerBar.kt` - The depleting next-ping bar, animated locally from a deadline
- `android/app/src/main/kotlin/net/meshmapper/app/MeshMapperEngine.kt` - Sole owner of the process FlutterEngine and its app-scoped channels
- `android/app/src/main/kotlin/net/meshmapper/app/MeshMapperApplication.kt` - Installs the engine factory the car service uses
- `lib/screens/watch_diagnostics_screen.dart` - Watch transport diagnostics (Settings)
- `lib/services/meshcore/packet_validator.dart` - Packet validation and carpeater filtering
- `lib/services/meshcore/regional_carpeater_filter.dart` - The region's shared CARpeater list: own-key exclusion, hop-prefix and full-key matching
- `lib/utils/public_key.dart` - Full public key normalization (upper-case 64 hex)
- `lib/models/noise_floor_session.dart` - Noise floor session data models
- `lib/widgets/noise_floor_chart.dart` - Noise floor graph visualization
- `assets/device-models.json` - Device database (30+ models)
