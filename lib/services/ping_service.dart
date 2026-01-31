import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../models/connection_state.dart';
import '../models/log_entry.dart';
import '../models/ping_data.dart';
import '../utils/debug_logger_io.dart';
import 'api_queue_service.dart';
import 'audio_service.dart';
import 'countdown_timer_service.dart';
import 'gps_service.dart';
import 'meshcore/connection.dart';
import 'meshcore/disc_tracker.dart';
import 'meshcore/tx_tracker.dart';
import 'wakelock_service.dart';

/// Ping service for TX/RX ping orchestration
/// Ported from wardrive.js ping logic
///
/// TX Flow:
/// 1. Validate GPS lock, 25m min distance (zone validation handled server-side)
/// 2. Start TxTracker to monitor for repeater echoes
/// 3. Send @[MapperBot] LAT, LON [POWERw] to #wardriving channel
/// 4. Start 6-second RX listening window (matches JS RX_LOG_LISTEN_WINDOW_MS)
/// 5. Post to API queue with type "TX"
///
/// RX Flow (via TxTracker):
/// 1. TxTracker receives LogRxData packets via UnifiedRxHandler
/// 2. Validates packet: GroupText header, channel hash, message correlation
/// 3. Extracts repeater ID from path (first hop)
/// 4. After window ends, collect results and post to API queue with type "RX"
///
/// Discovery Flow (Passive Mode only):
/// 1. In Passive Mode, send discovery request instead of TX ping
/// 2. Start 7-second listening window via DiscTracker
/// 3. Collect discovery responses (0x8E packets)
/// 4. After window ends, create log entry and queue DISC API payloads
class PingService {
  /// RX listening window duration (7 seconds - matches cooldown duration)
  static const Duration _rxListeningWindow = Duration(seconds: 7);
  /// Cooldown period between pings (7 seconds - matches JS COOLDOWN_MS = 7000)
  static const Duration _autoPingCooldown = Duration(seconds: 7);
  /// Discovery listening window duration (7 seconds)
  static const Duration _discoveryListeningWindow = Duration(seconds: 7);
  /// Discovery request interval (30 seconds - repeaters only respond 4 times per 2 minutes)
  static const Duration _discoveryInterval = Duration(seconds: 30);

  final GpsService _gpsService;
  final MeshCoreConnection _connection;
  final ApiQueueService _apiQueue;
  final WakelockService _wakelockService;
  final CooldownTimer _cooldownTimer;
  final RxWindowTimer _rxWindowCountdown;
  final DiscoveryWindowTimer _discoveryWindowCountdown;
  final String _deviceId;
  final TxTracker? _txTracker;
  final AudioService? _audioService;
  final bool Function(String repeaterId)? shouldIgnoreRepeater;

  PingStats _stats = const PingStats();
  DateTime? _lastTxTime;
  Timer? _rxWindowTimer;

  // TX ping context for queueing after RX window ends
  int? _pendingTxTimestamp;
  int? _pendingTxNoiseFloor;

  // Ping in progress guard (prevents concurrent BLE GATT errors)
  // Reference: state.pingInProgress in wardrive.js
  bool _pingInProgress = false;

  // Auto-ping mode
  bool _autoPingEnabled = false;
  bool _passiveModeEnabled = false;
  Timer? _autoTimer;

  // Pending disable flag - when true, disable will execute after RX window ends
  bool _pendingDisable = false;

  // Auto-ping interval in milliseconds (default 30s, options: 15s, 30s, 60s)
  // Reference: getSelectedIntervalMs() in wardrive.js
  int _autoPingIntervalMs = 30000;

  // Skip reason for display during auto mode countdown
  String? _skipReason;

  // Discovery tracking
  DiscTracker? _discTracker;
  StreamSubscription? _controlDataSubscription;
  Timer? _discoveryTimer;
  Position? _discoveryStartPosition;
  Position? _lastDiscoveryPosition;  // Track last discovery position for 25m check

  // Validation callbacks
  bool Function()? checkExternalAntennaConfigured;
  bool Function()? checkPowerLevelConfigured;

  /// Callback to check if TX is allowed by API (zone capacity check)
  bool Function()? checkTxAllowed;

  /// Callback for ping events
  void Function(TxPing)? onTxPing;
  void Function(RxPing)? onRxPing;
  void Function(PingStats)? onStatsUpdated;
  /// Called in real-time when each echo is received during tracking window
  /// Parameters: (TxPing txPing, HeardRepeater repeater, bool isNew)
  void Function(TxPing, HeardRepeater, bool isNew)? onEchoReceived;

  /// Callback for discovery events (Passive Mode)
  /// Called when a discovery window completes with the log entry
  void Function(DiscLogEntry)? onDiscoveryComplete;

