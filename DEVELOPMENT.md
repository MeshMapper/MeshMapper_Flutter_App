# Development Guide

This document provides comprehensive architecture documentation and development guidance for the MeshMapper Flutter App.

## Project Overview

MeshMapper Flutter App is a cross-platform wardriving application for MeshCore mesh network devices. It's a Flutter port of the [MeshMapper WebClient](https://github.com/MeshMapper/MeshMapper_WebClient), supporting Android and iOS. The web (Chrome/Edge) target's code is retained in the codebase but the web app is no longer built or published.

**Purpose**: Connect to MeshCore devices via Bluetooth Low Energy, send GPS-tagged pings to the `#wardriving` channel, track repeater echoes, and post coverage data to the MeshMapper API for community mesh mapping.

**Tech Stack**: Flutter 3.47.5 (Dart 3.13.4), Hive for local storage, Provider for state management

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

### Renderer Compatibility and Production Diagnostics

The 1.4.1 beta uses Flutter 3.47.5, including its Vulkan image-allocation
recovery for exhausted compression resources. Impeller and automatic backend
selection remain enabled. The app retains the 1.4.0 rendering behavior, without
the diagnostic probes, native log capture, forced OpenGLES or marker retries.

Debug log headers include the Flutter version and engine revision supplied by
the build tool, and Android's OS build ID and security patch. No device serial
or fingerprint is collected. Marker registration failures name the image and
whether rendering or registration failed, with coverage registration reported
as a group. These are lightweight diagnostics, not additional rendering work.

Use Flutter 3.47.5 for release builds, matching the version pinned in CI. A
successful build and tests do not replace confirmation on the affected Pixel.

### First-Run Quick Guide

The iOS and Android apps show a versioned Quick Guide after the required
first-run permission flow. `AppStateProvider` owns the seen-version state and
stores it as a separate key in the `user_preferences` Hive box
(`onboarding_guide_version_seen`, read into `OnboardingGuideProgress`), so a
missing key makes the current guide due for both new installs and existing
upgrades: `shouldShowOnboardingGuide` is `isLoaded && seenVersion <
currentVersion`. EVERY way out persists the seen version, including the X, the
Android back gesture out of the guide and the back gesture out of the welcome
prompt, or the welcome prompt came back on every launch. The two kinds of exit
differ only in what a FAILED persist does: Skip Guide and Finish Guide are
deliberate answers, so a failure keeps the surface up and re-enables the button
for another try; a dismiss may never be a dead end, so it closes anyway, logs
under `[APP]`, and the guide is simply due again next launch. Both keep the
in-flight guard, so a second tap or gesture during a persist is a no-op.
`MainScaffold` serializes the welcome prompt with other global
dialogs through `OnboardingGuideCoordinator.shared`, a one-slot reservation held
for the whole automatic presentation (welcome prompt plus guide route) and for a
manual replay. The link-offer dialog, the CARpeater re-entry prompt, the
CARpeater cap toast and the portal sign-in error toast all gate on that
reservation plus `OnboardingPromptGate.reservesModalLane` (which also holds the
lane while the seen state is still loading) and the open-guide flag. The sign-in
error is HELD, not cleared, while the lane is busy: a toast raised under the
welcome dialog or the fullscreen guide is never seen, and clearing it there would
lose the report entirely. Scheduling additionally waits for the first-run
permission disclosure flow to settle. About & Support offers manual replay on
mobile. The guide is a
self-contained Flutter PageView and never changes connection, wardriving, or
upload state. Its 12 pages cover connection, online/offline storage, privacy,
antenna setup, CARpeater setup, background operation, modes, Smart Pinging,
map controls, results, accounts, and a final recap. Optional explanations
expand within a page so the main setup steps stay easy to scan. Shared guide
components adapt accent brightness for dark mode; coverage swatches keep the
map's exact colors. The CARpeater and background-location setup actions use
the existing provider-backed flows.

### Cluster Tap Device Experiment

Cluster badges have a transparent circle hit layer above their symbol layers
and below spider markers and annotation symbols. Its radius follows half the
existing badge image canvas (24 logical pixels at the current scale); it does
not change marker artwork or the single `_clusterRadiusPx` merge radius.
The circle uses the same cluster source and filter, count lookup, resolver,
GPS fall-through and style-reload teardown as the badge. Detailed mode leaves
it inert because that source does not cluster.

This is a device experiment, not a verified reliability fix. `[MAP] tap dispatch:`
logs distinguish feature-layer hits from empty-map taps and include whether a
spider was open. Cluster re-taps now log `-> collapse` before returning, closing
a gap in the previous decision logging. Confirm repeated single taps on a real
iPhone before treating the symbol hit-test hypothesis as resolved.

### Uniform Repeater Corners

Single-repeater chips use `RepeaterMarkerStyle.chipCornerRadius` (8 logical
pixels) for every ID length and state, on both map modes and in the detail
popup header. Cluster badges remain circular. The matching server change is
implemented in the server repository.

### Repeater Identity and Collision Handling

Repeater identity is the cleaned full public key. The server's short `id`
can collide and must never select a device by first match. Marker taps,
spider groups, focus, isolation and coverage fading use full keys. The shared
`RepeaterLookup.resolveByHex` accepts an exact key or a unique prefix/legacy
id and rejects ambiguous matches, including for devices without coordinates.

At zone load, `repeater_collision.dart` mirrors the web's ordered twin and
fragment collapse, resets server exclusions, and recomputes exclusions at each
repeater's effective address width. The provider also caches full keys with a
conflict warning, since a wider-addressable device may still share two bytes.
These use the existing duplicate marker style. No collision pass runs on a
position tick or map rebuild. Load completion uses `_notifyMapNow()`.

Labels and detail/Manage sheets use each repeater's `advert_bytes`, falling
back to `hop_bytes`, independently of regional TX path-width enforcement.
Coverage requests use up to 40 characters of the full key to meet the API's
prefix limit. Legacy narrow coverage tokens can remain inherently ambiguous.

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
- `NetworkStateService`: Android constrained and satellite network monitoring; routine uploads use 60-second pacing and auth uses a 30-second timeout on constrained links
- `DeviceModelService`: Loads a validated cached device catalog, refreshes it once per launch, and serializes advisory unknown-device reports

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

**A style reload re-pushes everything, and on Android a second time.** Handing
`MapLibreMap` a new `styleString` makes the plugin fire a native `setStyle`, and
every source, layer and registered image is gone from that moment, so `_buildMap`
sets `_styleLoaded = false` right there instead of waiting for `onStyleLoaded`.
Nothing may push into a style being torn down, and every reader gates on the flag
before it latches anything, so an update dropped during a reload is re-detected
by the restore. `_buildMap` also bumps `_androidStyleResyncGen` so a callback
armed by the previous load bails rather than pushing into the incoming style, and
`_restoreStyle` bumps it again at the top for a programmatic swap that never
routes through `_buildMap`. On Android a style RELOAD (the user cycling the
basemap) can have its first push silently dropped: the native style object is
valid and every method-channel call succeeds, but the GL render thread has not
committed the new style yet, so the data is accepted and never drawn. 250 ms
later `_runAndroidStyleResync` re-pushes it all, push for push: coverage overlay
and its cell-highlight layers, region borders (signature reset to `-1` first so
the build-driven watcher repaints them if this push is the one that gets
dropped), then the full annotation sync (repeaters, coverage ping symbols
including the deferred pins, GPS puck source, focus lines, distance labels),
followed by `_repushCoverageSymbols`, because the annotation manager only
rewrites its GeoJSON source on an add or update and a sync that finds nothing
changed pushes nothing at all. `_androidResyncStillValid(gen)` is re-read before
every leg, and `_lastMarkerDataVersion` is stamped ONLY once the resync's own
push has landed: the style-loaded pass hands the stamp over rather than claiming
it, and every bail goes through `_abandonAndroidResync`, which resets it to `-1`
and calls `setState` so the next build re-syncs. Leaving the old value would not
do, since when nothing about the marker data changed across the reload it still
matches what `build()` computes and the build-driven sync never fires. First load,
iOS and web skip the resync. The history view answers
`preferences.showDeferredMarkers` exactly as the live view does, so toggling it
re-syncs (the marker data version reads it) and the cleanup loop takes the
now-unwanted pins off the map.

### 9-Step Connection Workflow

Critical safety: The connection sequence MUST complete in order.

1. **Transport Connect**: Platform-specific transport connection (BLE GATT, TCP socket, or USB Serial port)
2. **Protocol Handshake**: `deviceQuery()` with protocol version
3. **Device Info**: `deviceQuery()` returns manufacturer string, then `getSelfInfo()` acquires device public key (required for geo-auth API authentication). If `getSelfInfo()` fails, the entire connection fails.
4. **Device Identification**: Resolve the queried manufacturer against the current server-managed catalog. With nothing cached, this connect may arm one more refresh and waits at most 3 s for it. Recognition is advisory and never modifies radio settings.
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

Four auto-ping modes are available after connecting:

- **Active Mode**: Sends TX pings at user-configured interval (15s, 30s, or 60s). Each ping broadcasts a group channel message containing GPS location and radio power to `#wardriving`, then listens 7s for repeater echoes via `TxTracker`.
- **Passive Mode**: Sends discovery requests every 30s. No TX pings, only discovery request-response. Responses tracked via `DiscTracker`.
- **Hybrid Mode**: Alternates between discovery and TX pings at the user-configured interval. Discovery, TX, Discovery, TX...
- **Trace Mode**: Sends zero-hop trace path (CMD_SEND_TRACE_PATH, 0x24) to a specific repeater by ID at user-configured interval. Listens 7s for trace response (PUSH_CODE_TRACE_DATA, 0x89) via `TraceTracker`. Only successful traces are posted to API; failures are logged locally and shown as red markers on noise floor graph.

All modes also passively listen for RX packets via `RxLogger`, adding additional free coverage data to MeshMapper from nearby mesh traffic.

Stopping any mode arms a 5 second shared cooldown before another can start
(`AppStateProvider.toggleAutoPing`), and every button, Siri and the watch respect it. Passive
used to be exempt on the grounds that it is listen-only, but a Passive start puts a discovery
request on the air within milliseconds, so the toggle could be worked to flood the mesh. A
user-initiated Passive or Hybrid stop also KEEPS the 25 m discovery anchor
(`PingService._stopDiscoveryMode(keepDistanceAnchor: true)`), so restarting on the same spot
is held by the distance rule instead of transmitting at once, which is how the TX side has
always behaved (its anchor lives on `GpsService` and no stop clears it). A genuine teardown
(force disable, disconnect, dispose) still clears the anchor, so a reconnect always opens with
a discovery. The Offline Mode hot switch keeps it, since it stops through the same
user-stop path and the phone has not moved.

