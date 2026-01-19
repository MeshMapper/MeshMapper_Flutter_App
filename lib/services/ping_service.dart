import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../models/connection_state.dart';
import '../models/ping_data.dart';
import '../utils/debug_logger_io.dart';
import 'api_queue_service.dart';
import 'countdown_timer_service.dart';
import 'gps_service.dart';
import 'meshcore/connection.dart';
import 'meshcore/tx_tracker.dart';
import 'wakelock_service.dart';

/// Ping service for TX/RX ping orchestration
/// Ported from wardrive.js ping logic
///
/// TX Flow:
/// 1. Validate GPS lock, geofence (150km from Ottawa), 25m min distance
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
class PingService {
  /// RX listening window duration (6 seconds - matches JS RX_LOG_LISTEN_WINDOW_MS = 6000)
  static const Duration _rxListeningWindow = Duration(seconds: 6);
  /// Cooldown period between pings (7 seconds - matches JS COOLDOWN_MS = 7000)
  static const Duration _autoPingCooldown = Duration(seconds: 7);

  final GpsService _gpsService;
  final MeshCoreConnection _connection;
  final ApiQueueService _apiQueue;
  final WakelockService _wakelockService;
  final CooldownTimer _cooldownTimer;
  final RxWindowTimer _rxWindowCountdown;
  final String _deviceId;
  final TxTracker? _txTracker;

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
  bool _rxOnlyMode = false;
  Timer? _autoTimer;

  // Auto-ping interval in milliseconds (default 30s, options: 15s, 30s, 60s)
  // Reference: getSelectedIntervalMs() in wardrive.js
  int _autoPingIntervalMs = 30000;

  // Skip reason for display during auto mode countdown
  String? _skipReason;

  // Validation callbacks
  bool Function()? checkExternalAntennaConfigured;
  bool Function()? checkPowerLevelConfigured;

  /// Callback for ping events
  void Function(TxPing)? onTxPing;
  void Function(RxPing)? onRxPing;
  void Function(PingStats)? onStatsUpdated;
  /// Called in real-time when each echo is received during tracking window
  /// Parameters: (TxPing txPing, HeardRepeater repeater, bool isNew)
  void Function(TxPing, HeardRepeater, bool isNew)? onEchoReceived;

  /// Last TX ping sent (for updating with heard repeaters)
  TxPing? _lastTxPing;

  PingService({
    required GpsService gpsService,
    required MeshCoreConnection connection,
    required ApiQueueService apiQueue,
    required WakelockService wakelockService,
    required CooldownTimer cooldownTimer,
    required RxWindowTimer rxWindowTimer,
    required String deviceId,
    TxTracker? txTracker,
  })  : _gpsService = gpsService,
        _connection = connection,
        _apiQueue = apiQueue,
        _wakelockService = wakelockService,
        _cooldownTimer = cooldownTimer,
        _rxWindowCountdown = rxWindowTimer,
        _deviceId = deviceId,
        _txTracker = txTracker;

  /// Get current ping statistics
  PingStats get stats => _stats;

  /// Check if auto-ping is enabled
  bool get autoPingEnabled => _autoPingEnabled;

  /// Check if a ping is currently in progress
  bool get pingInProgress => _pingInProgress;

  /// Check if RX-only mode is active
  bool get rxOnlyMode => _rxOnlyMode;

  /// Get current auto-ping interval in milliseconds
  int get autoPingIntervalMs => _autoPingIntervalMs;

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
      if (_gpsService.status == GpsStatus.outsideGeofence) {
        return PingValidation.outsideGeofence;
      }
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

    // Check geofence
    if (!_gpsService.isWithinGeofence(position)) {
      return PingValidation.outsideGeofence;
    }

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
      if (_gpsService.status == GpsStatus.outsideGeofence) {
        return PingValidation.outsideGeofence;
      }
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

    // Check geofence
    if (!_gpsService.isWithinGeofence(position)) {
      return PingValidation.outsideGeofence;
    }

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
      // Check cooldown only for manual pings
      // Reference: manual && isInCooldown() check in wardrive.js
      if (manual && isInCooldown()) {
        final remainingSec = getRemainingCooldownSeconds();
        debugLog('[PING] Manual ping blocked by cooldown (${remainingSec}s remaining)');
        _pingInProgress = false;
        return false;
      }