  /// Callback when pending disable completes after RX window
  /// AppStateProvider uses this to update its state and cleanup
  Future<void> Function()? onPendingDisableComplete;

  /// Last TX ping sent (for updating with heard repeaters)
  TxPing? _lastTxPing;

  PingService({
    required GpsService gpsService,
    required MeshCoreConnection connection,
    required ApiQueueService apiQueue,
    required WakelockService wakelockService,
    required CooldownTimer cooldownTimer,
    required RxWindowTimer rxWindowTimer,
    required DiscoveryWindowTimer discoveryWindowTimer,
    required String deviceId,
    TxTracker? txTracker,
    AudioService? audioService,
    this.shouldIgnoreRepeater,
  })  : _gpsService = gpsService,
        _connection = connection,
        _apiQueue = apiQueue,
        _wakelockService = wakelockService,
        _cooldownTimer = cooldownTimer,
        _rxWindowCountdown = rxWindowTimer,
        _discoveryWindowCountdown = discoveryWindowTimer,
        _deviceId = deviceId,
        _txTracker = txTracker,
        _audioService = audioService;

  /// Get current ping statistics
  PingStats get stats => _stats;

  /// Check if auto-ping is enabled
  bool get autoPingEnabled => _autoPingEnabled;

  /// Check if a ping is currently in progress
  bool get pingInProgress => _pingInProgress;

  /// Check if Passive Mode is active (listen-only, no transmit)
  bool get isPassiveMode => _passiveModeEnabled;

  /// Check if discovery tracker is currently listening (for Passive Mode UI)
  bool get isDiscoveryListening => _discTracker?.isListening ?? false;

  /// Get current auto-ping interval in milliseconds
  int get autoPingIntervalMs => _autoPingIntervalMs;

  /// Check if a disable is pending (waiting for RX window to complete)
  bool get pendingDisable => _pendingDisable;

  /// Get current skip reason (for auto mode display)
  String? get skipReason => _skipReason;

  /// Set auto-ping interval (15000, 30000, or 60000 ms)
  /// Reference: getSelectedIntervalMs() in wardrive.js
  void setAutoPingInterval(int intervalMs) {
    // Clamp to valid values: 15s, 30s, or 60s
    if (intervalMs == 15000 || intervalMs == 30000 || intervalMs == 60000) {
      _autoPingIntervalMs = intervalMs;
      debugLog('[PING] Auto-ping interval set to ${intervalMs}ms');
    } else {
      debugWarn('[PING] Invalid interval $intervalMs, defaulting to 30000ms');
      _autoPingIntervalMs = 30000;
    }
  }

  /// Check if we can send a TX ping now
  PingValidation canPing() {
    // Check connection
    if (_connection.currentStep != ConnectionStep.connected) {
      return PingValidation.notConnected;
    }

    // Check if TX is allowed by API (zone capacity)
    if (checkTxAllowed != null && !checkTxAllowed!()) {
      return PingValidation.txNotAllowed;
    }

    // Check external antenna configuration
    if (checkExternalAntennaConfigured != null && !checkExternalAntennaConfigured!()) {
      return PingValidation.externalAntennaRequired;
    }

    // Check power level configuration (for unknown devices)
    if (checkPowerLevelConfigured != null && !checkPowerLevelConfigured!()) {
      return PingValidation.powerLevelRequired;
    }

    // Check GPS status
    if (_gpsService.status != GpsStatus.locked) {
      debugLog('[PING] GPS status check failed: status=${_gpsService.status}, '
          'lastPosition=${_gpsService.lastPosition != null ? 'available' : 'null'}');
      return PingValidation.noGpsLock;
    }

    // Check GPS position
    final position = _gpsService.lastPosition;
    if (position == null) {
      return PingValidation.noGpsLock;
    }

    // Note: GPS freshness check removed - 25m movement check is sufficient
    // If user hasn't moved, old position is still valid

    // Check GPS accuracy (< 100m)
    if (!_gpsService.isAccuracyAcceptableForPing(position)) {
      debugWarn('[PING] GPS accuracy too low, rejecting ping');
      return PingValidation.gpsInaccurate;
    }

    // Note: Zone validation is now handled server-side by the API

    // Check minimum distance from last ping
    if (!_gpsService.canPingAtPosition(position)) {
      return PingValidation.tooCloseToLastPing;
    }

    // Check cooldown (7 seconds between pings)
    if (_lastTxTime != null) {
      final elapsed = DateTime.now().difference(_lastTxTime!);
      if (elapsed < _autoPingCooldown) {
        return PingValidation.cooldownActive;
      }
    }

    return PingValidation.valid;
  }