The two user stop paths (the inline teardown in `toggleAutoPing`, taken when no ping is in
flight, and the drain that `PingService._executePendingDisable` hands to
`onPendingDisableComplete` after the window closes) finish the same way: heartbeat kept, idle
disconnect timer restarted, top-heard overlay cleared, 5 second cooldown started. A start that
is refused after its session check (`toggleAutoPing`'s start branch) restarts the idle
disconnect timer it cancelled, in its `finally`.

That finish is one method, `AppStateProvider._finishAutoPingStop`, and the Offline Mode hot
switch (`_stopAutoPingGracefully`) ends through it too, with `keepHeartbeat: false`: the
session is being left behind either way and the switch releases or re-mints it straight after,
which is the one documented difference. Each of the three used to carry its own copy of the
tail, so what a stop left behind depended on which one ran. The hot switch stopped the 5 second
cooldown the drain had just armed (the cooldown is now armed and LEFT RUNNING, so a mode cannot
be restarted into the switch), and it wrote the offline session file a second time. The switch
now owns that save for the length of the call (`_modeSwitchOwnsOfflineSave`), so the shared
finish holds its own back and the file is written once, after everything the stop flushed has
landed in the queue. The discovery countdown is the one timer the user stop paths leave alone
and the hot switch stops, because a discovery window still open belongs to the session being
torn down.

### GPS & Zone Validation

- Uses `geolocator` package with high accuracy and continuous tracking
- **Zone Validation**: Server-side — client sends GPS coordinates to the API, server returns zone status (in-zone, nearest zone, or error)
- **Min Distance Filter**: 25m between pings prevents spam
- **Airborne block** (`GpsService.positionLooksAirborne`): a fix counts as in the air when its altitude, less its own vertical accuracy, is above 6,000 m (higher than any road on Earth, below airliner cruise) OR its ground speed is above 250 km/h (catches take-off, approach and most small aircraft; a high-speed train trips it too, by design). Three consecutive airborne fixes set `GpsService.isAirborne`, three consecutive ground fixes clear it, and one fix of the other kind restarts the count. The latch records which test fired (`airborneGate`) and BOTH readings of the fix that set it (`airborneAltitude`, `airborneSpeed`, each null when unknown; `speedOrNull` mirrors `altitudeOrNull`), and reports every flip once through `onAirborneChanged`. Unknown altitude and speed arrive from geolocator as 0.0 and never qualify (fail open). Every accepted fix feeds the latch (`trackAirborne`): the position stream, the simulator and `getFreshPosition()`, which TX, discovery and trace sends all take. A fix handed over twice (stream plus fresh read, same platform timestamp) counts once, so the streak really is three distinct fixes. The latch resets whenever the fix source restarts (`startWatching`, `enableSimulator`), because the stream only fires on movement and a phone left on a desk after a simulated flight would otherwise stay locked out. `GpsService.altitudeOrNull` is the shared "does this fix know its altitude" test (only the 0.0/0.0 pair means unknown; Android omits the accuracy on fixes that do carry an altitude).
- **What the block does**: `AppStateProvider._checkAirborne()` is level-triggered from the position listener and from the auto-ping scheduling hook (on iOS the position stream is quiet in the background, so the fresh fix each ping takes is the only sample then). With a live session it calls `_endSessionForAirborne()`: disconnect alert, error-log entry with the altitude or speed in the user's units, then `disconnect(closeApp: false, releaseExtras: ...)`, the normal user-disconnect path (auto-ping off, RX logging off, queue cleared, offline session kept in Offline Mode, API session released, no auto-reconnect). It defers while a zone transfer is in progress, since that flow re-acquires a session after its awaits with no cancellation check. The listener returns early on that tick so it cannot run a zone check on the way out, and the 100 m zone recheck while disconnected is skipped while airborne (a flight would otherwise POST once a second for hours). The four connect entry points refuse via `_refuseConnectIfAirborne()` (which sets no `connectionError`: the Connection screen's Airborne panel outranks the error card, and a message set there would survive the landing until the next attempt), the Connection screen disables Connect and shows "Airborne" with the reading that set the latch (`airborneCause`, "Your altitude is 10000m." or "You are moving at 300 km/h."), the map's GPS chip shows the fix's altitude when known, `PingValidation.airborne` blocks all three validators, the discovery and trace send lanes read the latch again after their own fresh fix and bow out without transmitting (a TX is already covered by `canPing()`, which re-reads it after the same suspension; on iOS in the background that fresh fix is the sample that sets the latch, so without the re-read each of those lanes put one more packet on the air after the block engaged, and neither reschedules, since the provider's handler is ending the session), Siri and the watch get `ExternalCommandReasonCode.airborne`, and auto-reconnect abandons instead of retrying into a flight (same alert, error-log entry and release telemetry, preserved queue dropped; the check sits below the reconnect prep so the foreground service and RX-side objects are torn down first). The check skips while `_isConnecting`, because the step flips to connected before `_postConnectionSetup` finishes and a disconnect inside that window would null objects the setup still uses; the next fix catches it. The release call carries `disconnect_cause: airborne`, `airborne_gate` (the test that fired) and `airborne_value` (its reading, raw meters or km/h), plus `airborne_alt_m` and `airborne_speed_kmh`, BOTH readings of the fix that set the latch (each omitted when the platform did not know it, metric ints regardless of the unit setting), so a speed-gate fire can be told apart from a high-speed train; built by the pure `airborneReleaseInfo` in `lib/services/airborne_release.dart` and logged by the server. In Offline Mode the offline recording is paused for as long as the latch is set (`ApiQueueService.setOfflineRecordingPaused`, driven by `GpsService.onAirborneChanged`, logged once on pause and once on resume), so the RX flush at disconnect and any straggler row cannot land in the offline file; the server owner chose the app as the only control on that path. Known gaps: a small aircraft below both limits passes. Thresholds are compiled in (server-delivered limits and a server-side guard were considered and left out). Logged under `[GPS]`, `[APP]`, `[CONN]`.

### Smart Pinging

Auto mode defers TX pings and discovery requests in a grid square that already has a recent
bidir (green) or disc (cyan) result. A deferred ping is held rather than dropped: it waits in a
one-slot bank and goes out at the first fix in a square with no recent coverage. RX logging is
never deferred (it is free). Manual pings, Trace mode and the auto-mode start check are
untouched. On by default with a 14 day window.

- **Settings** (Settings → Wardriving → Auto-Ping): `smartPingEnabled` (default true) and `smartPingDays`
  (any whole number of days from 1 to 365, typed into a number field; default 14; bounds in
  `SmartPingDays`). A stored value outside the range falls back to 14. The window tile is
  hidden while the switch is off. An (i) button beside the switch opens `_showSmartPingInfo`,
  a dialog explaining the deferral in user-facing words.
- **Map trail**: a deferral adds a hollow yellow marker (`PingColors.deferred`, with
  color-vision palette variants) whenever the phone has moved the configured minimum ping
  distance since the last deferred marker, the same rule a real ping answers to, so a drive
  through mapped ground leaves the whole trail of rings. `AppStateProvider`'s `onPingDeferred`
  handler keeps its own anchor for that (`_lastDeferredMarkerLat` / `_lastDeferredMarkerLon`,
  cleared with the markers) and gates the marker and the noise-floor event on it; the `DEFER`
  enqueue below keeps its separate per-square-per-session check, so the two no longer share one
  gate. The distance gate is needed because the coverage check runs before the 25 m rule, so a
  phone parked on already mapped ground defers on every interval tick; a marker per tick grew
  the noise floor session's Hive record and the map's deferred list without bound and bumped
  `mapRevision` (Critical Rule 9) for a marker already on the map. The countdown still reads
  "Deferred" on every tick, because that comes from the skip reason, which `PingService` sets
  whether or not a marker is dropped. `AppStateProvider.deferredPingMarkers` follows the
  normal log limit and clears with map markers or logs, with a `mapRevision` bump.
  Deferred events are also recorded in noise-floor sessions when a reading is available,
  so saved-session maps and the graph preserve them. Startup deferrals are held until
  the recording session opens, with failed starts clearing that buffer. `PingEventType.deferred` appends
  Hive field 8 to the existing enum (type ID 11); earlier values keep their indices.
  Both the map and graph legends use the hollow Deferred swatch.
- **Optional recent-coverage view**: `smartPingRecentCoverageOnly` defaults to false.
  Settings shows "Show only recent coverage" beneath the time window while effective
  Smart Pinging is enabled. `coverageOverlayDays` uses that effective window, including
  regional overrides, and is null when the view is off or Smart Pinging is disabled.
  A direct map listener observes the effective window even on UI-only auth/release
  notifications. The overlay and live fresh-tile requests use `f_days` with all coverage
  types, so recent grey, purple, orange and red results remain visible alongside green
  and cyan. Only the Smart Pinging lookup uses `f_types=green,cyan` to decide whether
  to defer a ping. Old or never-mapped places remain gaps. Filter changes rebuild the overlay and
  clear its patch; patch bodies belong to a region/grid/radio/window context, and an
  in-flight fetch from an old context is discarded. This changes the coverage squares,
  not the session's ping markers or the Smart Pinging send rules.
- **Enforcement**: `/auth` carries `smart_ping` (bool) and `smart_ping_days` (int). When
  `smart_ping` is true the switch is locked on and the window is the server's; otherwise the
  user's own values apply. The preference is never overwritten: `AppStateProvider`
  exposes effective getters (`smartPingEnabled`, `smartPingDays`, `enforceSmartPing`), the
  `discDropEnabled` pattern. A missing or invalid field means not enforced, 14 days
  (`ApiService.enforceSmartPing`, `apiSmartPingDays`).
- **Data source**: `vector_tile.php?z=13&gsize=<grid>&f_days=<days>&f_types=green,cyan`
  (`ApiService.fetchRecentCoverageTile`), decoded by `decodeCoverageCells`. The square is the
  cell of the user's Coverage Grid setting (300 m or 100 m), so what is deferred matches what
  is painted, including the Detailed 3 by 3 smear. The tap API (`app_coverage.php`) is not used.
  The fetch also carries the radio preset filter (`f_freq`, `f_bw`, `f_sf`, see Coverage
  Overlay), and `RecentCoverageService.configure(radioKey:)` drops every loaded tile when the
  preset changes, since a tile fetched under the old preset answers for the wrong layer.
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
- **The deferral**: `PingService.checkRecentCoverage` (wired to `isCovered`) is consulted by
  `canPing()` before the distance check (covered wins: a fix that is both reads Deferred, not
  Skipped, so parked on already mapped ground is held rather than rate limited, and both Hybrid
  legs agree) and by the auto discovery path alongside its distance check. It yields
  `PingValidation.recentlyCovered` and the skip reason
  `'recently covered'` (`PingService.skipReasonRecentlyCovered`), which rides the existing
  `onAutoPingScheduled` hook, and it banks the ping instead of dropping it. The interval timer
  is untouched: the next attempt is still scheduled at the normal interval, so the timer stays
  the backstop for a phone that never reaches a clear square.
- **The bank**: one slot. `PingService._bankedPing` holds a `BankedPingType`, either `tx`
  (Active or Hybrid) or `discovery` (Passive or Hybrid), readable through `bankedPing`. A
  later deferral overwrites an earlier one, so what eventually goes out is whichever type was
  most recently due. `maybeSendBankedPing(position)` releases it and returns true when it
  dispatched one. Dispatched rather than delivered: both send paths take their own fresh fix
  and re-validate, so a released ping can still be stopped inside the send. The GPS position
  listener in `AppStateProvider` calls it on every fix, placed after the airborne early return,
  and on a true it also clears the countdown's skip reason so the label does not keep reading
  "Deferred" while the released ping is going out.
- **What lets a banked ping go**: the fix must answer `RecentCoverage.clear` (`unknown` is not
  enough, and the interval tick already fails open there) and must satisfy the same 25 m
  minimum-distance rule the send path enforces, measured against the last TX or the last
  discovery to match the banked type. The release is refused while auto mode is off, in
  targeted (Trace) mode, with a disable pending, with a ping already in progress, with the
  radio not connected, during the 5 second auto-ping cooldown that follows a TX
  (`isInCooldown()`, not the separate 15 second manual-tap cooldown), and while the airborne
  latch is set (checked here as well as by the caller, because the discovery send path has no
  airborne check of its own the way a TX send does through `canPing()`). On release it cancels
  the pending auto and discovery timers and sets `_nextPingIsDiscovery` explicitly rather than
  toggling it, so Hybrid's alternation stays correct however many deferrals came first.
- **Clearing the bank**: a ping that proceeds to send clears it, and so do auto-mode start,
  stop, mode switch and `dispose()`. `clearBankedPing()` clears it from `_syncRecentCoverage`
  when the lookup goes inactive, because with the lookup off `isCovered` answers `clear` for
  every fix and would otherwise release the hold on the next GPS tick. Every other skip of a
  scheduled attempt leaves the bank alone, the 25 m `'too close'` skip included: that ping is
  still owed. A released ping is the exception, because it leaves the bank before it is
  dispatched: if its own fresh fix then fails the 25 m check it skips as `'too close'` and is
  not re-banked, so that one deferral is lost (pre-branch behaviour, and not worth the extra
  state to recover).
- **"Deferred", not "Skipped"**: the word applies only to this hold. The countdown labels pick
  it from the skip reason (`_pausedWord` in `lib/widgets/ping_controls.dart`), so the 25 m
  distance skip still reads "Skipped". The shared phase title is the bare word `Deferred` with
  the detail "Waiting for a square with no recent mapping", carried by
  `LiveActivityPhase.deferred` (wire value `deferred`) and labelled natively in
  `ios/MeshMapperLiveActivity/MeshMapperLiveActivity.swift`, which reuses the skipped phase's
  icon and colour.
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
- **Credit**: a deferred ping never posts a coverage row, so smart pinging used to cost the
  user a leaderboard point on every mapped road. The app now reports three things it already
  knows and keeps no tally or score. (1) The running auto mode,
  as `auto_mode` (`active`, `hybrid`, `passive`, `trace`, `none`) on the batch post, the
  heartbeat and the `/auth` release, read at the moment of each call through
  `ApiService.currentAutoMode`, wired to `AppStateProvider.wireAutoMode` (a pure read of the
  enabled flag and `AutoMode.wireName`; `none` when nothing is running, and NOT gated on the
  pending stop, since a draining mode is still that mode). Never on connect, register, an
  offline-mode auth, the offline upload, or the release of an offline upload's own session.
  Every disconnect path stops the mode before it releases, so the release reads `none` in
  practice; the server credits the final gap from the mode it last stored and never reads the
  release's value, so that field is sent for contract completeness. (2) The mode that produced
  each queued item, as an optional `auto_mode` on the item (`ApiQueueItem` Hive field 19, read
  at enqueue time through `ApiQueueService.autoModeGetter`; `none` for a manual ping or an RX
  row heard with no mode running, absent only when no getter is wired, which the server reads
  as unknown, and never on a `DEFER`, which the factory cannot stamp). (3) One `DEFER` item
  per fixed 300 m square per API session, `{type, lat, lon, timestamp, held}` with `held`
  `tx` or `disc` and nothing else (no antenna, noise floor, power or altitude: the server pays
  for the square, not the reading). `PingService.onPingDeferred` fires at the two deferral
  sites (the TX auto branch and the discovery send) with the validated fix; the provider
  dedupes it through `RecentCoverageService.markDeferred` (always the 300 m grid, whatever the
  Coverage Grid setting, so a Detailed-grid user reports one per real square and a parked car
  reports one; the map marker is gated on distance instead, see Map trail above) and queues it
  with `ApiQueueService.enqueueDefer`, which rides the normal batch,
  the offline recording (honouring the airborne pause) and the pre-disconnect snapshot, and is
  never dropped on a session change (no wire tag). A new session id under a kept queue resets
  the dedupe set (`clearDeferred` on `onSessionIdChanged`), matching the server's per-session
  credit. A released banked ping does not cancel its `DEFER`: the user crossed the covered
  square without transmitting. The server verifies each square against its own coverage,
  dedupes again per session, credits it at 1.5 points and grants the three Airtime awards on
  the lifetime count; a drop is silent and the app has no constant for the weight, the
  thresholds or the names. The custom third-party endpoint gets `DEFER` items (documented as
  unverified in `docs/CUSTOM_API_ENDPOINT.md`) but never the stamp
  (`CustomApiService.forwardPings` strips it). **Server first, not optional**: an old server
  routes an unknown item type into its TX path and inserts a dead TX row, so no build carrying
  this may reach a phone pointed at a server without the other half
  (`MeshMapper_Server/docs/APP_API.md`).
- Logged under `[COVERAGE]` (tiles, session marks, deferral reports), `[API QUEUE]` (the
  `DEFER` enqueue) and `[PING]` / `[DISC]` (deferrals, releases and drops). The batch and
  heartbeat request summaries under `[API]` / `[HEARTBEAT]` show `auto_mode`.

### API Queue System

Three data flows (TX pings, RX observations, Discovery results) merge into unified API batch queue:

- **Storage**: Hive-based persistent queue survives app restarts
- **Batch Size**: Max 50 messages, auto-flush at 10 items or 30 seconds
- **Payload Format**: `[{type:"TX"|"RX"|"DISC"|"TRACE", ...}]`. TX/RX include `heard_repeats`; DISC includes `repeater_id`, `node_type`, `local_snr`, `local_rssi`, `remote_snr`, `public_key`; TRACE includes `repeater_id`, `local_snr`, `local_rssi`, `remote_snr`. Every type also carries `altitude` (whole meters, omitted when the phone did not know it; iOS reports height above mean sea level; Android usually reports height above the WGS84 ellipsoid, but Android 14+ substitutes mean sea level when the fix carries it, so one device can report either. The two references differ by the local geoid separation, up to ~100 m)
- **Radio preset stamp**: every item (TX, RX, DISC, TRACE and DEFER) carries `radio_freq`, the
  radio's configuration tag `freqMHz,bwKHz,SF,CR` as reported at connect (`ApiQueueItem` Hive
  field 20, read at enqueue time through `ApiQueueService.radioConfigGetter`, wired to the live
  radio only). The server reads the preset off the row instead of joining the session, and an item
  queued before a preset change keeps the preset it was heard on. Absent when the radio reported
  no configuration or the queue has no getter wired; the server then uses the session's value.
  The third-party endpoint keeps it. Contract:
  `MeshMapper_Server/docs/APP_API.md`.