      final validation = canPing();
      if (validation != PingValidation.valid) {
        // For auto mode, schedule next attempt if distance check failed
        if (!manual && _autoPingEnabled && !_rxOnlyMode) {
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
        _txTracker!.onEchoReceived = (repeaterId, snr, rssi, isNew) {
          debugLog('[PING] onEchoReceived callback fired: $repeaterId, SNR=$snr, RSSI=$rssi, isNew=$isNew');
          if (_lastTxPing != null) {
            final repeater = HeardRepeater(
              repeaterId: repeaterId,
              snr: snr,
              rssi: rssi,
              seenCount: _txTracker!.repeaters[repeaterId]?.seenCount ?? 1,
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

        _txTracker!.startTracking(
          payload: pingMessage,
          channelIdx: channelIndex,
          channelHash: channelHash,
          channelKey: channelKey,
          windowDuration: _rxListeningWindow,
        );
      } else {
        debugWarn('[PING] TX tracking not available - channel info missing or no tracker');
      }

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
  void _endRxListeningWindow(Position txPosition) {
    debugLog('[PING] RX listening window ended');

    // Format heard_repeats string from TxTracker results
    // Format: "4e(12.25),77(12.25)" or "None" if no echoes
    String heardRepeats = 'None';

    if (_txTracker != null && _txTracker!.repeaters.isNotEmpty) {
      debugLog('[PING] TxTracker collected ${_txTracker!.repeaters.length} repeater echoes');

      // Format heard_repeats: "repeaterId(snr),repeaterId(snr)"
      // Reference: buildHeardRepeatsString() in wardrive.js
      final repeaterStrings = <String>[];
      for (final entry in _txTracker!.repeaters.entries) {
        final repeaterId = entry.key;
        final echo = entry.value;
        // Format SNR with 2 decimal places
        repeaterStrings.add('$repeaterId(${echo.snr.toStringAsFixed(2)})');
        debugLog('[PING] Heard repeater: $repeaterId, SNR=${echo.snr}');
      }
      heardRepeats = repeaterStrings.join(',');

      // Update RX count stat for the echoes heard
      _stats = _stats.copyWith(rxCount: _stats.rxCount + _txTracker!.repeaters.length);
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

    // Schedule next auto ping if in TX/RX Auto mode
    // Reference: scheduleNextAutoPing() called after RX window in wardrive.js
    if (_autoPingEnabled && !_rxOnlyMode) {
      debugLog('[TX/RX AUTO] Scheduling next auto ping after RX window completion');
      _scheduleNextAutoPing();
    }

    // TxTracker automatically stops after window duration
  }

  /// Schedule next auto ping after interval
  /// Reference: scheduleNextAutoPing() in wardrive.js
  void _scheduleNextAutoPing() {
    if (!_autoPingEnabled || _rxOnlyMode) {
      debugLog('[TX/RX AUTO] Not scheduling next auto ping - auto mode not running or RX-only');
      return;
    }

    // Clear any existing timer to prevent accumulation (CRITICAL: prevents duplicate timers)
    // Reference: clearTimeout(state.autoTimerId) in wardrive.js
    _autoTimer?.cancel();
    _autoTimer = null;

    debugLog('[TX/RX AUTO] Scheduling next auto ping in ${_autoPingIntervalMs}ms');

    // Start countdown display (with skip reason if applicable)
    // The AutoPingTimer in countdown_timer_service.dart handles the display
    onAutoPingScheduled?.call(_autoPingIntervalMs, _skipReason);

    // Schedule the next ping
    _autoTimer = Timer(Duration(milliseconds: _autoPingIntervalMs), () {
      debugLog('[TX/RX AUTO] Auto ping timer fired');

      // Double-check guards before sending ping
      if (!_autoPingEnabled || _rxOnlyMode) {
        debugLog('[TX/RX AUTO] Auto mode no longer running, ignoring timer');
        return;
      }
      if (_pingInProgress) {
        debugLog('[TX/RX AUTO] Ping already in progress, ignoring timer');
        return;
      }

      // Clear skip reason before next attempt
      _skipReason = null;
      debugLog('[TX/RX AUTO] Sending auto ping');
      _sendAutoPing();
    });

    debugLog('[TX/RX AUTO] New timer scheduled');
  }

  /// Callback for auto ping scheduling (for UI countdown display)
  void Function(int intervalMs, String? skipReason)? onAutoPingScheduled;

  /// Helper to send auto ping with error handling (avoids catchError type issues)
  Future<void> _sendAutoPing() async {
    try {
      await sendTxPing(manual: false);
    } catch (e) {
      debugLog('[TX/RX AUTO] Auto ping error: $e');
    }
  }

  /// Helper to send initial auto ping with error handling
  Future<void> _sendInitialAutoPing() async {
    try {
      await sendTxPing(manual: false);
    } catch (e) {
      debugLog('[TX/RX AUTO] Initial auto ping error: $e');
      // Even on error, schedule next ping
      _scheduleNextAutoPing();
    }
  }

  /// Enable TX/RX Auto mode (timer-based auto ping)
  /// Reference: startAutoPing() in wardrive.js
  /// @param rxOnly - If true, only listens for RX (no TX pings) - this is RX Auto mode
  Future<bool> enableAutoPing({bool rxOnly = false}) async {
    debugLog('[TX/RX AUTO] enableAutoPing called (rxOnly=$rxOnly)');

    if (_autoPingEnabled) {
      debugLog('[TX/RX AUTO] Auto mode already enabled');
      return false;
    }

    // Check if we're in cooldown (can't start during cooldown)
    // Reference: isInCooldown() check in startAutoPing() in wardrive.js
    if (!rxOnly && isInCooldown()) {
      final remainingSec = getRemainingCooldownSeconds();
      debugLog('[TX/RX AUTO] Auto ping start blocked by cooldown (${remainingSec}s remaining)');
      return false;
    }

    // Clean up any existing auto-ping timer
    _autoTimer?.cancel();
    _autoTimer = null;

    // Clear any previous skip reason
    _skipReason = null;

    _autoPingEnabled = true;
    _rxOnlyMode = rxOnly;

    // Enable wake lock to keep screen on during auto mode
    // Reference: acquireWakeLock() in wardrive.js
    debugLog('[TX/RX AUTO] Acquiring wake lock for auto mode');
    await _wakelockService.enable();

    if (rxOnly) {
      // RX Auto mode: just enable wardriving listening, no pings
      debugLog('[RX AUTO] RX Auto mode started - listening for signals only');
    } else {
      // TX/RX Auto mode: send first ping immediately, then schedule timer
      // Reference: sendPing(false) called immediately in startAutoPing() in wardrive.js
      debugLog('[TX/RX AUTO] Sending initial auto ping');
      _sendInitialAutoPing();
    }

    return true;
  }

  /// Disable auto-ping mode (TX/RX Auto or RX Auto)
  /// Reference: stopAutoPing() and stopRxAuto() in wardrive.js
  Future<bool> disableAutoPing() async {
    debugLog('[PING] disableAutoPing called');

    if (!_autoPingEnabled) {
      debugLog('[PING] Auto mode not enabled');
      return true;
    }

    // Check cooldown before stopping (unless forced)
    // Reference: isInCooldown() check in stopAutoPing() in wardrive.js
    if (!_rxOnlyMode && isInCooldown()) {
      final remainingSec = getRemainingCooldownSeconds();
      debugLog('[TX/RX AUTO] Auto ping stop blocked by cooldown (${remainingSec}s remaining)');
      return false;
    }

    // Clear auto timer
    _autoTimer?.cancel();
    _autoTimer = null;

    // Clear skip reason
    _skipReason = null;

    _autoPingEnabled = false;
    _rxOnlyMode = false;

    // Disable wake lock when auto mode stops
    // Reference: releaseWakeLock() in wardrive.js
    await _wakelockService.disable();

    debugLog('[PING] Auto-ping disabled');
    return true;
  }

  /// Force disable auto-ping (ignores cooldown, used for disconnect)
  Future<void> forceDisableAutoPing() async {
    debugLog('[PING] Force disabling auto-ping');
    _autoTimer?.cancel();
    _autoTimer = null;
    _skipReason = null;
    _autoPingEnabled = false;
    _rxOnlyMode = false;
    await _wakelockService.disable();
  }

  /// Reset statistics
  void resetStats() {
    _stats = const PingStats();
    onStatsUpdated?.call(_stats);
  }

  /// Dispose of resources
  void dispose() async {
    _rxWindowTimer?.cancel();
    _autoTimer?.cancel();
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
  
  /// Outside geofence (150km from Ottawa)
  outsideGeofence,
  
  /// Too close to last ping (< 25m)
  tooCloseToLastPing,
  
  /// Cooldown period active (< 7s since last ping)
  cooldownActive,
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
        return 'Outside service area (150km from Ottawa)';
      case PingValidation.tooCloseToLastPing:
        return 'Move 25m before next ping';
      case PingValidation.cooldownActive:
        return 'Wait 7 seconds between pings';
    }
  }
}