  /// Check if auto mode can be started (excludes distance check)
  /// Allows starting auto mode while stationary - pings will be skipped until user moves
  /// This is the same as canPing() but WITHOUT the tooCloseToLastPing check
  PingValidation canStartAutoMode() {
    // Check connection
    if (_connection.currentStep != ConnectionStep.connected) {
      return PingValidation.notConnected;
    }

    // Check if TX is allowed by API (zone capacity)
    if (checkTxAllowed != null && !checkTxAllowed!()) {
      return PingValidation.txNotAllowed;
    }

    // Check external antenna configuration
    if (checkExternalAntennaConfigured != null && !checkExternalAntennaConfigured!()) {
      return PingValidation.externalAntennaRequired;
    }

    // Check power level configuration (for unknown devices)
    if (checkPowerLevelConfigured != null && !checkPowerLevelConfigured!()) {
      return PingValidation.powerLevelRequired;
    }

    // Check GPS status
    if (_gpsService.status != GpsStatus.locked) {
      return PingValidation.noGpsLock;
    }

    // Check GPS position
    final position = _gpsService.lastPosition;
    if (position == null) {
      return PingValidation.noGpsLock;
    }

    // Note: GPS freshness check removed - 25m movement check is sufficient

    // Check GPS accuracy (< 100m)
    if (!_gpsService.isAccuracyAcceptableForPing(position)) {
      return PingValidation.gpsInaccurate;
    }

    // Note: Zone validation is now handled server-side by the API

    // NOTE: Skip distance check (tooCloseToLastPing) intentionally
    // Auto mode handles this by setting skipReason='too close' and scheduling next ping

    // Check cooldown (7 seconds between pings)
    if (_lastTxTime != null) {
      final elapsed = DateTime.now().difference(_lastTxTime!);
      if (elapsed < _autoPingCooldown) {
        return PingValidation.cooldownActive;
      }
    }

    return PingValidation.valid;
  }

  /// Check if currently in cooldown period
  /// Reference: isInCooldown() in wardrive.js
  bool isInCooldown() {
    if (_lastTxTime == null) return false;
    final elapsed = DateTime.now().difference(_lastTxTime!);
    return elapsed < _autoPingCooldown;
  }

  /// Get remaining cooldown seconds
  int getRemainingCooldownSeconds() {
    if (_lastTxTime == null) return 0;
    final elapsed = DateTime.now().difference(_lastTxTime!);
    final remaining = _autoPingCooldown - elapsed;
    return remaining.inSeconds.clamp(0, _autoPingCooldown.inSeconds);
  }