- **Authentication**: API key in JSON body (NOT query string)
- **Retry Logic**: Exponential backoff on failures. A 429 storm-brake answer holds the whole queue for the server's `Retry-After` without spending a retry (see Session Heartbeat)
- **Closed keep-alive sockets are replayed once**: every request `ApiService` makes goes through `_send`, which sends it again when the first attempt comes back `ClientException: Connection closed before full header was received`. The server closes an idle connection after 5 seconds while Dart's HttpClient keeps it pooled for 15, so a request made in that gap goes out on a socket that is already gone; a backgrounded app widens the gap further, because a frozen event loop cannot notice the close. Such a request never reaches the server (no access-log entry there), so replaying it changes nothing about what the server did. One replay only, and the per-attempt timeout stays at the call site so the replay gets a full allowance. Without it a single dead socket failed the whole connect on `/auth` and the user had to press Connect again.

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
- **It MUST outlive the auto-reconnect window.** On Android the foreground service is the only thing holding the process alive, so `_startAutoReconnect` only re-titles it ("Reconnecting") and never stops it. Stopping it there froze the app within about three seconds and every Dart timer stalled with it, the 30 second reconnect timeout included: one user's reconnect gave up 18 to 21 minutes late, when they picked the phone back up, which is why the disconnect alert beeped on their return to the car instead of when the radio went out of range (the GPS stream, the 15 second batch timer and the reconnect timeout all resumed in the same millisecond). The service is stopped on the abandon path through `_fullDisconnectCleanup`, and by `_onReconnectSuccess` when there is no auto-ping to restore. A success that does restore auto-ping re-uses the running service, since `startService` folds into `updateNotification` when it is already up.
- **The disconnect alert is dated to its cause, not to when it plays.** `AppStateProvider._playDisconnectAlert(occurredAt)` refuses to beep once the event is older than `maxDisconnectAlertAge` (`lib/services/disconnect_alert_decision.dart`, 2 minutes) and writes an error-log entry naming the real delay instead. The reconnect abandon passes `_reconnectStartedAt` (the BLE drop); every other caller is event-driven and passes the current moment. This is the backstop for phones that freeze anyway, not the fix. `_logStuckTimers` also reports a reconnect window still open past twice its budget, under `[CONN]`.
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

