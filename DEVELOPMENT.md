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

**GPS position does NOT bump `mapRevision`.** Position updates ~1–2×/sec while
driving; rebuilding the map that often relayouts the iOS platform view (~24 ms
each) — a dominant heat source. Instead, the GPS listener calls plain
`notifyListeners()`, and `MapWidget` drives camera-follow, derived heading, and
the GPS puck from a **direct provider listener** (`_onPositionNotify` →
`_handleGpsPosition`) that calls the native controller (`animateCamera` /
`updateSymbol`) every tick — real-time nav, no widget rebuild. The GPS-info
overlay rebuilds only when the map itself does.

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
- `maplibre_gl`: Map rendering (MapLibre GL vector tiles via OpenFreeMap) — **vendored & patched**, see below
- `hive`: Local storage
- `provider`: State management
- `http`: API requests
- `pointycastle`: Encryption (AES-ECB, SHA-256)
- `usb_serial`: USB Serial communication on Android (USB OTG)

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
| `[WATCH]` | WatchConnectivity bridge: availability, snapshot delivery, wrist commands |
| `[LIVE ACTIVITY]` | ActivityKit bridge: sync, end, and authorization failures |

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
- `lib/services/transport/companion_transport.dart` - Transport-agnostic interface for companion connections
- `lib/services/transport/stream_frame_codec.dart` - TCP/USB Serial framing codec
- `lib/services/transport/stream_transport_base.dart` - Shared base for TCP/USB Serial transports
- `lib/services/transport/tcp_service.dart` - TCP socket transport with saved connections
- `lib/services/transport/android_serial_service.dart` - USB Serial transport for Android (USB OTG)
- `lib/services/transport/web_serial_service.dart` - USB Serial transport for Web (Web Serial API)
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
- `lib/services/watch/watch_bridge_service.dart` - WatchConnectivity transport: throttle, dedupe, movement gate, map-geo lease, command admission
- `lib/services/watch/watch_models.dart` - Watch wire contract and shared start-admission resolver
- `lib/services/watch/watch_geo_builder.dart` - Ping/repeater/heard geography for the wrist, with wire caps
- `lib/services/watch/watch_color.dart` - Wire colour projection shared with the phone map
- `lib/services/live_activity/live_activity_service.dart` - ActivityKit bridge: preflight urgency, throttle, dedupe, unavailable backoff
- `lib/services/live_activity/live_activity_models.dart` - Live Activity snapshot model and urgency keys
- `lib/screens/watch_diagnostics_screen.dart` - Watch transport diagnostics (Settings)
- `lib/services/meshcore/packet_validator.dart` - Packet validation and carpeater filtering
- `lib/models/noise_floor_session.dart` - Noise floor session data models
- `lib/widgets/noise_floor_chart.dart` - Noise floor graph visualization
- `assets/device-models.json` - Device database (30+ models)