  /// Send a TX ping
  /// @param manual - Whether this is a manual ping (true) or auto ping (false)
  /// Returns true if ping was sent successfully
  /// Reference: sendPing() in wardrive.js
  Future<bool> sendTxPing({bool manual = true}) async {
    debugLog('[PING] sendTxPing called (manual=$manual)');

    // Early guard: prevent concurrent ping execution (critical for preventing BLE GATT errors)
    // Reference: state.pingInProgress check in wardrive.js
    if (_pingInProgress) {
      debugLog('[PING] Ping already in progress, ignoring duplicate call');
      return false;
    }
    _pingInProgress = true;

    try {
      // Check cooldown for ALL pings (manual and auto)
      // This fixes a race condition where disabling Active Mode during cooldown
      // could still trigger an auto-ping from a late RX window timer callback
      if (isInCooldown()) {
        final remainingSec = getRemainingCooldownSeconds();
        debugLog('[PING] Ping blocked by cooldown (${remainingSec}s remaining), manual=$manual');
        _pingInProgress = false;
        return false;
      }

      final validation = canPing();
      if (validation != PingValidation.valid) {
        // For auto mode, schedule next attempt if distance check failed
        if (!manual && _autoPingEnabled && !_passiveModeEnabled) {
          if (validation == PingValidation.tooCloseToLastPing) {
            _skipReason = 'too close';
            debugLog('[PING] Auto ping blocked: too close to last ping, scheduling next');
          }
          _scheduleNextAutoPing();
        }
        _pingInProgress = false;
        return false;
      }

      // Clear skip reason on successful validation
      _skipReason = null;

      final position = _gpsService.lastPosition!;
      // Use power in watts (0.3, 0.6, 1.0, 2.0) - matches web client buildPayload()
      final powerWatts = _connection.deviceModel?.power ?? 0.3;
      // Also get txPower in dBm for API queue (for database records)
      final txPowerDbm = _connection.deviceModel?.txPower ?? 22;

      // Build ping message (same format used for TxTracker correlation)
      final coordsStr = '${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}';
      final powerStr = '${powerWatts.toStringAsFixed(1)}w';
      final pingMessage = '@[MapperBot] $coordsStr [$powerStr]';

      // Capture noise floor at ping time
      final noiseFloor = _connection.lastNoiseFloor;

      // Create TX ping record FIRST so it's available for echo callbacks
      final txPing = TxPing(
        latitude: position.latitude,
        longitude: position.longitude,
        power: txPowerDbm,
        timestamp: DateTime.now(),
        deviceId: _deviceId,
        heardRepeaters: [], // Will be populated dynamically as echoes arrive
      );

      // Store reference for updating with heard repeaters
      _lastTxPing = txPing;
      debugLog('[PING] Created TxPing, ready for echo tracking');

      // Notify immediately so TxLogEntry exists BEFORE echoes arrive
      // This fixes timing issue where echoes arrived before onTxPing was called
      onTxPing?.call(txPing);

      // Start TX echo tracking BEFORE sending ping (matches web client flow)
      // Reference: startTxTracking() called before sendChannelTextMessage() in wardrive.js
      final channelIndex = _connection.wardrivingChannelIndex;
      final channelHash = _connection.wardrivingChannelHash;
      final channelKey = _connection.wardrivingChannelKey;

      if (_txTracker != null && channelIndex != null && channelHash != null && channelKey != null) {
        debugLog('[PING] Starting TX echo tracking for: "$pingMessage"');

        // Wire up real-time echo callback before starting tracking
        final txTracker = _txTracker;
        txTracker.onEchoReceived = (repeaterId, snr, rssi, isNew) {
          debugLog('[PING] onEchoReceived callback fired: $repeaterId, SNR=$snr, RSSI=$rssi, isNew=$isNew');
          if (_lastTxPing != null) {
            final repeater = HeardRepeater(
              repeaterId: repeaterId,
              snr: snr,
              rssi: rssi,
              seenCount: txTracker.repeaters[repeaterId]?.seenCount ?? 1,
            );

            if (isNew) {
              // Add new repeater to the list
              _lastTxPing!.heardRepeaters.add(repeater);
              debugLog('[PING] Real-time: Added new repeater $repeaterId (SNR: $snr) - total: ${_lastTxPing!.heardRepeaters.length}');
            } else {
              // Update existing repeater's SNR if better
              final idx = _lastTxPing!.heardRepeaters.indexWhere((r) => r.repeaterId == repeaterId);
              if (idx >= 0) {
                _lastTxPing!.heardRepeaters[idx] = repeater;
                debugLog('[PING] Real-time: Updated repeater $repeaterId (SNR: $snr)');
              }
            }

            // Notify for real-time UI updates
            debugLog('[PING] Calling onEchoReceived callback (callback=${onEchoReceived != null ? "SET" : "NULL"})');
            onEchoReceived?.call(_lastTxPing!, repeater, isNew);
            debugLog('[PING] onEchoReceived callback completed');
          } else {
            debugWarn('[PING] onEchoReceived: _lastTxPing is null!');
          }
        };

        txTracker.startTracking(
          payload: pingMessage,
          channelIdx: channelIndex,
          channelHash: channelHash,
          channelKey: channelKey,
          windowDuration: _rxListeningWindow,
        );
      } else {
        debugWarn('[PING] TX tracking not available - channel info missing or no tracker');
      }

      // Play transmit sound immediately before sending
      _audioService?.playTransmitSound();

      // Send ping via BLE - uses watts format like "1.0w"
      await _connection.sendPing(position.latitude, position.longitude, powerWatts);

      // Mark ping time and position
      _lastTxTime = DateTime.now();
      _gpsService.markPingPosition(position);

      // Start cooldown timer (7 seconds)
      _cooldownTimer.start(_autoPingCooldown.inMilliseconds);

      // Store TX context for queueing after RX window ends
      // TX entry is queued AFTER RX window so heard_repeats can be populated
      _pendingTxTimestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _pendingTxNoiseFloor = noiseFloor;

      // Start RX listening window (TX will be queued when window ends)
      _startRxListeningWindow(position);

      // Note: TX entry is queued after 6-second RX window in _endRxListeningWindow()
      // The 15-second batch timer in ApiQueueService handles regular uploads

      // Update stats
      _stats = _stats.copyWith(txCount: _stats.txCount + 1);
      onStatsUpdated?.call(_stats);

      debugLog('[PING] Ping sent successfully');
      return true;
    } catch (e) {
      debugLog('[PING] Ping operation failed: $e');
      _pingInProgress = false;
      return false;
    }
  }

  /// Start the 6-second RX listening window after TX
  /// Note: TxTracker handles the actual echo tracking, we just manage the countdown UI
  /// Reference: RX_LOG_LISTEN_WINDOW_MS = 6000 in wardrive.js
  void _startRxListeningWindow(Position txPosition) {
    // Cancel previous timer
    _rxWindowTimer?.cancel();

    // Start RX window countdown display (6 seconds - matches JS RX_LOG_LISTEN_WINDOW_MS)
    _rxWindowCountdown.start(_rxListeningWindow.inMilliseconds);

    // Set timer for window end
    _rxWindowTimer = Timer(_rxListeningWindow, () {
      _endRxListeningWindow(txPosition);
    });
  }