- **The user's own CARpeater** (`UserPreferences.carpeaterPublicKey`, a full upper-case 64-hex public key, on while `ignoreCarpeater` is set; entered in Settings by the trace repeater picker or a validated text field). Pass-through: a TX echo or RX packet whose hop matches is stripped and the repeater behind it is credited with null SNR/RSSI; a single-hop packet via it is dropped; a discovery response from it is dropped. The hop is compared at its own width (2 to 8 hex) via `PacketValidator.isCarpeaterIdMatch`. The pre-share 6-hex prefix is wiped at load (`UserPreferences.stripLegacyCarpeater`), never migrated, and a persisted `carpeater_reentry_pending` flag makes `MainScaffold` prompt for the full key after the next connect (with a button to the Wardriving settings page; "Not now" repeats after the next connect, "I don't use a CARpeater" clears it, so does setting a key). Saving the setup dialog with the field EMPTY clears the flag too (`carpeater_setup_dialog.dart` calls `dismissCarpeaterReentry()` on that path): it is the same answer as "I don't use a CARpeater" and takes the same provider path, and the provider only dismisses the prompt when a key is SET, so without it the prompt came back after every connect.
- **Regional CARpeaters** (`RegionalCarpeaterFilter`, `lib/services/meshcore/regional_carpeater_filter.dart`): the region's shared list. The app sends its own key as `carpeater` on connect and register auths (never on an offline-mode auth), and a LIVE auth answer carries `carpeaters`, which replaces the Hive cache (`user_preferences` box, key `regional_carpeaters`) in full, so an entry an admin deleted or retention aged out leaves the phone at the next auth and Offline Mode keeps the last copy. A missing field on a live answer is an empty list. The replace runs only on a live connect or register auth: an offline-mode or `skipSessionStore` auth is not one (the offline upload authenticates only to close out its own isolated session and never sends the user's `carpeater`), and a server that answered it without the field would wipe the very cache Offline Mode exists to keep. The filter excludes the user's own key while their switch is on; every other key is a plain drop, always, even with the user's filter off: someone else's CARpeater is in someone else's car, so neither it nor the repeater behind it may be credited. TX checks the first hop and the credited hop, RX the credited hop, both AFTER the own-CARpeater strip; discovery matches the full key. Regional drops are debug-log only (`[TX LOG]`, `[RX LOG]`, `[DISC]`), never error-log entries. A raw `/auth` body is never logged verbatim, because the answer carries the region's whole key list and a debug log file ships with bug reports: `ApiService._redactBodyForLog` puts a body that parses as a JSON object through the same `_sanitizePayload` redaction the request and response summaries get, and cuts anything else (an HTML error page, a truncated stream) to 200 characters. Both the non-200 and the non-JSON `/auth` log lines go through it. Settings shows "Filtering N regional CARpeaters" with a list. The server caps one radio at 5 live tags per zone; `carpeater_error: max_reached` becomes an error-log entry plus a toast and never affects the connection. Contract: `MeshMapper_Server/docs/APP_API.md`.
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
- Every file opens with a two-line header: the start time, then the app build,
  OS version and hardware model (`=== App APP-1.4.0 | iOS 18.5 | iPhone 15 Pro
  (iPhone16,1) ===`). Resolved once per launch via `device_info_plus` and
  repeated on the rotated file, because a submission carries several files and
  the one worth reading is rarely the first. It names the model and OS only:
  no serial, no fingerprint, no device name, no vendor id. A report that blames
  the app is often an OEM battery manager or an OS quirk instead, and this is
  the only way to tell that from the log alone. A plugin that cannot answer
  degrades to a note in the same line and never stops the log.

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
- **iOS background sounds**: `SoundNotificationService` routes TX, RX and disconnect sounds through standard local notifications whenever the app is not resumed. Bundled WAV files preserve the existing sounds. Each type reuses its own ID (891 disconnect, 892 TX, 893 RX), replacing earlier notifications of that type. Silent mode, Focus and notification settings control delivery and sound; no critical alerts or background media playback are used. The master and per-sound toggles gate playback. Enabling sounds requests notification permission, including at startup for existing enabled preferences. Foreground and Android audio playback remain unchanged. Disconnect automatic-mode and stale-alert gates remain in the provider. The app must still execute each event callback before the system can deliver a notification; system notification throttling can limit rapid RX sounds.
- **File**: `lib/services/audio_service.dart`

### Session Heartbeat

Prevents session timeout during long wardriving sessions by periodically refreshing the session expiry.

- **Trigger**: Enabled when the API session is acquired at connect (`enableHeartbeat()`), and again on every auto-ping start, zone re-entry and zone transfer. Disabled on disconnect, on entering zone grace or a zone transfer, and by the Offline Mode hot switch. Stopping an auto mode does NOT disable it, on either stop path: the session stays valid while the radio is connected and idle, and the 15 minute idle disconnect is what ends it. (The pending-disable drain used to disable it, so a stop tapped during an echo window let the session lapse and the next Start came back `session_expired`.)
- **Timing**: Heartbeat fires **1 minute before** session `expires_at`. If already expired, sends immediately, but never more than one send per 30s (`minHeartbeatSpacing`). The floor matters because `expires_at` is server-clock while the delay math runs on the device clock: a device clock 4+ minutes fast (server TTL is 300s) makes every fresh expiry read as already due, and without the floor the "send immediately" path re-fired one POST per network round trip (the 2026-08-29 storm: 361k POSTs in 64 minutes from one device). An in-flight guard keeps re-entrant `scheduleHeartbeat` callers (upload success, per-ping session check) from stacking concurrent send chains, and a circuit breaker (`maxHeartbeatsPerMinute` = 6) pauses the lane for 60s as a backstop. Regression tests: `test/services/api_service_heartbeat_test.dart`.
- **Storm brake (429)**: a `rate_limited` answer from `/wardrive` carries `Retry-After` (75s by default) and keeps the session valid (server contract: `docs/APP_API.md` Appendix C item 9, "a 429 is not a sign-out"). `ApiService` parses it into one per-session hold, `wardriveBackoff`, that every sender on that door respects: `uploadBatch` returns `UploadResult.held` (no retry spent), `checkSessionValid` skips the post and reports the last known verdict so the ping itself proceeds, and the keepalive reschedules after the hold instead of going quiet. The brake re-arms its penalty on every blocked hit, so one lane knocking through it would keep all of them locked out. Without the keepalive reschedule, a braked session lapsed while the car was stopped (no ping or upload restarted the lane), the next post got a 401 and the app re-minted a fresh session id, which is exactly what the brake must not cause (VLC-20260903-0002). A new session id drops the hold. The hold honours `Retry-After` in full, up to the one hour ceiling `maxWardriveRetryAfter`: the server derives the value from its penalty and re-arms the lockout on every blocked hit, so a client that retries before the penalty has run is braked for the rest of the session, which is why the app never shortens it. The 429 path on the server answers before any session work and does not refresh `expires_at`, so a hold that outlasts the 300 s session TTL lets the session lapse, and the TX pings queued behind wire tags minted under it are dropped when the next `/auth` returns a new session id. The app cannot close that gap without knocking into the open window; it is a server matter (refresh the expiry on a 429, or keep the penalty under the TTL). In practice the brake only trips above 300 posts per 60 s from one session, so a healthy app never sees it. Tests: `test/services/api_service_rate_limit_test.dart`.
- **Mechanism**: POST to `/wardrive-api.php/wardrive` with `heartbeat: true` flag and optional GPS coordinates
- **Response**: Returns updated `expires_at`, which schedules the next heartbeat
- **Expiry recovery**: A live online companion treats only `session_expired` as recoverable. It serializes one replacement `/auth`, preserves the BLE connection and current auto mode, refreshes the region channels, validator, flood scope, capacity, Smart Pinging settings and path widths, then lets the recovered heartbeat lane own its next schedule. A recovered path policy applies the enforced regional width when present and otherwise restores the device firmware width, while retaining the user's trace-width preference. A recovery captures the exact connection and lifecycle generation, blocks new TX, and waits for an on-air TX window to finish its queued old wire tag before cleanup and session swap. Disconnect, zone transfer, Offline Mode, reconnect and disposal invalidate that ownership and wait for the recovery before releasing the current session. A superseded request is distinct from a failed recovery: stale preflights stop without a disconnect, stale heartbeats end quietly, and stale uploads stay held. If replacement configuration cannot be applied, the replacement session is explicitly released before the ordinary fatal path. Stale wire-tagged TX rows are removed before the new session ID is installed; untagged passive observations stay queued. Recovery is refused during disconnect, zone transfer, connection setup and Offline Mode. Other session and auth errors still follow the normal fatal-session path.
- **Bounding the recovery wait**: ownership is one predicate, `_ownsSessionRecovery(generation, connection, publicKey)`, re-read after every await: not disposed, still the current generation, not in Offline Mode, not connecting, reconnecting or transferring, still at `ConnectionStep.connected`, the same `MeshCoreConnection` instance and the same device public key. The teardown paths bump that generation (`_invalidateLiveSessionRecovery`) and then wait, but only for `sessionRecoveryWaitTimeout` (15 s, through `awaitSessionRecoveryBounded`), after which they carry on and log under `[SESSION]`. Giving up is safe precisely because of the ownership re-read: the recovery finishes on its own and finds it has been superseded. A recovery is two network legs (an `/auth` POST, then the channel and validator work it applies), and an unbounded wait held `disconnect()` and `_startAutoReconnect()` for as long as it liked with the UI already reading Disconnecting and the radio still up. `disconnect()` releases the sign gate and the repeater-admin slot (`abortPendingSign()`, `abortPendingAdmin()`) BEFORE that wait, not after it: a live sign holding the gate through all 15 seconds is exactly what aborting first exists to prevent. A superseded recovery releases the replacement session it already minted through `_releaseRecoveredSession` without being awaited, because that release is a second `/auth` POST that can sit for 30 s, nothing on this path depends on its answer, and the caller that superseded it is blocked on this recovery settling. A recovery that fails for its own reasons still awaits its release before returning `failed`.
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
  **raw 32 bytes** → `linkDevice(pubkey, nonce, signature, label)` binds it. A
  key held by a placeholder group (a region admin's grouping from before
  accounts existed) is adopted by the server on this lane exactly as in the
  browser: every radio in the group moves to the account and the answer
  carries `adopted: N` (this radio included), which the success toast reports
  when N is above 1. An OLD server still answers `adoption_required` instead;
  that dialog explains the group and says to link this same radio from the
  portal's Link a companion button, which is what triggers adoption there.
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

### Repeater Administrators

A connected user picks a repeater (the Trace row's Manage button, the repeater detail sheet,
or My Repeaters in Settings > MeshMapper Account), opens the Manage sheet and logs in with the
repeater's admin or guest password over the mesh. Either login can fetch the repeater's
neighbour table a page per tap and upload it without a MeshMapper claim. Only an admin login
can claim the repeater on MeshMapper: the app proves admin with the login reply's admin flag,
then a `GET_ACCESS_LIST`
binary request that a guest never gets answered. The user can also see and reset the route the
radio learned. Everything is a request with a pushed response. **Never:**
a CLI command (its reply is a direct message), a read of the radio's message queue
(`CMD_SYNC_NEXT_MESSAGE` stays unsent, `MSG_WAITING` unhandled), or an export of the radio's
private key. Server contract: `MeshMapper_Server/docs/APP_API.md`.
**Server first:** an old server answers the `/repeater` leg with 400 `invalid_request`, which
the app shows as "This region does not support claiming yet."

