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
  /// Cooldown period between manual pings (15 seconds)
  static const Duration _manualPingCooldown = Duration(seconds: 15);

  final GpsService _gpsService;
  final MeshCoreConnection _connection;
  final ApiQueueService _apiQueue;
  final WakelockService _wakelockService;
  final CooldownTimer _cooldownTimer;
  final ManualPingCooldownTimer _manualPingCooldownTimer;
  final RxWindowTimer _rxWindowCountdown;
  final DiscoveryWindowTimer _discoveryWindowCountdown;
  final String _deviceId;
  final TxTracker? _txTracker;
  final AudioService? _audioService;
  final bool Function(String repeaterId)? shouldIgnoreRepeater;

  /// When true, skip RSSI carpeater check in DiscTracker (user setting)
  bool disableRssiFilter;

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
  bool _hybridModeEnabled = false;
  bool _nextPingIsDiscovery = true;  // Start hybrid with discovery
  Timer? _autoTimer;

  // Pending disable flag - when true, disable will execute after RX window ends
  bool _pendingDisable = false;

  // Auto-ping interval in milliseconds (default 30s, options: 15s, 30s, 60s)
  // Reference: getSelectedIntervalMs() in wardrive.js
  int _autoPingIntervalMs = 30000;

  // Skip reason for display during auto mode countdown
  String? _skipReason;

  // Discovery tracking
  DiscLogEntry? _lastDiscPing;
  DiscTracker? _discTracker;
  StreamSubscription? _controlDataSubscription;
  Timer? _discoveryTimer;
  Position? _discoveryStartPosition;
  Position? _lastDiscoveryPosition;  // Track last discovery position for 25m check

  // Validation callbacks
  bool Function()? checkExternalAntennaConfigured;
  bool Function()? checkPowerLevelConfigured;

  /// Callback to get the external antenna value for API payloads
  bool Function()? getExternalAntenna;

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
  /// Fires immediately when disc ping is created (like onTxPing)
  void Function(DiscLogEntry)? onDiscPing;

  /// Called in real-time when each node is discovered during tracking window
  /// Parameters: (DiscLogEntry discPing, DiscoveredNodeEntry nodeEntry, bool isNew)
  void Function(DiscLogEntry, DiscoveredNodeEntry, bool isNew)? onDiscNodeDiscovered;

  /// Callback when TX window ends (for noise floor graph)
  /// Parameters: (bool success) - true if any repeaters heard, false if none
  void Function(bool success)? onTxWindowComplete;

  /// Callback when discovery window ends (for noise floor graph)
  /// Parameters: (bool success) - true if any nodes discovered, false if none
  void Function(bool success)? onDiscoveryWindowComplete;

  /// Callback when pingInProgress changes (for immediate UI refresh)
  void Function()? onPingProgressChanged;

  /// Callback when pending disable completes after RX window
  /// AppStateProvider uses this to update its state and cleanup
  Future<void> Function()? onPendingDisableComplete;

  /// Callback for discovery carpeater drops (for quiet error logging)
  /// Wired to DiscTracker.onCarpeaterDrop when discovery mode starts
  void Function(String repeaterId, String reason)? onDiscCarpeaterDrop;

  /// Last TX ping sent (for updating with heard repeaters)
  TxPing? _lastTxPing;

  PingService({
    required GpsService gpsService,
    required MeshCoreConnection connection,
    required ApiQueueService apiQueue,
    required WakelockService wakelockService,
    required CooldownTimer cooldownTimer,
    required ManualPingCooldownTimer manualPingCooldownTimer,
    required RxWindowTimer rxWindowTimer,
    required DiscoveryWindowTimer discoveryWindowTimer,
    required String deviceId,
    TxTracker? txTracker,
    AudioService? audioService,
    this.shouldIgnoreRepeater,
    this.disableRssiFilter = false,
  })  : _gpsService = gpsService,
        _connection = connection,
        _apiQueue = apiQueue,
        _wakelockService = wakelockService,
        _cooldownTimer = cooldownTimer,
        _manualPingCooldownTimer = manualPingCooldownTimer,
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

  /// Check if Hybrid Mode is active (alternates discovery + TX)
  bool get isHybridMode => _hybridModeEnabled;

  /// Check if discovery tracker is currently listening (for Passive Mode UI)
  bool get isDiscoveryListening => _discTracker?.isListening ?? false;

  /// Get current auto-ping interval in milliseconds
  int get autoPingIntervalMs => _autoPingIntervalMs;

  /// Check if a disable is pending (waiting for RX window to complete)
  bool get pendingDisable => _pendingDisable;

  /// Get current skip reason (for auto mode display)
  String? get skipReason => _skipReason;

  /// Get the manual ping cooldown timer (for UI display)
  ManualPingCooldownTimer get manualPingCooldownTimer => _manualPingCooldownTimer;

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
    if (checkTxAllowed?.call() == false) {
      return PingValidation.txNotAllowed;
    }

    // Check external antenna configuration
    if (checkExternalAntennaConfigured?.call() == false) {
      return PingValidation.externalAntennaRequired;
    }

    // Check power level configuration (for unknown devices)
    if (checkPowerLevelConfigured?.call() == false) {
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
    final lastTx = _lastTxTime;
    if (lastTx != null) {
      final elapsed = DateTime.now().difference(lastTx);
      if (elapsed < _autoPingCooldown) {
        return PingValidation.cooldownActive;
      }
    }

    return PingValidation.valid;
  }

  /// Check if we can send a manual TX ping now
  /// Same as canPing() but WITHOUT the distance check and uses 15-second manual cooldown
  PingValidation canPingManual() {
    // Check connection
    if (_connection.currentStep != ConnectionStep.connected) {
      return PingValidation.notConnected;
    }

    // Check if TX is allowed by API (zone capacity)
    if (checkTxAllowed?.call() == false) {
      return PingValidation.txNotAllowed;
    }

    // Check external antenna configuration
    if (checkExternalAntennaConfigured?.call() == false) {
      return PingValidation.externalAntennaRequired;
    }

    // Check power level configuration (for unknown devices)
    if (checkPowerLevelConfigured?.call() == false) {
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

    // Check GPS accuracy (< 100m)
    if (!_gpsService.isAccuracyAcceptableForPing(position)) {
      return PingValidation.gpsInaccurate;
    }

    // NO distance check - removed for manual pings

    // 15-second manual cooldown check - use remainingMs for real-time accuracy
    // (isRunning depends on 500ms timer callback, remainingMs checks actual time)
    if (_manualPingCooldownTimer.remainingMs > 0) {
      return PingValidation.manualCooldownActive;
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
    if (checkTxAllowed?.call() == false) {
      return PingValidation.txNotAllowed;
    }

    // Check external antenna configuration
    if (checkExternalAntennaConfigured?.call() == false) {
      return PingValidation.externalAntennaRequired;
    }

    // Check power level configuration (for unknown devices)
    if (checkPowerLevelConfigured?.call() == false) {
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
    final lastTx = _lastTxTime;
    if (lastTx != null) {
      final elapsed = DateTime.now().difference(lastTx);
      if (elapsed < _autoPingCooldown) {
        return PingValidation.cooldownActive;
      }
    }

    return PingValidation.valid;
  }

  /// Check if currently in cooldown period
  /// Reference: isInCooldown() in wardrive.js
  bool isInCooldown() {
    final lastTx = _lastTxTime;
    if (lastTx == null) return false;
    final elapsed = DateTime.now().difference(lastTx);
    return elapsed < _autoPingCooldown;
  }

  /// Get remaining cooldown seconds
  int getRemainingCooldownSeconds() {
    final lastTx = _lastTxTime;
    if (lastTx == null) return 0;
    final elapsed = DateTime.now().difference(lastTx);
    final remaining = _autoPingCooldown - elapsed;
    return remaining.inSeconds.clamp(0, _autoPingCooldown.inSeconds);
  }

  /// Check if currently in manual ping cooldown period
  bool isInManualCooldown() {
    return _manualPingCooldownTimer.remainingMs > 0;
  }

  /// Get remaining manual cooldown seconds
  int getRemainingManualCooldownSeconds() {
    return _manualPingCooldownTimer.remainingSec;
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
      // Use different validation and cooldown for manual vs auto pings
      if (manual) {
        // Manual ping: 15-second cooldown, no distance check
        if (isInManualCooldown()) {
          final remainingSec = getRemainingManualCooldownSeconds();
          debugLog('[PING] Manual ping blocked by cooldown (${remainingSec}s remaining)');
          _pingInProgress = false;
          return false;
        }

        final validation = canPingManual();
        if (validation != PingValidation.valid) {
          debugLog('[PING] Manual ping blocked by validation: $validation');
          _pingInProgress = false;
          return false;
        }
      } else {
        // Auto ping: 7-second cooldown, 25m distance check
        // This fixes a race condition where disabling Active Mode during cooldown
        // could still trigger an auto-ping from a late RX window timer callback
        if (isInCooldown()) {
          final remainingSec = getRemainingCooldownSeconds();
          debugLog('[PING] Auto ping blocked by cooldown (${remainingSec}s remaining)');
          _pingInProgress = false;
          return false;
        }

        final validation = canPing();
        if (validation != PingValidation.valid) {
          // For auto mode, schedule next attempt if distance check failed
          if (_autoPingEnabled && !_passiveModeEnabled) {
            if (validation == PingValidation.tooCloseToLastPing) {
              _skipReason = 'too close';
              debugLog('[PING] Auto ping blocked: too close to last ping, scheduling next');
            }
            _scheduleNextAutoPing();
          }
          _pingInProgress = false;
          return false;
        }
      }

      // Clear skip reason on successful validation
      _skipReason = null;

      final position = _gpsService.lastPosition;
      if (position == null) {
        debugError('[PING] No GPS position available');
        _pingInProgress = false;
        return false;
      }
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
          final txPing = _lastTxPing;
          if (txPing != null) {
            final repeater = HeardRepeater(
              repeaterId: repeaterId,
              snr: snr,
              rssi: rssi,
              seenCount: txTracker.repeaters[repeaterId]?.seenCount ?? 1,
            );

            if (isNew) {
              // Add new repeater to the list
              txPing.heardRepeaters.add(repeater);
              debugLog('[PING] Real-time: Added new repeater $repeaterId (SNR: $snr) - total: ${txPing.heardRepeaters.length}');
            } else {
              // Update existing repeater's SNR if better
              final idx = txPing.heardRepeaters.indexWhere((r) => r.repeaterId == repeaterId);
              if (idx >= 0) {
                txPing.heardRepeaters[idx] = repeater;
                debugLog('[PING] Real-time: Updated repeater $repeaterId (SNR: $snr)');
              }
            }

            // Notify for real-time UI updates
            debugLog('[PING] Calling onEchoReceived callback (callback=${onEchoReceived != null ? "SET" : "NULL"})');
            onEchoReceived?.call(txPing, repeater, isNew);
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

      // Start appropriate cooldown timer
      if (manual) {
        // Manual ping: 15-second cooldown, no distance check
        _manualPingCooldownTimer.start(_manualPingCooldown.inMilliseconds);
      } else {
        // Auto ping: 7-second cooldown
        _cooldownTimer.start(_autoPingCooldown.inMilliseconds);
      }

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
    _rxWindowCountdown.stop();

    // Format heard_repeats string from TxTracker results
    // Format: "4e(12.25),77(12.25)" or "None" if no echoes
    String heardRepeats = 'None';

    final txTracker = _txTracker;
    final txSuccess = txTracker != null && txTracker.repeaters.isNotEmpty;
    if (txSuccess) {
      debugLog('[PING] TxTracker collected ${txTracker.repeaters.length} repeater echoes');

      // Format heard_repeats: "repeaterId(snr),repeaterId(snr)"
      // Reference: buildHeardRepeatsString() in wardrive.js
      final repeaterStrings = <String>[];
      for (final entry in txTracker.repeaters.entries) {
        final repeaterId = entry.key;
        final echo = entry.value;
        // Format SNR with 2 decimal places, or "null" for CARpeater pass-through
        repeaterStrings.add(echo.snr != null
            ? '$repeaterId(${echo.snr!.toStringAsFixed(2)})'
            : '$repeaterId(null)');
        debugLog('[PING] Heard repeater: $repeaterId, SNR=${echo.snr}');
      }
      heardRepeats = repeaterStrings.join(',');

      // Update RX count stat for the echoes heard
      _stats = _stats.copyWith(rxCount: _stats.rxCount + txTracker.repeaters.length);
      onStatsUpdated?.call(_stats);
    } else {
      debugLog('[PING] No repeater echoes detected during listening window');
    }

    // Notify about TX window completion for noise floor graph
    onTxWindowComplete?.call(txSuccess);

    // Queue TX entry with heard_repeats AFTER RX window ends
    // Reference: enqueueTX() called after RX window in wardrive.js
    final txTimestamp = _pendingTxTimestamp;
    if (txTimestamp != null) {
      _apiQueue.enqueueTx(
        latitude: txPosition.latitude,
        longitude: txPosition.longitude,
        heardRepeats: heardRepeats,
        timestamp: txTimestamp,
        externalAntenna: getExternalAntenna?.call() ?? false,
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
      final wasHybrid = _hybridModeEnabled;
      _autoPingEnabled = false;
      _passiveModeEnabled = false;
      _hybridModeEnabled = false;
      _nextPingIsDiscovery = true;
      _autoTimer?.cancel();
      _autoTimer = null;
      // Clean up discovery infrastructure if hybrid was enabled
      if (wasHybrid) {
        _stopDiscoveryMode();
      }
      // Start cooldown immediately
      _cooldownTimer.start(_autoPingCooldown.inMilliseconds);
      debugLog('[PING] Pending disable complete, cooldown started');
      // Notify AppStateProvider to update its state and cleanup
      await onPendingDisableComplete?.call();
      return;  // Don't schedule next auto ping
    }

    // Schedule next ping based on mode
    // The cooldown check prevents scheduling when user disabled auto mode during RX window
    // (the cooldown timer started when auto mode was disabled)
    // Reference: scheduleNextAutoPing() called after RX window in wardrive.js
    if (_autoPingEnabled && !isInCooldown()) {
      if (_hybridModeEnabled) {
        debugLog('[HYBRID] Scheduling next hybrid ping after RX window completion');
        _scheduleNextHybridPing();
      } else if (!_passiveModeEnabled) {
        debugLog('[ACTIVE MODE] Scheduling next auto ping after RX window completion');
        _scheduleNextAutoPing();
      }
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

  /// Enable Active Mode (timer-based auto ping), Passive Mode (listen-only), or Hybrid Mode
  /// Reference: startAutoPing() in wardrive.js
  /// @param passiveMode - If true, only listens for RX (no TX pings) - this is Passive Mode
  /// @param hybridMode - If true, alternates discovery + TX pings each interval
  Future<bool> enableAutoPing({bool passiveMode = false, bool hybridMode = false}) async {
    debugLog('[AUTO] enableAutoPing called (passiveMode=$passiveMode, hybridMode=$hybridMode)');

    if (_autoPingEnabled) {
      debugLog('[AUTO] Auto mode already enabled');
      return false;
    }

    // Check if we're in cooldown (can't start during cooldown)
    // Hybrid and Active modes are blocked by cooldown, Passive is not
    // Reference: isInCooldown() check in startAutoPing() in wardrive.js
    if (!passiveMode && isInCooldown()) {
      final remainingSec = getRemainingCooldownSeconds();
      debugLog('[AUTO] Start blocked by cooldown (${remainingSec}s remaining)');
      return false;
    }

    // Clean up any existing auto-ping timer
    _autoTimer?.cancel();
    _autoTimer = null;

    // Clear any previous skip reason
    _skipReason = null;

    _autoPingEnabled = true;
    _passiveModeEnabled = passiveMode;
    _hybridModeEnabled = hybridMode;
    _nextPingIsDiscovery = true;  // Always start hybrid with discovery

    // Enable wake lock to keep screen on during auto mode
    // Reference: acquireWakeLock() in wardrive.js
    debugLog('[AUTO] Acquiring wake lock for auto mode');
    await _wakelockService.enable();

    if (hybridMode) {
      // Hybrid Mode: set up discovery infrastructure, then start with discovery
      debugLog('[HYBRID] Hybrid Mode started - alternating discovery + TX pings');
      await _startDiscoveryMode();
      // First ping was discovery, so next should be TX
      _nextPingIsDiscovery = false;
    } else if (passiveMode) {
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

    // Clean up discovery infrastructure if passive or hybrid was enabled
    if (_passiveModeEnabled || _hybridModeEnabled) {
      _stopDiscoveryMode();
    }

    _autoPingEnabled = false;
    _passiveModeEnabled = false;
    _hybridModeEnabled = false;
    _nextPingIsDiscovery = true;

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
    _hybridModeEnabled = false;
    _nextPingIsDiscovery = true;
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
    final tracker = DiscTracker(
      shouldIgnoreRepeater: shouldIgnoreRepeater,
      disableRssiFilter: disableRssiFilter,
    );
    _discTracker = tracker;
    tracker.onCarpeaterDrop = onDiscCarpeaterDrop;
    tracker.onNodeDiscovered = (node, isNew) {
      debugLog('[DISC] Node discovered: ${node.repeaterId} (${node.nodeTypeName}), isNew=$isNew');
      final discPing = _lastDiscPing;
      if (discPing != null) {
        final nodeEntry = DiscoveredNodeEntry(
          repeaterId: node.repeaterId,
          nodeType: node.nodeTypeName,
          localSnr: node.localSnr,
          localRssi: node.localRssi,
          remoteSnr: node.remoteSnr,
          pubkeyHex: node.pubkeyFull,
        );
        if (isNew) {
          discPing.discoveredNodes.add(nodeEntry);
        } else {
          final idx = discPing.discoveredNodes.indexWhere((n) => n.repeaterId == node.repeaterId);
          if (idx >= 0) discPing.discoveredNodes[idx] = nodeEntry;
        }
        onDiscNodeDiscovered?.call(discPing, nodeEntry, isNew);
      }
    };
    tracker.onWindowComplete = (nodes) {
      debugLog('[DISC] Window complete: ${nodes.length} nodes discovered');
      _handleDiscoveryWindowComplete(nodes);
    };

    // Subscribe to control data stream for discovery responses
    _controlDataSubscription = _connection.controlDataStream.listen((data) {
      final dt = _discTracker;
      if (dt != null && dt.isListening) {
        dt.handlePacket(data.raw, data.snr, data.rssi);
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
    _lastDiscPing = null;
  }

  /// Send a discovery request and start listening window
  Future<void> _sendDiscoveryRequest() async {
    if (!_autoPingEnabled || (!_passiveModeEnabled && !_hybridModeEnabled)) {
      debugLog('[DISC] Not in Passive/Hybrid Mode, skipping discovery request');
      return;
    }

    // Check GPS
    final position = _gpsService.lastPosition;
    if (position == null) {
      debugLog('[DISC] No GPS position, skipping discovery request');
      _pingInProgress = false;
      _scheduleNextDiscovery();
      return;
    }

    // Check minimum distance from last discovery (25m)
    final lastDiscPos = _lastDiscoveryPosition;
    if (lastDiscPos != null) {
      final distance = Geolocator.distanceBetween(
        lastDiscPos.latitude,
        lastDiscPos.longitude,
        position.latitude,
        position.longitude,
      );
      if (distance < GpsService.minDistanceMeters) {
        debugLog('[DISC] Too close to last discovery (${distance.toStringAsFixed(1)}m < 25m), skipping');
        _skipReason = 'too close';
        _pingInProgress = false;
        _scheduleNextDiscovery();
        return;
      }
    }

    // Clear skip reason since we're proceeding
    _skipReason = null;

    // Signal "Sending..." to UI (matches TX flow which sets flag before setup work)
    _pingInProgress = true;
    onPingProgressChanged?.call();

    // Note: Zone validation is now handled server-side by the API

    // Store position at discovery start
    _discoveryStartPosition = position;

    // Capture noise floor
    final noiseFloor = _connection.lastNoiseFloor;
    _pendingTxNoiseFloor = noiseFloor;

    // Create disc ping entry IMMEDIATELY (mirrors TX flow)
    final discPing = DiscLogEntry(
      timestamp: DateTime.now(),
      latitude: position.latitude,
      longitude: position.longitude,
      noiseFloor: noiseFloor,
      discoveredNodes: [],
    );
    _lastDiscPing = discPing;
    debugLog('[DISC] Created DiscLogEntry, ready for node tracking');
    onDiscPing?.call(discPing);

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

      // Clear pingInProgress now that discovery window is active
      _pingInProgress = false;

      // Update last discovery position for 25m check
      _lastDiscoveryPosition = position;

    } catch (e) {
      _pingInProgress = false;
      debugError('[DISC] Failed to send discovery request: $e');
      _scheduleNextDiscovery();
    }
  }

  /// Handle discovery window completion
  void _handleDiscoveryWindowComplete(List<DiscoveredNode> nodes) {
    _discoveryWindowCountdown.stop();
    final position = _discoveryStartPosition;
    if (position == null) {
      debugLog('[DISC] No position recorded for discovery, skipping');
      // Notify about discovery failure for noise floor graph
      onDiscoveryWindowComplete?.call(false);
      _lastDiscPing = null;
      _scheduleNextDiscovery();
      return;
    }

    // Use _lastDiscPing which was already created and added to log in _sendDiscoveryRequest
    final discoverySuccess = _lastDiscPing?.discoveredNodes.isNotEmpty ?? false;

    if (discoverySuccess) {
      debugLog('[DISC] Processing ${nodes.length} discovered nodes');

      // Queue API payloads for each discovered node (uses nodes for pubkeyFull)
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
          externalAntenna: getExternalAntenna?.call() ?? false,
          noiseFloor: _pendingTxNoiseFloor,
        );
      }

      // Update stats
      _stats = _stats.copyWith(discCount: _stats.discCount + 1);
      onStatsUpdated?.call(_stats);
    } else {
      debugLog('[DISC] No nodes discovered');
    }

    // Entry already added to log via onDiscPing - no need to fire onDiscoveryComplete

    // Fire noise floor callback (entry already in _discLogEntries via onDiscPing)
    onDiscoveryWindowComplete?.call(discoverySuccess);

    debugLog('[DISC] Discovery window complete: ${nodes.length} nodes${discoverySuccess ? ', queued ${nodes.length} API payloads' : ''}');

    _lastDiscPing = null;
    _scheduleNextDiscovery();
  }

  /// Schedule next discovery request
  /// Uses fixed 30-second interval (repeaters only respond 4 times per 2 minutes)
  void _scheduleNextDiscovery() {
    // In hybrid mode, route to hybrid scheduler instead
    if (_hybridModeEnabled) {
      _scheduleNextHybridPing();
      return;
    }

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

  /// Schedule next hybrid ping (alternates discovery ↔ TX)
  /// Uses user-configured interval for both ping types
  void _scheduleNextHybridPing() {
    if (!_autoPingEnabled || !_hybridModeEnabled) return;

    _autoTimer?.cancel();
    _autoTimer = null;

    // Subtract listening window so interval is measured start-to-start
    // At 15s: wait = 15000 - 7000 = 8000ms. Clamp to min 1s.
    final listenMs = _rxListeningWindow.inMilliseconds; // 7000
    final waitMs = (_autoPingIntervalMs - listenMs).clamp(1000, _autoPingIntervalMs);

    final isNextDisc = _nextPingIsDiscovery;
    debugLog('[HYBRID] Scheduling next ${isNextDisc ? "discovery" : "TX"} ping in ${waitMs}ms');

    onAutoPingScheduled?.call(waitMs, _skipReason);

    _autoTimer = Timer(Duration(milliseconds: waitMs), () {
      if (!_autoPingEnabled || !_hybridModeEnabled) return;
      if (_pingInProgress) {
        debugLog('[HYBRID] Ping already in progress, skipping');
        return;
      }
      _skipReason = null;

      if (_nextPingIsDiscovery) {
        debugLog('[HYBRID] Sending discovery ping');
        _sendDiscoveryRequest();
      } else {
        debugLog('[HYBRID] Sending TX ping');
        _sendAutoPing();
      }
      _nextPingIsDiscovery = !_nextPingIsDiscovery;
    });
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
  void dispose() {
    _rxWindowTimer?.cancel();
    _rxWindowTimer = null;
    _autoTimer?.cancel();
    _autoTimer = null;
    _stopDiscoveryMode();
    _wakelockService.dispose();
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

  /// Manual ping cooldown period active (< 15s since last manual ping)
  manualCooldownActive,

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
      case PingValidation.manualCooldownActive:
        return 'Wait 15 seconds between manual pings';
      case PingValidation.txNotAllowed:
        return 'Zone at TX capacity (Passive Only)';
    }
  }
}