  /// End RX listening window and finalize results from TxTracker
  /// Reference: setTimeout callback at RX_LOG_LISTEN_WINDOW_MS in wardrive.js
  Future<void> _endRxListeningWindow(Position txPosition) async {
    debugLog('[PING] RX listening window ended');

    // Format heard_repeats string from TxTracker results
    // Format: "4e(12.25),77(12.25)" or "None" if no echoes
    String heardRepeats = 'None';

    final txTracker = _txTracker;
    if (txTracker != null && txTracker.repeaters.isNotEmpty) {
      debugLog('[PING] TxTracker collected ${txTracker.repeaters.length} repeater echoes');

      // Format heard_repeats: "repeaterId(snr),repeaterId(snr)"
      // Reference: buildHeardRepeatsString() in wardrive.js
      final repeaterStrings = <String>[];
      for (final entry in txTracker.repeaters.entries) {
        final repeaterId = entry.key;
        final echo = entry.value;
        // Format SNR with 2 decimal places
        repeaterStrings.add('$repeaterId(${echo.snr.toStringAsFixed(2)})');
        debugLog('[PING] Heard repeater: $repeaterId, SNR=${echo.snr}');
      }
      heardRepeats = repeaterStrings.join(',');

      // Update RX count stat for the echoes heard
      _stats = _stats.copyWith(rxCount: _stats.rxCount + txTracker.repeaters.length);
      onStatsUpdated?.call(_stats);
    } else {
      debugLog('[PING] No repeater echoes detected during listening window');
    }

    // Queue TX entry with heard_repeats AFTER RX window ends
    // Reference: enqueueTX() called after RX window in wardrive.js
    if (_pendingTxTimestamp != null) {
      _apiQueue.enqueueTx(
        latitude: txPosition.latitude,
        longitude: txPosition.longitude,
        heardRepeats: heardRepeats,
        timestamp: _pendingTxTimestamp!,
        noiseFloor: _pendingTxNoiseFloor,
      );
      debugLog('[PING] Queued TX entry with heard_repeats: $heardRepeats');

      // Clear pending TX context
      _pendingTxTimestamp = null;
      _pendingTxNoiseFloor = null;
    }

    // Unlock ping controls immediately (don't wait for API)
    // Reference: unlockPingControls("after RX listening window completion") in wardrive.js
    _pingInProgress = false;

    // After RX window ends, check if disable was requested during the window
    if (_pendingDisable) {
      debugLog('[PING] Executing pending disable after RX window');
      _pendingDisable = false;
      _autoPingEnabled = false;
      _passiveModeEnabled = false;
      _autoTimer?.cancel();
      _autoTimer = null;
      // Start cooldown immediately
      _cooldownTimer.start(_autoPingCooldown.inMilliseconds);
      debugLog('[PING] Pending disable complete, cooldown started');
      // Notify AppStateProvider to update its state and cleanup
      await onPendingDisableComplete?.call();
      return;  // Don't schedule next auto ping
    }

    // Schedule next auto ping if in Active Mode AND not in cooldown
    // The cooldown check prevents scheduling when user disabled auto mode during RX window
    // (the cooldown timer started when auto mode was disabled)
    // Reference: scheduleNextAutoPing() called after RX window in wardrive.js
    if (_autoPingEnabled && !_passiveModeEnabled && !isInCooldown()) {
      debugLog('[ACTIVE MODE] Scheduling next auto ping after RX window completion');
      _scheduleNextAutoPing();
    } else if (isInCooldown()) {
      debugLog('[PING] Skipping auto-ping scheduling - cooldown active');
    }

    // TxTracker automatically stops after window duration
  }

  /// Schedule next auto ping after interval
  /// Reference: scheduleNextAutoPing() in wardrive.js
  void _scheduleNextAutoPing() {
    if (!_autoPingEnabled || _passiveModeEnabled) {
      debugLog('[ACTIVE MODE] Not scheduling next auto ping - auto mode not running or Passive Mode');
      return;
    }

    // Clear any existing timer to prevent accumulation (CRITICAL: prevents duplicate timers)
    // Reference: clearTimeout(state.autoTimerId) in wardrive.js
    _autoTimer?.cancel();
    _autoTimer = null;

    debugLog('[ACTIVE MODE] Scheduling next auto ping in ${_autoPingIntervalMs}ms');

    // Start countdown display (with skip reason if applicable)
    // The AutoPingTimer in countdown_timer_service.dart handles the display
    onAutoPingScheduled?.call(_autoPingIntervalMs, _skipReason);

    // Schedule the next ping
    _autoTimer = Timer(Duration(milliseconds: _autoPingIntervalMs), () {
      debugLog('[ACTIVE MODE] Auto ping timer fired');

      // Double-check guards before sending ping
      if (!_autoPingEnabled || _passiveModeEnabled) {
        debugLog('[ACTIVE MODE] Auto mode no longer running, ignoring timer');
        return;
      }
      if (_pingInProgress) {
        debugLog('[ACTIVE MODE] Ping already in progress, ignoring timer');
        return;
      }

      // Clear skip reason before next attempt
      _skipReason = null;
      debugLog('[ACTIVE MODE] Sending auto ping');
      _sendAutoPing();
    });

    debugLog('[ACTIVE MODE] New timer scheduled');
  }