- **The mesh conversation** (`lib/services/repeater_admin/repeater_admin_session.dart`,
  `RepeaterAdminSession`, a `ChangeNotifier` the sheet listens to, depends on
  `MeshCoreConnection` only). Step 1 makes sure the radio has the repeater as a contact
  (`getContacts`, then `addContact` as a flood repeater with the MeshMapper name and position
  only when absent, because an add wipes a learned route; the contact list is read in full
  once per BLE connection and cached on the `MeshCoreConnection`, and every later
  `getContacts` sends the firmware's `since` filter (the newest `lastmod` from the
  END_OF_CONTACTS frame) and merges what changed, so the 52 KB stream happens once, not per
  login; a learned route bumps `lastmod` so it syncs, `resetPath` does not so the cached
  record is patched, `addContact` inserts its record, and the cache dies with the connection
  object (auto-reconnect builds a new one); `ERR 3` there is "Your radio's
  contact list is full."). Step 2 logs in (`login`, `CMD_SEND_LOGIN` with the raw UTF-8
  password, no NUL; the firmware terminates the frame). The 14-byte `LOGIN_SUCCESS` carries
  an explicit admin flag, the ACL perms byte and the firmware level. **Firmware floor, no
  legacy support:** companion `FIRMWARE_VER_CODE >= 7` is required (the capability code
  introduced with MeshCore v1.9.0). It comes from byte 1 of `RESP_CODE_DEVICE_INFO`, already
  parsed as `DeviceQueryResponse.protocolVersion` and exposed by the provider as
  `companionFirmwareVersionCode`. Both Manage gates use `companionSupportsRepeaterAdmin`;
  unknown or lower codes disable Manage with "Update companion firmware to use Manage".
  The display version string is not a capability check, so forks can use their own release
  numbering. Repeater firmware v1.9.0 or newer is
  required and detected at login (that release added `GET_ACCESS_LIST`, `GET_NEIGHBOURS` and
  the firmware-level byte; an older repeater's 12-byte reply has no such byte, the companion
  forwards the cipher's zero pad in its place, so a level of 0 stops the session with "This
  repeater seems to be running firmware older than v1.9.0. Manage needs repeater firmware
  v1.9.0 or newer." and sends it nothing further). A shorter `LOGIN_SUCCESS` is a protocol
  error, not a state. **A wrong password gets no reply from the repeater** (firmware `handleLoginReq` returns without answering), so it
  presents as the login timeout "No reply from the repeater. Check the password and try
  again." Step 3 proves admin: `sendBinaryRequest` with `[0x05, 0, 0]`; the reply's entries
  are read for the count and discarded (never shown, uploaded or logged); silence within the
  timeout refuses the claim with "The repeater did not confirm admin access." Step 4 renders
  the contact's `out_path` as hops at the width its `out_path_len` byte encodes (the packet
  path_len encoding: top two bits hash size less one, low six the hop count; it is NOT a byte
  count, so 0x81 is one 3-byte hop; `ContactRecord.routeHopBytes`) (names resolved by unique
  prefix against the zone list, else hex; `0xFF` is "Flood (no route learned yet)"; a zero hop
  count, 0x80 on a 3-byte mesh, is "Direct (no hops)", a LEARNED route the radio sends along
  with an empty path, which is what a repeater in range answers with),
  re-read on every `PATH_UPDATED` push, and `resetPath` floods the next send. The route line sits
  under the header at all times (hop hashes only, a Details dialog lists the hops by name), with
  Reset route beside it once the contact has been read and until a login succeeds: the
  radio sends the login DIRECT along a learned route and never falls back to flood, so a
  stale route is silent exactly like a wrong password, and the timeout sentence names the
  route when one is learned. After 3 unanswered logins in a row along a learned route the
  session resets the route itself (`kLoginTimeoutsBeforeRouteReset`, the official client's
  habit) and says so; it never resends, the next tap floods. Any login reply, a manual reset
  or a flood-route timeout clears the count. Once logged in the route cannot change for the session, so it
  shows as a read-only fact row under the header. Step 5 reads
  the neighbour table one page per tap: `[0x06][0][10][offset:u16][0][8][random:4]`, ten
  entries per page at an 8-byte prefix, newest first. A binary reply's body starts at its
  first field (`[total:u16][returned:u16]`, or the first 7-byte ACL entry): the repeater
  prefixes every reply with its 4-byte timestamp, but the companion lifts that into the push
  frame's tag and `sendBinaryRequest` drops it, so the parsers must NOT skip one (they did,
  and every entry landed 4 bytes late: prefixes ending in three zero bytes, perms bytes out
  of the middle of a key). "Fetch neighbours" is the first page,
  "Load more" is the next (`hasMoreNeighbours` is false once the table is complete, a page
  comes back empty, or the 30-page brake trips); nothing pages on its own, and Upload sends
  the pages held with the repeater's own `total` beside them. SNR is the firmware's
  `int8 / 4` dB. Timeouts are the radio's `est_timeout_ms` from
  the `SENT` reply plus 5 s, clamped to [8 s, 60 s]. Commands never overlap: the companion
  keeps one pending request and a login clears it. The noise floor and battery pollers skip
  their tick while an admin command holds the link: a 350-contact stream is 52 KB through the
  companion's BLE queue, and both times a poll landed inside one the radio dropped the link.
- **Connection layer** (`lib/services/meshcore/connection.dart`): `getContacts`,
  `addContact`, `login`, `sendBinaryRequest`, `resetPath`, `pathUpdatedStream`, each a
  completer plus timeout in the `sign()` style, one at a time (`StateError` otherwise),
  all through `_write` so the sign gate still parks them. `SENT` is parsed for its tag and
  estimate. `ERR` completes them with `RadioErrorException(code)`; `abortPendingAdmin()`
  completes them with `RadioAbortedException` and is called from `disconnect()`,
  `deleteWardrivingChannelEarly()`, `dispose()` and the provider's disconnect, the
  `abortPendingSign` pattern. The login frame is logged by length only, and
  `DebugFileLogger.scrubSecrets` redacts any `password=` shape as a backstop.
  An ERR frame carries no correlation, so it is claimed for the admin lane only when no
  poller or query completer is pending (stats, channel info, device query, export contact,
  get time). Holding the pollers is not enough to make that rule hold, because `_pollsHeld`
  only stops ticks that START after the slot is claimed: a `getNoiseFloor()` already awaiting
  its answer keeps the stats completer set for up to 5 s, and its ERR would be eaten there
  while the admin command timed out still holding the slot. Every admin command therefore
  calls `_drainPollsForAdminCommand` before its frame is written, waiting out any stats or
  battery request already on the wire (each bounded by the poll's own timeout, and their
  errors stay with the poll). That drain also keeps a poll reply out of the 52 KB contact
  stream, the collision the poll hold was added for. The claim is atomic against a poll
  starting, because both the poll's guards and `getStats`' claim of its settle slot are
  synchronous. `getStats` clears its own completer on its own timeout, or a request the radio
  never answered would keep the stats poll reading as pending for the life of the connection
  and go on deciding where every ERR went.
  A command that times out with its bare `OK` still owed keeps the slot and waits for the late
  reply, bounded by a 10 s `lateResponseBackstop`: when it fires, the slot is released and the
  late state cleared. It arms nothing on the way out, because an `OK` carries no correlation
  and the lane cannot tell the owed one from the next command's real one, so ignoring "the next
  OK" would cascade. At worst a late `OK` completes the following command early. Without the
  backstop the slot stayed owned until the sheet closed: every later tap refused and both
  pollers held.
- **Modules** (`repeater_admin_module.dart`): `RepeaterAdminModule { name, needsAdmin,
  run(session) }` produces one payload for one server action. `ClaimModule` needs admin,
  runs the ACL proof and returns `{login, acl, perms, fw_level}`; `NeighboursModule` allows
  admin or guest access and returns
  `{fetched_at, total, entries}` for the pages the user loaded, capped at 300, with `total`
  the repeater's own count so the server knows the table may be partial. A later module is one class here and one
  server action.
- **API** (`repeater_admin_api.dart`, `RepeaterAdminApi`): `claim`, `unclaim`, `mine`,
  `neighbours`, all `POST /wardrive-api.php/repeater` with `key`, `session_id`, `action`,
  `app_ver`. **The body never carries a top-level `data`, `public_key`, `heartbeat`, `lat`,
  `lng` or `lon`** (the old router keys on them; asserted in `_post`). Every body carries a top-level `radio_freq` (the full configuration tag) when the radio reported
  one, so a claim and a neighbour table are tied to the preset they were made on. Refusals map to
  `RepeaterAdminFailureKind` with one sentence each (`userMessage`); a 429 carries
  `Retry-After`; `sessionExpired` is reported, never acted on (the sheet never touches the
  connection). Offline Mode or no session refuses claim, unclaim and upload locally.
- **Provider**: one live session at most (`openRepeaterAdminSession` /
  `closeRepeaterAdminSession`). While open, `sendPing` and `toggleAutoPing` refuse and every
  ping button is disabled (`isRepeaterAdminActive` in the controls deps); every exit path
  (sheet close, error, disconnect in both flows, the auto-reconnect teardown, dispose) closes
  the session (Rule 7). A
  session may open only when `repeaterAdminBlockReason` is null (connected, no mode running,
  no ping in flight, no other session; `manageBlockReason` in `manage_target.dart`, shared
  by every entry point so the surfaces give the same answer). Claims are cached in Hive
  (`user_preferences`, key `repeater_claims`, a JSON map keyed by companion pubkey) and
  reconciled from the server's `mine` action after every connect (non-fatal, skipped on an
  old server). A successful claim awaits a fresh `mine` response instead of creating a
  local row with the phone's zone. If that refresh fails, the existing cache is kept.
  Passwords go through `SecureTokenStore` under `repeater_admin_pw_<HEX>`,
  are sent to the repeater over the mesh, but are never logged or sent to the MeshMapper
  server. Only a login that PROVED admin is persisted (`shouldRememberAdminPassword` in
  `repeater_admin_sheet.dart`: `remember && state == RepeaterAdminState.admin`). A guest
  login is a login too, and the Remember switch defaults on whenever an admin password is
  already stored, so persisting on any login let a guest password overwrite the remembered
  admin one; a guest login now writes nothing and deletes nothing, and Forget password stays
  the only way to clear a stored password. Nothing here bumps `mapRevision`.
- **Entry points**: the Trace row is three pieces, `[list + ID]` (one neutral group), `[Trace]`
  and `[Manage]` (each its own tinted box); Manage needs
  the full key, so a picked repeater carries it and a typed ID counts only when it prefixes
  exactly one loaded repeater (`resolveManageTarget`), else the tooltip reads "Choose from
  the list". The compact (landscape) controls are unchanged. The detail sheet gets an
  Administrators row and a Manage button (disabled with the block reason while it cannot
  open). A repeater's neighbours appear ONLY in the Manage sheet, at the moment they are
  fetched off the radio for upload. The detail sheet used to echo the server's own
  `proven_neighbours` back as a "Proven neighbours (via app)" list; that was both unwanted
  and dead, since the parser read `hex`/`prefix` and the server has always sent `key`, so
  every row failed to parse and the section never rendered. The app ignores the field. My Repeaters lists the cached claims; a row opens the sheet when a radio is
  connected. Labels prefer the server's nonempty `group_code` (such as BALTIC), otherwise
  `iata`. Both fields persist in the JSON claim cache; older rows without `group_code`
  retain their IATA label until a successful refresh supplies a group.
- **Repeater list fields**: `Repeater.admins` (display names; an old list has none). The
  server also sends `proven_neighbours`, which the app does not read.
- **Admin-entered site details** (`hardware`, `antenna`, `heightMeters`, `power`,
  `powerSource`, `siteNotes`) and the preset the repeater is heard on (`presetCurrent`,
  the server's three-slot `freq,bw,sf` tag, not the app's own four-slot radio tag). Free
  text the server does not validate, so a blank reads as absent and a non-string is
  ignored rather than stringified. Null on most repeaters and on any older server, which
  is the expected state and is never logged. The detail sheet renders each as its own row
  only when set, with the antenna and its height on one row and the power and its source
  on another, and the height following the imperial preference. Three getters do the
  tidying the server does not: `displayPower` normalises a hand-typed column where `0.3`,
  `0.3w` and `1.0W` are all real stored values, `displayPowerSource` cases `solar`/`poe`/
  `mains`, and `displayPreset` renders the tag as `910.525 MHz · 62.5 kHz · SF7`, falling
  back to the raw string when it is not three numeric slots. Covered by
  `test/models/repeater_site_details_test.dart`.
- **The detail sheet's facts card scrolls inside a cap** (`_repeaterCardMaxHeightFraction`,
  32% of screen height) so a fully populated repeater cannot grow the sheet past its normal
  opening height and scroll the close button away. Its ID chip is drawn by the map's own
  painter (`_RepeaterChip` over `paintRepeaterChip`), scaled to the header by
  `_sheetChipBoxHeight`, so the chip and the marker that was tapped can never drift apart.