  /// Callback for auto ping scheduling (for UI countdown display)
  void Function(int intervalMs, String? skipReason)? onAutoPingScheduled;

  /// Helper to send auto ping with error handling (avoids catchError type issues)
  Future<void> _sendAutoPing() async {
    try {
      await sendTxPing(manual: false);
    } catch (e) {
      debugLog('[ACTIVE MODE] Auto ping error: $e');
    }
  }

  /// Helper to send initial auto ping with error handling
  Future<void> _sendInitialAutoPing() async {
    try {
      await sendTxPing(manual: false);
    } catch (e) {
      debugLog('[ACTIVE MODE] Initial auto ping error: $e');
      // Even on error, schedule next ping
      _scheduleNextAutoPing();
    }
  }

  /// Enable Active Mode (timer-based auto ping) or Passive Mode (listen-only)
  /// Reference: startAutoPing() in wardrive.js
  /// @param passiveMode - If true, only listens for RX (no TX pings) - this is Passive Mode
  Future<bool> enableAutoPing({bool passiveMode = false}) async {
    debugLog('[ACTIVE MODE] enableAutoPing called (passiveMode=$passiveMode)');

    if (_autoPingEnabled) {
      debugLog('[ACTIVE MODE] Auto mode already enabled');
      return false;
    }

    // Check if we're in cooldown (can't start during cooldown)
    // Reference: isInCooldown() check in startAutoPing() in wardrive.js
    if (!passiveMode && isInCooldown()) {
      final remainingSec = getRemainingCooldownSeconds();
      debugLog('[ACTIVE MODE] Start blocked by cooldown (${remainingSec}s remaining)');
      return false;
    }

    // Clean up any existing auto-ping timer
    _autoTimer?.cancel();
    _autoTimer = null;

    // Clear any previous skip reason
    _skipReason = null;

    _autoPingEnabled = true;
    _passiveModeEnabled = passiveMode;

    // Enable wake lock to keep screen on during auto mode
    // Reference: acquireWakeLock() in wardrive.js
    debugLog('[ACTIVE MODE] Acquiring wake lock for auto mode');
    await _wakelockService.enable();

    if (passiveMode) {
      // Passive Mode: send discovery requests instead of TX pings
      debugLog('[PASSIVE MODE] Passive Mode started - using discovery protocol');
      await _startDiscoveryMode();
    } else {
      // Active Mode: send first ping immediately, then schedule timer
      // Reference: sendPing(false) called immediately in startAutoPing() in wardrive.js
      debugLog('[ACTIVE MODE] Sending initial auto ping');
      _sendInitialAutoPing();
    }

    return true;
  }

  /// Disable auto-ping mode (Active Mode or Passive Mode)
  /// Reference: stopAutoPing() and stopRxAuto() in wardrive.js
  Future<bool> disableAutoPing() async {
    debugLog('[PING] disableAutoPing called');

    if (!_autoPingEnabled) {
      debugLog('[PING] Auto mode not enabled');
      return true;
    }

    // If ping is in progress (sending or listening), queue the disable
    // Let the RX window complete naturally, then disable + start cooldown
    if (_pingInProgress) {
      debugLog('[PING] Ping in progress, queuing disable for after RX window');
      _pendingDisable = true;
      return true;  // Return true to indicate disable was accepted (pending)
    }

    // Check cooldown before stopping (unless forced)
    // Reference: isInCooldown() check in stopAutoPing() in wardrive.js
    if (!_passiveModeEnabled && isInCooldown()) {
      final remainingSec = getRemainingCooldownSeconds();
      debugLog('[ACTIVE MODE] Stop blocked by cooldown (${remainingSec}s remaining)');
      return false;
    }

    // Clear auto timer
    _autoTimer?.cancel();
    _autoTimer = null;

    // Clear skip reason
    _skipReason = null;

    _autoPingEnabled = false;
    _passiveModeEnabled = false;

    // Disable wake lock when auto mode stops
    // Reference: releaseWakeLock() in wardrive.js
    await _wakelockService.disable();

    debugLog('[PING] Auto-ping disabled');
    return true;
  }