- Logged under `[RADMIN]` (session, modules, API, sheet, provider) and `[CONN]` (frames).

### Repeater Markers

A repeater marker's large area is NEUTRAL and its state rides the edge. That is
the one rule the whole design rests on, and it is not a preference: the old
state-coloured fills were darker siblings of the coverage colours drawn
underneath them (OKLab dE 6.2 for `new` against the no-coverage red, 7.6 for
`stale` against the dead-zone grey), so every marker competed with the data it
sat on. The constant body is dE 25.7 from the nearest coverage colour.

- **Single repeater**: a `#22303A` body in every state and every colour-vision
  palette, an 8 px state-coloured bar down the left clipped to the rounded
  rect, a 1.5 px state line just outside the body and a 1 px `#0d1114`
  hairline outside that. The body is inset 2.5 px (1.5 + 1) so the edge is
  added INWARD and the footprint is unchanged. Width follows the id length
  (`<= 2` chars: 24, else `10 + len * 7`, plus 8 for the bar), and the label is
  centred in the space RIGHT of the bar, not in the whole box. A newly
  discovered repeater is taller (28 vs 24), with a larger label and a wider
  glow. Corner radius still encodes hop-byte width (4 / 6 / 8), which is this
  app's own signal and has no web counterpart.
- **Group marker**: a `#22303A` disc of radius 19 with the count across it, a
  2.5 px ring at radius 17.75 in the DOMINANT state's colour, a 1 px hairline
  at 19.5, and one uniform 2.6 px dot per state PRESENT, pitch 4.2, centred at
  `cy + 9.5`. The dots say WHICH states are in the cluster and the ring says
  which one DOMINATES: two different facts, which is why both are drawn.
  Sizing the dots by share instead was considered and rejected. It stays a
  circle rather than a pill because hex ids like `41`, `CC` and `FD` are real,
  so a pill reading `23` would be ambiguous with a single repeater.
- **Five states**, `RepeaterMarkerStatus` in
  `lib/utils/repeater_marker_style.dart`. Declaration order is load-bearing
  twice: it is the dot-row order and the tie-break order for the dominant
  state. `wireKey` keeps the names already baked into image ids and GeoJSON
  properties (`dead` for stale, `dup` for excluded).
  Priority for a single repeater is `dup > dead > new > backbone > active`.
  One registry, one lookup: a status with no entry draws in the active colour
  and logs a single `[MAP]` warning, because a silent wrong colour is worse
  than a loud one.
- **Three measured constraints that must not be optimised away.** The state
  colour never goes in the fill (above). The label ink is DERIVED from the body
  by `RepeaterMarkerStyle.labelInkFor` at the 0.179129 luminance threshold
  where white and black contrast equally, never hardcoded, so a future palette
  cannot ship an unreadable label. Backbone gold `#E8B923` stays light: it is
  the same hue as the brown it replaced and only reads as gold above roughly
  L* 75, so darkening it for a dark theme turns it back into brown.
- **Cluster aggregation.** Clustering happens natively inside MapLibre, so
  there is no Dart-side view of a cluster's members. The source declares one
  `clusterProperties` running count per state, accumulated with `+` only (the
  operator both native bridges are exercised with); the badge layer picks its
  disc with nested binary `case` expressions comparing each count to the
  maximum (plurality, ties to the earlier status). Binary cases avoid the iOS
  MLN_IF icon-image parsing crash; maximum comparisons avoid its BETWEEN
  predicate folding. The native regression check in
  `test/native/check_repeater_expressions.py` exercises the production JSON
  against the pinned simulator SDK. The layer picks its dot strip with a `step`
  over a presence bitmask. This needed
  the MapLibre upgrade: `clusterProperties` was unimplemented on iOS and absent
  on Android before it.
- **Bitmaps.** Simplified (clustered) bakes 15 chip BODIES (5 states x 3 hop
  widths) and lets MapLibre place the hex as a shared-glyph label nudged right
  by half the bar; Detailed (un-clustered) bakes the label INTO the chip, one
  image per `(status, hop, hex)`, because an overlapping un-clustered chip can
  otherwise have its label detach onto a neighbour's box (the MapLibre symbol
  two-pass overlap bug). Badge discs are 5 images; presence-dot strips are
  baked lazily for the masks the states on screen can actually produce (a zone
  showing three states needs 8, not 32), read back off the pushed
  FeatureCollection so the registered set cannot drift from what the layer
  asks for. Both caches are cleared on style reload, because a native style
  teardown drops every registered image.
- **A Colour Vision change re-bakes every marker bitmap.** They are baked with
  whatever palette was active when the style loaded, so without this the
  repeater markers, cluster badges and coverage pins kept the old palette until
  the user happened to cycle the basemap.
- **Tapping a group: one press, one useful outcome.** One rule,
  `_resolveClusterTap`, shared by the direct tap and the GPS-marker
  fall-through so the two can never answer differently. The group's own
  geography decides, not the zoom level. `clusterExpansionZoom`
  (`lib/utils/cluster_spread.dart`) inverts `metersPerPixelAtZoom` to find the
  zoom at which the group's span finally exceeds MapLibre's merge radius, and
  the tap jumps STRAIGHT there instead of crawling two levels at a time. When
  no reachable zoom separates it, because the markers share a rooftop, the tap
  spreads it immediately at whatever zoom the user is on. Before this the rule
  was "zoom two levels, spread only at max zoom", which cost three or four
  presses and swallowed the ones at the end.
  - The answer is a WHOLE zoom level, because clustering is recomputed at
    integer zooms and the camera stops just short of 17, so the deepest
    clustering level a user can reach is 16. Judging the span at the fractional
    maximum instead promises a separation that never arrives, and the tap then
    zooms to the end and sits there.
  - The span is the bounding box diagonal, which can only over-state the widest
    pair, so the answer errs towards zooming and only tight clusters changed.
    Points under half a metre apart are one mast by definition; that floor also
    stops a pole, where the span and the scale are both floating-point noise,
    dividing one near-zero by another and claiming a spread of 900,000 px.
  - The merge radius is ONE constant, `_clusterRadiusPx`, read by the cluster
    source, by this rule, and by the spider grouping. A drift between them
    makes the rule describe a map that does not exist. MapLibre documents its
    own radius against tile width rather than screen pixels, so the model can
    still be off; `_zoomInOnCluster` therefore never zooms LESS than the old
    two-level step, and a tap that lands short simply recomputes from wherever
    the camera ended up. It also reports whether the camera had anywhere to go
    at all, so a tap at max zoom is never spent on a move nobody can see.
  - **A tap that routes here must not then fail to find what it hit.** The
    native tap dispatcher is more forgiving than an exact-point feature query,
    so the `point_count` lookup falls back to a `_clusterTapTolerancePx` box
    around the finger before giving up. Losing the count is not harmless: the
    resolver then falls back to a BFS group, which can be WIDER than the
    cluster actually tapped and so answers "zoom" where the real group would
    have answered "spread". That is what made one tight group of three spread
    on some taps and zoom on others.
  - Every cluster tap logs its count, group size, zoom, computed expansion zoom
    and the action taken under `[MAP]`, because "sometimes" is not a thing that
    can be reasoned about from the source.
- **Backbone comes from the server and is NEVER computed locally.** Scoring is
  whole-pool: every repeater in a region ranked by its share of the region's
  summed link counts, smallest set reaching 50% of the traffic. The app fetches
  a zone's repeaters, not a region's traffic, so a local score would disagree
  with the web for the same area, and no app-facing endpoint carries link data.
  `Repeater.backbone` and `backboneShare` are additive and **absent, not null**,
  in three ordinary cases: a server predating the fields, a region whose
  background job has not run, and a region too quiet to score. Absent means
  "not backbone", it is the expected state, and nothing is logged or surfaced.
  Gold REPLACES active and never stacks, so a stale or ambiguous repeater keeps
  its own colour even when the server marks it (`Repeater.isBackbone` folds the
  active requirement in). The values refresh on the order of hours, so they are
  never polled. The repeater detail sheet shows the share as a rounded percent
  when the server sent one.
- **Tests**: `test/utils/repeater_marker_style_test.dart` pins the derived ink,
  the dominant/presence resolvers against a small evaluator for the MapLibre
  expressions (the only way to check those agree without a device), the chip
  and badge geometry, and a guard that all five accents clear 3:1 on the body
  and differ from one another in every palette.
  `test/utils/repeater_marker_painter_test.dart` rasterises the real painters
  and probes pixels, because "the body is neutral and the state is on the edge"
  is a claim about pixels that no amount of clean analysis speaks to.
  `test/models/repeater_backbone_test.dart` covers the absent and present
  paths against a faked response.
- **Files**: `lib/utils/repeater_marker_style.dart` (geometry, registry,
  cluster expressions), `lib/utils/repeater_marker_painter.dart` (the drawing),
  `lib/widgets/map_widget.dart` (`_MapImages`, `_registerMapImages`,
  `_ensureRepeaterChipImages`, `_ensureRepeaterDotImages`,
  `_setupRepeaterClusterLayers`), `lib/utils/ping_colors.dart` (the five
  accents per colour-vision palette).

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
- **Radio preset filter**: the tile URL, the post-wardrive fresh refetch, both coverage tap
  requests and the repeater list carry `f_freq`, `f_bw` and `f_sf` (never `f_cr`, so a channel
  matches every coding rate), built by `radioFilterFromTag` in `lib/utils/radio_filter.dart` from
  the radio's tag. Connected: the live radio's. Disconnected: the last connect's, persisted in
  `user_preferences` under `last_radio_config` (deleted when a radio that reports no
  configuration connects). No configuration means no parameters. `ApiService.radioFilterGetter`
  feeds the readers; `MapWidget` bakes the same suffix into its tile template and rebuilds the
  overlay when `AppStateProvider.radioFilterKey` differs from the key it last applied (session
  patch and open community view dropped, like a grid change). Server first: a region door that
  answers an unknown `f_` with 400 would blank the overlay.
- **Post-wardrive live refresh**: on upload success the queue hands the uploaded items to
  `AppStateProvider`; +7 s later the server re-renders the affected tiles at z11–14
  (`fresh=1`, incl. neighbouring tiles within ~0.005° — blob/border spill lands in the
  next tile over), and the user's own cells are decoded from the fresh z14 bodies
  (`lib/utils/mvt_cells.dart`) into a session **patch layer**: a GeoJSON source updated
  in place above the base layer, with the base layer's copies hidden via `setFilter`.
  The base source is never swapped — nothing visibly changes except the changed cells.
  A second check runs at +10 s only when the first found no changes. Logged under
  `[COVERAGE]`.
  z11-13 refreshes send `If-None-Match: *`: the server still renders and warms
  its cache, but returns a body-free 304 with its `X-Tile-Changed` verdict.
  That verdict still drives the existing retry decision. A server returning
  200 remains supported. z14 stays unconditional and supplies the complete
  tile bytes for live cell updates, including unchanged server verdicts.
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

### The One Session Status Model

"What is the session doing right now?" is worked out in exactly one place,
`lib/services/status/session_status_resolver.dart`, and every surface reads that
one answer. Before this existed the phone buttons, the Live Activity, the watch,
Siri and the Android notification each derived the state themselves, so they
could disagree about it, not merely lag.

`resolveSessionStatus(...)` is a pure function of about two dozen facts (each
timer flattened to a running flag plus an absolute deadline, no clock and no live
object) and returns a `SessionStatus`: a single glance answer (`activity`,
`owner`, `deadline`) plus four `LaneStatus` lanes (manual, txAuto, discovery,
targeted). The precedence is one ordered list of observations, each naming the
lane it belongs to; the single-phase surfaces take the first, and each button
takes the first belonging to its own lane, or reports being held by it. That is
what makes "the surfaces cannot disagree" structural: a surface can only report a
state some lane is actually in.

Who reads what:

- **The in-app buttons** (`lib/services/status/ping_control_labels.dart`) read
  the four lanes. `AppStateProvider.sessionStatus` resolves the model fresh on
  each layout so the countdowns stay live.
- **The Live Activity, watch and Siri** read the glance answer, projected to a
  title and detail by `resolveSessionPhase`
  (`lib/services/status/session_phase_resolver.dart`). The watch and Siri pass it
  through `resolveWatchSurfacePhase`, which substitutes `idle` in the two cases
  the wrist renders while the phone shows nothing (a truly idle Starting, and a
  post-stop cooldown with no glance session).
- **The Android foreground notification** reads `androidNotificationContent`
  (`lib/services/status/android_notification.dart`) for its finished title and
  body; the background isolate composes nothing.

**A pending stop belongs to the mode being stopped.** It is the one state that is NOT a lane
observation: it is laid over the glance only, so the lane the mode is closing keeps counting
its own window down. The glance names that mode's lane as the `owner` (`_autoLane(autoMode)`),
and the buttons ask the same question through `isTxStopping` / `isPassiveStopping` /
`isTraceStopping` in `ping_control_labels.dart`. Exactly one is true whenever a stop is
pending, Active taking anything no other mode claims, so a stop is never rendered nowhere and
never on a button whose mode was not running. `isPendingDisable` used to be a lane-less
boolean that every renderer put on the Active/Hybrid button, so stopping Passive turned
Active orange and read "Stopping" for a mode that had never been enabled. The button that
owns the stop also stops taking taps while it drains, which Active always did and Passive and
Trace did not (their `isXRunning ||` short-circuited past the guard, and a second tap tore the
lane down without clearing the parked disable, leaving the stop up for the full 12 second
backstop).