  /// Force disable auto-ping (ignores cooldown, used for disconnect)
  Future<void> forceDisableAutoPing() async {
    debugLog('[PING] Force disabling auto-ping');
    _pendingDisable = false;  // Clear any pending disable
    _autoTimer?.cancel();
    _autoTimer = null;
    _skipReason = null;
    _autoPingEnabled = false;
    _passiveModeEnabled = false;
    _stopDiscoveryMode();
    await _wakelockService.disable();
  }

  /// Reset statistics
  void resetStats() {
    _stats = const PingStats();
    onStatsUpdated?.call(_stats);
  }

  // ============================================
  // Discovery Mode (Passive Mode)
  // ============================================

  /// Start discovery mode - subscribes to control data and sends discovery requests
  Future<void> _startDiscoveryMode() async {
    debugLog('[DISC] Starting discovery mode');

    // Create and configure discovery tracker
    _discTracker = DiscTracker(shouldIgnoreRepeater: shouldIgnoreRepeater);
    _discTracker!.onNodeDiscovered = (node, isNew) {
      debugLog('[DISC] Node discovered: ${node.repeaterId} (${node.nodeTypeName}), isNew=$isNew');
    };
    _discTracker!.onWindowComplete = (nodes) {
      debugLog('[DISC] Window complete: ${nodes.length} nodes discovered');
      _handleDiscoveryWindowComplete(nodes);
    };

    // Subscribe to control data stream for discovery responses
    _controlDataSubscription = _connection.controlDataStream.listen((data) {
      if (_discTracker != null && _discTracker!.isListening) {
        _discTracker!.handlePacket(data.raw, data.snr, data.rssi);
      }
    });

    // Send first discovery request immediately
    await _sendDiscoveryRequest();
  }

  /// Stop discovery mode - cleans up tracker and subscription
  void _stopDiscoveryMode() {
    debugLog('[DISC] Stopping discovery mode');
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _controlDataSubscription?.cancel();
    _controlDataSubscription = null;
    _discTracker?.dispose();
    _discTracker = null;
    _discoveryStartPosition = null;
    _lastDiscoveryPosition = null;  // Reset so first discovery always sends on next start
  }

  /// Send a discovery request and start listening window
  Future<void> _sendDiscoveryRequest() async {
    if (!_autoPingEnabled || !_passiveModeEnabled) {
      debugLog('[DISC] Not in Passive Mode, skipping discovery request');
      return;
    }

    // Check GPS
    final position = _gpsService.lastPosition;
    if (position == null) {
      debugLog('[DISC] No GPS position, skipping discovery request');
      _scheduleNextDiscovery();
      return;
    }

    // Check minimum distance from last discovery (25m)
    if (_lastDiscoveryPosition != null) {
      final distance = Geolocator.distanceBetween(
        _lastDiscoveryPosition!.latitude,
        _lastDiscoveryPosition!.longitude,
        position.latitude,
        position.longitude,
      );
      if (distance < GpsService.minDistanceMeters) {
        debugLog('[DISC] Too close to last discovery (${distance.toStringAsFixed(1)}m < 25m), skipping');
        _skipReason = 'too close';
        _scheduleNextDiscovery();
        return;
      }
    }

    // Clear skip reason since we're proceeding
    _skipReason = null;

    // Note: Zone validation is now handled server-side by the API

    // Store position at discovery start
    _discoveryStartPosition = position;

    // Capture noise floor
    final noiseFloor = _connection.lastNoiseFloor;

    debugLog('[DISC] Sending discovery request at ${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}');

    try {
      // Play transmit sound immediately before sending
      _audioService?.playTransmitSound();

      // Send discovery request and get tag
      final tag = await _connection.sendDiscoveryRequest();

      // Start tracking with the tag
      _discTracker?.startTracking(
        tag: tag,
        windowDuration: _discoveryListeningWindow,
      );

      // Start discovery window countdown display (7 seconds)
      _discoveryWindowCountdown.start(_discoveryListeningWindow.inMilliseconds);

      // Store noise floor for later use
      _pendingTxNoiseFloor = noiseFloor;

      // Update last discovery position for 25m check
      _lastDiscoveryPosition = position;

    } catch (e) {
      debugError('[DISC] Failed to send discovery request: $e');
      _scheduleNextDiscovery();
    }
  }

  /// Handle discovery window completion
  void _handleDiscoveryWindowComplete(List<DiscoveredNode> nodes) {
    final position = _discoveryStartPosition;
    if (position == null) {
      debugLog('[DISC] No position recorded for discovery, skipping');
      _scheduleNextDiscovery();
      return;
    }

    debugLog('[DISC] Processing ${nodes.length} discovered nodes');

    // Create log entry
    final discoveredNodes = nodes.map((n) => DiscoveredNodeEntry(
      repeaterId: n.repeaterId,
      nodeType: n.nodeTypeName,
      localSnr: n.localSnr,
      localRssi: n.localRssi,
      remoteSnr: n.remoteSnr,
    )).toList();

    final logEntry = DiscLogEntry(
      timestamp: DateTime.now(),
      latitude: position.latitude,
      longitude: position.longitude,
      noiseFloor: _pendingTxNoiseFloor,
      discoveredNodes: discoveredNodes,
    );

    // Queue API payloads for each discovered node
    for (final node in nodes) {
      _apiQueue.enqueueDisc(
        latitude: position.latitude,
        longitude: position.longitude,
        repeaterId: node.repeaterId,
        nodeType: node.nodeTypeName,
        localSnr: node.localSnr,
        localRssi: node.localRssi,
        remoteSnr: node.remoteSnr,
        pubkeyFull: node.pubkeyFull,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        noiseFloor: _pendingTxNoiseFloor,
      );
    }

    // Update stats
    _stats = _stats.copyWith(discCount: _stats.discCount + 1);
    onStatsUpdated?.call(_stats);

    // Notify callback
    onDiscoveryComplete?.call(logEntry);

    debugLog('[DISC] Discovery window complete: ${nodes.length} nodes, queued ${nodes.length} API payloads');

    // Schedule next discovery
    _scheduleNextDiscovery();
  }

  /// Schedule next discovery request
  /// Uses fixed 30-second interval (repeaters only respond 4 times per 2 minutes)
  void _scheduleNextDiscovery() {
    if (!_autoPingEnabled || !_passiveModeEnabled) {
      debugLog('[DISC] Not in Passive Mode, not scheduling next discovery');
      return;
    }

    _discoveryTimer?.cancel();
    _discoveryTimer = Timer(_discoveryInterval, () {
      debugLog('[DISC] Discovery timer fired');
      if (_autoPingEnabled && _passiveModeEnabled) {
        _sendDiscoveryRequest();
      }
    });

    // Notify callback for countdown display (30 seconds hardcoded for discovery)
    onAutoPingScheduled?.call(_discoveryInterval.inMilliseconds, _skipReason);

    debugLog('[DISC] Next discovery scheduled in ${_discoveryInterval.inSeconds}s');
  }

  /// Stop any active TX echo tracking window
  /// Called when disabling auto mode to prevent late timer callbacks from
  /// triggering pings during cooldown (race condition fix)
  void stopEchoTracking() {
    debugLog('[PING] Stopping TX echo tracking and RX window timer');
    _rxWindowTimer?.cancel();
    _rxWindowTimer = null;
    _txTracker?.stopTracking();
    // Clear pending TX context since we're aborting the window
    _pendingTxTimestamp = null;
    _pendingTxNoiseFloor = null;
    // Unlock ping controls if the window was in progress
    _pingInProgress = false;
  }

  /// Dispose of resources
  void dispose() async {
    _rxWindowTimer?.cancel();
    _autoTimer?.cancel();
    _stopDiscoveryMode();
    await _wakelockService.dispose();
  }
}

/// Ping validation result
enum PingValidation {
  /// All conditions met, can ping
  valid,
  
  /// Not connected to device
  notConnected,
  
  /// External antenna not configured
  externalAntennaRequired,
  
  /// Power level not set (unknown device model)
  powerLevelRequired,
  
  /// No GPS lock
  noGpsLock,
  
  /// GPS data too old (> 60 seconds)
  gpsDataStale,
  
  /// GPS accuracy too low (> 100 meters)
  gpsInaccurate,
  
  /// Outside service area (zone validation handled by API)
  /// Reserved for future use with dynamic zone boundaries
  outsideGeofence,
  
  /// Too close to last ping (< 25m)
  tooCloseToLastPing,
  
  /// Cooldown period active (< 7s since last ping)
  cooldownActive,

  /// TX not allowed by API (zone at capacity)
  txNotAllowed,
}

extension PingValidationExtension on PingValidation {
  String get message {
    switch (this) {
      case PingValidation.valid:
        return 'Ready to ping';
      case PingValidation.notConnected:
        return 'Not connected to device';
      case PingValidation.externalAntennaRequired:
        return 'Select antenna option before pinging';
      case PingValidation.powerLevelRequired:
        return 'Select power level (unknown device)';
      case PingValidation.noGpsLock:
        return 'Waiting for GPS lock';
      case PingValidation.gpsDataStale:
        return 'GPS data too old (> 60 seconds)';
      case PingValidation.gpsInaccurate:
        return 'GPS accuracy too low (> 100 meters)';
      case PingValidation.outsideGeofence:
        return 'Outside service area';
      case PingValidation.tooCloseToLastPing:
        return 'Move 25m before next ping';
      case PingValidation.cooldownActive:
        return 'Wait 7 seconds between pings';
      case PingValidation.txNotAllowed:
        return 'Zone at TX capacity (Passive Only)';
    }
  }
}