"Is the session stopping" is one fact, `AppStateProvider.isPendingDisable`: a disable parked
behind an in-flight ping, OR the teardown that follows one (`_autoPingStopping`). The latch
half matters because the parked flag is cleared by `PingService` on the first line of the
drain and the provider's half of the teardown runs after that, across three awaits, and the
inline stop path parks no flag at all. Without it the session read as running for the back
half of every stop, and a repeat Stop from Siri or the watch landing there was admitted and
re-ran the teardown, re-arming the 5 second cooldown from zero. The Siri/watch lane answers a
repeat Stop with a no-op, "MeshMapper is already stopping"
(`resolveExternalSessionTransition`, ahead of its idle test because one stop path clears the
session flag while the disable is still parked), and `PingService.disableAutoPing` returns
early when a disable is already parked, so no caller can strand one: the old fall-through ran
the immediate teardown, which disposes the tracker whose window completion is the only thing
that drains it. `forceDisableAutoPing` is still the way to override a parked disable. A Start
arriving on that lane while the stop drains is REFUSED with `stillStopping` ("MeshMapper is
still stopping. Try again shortly."), ahead of both the already-running and the already-starting
tests, the mirror of the Stop branch: a parked disable still reads as an active session, so the
answer used to be a no-op reported as success ("MeshMapper is already running in Active mode")
about a session that was visibly stopping. It is the same reason `resolveSessionStartAvailability`
gives for the same state, which is the gate the phone's own buttons and the watch's enablement
read; the transition used to admit and lean on that second gate, so a surface consulting only
this resolver was one call away from starting a mode on top of a draining stop.

All three send lanes latch `_pingInProgress` BEFORE their fresh GPS fix, never after it, so a
Stop pressed during that fetch parks rather than tearing the lane down under a send that is
still running. Trace was the exception and it showed: its stop ran the immediate teardown,
disposed the TraceTracker and nulled the distance anchor, and the suspended send then resumed
with nothing to stop it, putting a trace on the air for a session the user had already
stopped, arming a listening window against a disposed tracker (a countdown whose completion
could never fire), and leaving a stale anchor that skipped the next session's first trace. The
corollary of the latch is that every bow-out past it (no fix, the 25 m rule) has to drain a
parked disable itself, or that stop waits out the 12 second backstop.

The latch only covers the graceful stop, the one that parks. `forceDisableAutoPing` consults
nothing: it clears the mode flags and disposes the trackers whatever is in flight, and that is
the stop behind a disconnect, the airborne block, a session error, a zone grace or transfer,
and a mode switch. So all three sends re-read the mode after the fresh fix and bow out without
transmitting if the lane is gone. That matters most for the airborne block, which exists to
stop transmitting from an aircraft and was letting one more packet out on every lane. On the
TX side the check is auto-only: a manual ping is not part of an auto session, and it takes no
fresh fix there anyway. `canPing()` re-reads the connection step and the airborne latch after
that suspension but never the mode, which is why the mode needs its own check.

The mode re-read is not enough on its own, because `forceDisableAutoPing` also clears
`_pingInProgress` (it has to: a force disable during a 7 second echo window would otherwise
leave the flag latched for the next session) and a zone transfer can re-auth and restart the
session inside the old send's fetch. The resumed send then read the mode as on and went out
alongside the new session's first ping. So each lane also captures `PingService._sendEpoch`
before its fetch; `forceDisableAutoPing` bumps it, and a send that finds it moved bows out
without touching the flag, which by then is either already clear or held by the new session's
send. The trace lane's `finally` makes the same exception for its flag reset.

The discovery lane's `finally` is shaped like the trace lane's: it resets `_pingInProgress`
first, under `!armedWindow && epoch == _sendEpoch`, and drains a parked disable after. The
reset used to be a *condition* of the drain (`!armedWindow && !_pingInProgress &&
_pendingDisable`), so a throw anywhere in the latched region left the flag set for the life of
the service, which every discovery, trace, auto and manual ping reads, and made the drain
unreachable on exactly that path.

A session recovery is the third way a scheduled attempt bows out, and it has to re-arm the
lane on the way. `sendTxPing` checks `_sessionRecoveryInProgress` twice, once before the fresh
fix and once after it, and both bow-outs call `_rescheduleAutoLane`, which picks the Hybrid or
the Active schedule exactly as the 25 m skip path picks it. Every interval timer here is
one-shot and the provider clears the recovery flag in a `finally` only, so a tick that landed
during a recovery used to end the lane for the rest of the session with the mode flags still
reading enabled. A manual ping arms nothing. The second bow-out clears `_pingInProgress`
before it reschedules, as the validation skip path does: `onAutoPingScheduled` fires
synchronously, and a disable arriving while that flag is still true latches as pending with no
window left to drain it.

Two observations carry an `onGlance` flag so a state can belong to a lane (which
the buttons read) without moving the single glance answer, or reach both. The
`SessionActivity` type is an alias of `LiveActivityPhase`, so a phase dropped
anywhere fails to compile rather than rendering blank.

The `sending` observation is gated on `autoPingSkipReason == null` as well as
`isPingInProgress`, because that flag latches at the top of the send, before the
fresh fix and validation: an auto attempt about to defer (covered) or skip (25 m)
would otherwise flash `Sending` for the length of the GPS read before dropping to
Deferred/Skipped (the Hybrid-while-parked flapping). A real send clears the skip
reason as it validates, so it still reads `Sending`. The deferred/skipped
observation is correspondingly widened to fire in that same in-progress gap
(`isAutoPingRunning || (isPingInProgress && autoPingSkipReason != null)`), not
only while the interval timer runs: the timer fires and is not rescheduled until
the attempt validates, so without this the lane falls through to the resting
`active` and the button flashes the bare mode word (`Hybrid Mode`) in the gap.

**Kept out of the per-tick path on purpose:** the model carries no validator
result (no `canPing()`, geodesic distance or coverage lookup). It is resolved on
every countdown tick, about 2 Hz for a whole session, and this app has a
wardriving overheat history. The one label that needs the validators
(`blockingHint`) takes them as a separate argument, so only that caller pays.

Golden tables pin all of it (`test/services/status/`): a per-return-site table
for the phase resolver, a per-lane table for the buttons, and an agreement test
over the glance surfaces (the watch and Siri projection substitutes `idle` in
exactly two defined cases and otherwise passes the phase through, the resolver
never itself produces `idle`, and the two states the buttons alone used to show
now reach the glance). The differential harness that proved the button lift
changed no output was scaffolding against the pre-lift implementation and was
retired with it once the lift landed (`ac108b6`); the per-lane table guards the
buttons now.

Know what is NOT covered: no test puts a button label beside a glance title, so
the agreement between those two is structural (one resolver, one ordered
precedence list) rather than asserted. A condition that reads a fact outside the
lane it belongs to can therefore still split them with every table green, which
is how a stale `AutoPingTimer.skipReason` once left `Deferred` on a resting
Active button beside Send Ping's `Listening`. When you add an observation, gate
it on the same session and lane facts as its neighbours.

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
- `Siri, start MeshMapper` defaults to Passive.
- `Siri, start a Passive session in MeshMapper`.
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

The app consumes upstream `0.27.1` through the local `dependency_overrides` path,
with `example/` and the Android/iOS `.gitignore` files omitted. The native delta
is confined to the two `MapLibreMapController` files, tagged `MESHMAPPER GUARD`:

- Android retains the `camera#move` and `camera#animate` guards. A missing map view
  or either dimension below one pixel completes the call with `false` before
  camera conversion. Upstream 0.27.1 still has no equivalent viewport check.
- iOS keeps upstream's central `camera#` deferral before camera conversion, but
  checks each bounds dimension below one point and limits each call to ten
  retries, spaced 16 ms apart. A permanently unusable viewport or a controller
  released while waiting completes the call with `false`. A viewport that becomes
  usable proceeds normally. Upstream only checks an exactly zero frame and
  redispatches indefinitely, leaving the Dart future unfinished on persistent
  layout failure. The retry bound is per call, not shared between camera calls.

These checks prevent a degenerate viewport from reaching native `unproject`,
which can produce NaN and an uncaught C++ `std::domain_error` (SIGABRT). Dart
cannot catch that native abort. The Dart `_mapHasRenderedOnce` / `_canAnimateCamera`
backstop in `map_widget.dart` remains in place.

The previous 0.25.0 vendor also carried ten Android returns after null-style
errors; the old documentation's claim that the camera guard was the only delta
was incorrect. Each site was checked against 0.27.1 and all ten are now retired:
`style#addImage`, `style#addImageSource`, `style#updateImageSource`,
`style#removeSource`, `style#removeLayer`, `style#setFilter`, `style#getFilter`,
and `layer#setVisibility` exit with `break` on `STYLE_NOT_READY`.
`style#addLayer` and `style#addLayerBelow` call `addRasterLayer`, which returns
`false` before accessing an unavailable style; both callers then report the
error and exit. No additional style-handler patch is carried.

**Native versions:** iOS is governed by
`third_party/maplibre_gl/ios/maplibre_gl/Package.swift`, which pins MapLibre
`6.28.0`; the podspec matches for CocoaPods consumers. Verify the actual Swift
package resolution when building this app. Android uses `android-sdk-opengl:13.5.0`,
including the app's explicit dependency for offline cache access. The previous
Android version was `12.3.1`. JDK 21 compiles the plugin; the app retains its
Java/Kotlin 17 targets.

**On upgrade:** compare against the upstream package, retain the camera guards
unless upstream provides equivalent persistent-viewport protection, and recheck
all native pins. `python3 -m unittest discover -s test/native` compiles and runs
the production Swift method's camera gate against controlled viewport and
lifetime scenarios on macOS. It does not replace real-device rendering checks.

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
| `[RADMIN]` | Repeater administrators: admin session, claim and neighbour modules, the /repeater API, the Manage sheet |
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

### Describing Session State

There is no free-form status-string API (an older `statusMessage` / `StatusType`
/ `setStatus` shape was documented here but never existed in `lib/`). What the
session is doing is one value, resolved by `resolveSessionStatus` and read by
every surface. See **The One Session Status Model**. New UI that needs to say
what the session is doing reads that model rather than composing its own label,
so the surfaces stay in agreement. Transient user feedback (an error or an event
worth surfacing) goes to the error log, which is a separate concern.

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

## Device Catalog

The catalog contract is `docs/DEVICE_CATALOG.md`.

The app has no bundled device list. `DeviceModelService` loads the last fully
validated server response from `SharedPreferences`, then starts one shared
10-second catalog refresh for the launch. It replaces memory and the cache only
after the whole response passes strict type, bound, and normalized-identity
validation (`DeviceCatalog.fromJson` in `lib/models/device_catalog.dart`: at most
500 devices, 50 aliases per device, 1 MiB encoded, no duplicate device ID and no
duplicate normalized identity). `initialize()` never throws. A platform-channel
failure or an unreadable preference store leaves the service with no storage and
no catalog, logged under `[MODEL]`, because app startup awaits this call and a
throw used to abort the rest of it: preferences, regional CARpeaters, repeater
claims, the remembered device and every listener below it were skipped, leaving
the app on defaults with no sign of why. A fetched catalog is published to memory
even when the cache write is refused, so a device that cannot persist still
recognizes radios for the rest of that launch.

A connect that finds no catalog cached arms one more refresh itself. At most one
per connect resolve, never while a refresh is in flight, and no sooner than
`connectRetryFloor` (30 s) after the previous refresh ended, so a dead link
cannot turn every connect into a fetch. Identification then waits at most
`connectWaitCap` (3 s) for a catalog to land, whatever deadline that refresh is
running to, and continues as unknown when the cap expires. The cap is sized
against `handshakeRerunWindow` in
`lib/services/bluetooth/ble_connect_retry_policy.dart` (20 s): resolution happens
at connection workflow step 4, before the first radio write of the handshake, and
spending a whole fetch deadline there would push a link that dies right after the
transport connect past the window that earns it a one-shot workflow rerun. The
fetch itself keeps running to its own deadline and lands in the cache for the
next connect.

Cache publication writes an inactive slot before switching the active pointer.
Startup reloads durable preferences before reading that pointer, because a failed
SharedPreferences write can still change its process cache. Legacy cached JSON
is retained as the fallback until a slot is successfully published.

Matching (`lib/services/device_model_matcher.dart`) is exact after shared
sanitization, approved build-suffix removal (a trailing
`(nightly|stable|dev)-<hex>`, case-insensitive) and ASCII-only normalization
(letters and digits, lower-cased). It considers manufacturer, short name, and
aliases, and recognizes a result only when exactly one device ID matches. There
is no partial or prefix fallback: a firmware identity the app does not recognize
is fixed by adding a server-side alias, not by loosening the match. Unknown or
unavailable-catalog paths remain connectable and preserve the existing manual
reporting-power flow. Recognition only selects the `power` and `txPower` values
reported to the API (`resolveReportingPower` in
`lib/services/reporting_power.dart`, where a saved per-radio override outranks
the matched model). Those figures, the PA amplifier models' included, live in the
server catalog; the app holds no power table of its own and never writes radio TX
settings.

Genuine unknown identities observed against a valid catalog enter a bounded,
versioned `SharedPreferences` outbox. The outbox is serialized, reports at most
once per normalized identity per launch, retains failed sends for a later launch,
and removes an item only after an exact `known`, `pending`, or `dismissed`
acknowledgement for the submitted generation. A successful catalog refresh
suppresses queued identities it now recognizes.

New observation generations combine a random launch nonce with a monotonic
counter. Evicting and reinserting an identity cannot reuse the token of an older
in-flight report. Positive integer generations from older saved outboxes remain
readable and can still be acknowledged on a later launch.

Network requests run outside the mutation chain. Acknowledgements re-enter it
before reading the stored generation and publishing a removal, so delayed writes
cannot overwrite newer observations or refresh cleanup. Failed local writes do
not dispatch a report or consume an attempt, and refresh recognition is checked
again after an observation finishes persisting.

The provider uses `preferencesForConnectingDevice` before online auth and
`prepareConnectedDevice` after every successful transport handshake. These
decisions live in `lib/providers/device_connection_setup.dart`: the current
radio's saved power overrides its selected model, and an unknown radio with no
saved choice clears the previous radio's configured flags. The post-connect
function also gates asynchronous unknown reporting on a completed connection.
Offline Mode follows the same post-connect decisions without the auth step.

## MeshMapper API Endpoints

**Base URL**: `https://meshmapper.net/`

**API Key**: Injected at build time via `--dart-define=API_KEY=...`. Never hardcoded in source. `Build.sh` prompts for it, or set `MESHMAPPER_API_KEY` env var.

- **POST /wardrive-api.php/status**: Check zone status (geo-auth)
- **POST /wardrive-api.php/auth**: Acquire/release session (geo-auth)
- **POST /wardrive-api.php/devices**: Refresh supported devices or report an unknown identity (App key)
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
- `lib/services/status/session_status_resolver.dart` - The one session model: pure `resolveSessionStatus` (glance answer plus four lanes)
- `lib/services/status/session_status.dart` - `SessionStatus` / `LaneStatus` / `SessionActivity` types
- `lib/services/status/session_phase_resolver.dart` - Projects the model to the glance title and detail (Live Activity, watch, Siri)
- `lib/services/status/ping_control_labels.dart` - The in-app button labels and countdowns, read from the model's lanes
- `lib/services/status/android_notification.dart` - Pure title/body for the Android foreground notification
- `lib/services/gps_service.dart` - GPS tracking and geofencing
- `lib/services/recent_coverage_service.dart` - Smart Pinging lookup: recently covered cells from filtered z13 tiles
- `lib/services/airborne_release.dart` - Pure builder for the airborne session-end text and release telemetry
- `lib/services/disconnect_alert_decision.dart` - Pure staleness rule for the disconnect alert, so a beep delayed by a suspended process is never played
- `lib/services/api_queue_service.dart` - Persistent upload queue
- `lib/services/device_model_service.dart` - Device catalog cache, launch and connect-time refresh, unknown-device outbox
- `lib/services/device_model_matcher.dart` - Shared identity sanitization, normalization and exact catalog match
- `lib/models/device_catalog.dart` - Validated catalog envelope and its bounds
- `lib/models/device_model.dart` - One validated catalog device record
- `lib/services/reporting_power.dart` - Reporting-only power resolution with the per-radio override precedence
- `lib/providers/device_connection_setup.dart` - Pure pre-auth and post-connect device decisions
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
- `lib/services/repeater_admin/repeater_admin_session.dart` - Repeater admin session: contact, login, ACL proof, route, neighbour pager over the mesh
- `lib/services/repeater_admin/repeater_admin_module.dart` - ClaimModule and NeighboursModule: one payload per server action
- `lib/services/repeater_admin/repeater_admin_api.dart` - The /repeater leg (claim, unclaim, mine, neighbours) and its refusal mapping
- `lib/services/repeater_admin/repeater_admin_models.dart` - Repeater admin models, request builders and reply parsers
- `lib/services/repeater_admin/manage_target.dart` - Pure Manage-target resolver and the shared block reason
- `lib/widgets/repeater_admin_sheet.dart` - The Manage bottom sheet
- `lib/utils/pkce.dart` - RFC 7636 S256 PKCE pair generation
- `lib/services/watch/watch_bridge_service.dart` - WatchConnectivity transport: throttle, dedupe, movement gate, map-geo lease, command admission
- `lib/services/watch/watch_models.dart` - Watch wire contract and shared start-admission resolver
- `lib/services/watch/watch_geo_builder.dart` - Ping/repeater/heard geography for the wrist, with wire caps
- `lib/services/watch/watch_color.dart` - Wire colour projection shared with the phone map
- `lib/services/live_activity/live_activity_service.dart` - ActivityKit bridge: preflight urgency, throttle, dedupe, unavailable backoff
- `lib/services/live_activity/live_activity_heard.dart` - The Live Activity's heard rows, read from the map's Top Heard box (shared with the watch)
- `lib/services/live_activity/live_activity_models.dart` - Live Activity snapshot model and urgency keys
- `lib/services/external_surfaces/external_surface_publisher.dart` - Shared publish pipeline (preflight dedupe, throttle, retry) behind watch, Live Activity, and Siri snapshots
- `lib/services/external_surfaces/geo/external_surface_geo_builder.dart` - Ping/repeater/heard geography for external surfaces, with wire caps (was watch_geo_builder)
- `lib/services/external_commands/external_session_commands.dart` - Shared Siri/watch session-command admission and deadline rules
- `lib/services/external_commands/external_command_models.dart` - External command wire model, refusal reasons, and voice copy
- `lib/services/app_intents/app_intent_bridge_service.dart` - Siri method channel: command decode, dedupe, snapshot publish
- `lib/services/app_intents/siri_snapshot_builder.dart` - App Group snapshot content (recent heard, repeater catalogue, counts)
- `lib/services/app_intents/last_companion_connection.dart` - Connect-last-companion admission for the Siri intent
- `lib/screens/watch_diagnostics_screen.dart` - Watch transport diagnostics (Settings)
- `lib/services/meshcore/packet_validator.dart` - Packet validation and carpeater filtering
- `lib/services/meshcore/regional_carpeater_filter.dart` - The region's shared CARpeater list: own-key exclusion, hop-prefix and full-key matching
- `lib/utils/public_key.dart` - Full public key normalization (upper-case 64 hex)
- `lib/utils/repeater_marker_style.dart` - Repeater marker geometry, the five-state colour registry, and the cluster dominant/presence expressions
- `lib/utils/cluster_spread.dart` - The zoom that pulls a repeater cluster apart, deciding zoom-vs-spread on tap
- `lib/utils/repeater_marker_painter.dart` - Draws the repeater chip, the cluster badge disc and its presence dots
- `lib/models/noise_floor_session.dart` - Noise floor session data models
- `lib/widgets/noise_floor_chart.dart` - Noise floor graph visualization
