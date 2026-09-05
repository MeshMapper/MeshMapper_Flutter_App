import 'dart:async';
import 'dart:typed_data';

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
import 'meshcore/trace_tracker.dart';
import 'meshcore/tx_tracker.dart';
import 'meshcore/wire_tag_codec.dart';
import 'meshcore/unified_rx_handler.dart';
import 'recent_coverage_service.dart';
import 'wakelock_service.dart';

/// Ping service for TX/RX ping orchestration
/// Ported from wardrive.js ping logic
///
/// TX Flow:
/// 1. Validate GPS lock, 25m min distance (zone validation handled server-side)
/// 2. Start TxTracker to monitor for repeater echoes
/// 3. Send @[MapperBot] LAT, LON [POWERw] to #wardriving channel
/// 4. Start 5-second RX listening window
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
/// 2. Start 5-second listening window via DiscTracker
/// 3. Collect discovery responses (0x8E packets)
/// 4. After window ends, create log entry and queue DISC API payloads
class PingService {
  /// RX listening window duration (5 seconds - matches cooldown duration)
  static const Duration _rxListeningWindow = Duration(seconds: 5);

  /// Cooldown period between pings (5 seconds)
  static const Duration _autoPingCooldown = Duration(seconds: 5);

  /// Discovery listening window duration (7 seconds)
  static const Duration _discoveryListeningWindow = Duration(seconds: 7);

  /// Discovery request interval (30 seconds - repeaters only respond 4 times per 2 minutes)
  static const Duration _discoveryInterval = Duration(seconds: 30);

  /// Cooldown period between manual pings (15 seconds)
  static const Duration _manualPingCooldown = Duration(seconds: 15);

  /// Current configured min ping distance (for validation messages)
  static int currentMinDistance = 25;

  /// Skip reason reported when Smart Pinging held an auto send back because
  /// the square is already covered. Read by the countdown and the Live
  /// Activity, so it is named here rather than repeated as a literal.
  static const String skipReasonRecentlyCovered = 'recently covered';

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

  /// Number of bytes per hop in path hash (1, 2, or 3). Passed to DiscTracker for repeater ID length.
  int _hopBytes;

  /// Number of bytes for trace path IDs (1, 2, or 4). Uses bitshift encoding, separate from TX.
  int _traceHopBytes;

  /// Update hop bytes at runtime (e.g. when user changes path mode while connected)
  set hopBytes(int value) => _hopBytes = value;

  /// Update trace hop bytes at runtime (e.g. when user changes trace byte setting)
  set traceHopBytes(int value) => _traceHopBytes = value;

  /// When true, skip RSSI carpeater check in DiscTracker (user setting)
  bool disableRssiFilter;

  /// Unified RX handler reference for routing trace packets
  UnifiedRxHandler? unifiedRxHandler;

  PingStats _stats = const PingStats();
  DateTime? _lastTxTime;
  Timer? _rxWindowTimer;

  // TX ping context for queueing after RX window ends
  int? _pendingTxTimestamp;
  int? _pendingTxNoiseFloor;
  int? _pendingTxPingCounter; // wire-tag ping counter (null in coords mode)
  String? _pendingTxWireTag; // wire-tag body sent on air (null in coords mode)

  // Ping in progress guard (prevents concurrent BLE GATT errors)
  // Reference: state.pingInProgress in wardrive.js
  bool _pingInProgress = false;

  // Auto-ping mode
  bool _autoPingEnabled = false;
  bool _passiveModeEnabled = false;
  bool _hybridModeEnabled = false;
  bool _targetedModeEnabled = false;
  bool _nextPingIsDiscovery = true; // Start hybrid with discovery
  Timer? _autoTimer;

  // Targeted mode tracking
  TraceTracker? _traceTracker;
  StreamSubscription<Uint8List>? _traceDataSubscription;
  Timer? _targetedTimer;
  String? _targetRepeaterId;
  Position? _lastTargetedPosition;

  // Pending disable flag - when true, disable will execute after RX window ends
  bool _pendingDisable = false;

  // Last-resort backstop for the flag above. Every path that ends a ping
  // lifecycle (RX/discovery/trace window end, validation skip, failed send)
  // drains the flag itself (#496); this timer only remains for paths nobody
  // has thought of, so a stranded disable can never outlive it (#476).
  Timer? _pendingDisableTimeout;

  /// How long to wait for the real window completion before forcing a parked
  /// disable. Comfortably past the longest legitimate in-flight ping (the 7s
  /// discovery window) so a TX that is already on the air still gets its echoes.
  static const Duration _pendingDisableTimeoutDelay = Duration(seconds: 12);

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
  Position?
      _lastDiscoveryPosition; // Track last discovery position for 25m check

  // Validation callbacks
  bool Function()? checkExternalAntennaConfigured;
  bool Function()? checkPowerLevelConfigured;

  /// Callback to get the external antenna value for API payloads
  bool Function()? getExternalAntenna;

  /// Callback to get the power level in watts (0.3, 0.6, 1.0, 2.0) from user preferences
  double Function()? getPowerLevel;

  /// Smart Pinging: whether the cell under a fix already has recent coverage.
  /// Consulted by the auto TX validator and the auto discovery path only.
  /// Null (or [RecentCoverage.unknown]) never blocks. Wired by the provider
  /// to [RecentCoverageService.isCovered].
  RecentCoverage Function(double lat, double lon)? checkRecentCoverage;

  /// Callback to check if discovery drop is enabled (failed discoveries → API)
  bool Function()? getDiscDropEnabled;

  /// Callback to check if TX is allowed by API (zone capacity check)
  bool Function()? checkTxAllowed;

  /// Wire-tag composition (default privacy mode). Return the active session_id,
  /// the wire-tag key from /auth, the next per-session ping counter, and whether
  /// the user opted into broadcasting real coords on the air.
  String? Function()? getSessionId;
  String? Function()? getWireKey;
  int Function()? getNextPingCounter;
  bool Function()? getBroadcastCoords;

  /// Peek the current per-session ping counter, and react when it is exhausted
  /// (wire tag's 11-bit cap) — AppStateProvider disconnects with a session-limit message.
  int Function()? getPingCounter;
  Future<void> Function()? onSessionLimitReached;

  /// Callback for ping events
  void Function(TxPing)? onTxPing;
  void Function(RxPing)? onRxPing;
  void Function(PingStats)? onStatsUpdated;

  /// Called in real-time when each direct echo is received during tracking window
  /// Parameters: (TxPing txPing, HeardRepeater repeater, bool isNew)
  void Function(TxPing, HeardRepeater, bool isNew)? onEchoReceived;

  /// Called in real-time when each multi-hop echo is received during tracking window
  void Function(TxPing txPing, String repeaterId, double? snr, int? rssi,
      List<String> pathHops, bool isNew)? onMultiHopEchoReceived;

  /// Callback for discovery events (Passive Mode)
  /// Fires immediately when disc ping is created (like onTxPing)
  void Function(DiscLogEntry)? onDiscPing;

  /// Called in real-time when each node is discovered during tracking window
  /// Parameters: (DiscLogEntry discPing, DiscoveredNodeEntry nodeEntry, bool isNew)
  void Function(DiscLogEntry, DiscoveredNodeEntry, bool isNew)?
      onDiscNodeDiscovered;

  /// Callback when TX window ends (for noise floor graph)
  /// Parameters: (bool directSuccess, List multiHopEchoes)
  void Function(
      bool directSuccess,
      List<({String repeaterId, double? snr, int? rssi, List<String> pathHops})>
          multiHopEchoes)? onTxWindowComplete;

  /// Callback when discovery window ends (for noise floor graph)
  /// Parameters: (bool success) - true if any nodes discovered, false if none
  void Function(bool success)? onDiscoveryWindowComplete;

  /// Callback when trace window ends (for noise floor graph + log)
  /// Parameters: (TraceResult? result) - null if no response
  void Function(TraceResult? result)? onTraceWindowComplete;

  /// Callback when trace ping is sent (for log entry creation)
  void Function(TraceLogEntry)? onTracePing;

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
    int hopBytes = 1,
    int traceHopBytes = 1,
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
        _audioService = audioService,
        _hopBytes = hopBytes,
        _traceHopBytes = traceHopBytes;

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

  /// Check if Targeted Mode is active (zero-hop trace to specific repeater)
  bool get isTargetedMode => _targetedModeEnabled;

  /// Check if discovery tracker is currently listening (for Passive Mode UI)
  bool get isDiscoveryListening => _discTracker?.isListening ?? false;

  /// Get current auto-ping interval in milliseconds
  int get autoPingIntervalMs => _autoPingIntervalMs;

  /// Check if a disable is pending (waiting for RX window to complete)
  bool get pendingDisable => _pendingDisable;

  /// Get current skip reason (for auto mode display)
  String? get skipReason => _skipReason;

  /// Get the manual ping cooldown timer (for UI display)
  ManualPingCooldownTimer get manualPingCooldownTimer =>
      _manualPingCooldownTimer;

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

    // Airborne block: the provider ends the session, this only closes the
    // few-second window before the transport is gone.
    if (_gpsService.isAirborne) {
      return PingValidation.airborne;
    }

    // Note: GPS freshness check removed - 25m movement check is sufficient
    // If user hasn't moved, old position is still valid

    // Check GPS accuracy (< 100m)
    // Deliberately silent, like the other two validators. This runs on every
    // provider notify (ping_controls.dart reads it to enable the buttons), so
    // logging here wrote a line per second for as long as GPS stayed poor: 196
    // lines in four minutes, 20% of a reporter's whole debug file (#476). The
    // send paths log the blocking reason instead, once per real attempt.
    if (!_gpsService.isAccuracyAcceptableForPing(position)) {
      return PingValidation.gpsInaccurate;
    }

    // Note: Zone validation is now handled server-side by the API

    // Check minimum distance from last ping
    if (!_gpsService.canPingAtPosition(position)) {
      return PingValidation.tooCloseToLastPing;
    }

    // Smart Pinging: skip a square that already has a recent bidir or disc
    // result. After the distance check so a fix that is both reports too
    // close, and only here (auto): manual pings always send.
    if (checkRecentCoverage?.call(position.latitude, position.longitude) ==
        RecentCoverage.covered) {
      return PingValidation.recentlyCovered;
    }

    // Check cooldown (5 seconds between pings)
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

    // Airborne block: the provider ends the session, this only closes the
    // few-second window before the transport is gone.
    if (_gpsService.isAirborne) {
      return PingValidation.airborne;
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

    // Airborne block: the provider ends the session, this only closes the
    // few-second window before the transport is gone.
    if (_gpsService.isAirborne) {
      return PingValidation.airborne;
    }

    // Note: GPS freshness check removed - 25m movement check is sufficient

    // Check GPS accuracy (< 100m)
    if (!_gpsService.isAccuracyAcceptableForPing(position)) {
      return PingValidation.gpsInaccurate;
    }

    // Note: Zone validation is now handled server-side by the API

    // NOTE: Skip distance check (tooCloseToLastPing) intentionally
    // Auto mode handles this by setting skipReason='too close' and scheduling next ping

    // Check cooldown (5 seconds between pings)
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

  /// Clear the auto-ping cooldown (used during zone transfer to avoid blocking restart).
  void clearCooldown() {
    _lastTxTime = null;
  }

  /// Check if currently in manual ping cooldown period
  bool isInManualCooldown() {
    return _manualPingCooldownTimer.remainingMs > 0;
  }

  /// Get remaining manual cooldown seconds
  int getRemainingManualCooldownSeconds() {
    return _manualPingCooldownTimer.remainingSec;
  }

  /// Set when a deadline gate refused a transmission.
  ///
  /// Lets a caller tell "the radio never keyed up because I had already given
  /// up" apart from the ordinary reasons a send is skipped: cooldown, failed
  /// validation, no GPS. Only the former abandons a start or earns a spoken
  /// "took too long"; the rest keep their own reasons. Reset on entry to every
  /// gated path, so it always describes the send just attempted.
  bool _transmitAbortedByDeadline = false;

  bool get transmitAbortedByDeadline => _transmitAbortedByDeadline;

  /// Whether the surface waiting on this transmission has already given up.
  ///
  /// Call at the last suspension point before an RF send. Every send path here
  /// awaits a fresh GPS fix first, and that fix can outlive the deadline an
  /// external surface is holding a person on.
  bool _deadlinePassed(bool Function()? shouldAbortBeforeTransmit) {
    if (!(shouldAbortBeforeTransmit?.call() ?? false)) return false;
    _transmitAbortedByDeadline = true;
    debugLog('[PING] Deadline passed before transmit, not sending');
    return true;
  }

  /// Send a TX ping
  /// @param manual - Whether this is a manual ping (true) or auto ping (false)
  /// @param shouldAbortBeforeTransmit - Deadline gate for an external caller
  /// Returns true if ping was sent successfully
  /// Reference: sendPing() in wardrive.js
  Future<bool> sendTxPing({
    bool manual = true,
    bool Function()? shouldAbortBeforeTransmit,
  }) async {
    debugLog('[PING] sendTxPing called (manual=$manual)');
    _transmitAbortedByDeadline = false;

    // Guard: don't send pings if connection is not in connected state
    // Handles race where timer callback fires after reconnect started
    if (_connection.currentStep != ConnectionStep.connected) {
      debugLog(
          '[PING] Ignoring TX ping — not connected (step: ${_connection.currentStep})');
      return false;
    }

    // Early guard: prevent concurrent ping execution (critical for preventing BLE GATT errors)
    // Reference: state.pingInProgress check in wardrive.js
    if (_pingInProgress) {
      debugLog('[PING] Ping already in progress, ignoring duplicate call');
      return false;
    }
    _pingInProgress = true;

    try {
      // For auto pings, request a fresh GPS position before validation.
      // This ensures the 25m distance check and ping coordinates reflect
      // where the device is NOW, not where it was at the last stream event.
      if (!manual) {
        await _gpsService.getFreshPosition();
      }

      // The transport parks a non-sign write behind an in-progress sign, and
      // that wait is unbounded. It would happen inside the send call below,
      // after the TxPing record exists and past everything checkable here. Take
      // it now, while abandoning still costs nothing.
      if (shouldAbortBeforeTransmit != null) {
        await _connection.awaitWritableState();
      }

      // Last suspension point before the transmission: with the write gate
      // already open, nothing below this awaits until the BLE send. Checking
      // here rather than at the send itself is the same instant in wall-clock
      // terms and leaves no TxPing record and no consumed wire-tag counter
      // behind for a ping that never went out.
      if (_deadlinePassed(shouldAbortBeforeTransmit)) {
        _pingInProgress = false;
        return false;
      }

      // Use different validation and cooldown for manual vs auto pings
      if (manual) {
        // Manual ping: 15-second cooldown, no distance check
        if (isInManualCooldown()) {
          final remainingSec = getRemainingManualCooldownSeconds();
          debugLog(
              '[PING] Manual ping blocked by cooldown (${remainingSec}s remaining)');
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
        // Auto ping: 5-second cooldown, 25m distance check
        // This fixes a race condition where disabling Active Mode during cooldown
        // could still trigger an auto-ping from a late RX window timer callback
        if (isInCooldown()) {
          final remainingSec = getRemainingCooldownSeconds();
          debugLog(
              '[PING] Auto ping blocked by cooldown (${remainingSec}s remaining)');
          _pingInProgress = false;
          return false;
        }

        final validation = canPing();
        if (validation != PingValidation.valid) {
          // Unlock BEFORE scheduling. onAutoPingScheduled fires synchronously
          // and the idle auto-stop hangs off it, so a disable arriving while
          // this is still true latches as pending and never drains (a skipped
          // ping arms no RX window). Matches _sendDiscoveryRequest's ordering.
          _pingInProgress = false;
          // Logged here rather than inside canPing(), which the UI calls on
          // every notify. Once per real attempt, matching the manual path.
          debugLog('[PING] Auto ping blocked by validation: $validation');
          // For auto mode, schedule next attempt if distance check failed
          if (_autoPingEnabled && !_passiveModeEnabled) {
            if (validation == PingValidation.tooCloseToLastPing) {
              _skipReason = 'too close';
            } else if (validation == PingValidation.recentlyCovered) {
              _skipReason = skipReasonRecentlyCovered;
            } else {
              // Anything else clears it, so a stale "recently covered" from
              // the previous attempt cannot ride into the countdown and the
              // Live Activity.
              _skipReason = null;
            }
            if (_hybridModeEnabled) {
              _scheduleNextHybridPing();
            } else {
              _scheduleNextAutoPing();
            }
          }
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
      final txPowerDbm = _connection.deviceModel?.txPower ?? 22;

      // Build the on-air body ONCE (same string is used for TxTracker echo
      // correlation AND the actual transmission). Power is sent per-ping in the API.
      //
      // A keyed wire tag "MM:<tag>" (privacy default), or "MM:<tag>:lat,lon" when
      // Broadcast My Coordinates is on (tag + plaintext coords). Those are the only
      // two shapes: without a session there is no tag, and the ping is refused.
      final coordsStr =
          '${position.latitude.toStringAsFixed(5)},${position.longitude.toStringAsFixed(5)}';
      final broadcastCoords = getBroadcastCoords?.call() ?? false;
      final sessionId = getSessionId?.call();
      String pingMessage;
      int? txPingCounter;
      String? txWireTag;
      final hasSession = sessionId != null && sessionId.isNotEmpty;
      if (hasSession) {
        // Session-limit guard: the wire tag's counter is 11 bits (max 2047). When it
        // is exhausted, end the session cleanly rather than repeating/corrupting tags.
        // Applies to BOTH privacy and broadcast-coords modes — a combined ping consumes
        // a counter exactly like a privacy ping, so the session ends identically.
        if ((getPingCounter?.call() ?? 0) >= 2047) {
          debugError(
              '[SESSION] Reached session ping limit (2047) — disconnecting');
          _pingInProgress = false;
          onSessionLimitReached?.call();
          return false;
        }
        txPingCounter = getNextPingCounter?.call() ?? 1;
        txWireTag =
            WireTagCodec.encode(sessionId, txPingCounter, getWireKey?.call());
        // Identical to privacy mode in every way EXCEPT broadcast-coords appends the
        // plaintext coords to the on-air body. The bare tag still goes to the API
        // (txWireTag → _pendingTxWireTag), so /wardrive validation + tx_pings are unchanged.
        pingMessage = broadcastCoords ? '$txWireTag:$coordsStr' : txWireTag;
      } else {
        // Unreachable: tx_allowed and session_id arrive in the same /auth response,
        // and every TX validator requires txAllowed. If we get here the session state
        // is corrupt, so refuse to transmit rather than emit a tagless (untraceable)
        // ping. Every ping the app sends carries a wire tag by construction.
        debugError('[PING] TX attempted with no session, aborting ping');
        _pingInProgress = false;
        return false;
      }

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

      if (_txTracker != null &&
          channelIndex != null &&
          channelHash != null &&
          channelKey != null) {
        debugLog('[PING] Starting TX echo tracking for: "$pingMessage"');

        // Wire up real-time echo callback before starting tracking
        final txTracker = _txTracker;
        txTracker.onEchoReceived = (repeaterId, snr, rssi, isNew) {
          debugLog(
              '[PING] onEchoReceived callback fired: $repeaterId, SNR=$snr, RSSI=$rssi, isNew=$isNew');
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
              debugLog(
                  '[PING] Real-time: Added new repeater $repeaterId (SNR: $snr) - total: ${txPing.heardRepeaters.length}');
            } else {
              // Update existing repeater's SNR if better
              final idx = txPing.heardRepeaters
                  .indexWhere((r) => r.repeaterId == repeaterId);
              if (idx >= 0) {
                txPing.heardRepeaters[idx] = repeater;
                debugLog(
                    '[PING] Real-time: Updated repeater $repeaterId (SNR: $snr)');
              }
            }

            // Notify for real-time UI updates
            debugLog(
                '[PING] Calling onEchoReceived callback (callback=${onEchoReceived != null ? "SET" : "NULL"})');
            onEchoReceived?.call(txPing, repeater, isNew);
            debugLog('[PING] onEchoReceived callback completed');
          } else {
            debugWarn('[PING] onEchoReceived: _lastTxPing is null!');
          }
        };

        txTracker.onMultiHopEchoReceived =
            (repeaterId, snr, rssi, pathHops, isNew) {
          debugLog(
              '[PING] Multi-hop echo: $repeaterId, SNR=$snr, hops=${pathHops.length}, isNew=$isNew');
          final txPing = _lastTxPing;
          if (txPing != null) {
            final repeater = HeardRepeater(
              repeaterId: repeaterId,
              snr: snr,
              rssi: rssi,
              seenCount:
                  txTracker.multiHopRepeaters[repeaterId]?.seenCount ?? 1,
              pathHops: pathHops,
            );

            if (isNew) {
              txPing.heardRepeaters.add(repeater);
            } else {
              final idx = txPing.heardRepeaters.indexWhere(
                  (r) => r.repeaterId == repeaterId && r.pathHops != null);
              if (idx >= 0) {
                txPing.heardRepeaters[idx] = repeater;
              }
            }

            onMultiHopEchoReceived?.call(
                txPing, repeaterId, snr, rssi, pathHops, isNew);
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
        debugWarn(
            '[PING] TX tracking not available - channel info missing or no tracker');
      }

      // Play transmit sound immediately before sending
      _audioService?.playTransmitSound();

      // Send ping via BLE (pre-composed body — wire tag or legacy coords)
      await _connection.sendPing(pingMessage);

      // Mark ping time and position
      _lastTxTime = DateTime.now();
      _gpsService.markPingPosition(position);

      // Start appropriate cooldown timer
      if (manual) {
        // Manual ping: 15-second cooldown, no distance check
        _manualPingCooldownTimer.start(_manualPingCooldown.inMilliseconds);
      } else {
        // Auto ping: 5-second cooldown
        _cooldownTimer.start(_autoPingCooldown.inMilliseconds);
      }

      // Store TX context for queueing after RX window ends
      // TX entry is queued AFTER RX window so heard_repeats can be populated
      _pendingTxTimestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _pendingTxNoiseFloor = noiseFloor;
      _pendingTxPingCounter = txPingCounter; // null in coords mode
      _pendingTxWireTag = txWireTag; // null in coords mode

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
    } finally {
      // A ping that ended without arming an RX window (validation skip, no
      // GPS, failed send, any early return above) is the end of the lifecycle
      // a queued disable was waiting on. Drain it here rather than leaving it
      // for the timeout backstop, which locked the controls for the whole
      // 12s wait (#496). A successful send leaves _pingInProgress true until
      // _endRxListeningWindow, which does its own drain.
      if (!_pingInProgress && _pendingDisable) {
        await _executePendingDisable('ping ended without RX window');
      }
    }
  }

  /// Start the 5-second RX listening window after TX
  /// Note: TxTracker handles the actual echo tracking, we just manage the countdown UI
  void _startRxListeningWindow(Position txPosition) {
    // Cancel previous timer
    _rxWindowTimer?.cancel();

    // Start RX window countdown display (5 seconds)
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
      debugLog(
          '[PING] TxTracker collected ${txTracker.repeaters.length} repeater echoes');

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
      _stats =
          _stats.copyWith(rxCount: _stats.rxCount + txTracker.repeaters.length);
      onStatsUpdated?.call(_stats);
    } else {
      debugLog('[PING] No repeater echoes detected during listening window');
    }

    // Collect multi-hop echo data for the onTxWindowComplete callback
    final multiHopEchoes = <({
      String repeaterId,
      double? snr,
      int? rssi,
      List<String> pathHops
    })>[];
    if (txTracker != null && txTracker.multiHopRepeaters.isNotEmpty) {
      for (final entry in txTracker.multiHopRepeaters.entries) {
        final echo = entry.value;
        multiHopEchoes.add((
          repeaterId: echo.repeaterId,
          snr: echo.snr,
          rssi: echo.rssi,
          pathHops: echo.pathHops,
        ));
      }
    }

    // Notify about TX window completion for noise floor graph
    onTxWindowComplete?.call(txSuccess, multiHopEchoes);

    // Queue TX entry with heard_repeats AFTER RX window ends
    final txTimestamp = _pendingTxTimestamp;
    if (txTimestamp != null) {
      _apiQueue.enqueueTx(
        latitude: txPosition.latitude,
        longitude: txPosition.longitude,
        heardRepeats: heardRepeats,
        timestamp: txTimestamp,
        externalAntenna: getExternalAntenna?.call() ?? false,
        noiseFloor: _pendingTxNoiseFloor,
        power: getPowerLevel?.call(),
        pingCounter:
            _pendingTxPingCounter, // null in coords mode → server coords path
        wireTag: _pendingTxWireTag, // null in coords mode → server coords path
        altitude: GpsService.altitudeOrNull(txPosition),
      );
      debugLog('[PING] Queued TX entry with heard_repeats: $heardRepeats');

      // Queue multi-hop echoes as individual RX API entries
      if (multiHopEchoes.isNotEmpty) {
        for (final echo in multiHopEchoes) {
          final rxHeardRepeats = echo.snr != null
              ? '${echo.repeaterId}(${echo.snr!.toStringAsFixed(2)})'
              : '${echo.repeaterId}(null)';
          _apiQueue.enqueueRx(
            latitude: txPosition.latitude,
            longitude: txPosition.longitude,
            heardRepeats: rxHeardRepeats,
            timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            repeaterId: echo.repeaterId,
            externalAntenna: getExternalAntenna?.call() ?? false,
            noiseFloor: _pendingTxNoiseFloor,
            power: getPowerLevel?.call(),
            altitude: GpsService.altitudeOrNull(txPosition),
          );
        }
        debugLog(
            '[PING] Queued ${multiHopEchoes.length} multi-hop echoes as RX');
      }

      // Clear pending TX context
      _pendingTxTimestamp = null;
      _pendingTxNoiseFloor = null;
    }

    // Unlock ping controls immediately (don't wait for API)
    // Reference: unlockPingControls("after RX listening window completion") in wardrive.js
    _pingInProgress = false;

    // After RX window ends, check if disable was requested during the window
    if (_pendingDisable) {
      await _executePendingDisable('after RX window');
      return; // Don't schedule next auto ping
    }

    // Schedule next ping based on mode
    // The cooldown check prevents scheduling when user disabled auto mode during RX window
    // (the cooldown timer started when auto mode was disabled)
    // Reference: scheduleNextAutoPing() called after RX window in wardrive.js
    if (_autoPingEnabled && !isInCooldown()) {
      if (_hybridModeEnabled) {
        debugLog(
            '[HYBRID] Scheduling next hybrid ping after RX window completion');
        _scheduleNextHybridPing();
      } else if (!_passiveModeEnabled) {
        debugLog(
            '[ACTIVE MODE] Scheduling next auto ping after RX window completion');
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
      debugLog(
          '[ACTIVE MODE] Not scheduling next auto ping - auto mode not running or Passive Mode');
      return;
    }

    // Clear any existing timer to prevent accumulation (CRITICAL: prevents duplicate timers)
    // Reference: clearTimeout(state.autoTimerId) in wardrive.js
    _autoTimer?.cancel();
    _autoTimer = null;

    debugLog(
        '[ACTIVE MODE] Scheduling next auto ping in ${_autoPingIntervalMs}ms');

    // Start countdown display (with skip reason if applicable)
    // The AutoPingTimer in countdown_timer_service.dart handles the display
    onAutoPingScheduled?.call(_autoPingIntervalMs, _skipReason);

    // That callback runs synchronously and can stop auto mode (the idle
    // auto-stop hangs off it), which cancels _autoTimer. Re-check so we don't
    // re-arm a timer the stop just cleared.
    if (!_autoPingEnabled || _passiveModeEnabled) {
      debugLog(
          '[ACTIVE MODE] Auto mode stopped while scheduling, not arming timer');
      return;
    }

    // Schedule the next ping
    _autoTimer = Timer(Duration(milliseconds: _autoPingIntervalMs), () {
      debugLog('[ACTIVE MODE] Auto ping timer fired');

      // Guard: connection may have dropped since timer was scheduled
      if (_connection.currentStep != ConnectionStep.connected) {
        debugLog('[ACTIVE MODE] Not connected, ignoring timer');
        return;
      }
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
  Future<void> _sendInitialAutoPing({
    bool Function()? shouldAbortBeforeTransmit,
  }) async {
    try {
      await sendTxPing(
        manual: false,
        shouldAbortBeforeTransmit: shouldAbortBeforeTransmit,
      );
    } catch (e) {
      debugLog('[ACTIVE MODE] Initial auto ping error: $e');
      // Even on error, schedule next ping
      _scheduleNextAutoPing();
    }
  }

  /// Enable Active Mode (timer-based auto ping), Passive Mode (listen-only),
  /// Hybrid Mode, or Targeted Mode (zero-hop trace)
  /// Reference: startAutoPing() in wardrive.js
  /// @param passiveMode - If true, only listens for RX (no TX pings) - this is Passive Mode
  /// @param hybridMode - If true, alternates discovery + TX pings each interval
  /// @param targetedMode - If true, sends trace path to specific repeater
  /// @param targetRepeaterId - Repeater ID hex string (required when targetedMode=true)
  /// @param shouldAbortBeforeTransmit - Deadline gate for an external caller
  ///
  /// The gate lets an external surface holding a person on a deadline (Siri)
  /// abandon the start if that deadline passes before the session's first
  /// transmission. A session must never come up after the surface has already
  /// reported that it did not.
  Future<bool> enableAutoPing({
    bool passiveMode = false,
    bool hybridMode = false,
    bool targetedMode = false,
    String? targetRepeaterId,
    bool Function()? shouldAbortBeforeTransmit,
  }) async {
    debugLog(
        '[AUTO] enableAutoPing called (passiveMode=$passiveMode, hybridMode=$hybridMode, targetedMode=$targetedMode)');

    if (_autoPingEnabled) {
      debugLog('[AUTO] Auto mode already enabled');
      return false;
    }

    // Targeted mode requires a repeater ID
    if (targetedMode &&
        (targetRepeaterId == null || targetRepeaterId.isEmpty)) {
      debugLog('[AUTO] Targeted mode requires a repeater ID');
      return false;
    }

    // Check if we're in cooldown (can't start during cooldown)
    // Hybrid, Active, and Targeted modes are blocked by cooldown, Passive is not
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
    _transmitAbortedByDeadline = false;

    _autoPingEnabled = true;
    _passiveModeEnabled = passiveMode;
    _hybridModeEnabled = hybridMode;
    _targetedModeEnabled = targetedMode;
    _nextPingIsDiscovery = true; // Always start hybrid with discovery

    if (targetedMode) {
      _targetRepeaterId = targetRepeaterId;
    }

    // Enable wake lock to keep screen on during auto mode
    // Reference: acquireWakeLock() in wardrive.js
    debugLog('[AUTO] Acquiring wake lock for auto mode');
    await _wakelockService.enable();

    if (targetedMode) {
      // Targeted Mode: send trace path to specific repeater
      debugLog(
          '[TARGETED] Targeted Mode started - tracing repeater $targetRepeaterId');
      await _startTargetedMode();
    } else if (hybridMode) {
      // Hybrid Mode: set up discovery infrastructure, then start with discovery
      debugLog(
          '[HYBRID] Hybrid Mode started - alternating discovery + TX pings');
      await _startDiscoveryMode(
        shouldAbortBeforeTransmit: shouldAbortBeforeTransmit,
      );
      // First ping was discovery, so next should be TX
      _nextPingIsDiscovery = false;
    } else if (passiveMode) {
      // Passive Mode: send discovery requests instead of TX pings
      debugLog(
          '[PASSIVE MODE] Passive Mode started - using discovery protocol');
      await _startDiscoveryMode(
        shouldAbortBeforeTransmit: shouldAbortBeforeTransmit,
      );
    } else {
      // Active Mode: send first ping immediately, then schedule timer
      // Reference: sendPing(false) called immediately in startAutoPing() in wardrive.js
      debugLog('[ACTIVE MODE] Sending initial auto ping');
      if (shouldAbortBeforeTransmit == null) {
        _sendInitialAutoPing();
      } else {
        // Awaited only on the deadline-carrying path, so the ordinary start
        // keeps returning as soon as the first ping is on its way.
        await _sendInitialAutoPing(
          shouldAbortBeforeTransmit: shouldAbortBeforeTransmit,
        );
      }
    }

    if (_transmitAbortedByDeadline) {
      await _abandonAutoPingStart();
      return false;
    }

    return true;
  }

  /// Unwind a start whose deadline passed before the first transmission.
  ///
  /// Mirrors the teardown in [disableAutoPing] without its cooldown and
  /// pending-disable handling: nothing was transmitted, so there is no RX
  /// window to let finish and no cooldown to earn.
  Future<void> _abandonAutoPingStart() async {
    debugLog('[AUTO] Abandoning start: caller gave up before first transmit');
    _autoTimer?.cancel();
    _autoTimer = null;
    _skipReason = null;

    if (_passiveModeEnabled || _hybridModeEnabled) {
      _stopDiscoveryMode();
    }
    if (_targetedModeEnabled) {
      _stopTargetedMode();
    }

    _autoPingEnabled = false;
    _passiveModeEnabled = false;
    _hybridModeEnabled = false;
    _targetedModeEnabled = false;
    _nextPingIsDiscovery = true;

    await _wakelockService.disable();
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
      _armPendingDisableTimeout();
      return true; // Return true to indicate disable was accepted (pending)
    }

    // Check cooldown before stopping (unless forced)
    // Reference: isInCooldown() check in stopAutoPing() in wardrive.js
    if (!_passiveModeEnabled && isInCooldown()) {
      final remainingSec = getRemainingCooldownSeconds();
      debugLog(
          '[ACTIVE MODE] Stop blocked by cooldown (${remainingSec}s remaining)');
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

    // Clean up targeted mode infrastructure
    if (_targetedModeEnabled) {
      _stopTargetedMode();
    }

    _autoPingEnabled = false;
    _passiveModeEnabled = false;
    _hybridModeEnabled = false;
    _targetedModeEnabled = false;
    _nextPingIsDiscovery = true;

    // Disable wake lock when auto mode stops
    // Reference: releaseWakeLock() in wardrive.js
    await _wakelockService.disable();

    debugLog('[PING] Auto-ping disabled');
    return true;
  }

  /// Run the disable that [disableAutoPing] parked while a ping was in flight:
  /// clear auto mode, cancel the auto timer, start the cooldown, then hand back
  /// to AppStateProvider for its half of the teardown.
  ///
  /// Safe to call from either the RX window completion or the timeout backstop:
  /// it clears [_pendingDisable] and the timeout first, and both callers gate on
  /// [_pendingDisable] still being set, so it can never run twice.
  Future<void> _executePendingDisable(String trigger) async {
    debugLog('[PING] Executing pending disable ($trigger)');
    _pendingDisable = false;
    _pendingDisableTimeout?.cancel();
    _pendingDisableTimeout = null;
    final wasPassive = _passiveModeEnabled;
    final wasHybrid = _hybridModeEnabled;
    final wasTargeted = _targetedModeEnabled;
    _autoPingEnabled = false;
    _passiveModeEnabled = false;
    _hybridModeEnabled = false;
    _targetedModeEnabled = false;
    _nextPingIsDiscovery = true;
    _autoTimer?.cancel();
    _autoTimer = null;
    // Clean up discovery infrastructure if passive or hybrid was enabled
    if (wasPassive || wasHybrid) {
      _stopDiscoveryMode();
    }
    // Clean up targeted infrastructure if targeted was enabled
    if (wasTargeted) {
      _stopTargetedMode();
    }
    // Start cooldown immediately
    _cooldownTimer.start(_autoPingCooldown.inMilliseconds);
    debugLog('[PING] Pending disable complete, cooldown started');
    // Notify AppStateProvider to update its state and cleanup. Several callers
    // run from void tracker callbacks or timer-driven send paths where nothing
    // awaits this method, so an escaping error here would go unhandled. The
    // local teardown above is already done by this point.
    try {
      await onPendingDisableComplete?.call();
    } catch (e) {
      debugError('[PING] Pending disable provider cleanup failed: $e');
    }
  }

  /// Guarantee a parked disable is drained even when the RX window that was
  /// supposed to drain it never arrives.
  ///
  /// The window is only armed once a ping actually goes out. A ping rejected by
  /// validation, or one that fails to send, clears [_pingInProgress] and returns
  /// without arming anything, so the queued disable had no completion to wait
  /// for and auto mode kept running (#476: hybrid kept scheduling pings for four
  /// minutes after the user stopped it).
  void _armPendingDisableTimeout() {
    _pendingDisableTimeout?.cancel();
    _pendingDisableTimeout = Timer(_pendingDisableTimeoutDelay, () async {
      if (!_pendingDisable) return; // the window drained it, nothing to do
      debugWarn('[PING] Pending disable never drained after '
          '${_pendingDisableTimeoutDelay.inSeconds}s (no RX window arrived) - forcing it');
      // The ping this was waiting on is gone. Leaving this set would keep the
      // ping controls locked out until a restart.
      _pingInProgress = false;
      try {
        await _executePendingDisable('timeout backstop');
      } catch (e) {
        // Nothing is awaiting a timer callback, so an escaping error here would
        // go unhandled. The flags are already cleared by this point.
        debugError('[PING] Forced pending disable failed: $e');
      }
    });
  }

  /// Force disable auto-ping (ignores cooldown, used for disconnect)
  Future<void> forceDisableAutoPing() async {
    debugLog('[PING] Force disabling auto-ping');
    _pendingDisable = false; // Clear any pending disable
    _pendingDisableTimeout?.cancel();
    _pendingDisableTimeout = null;
    _autoTimer?.cancel();
    _autoTimer = null;
    _skipReason = null;
    _autoPingEnabled = false;
    _passiveModeEnabled = false;
    _hybridModeEnabled = false;
    _targetedModeEnabled = false;
    _nextPingIsDiscovery = true;
    _stopDiscoveryMode();
    _stopTargetedMode();
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
  Future<void> _startDiscoveryMode({
    bool Function()? shouldAbortBeforeTransmit,
  }) async {
    debugLog('[DISC] Starting discovery mode');

    // Create and configure discovery tracker
    final tracker = DiscTracker(
      shouldIgnoreRepeater: shouldIgnoreRepeater,
      disableRssiFilter: disableRssiFilter,
      hopBytes: _hopBytes,
    );
    _discTracker = tracker;
    tracker.onCarpeaterDrop = onDiscCarpeaterDrop;
    tracker.onNodeDiscovered = (node, isNew) {
      debugLog(
          '[DISC] Node discovered: ${node.repeaterId} (${node.nodeTypeName}), isNew=$isNew');
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
          final idx = discPing.discoveredNodes
              .indexWhere((n) => n.repeaterId == node.repeaterId);
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
    await _sendDiscoveryRequest(
      shouldAbortBeforeTransmit: shouldAbortBeforeTransmit,
    );
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
    _lastDiscoveryPosition =
        null; // Reset so first discovery always sends on next start
    _lastDiscPing = null;
  }

  /// Send a discovery request and start listening window
  ///
  /// [shouldAbortBeforeTransmit] is supplied only for the session's first
  /// discovery. Later requests come from timers and belong to the session
  /// itself, so no external deadline applies to them.
  Future<void> _sendDiscoveryRequest({
    bool Function()? shouldAbortBeforeTransmit,
  }) async {
    // Guard: don't send discovery during reconnect (race with timer queue)
    if (_connection.currentStep != ConnectionStep.connected) {
      debugLog(
          '[DISC] Ignoring discovery request — not connected (step: ${_connection.currentStep})');
      return;
    }

    if (!_autoPingEnabled || (!_passiveModeEnabled && !_hybridModeEnabled)) {
      debugLog('[DISC] Not in Passive/Hybrid Mode, skipping discovery request');
      return;
    }

    // Request fresh GPS position before discovery (same rationale as TX auto-ping)
    final position = await _gpsService.getFreshPosition();

    // As in sendTxPing: the transport parks a non-sign write behind an
    // in-progress sign, so take that wait here rather than inside the send.
    if (shouldAbortBeforeTransmit != null) {
      await _connection.awaitWritableState();
    }

    // Ahead of every early return below, not just of the send: those returns
    // schedule a retry, so a caller that has already given up would otherwise
    // get a session that transmits on the next tick anyway.
    if (_deadlinePassed(shouldAbortBeforeTransmit)) {
      _pingInProgress = false;
      return;
    }

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
      if (distance < _gpsService.configuredMinDistance) {
        debugLog(
            '[DISC] Too close to last discovery (${distance.toStringAsFixed(1)}m < ${_gpsService.configuredMinDistance.toInt()}m), skipping');
        _skipReason = 'too close';
        _pingInProgress = false;
        _scheduleNextDiscovery();
        return;
      }
    }

    // Smart Pinging: a covered square gets no discovery request either.
    if (checkRecentCoverage?.call(position.latitude, position.longitude) ==
        RecentCoverage.covered) {
      debugLog('[DISC] Square recently covered, skipping discovery request');
      _skipReason = skipReasonRecentlyCovered;
      _pingInProgress = false;
      _scheduleNextDiscovery();
      return;
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

    debugLog(
        '[DISC] Sending discovery request at ${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}');

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

      // Start discovery window countdown display (5 seconds)
      _discoveryWindowCountdown.start(_discoveryListeningWindow.inMilliseconds);

      // Clear pingInProgress now that discovery window is active
      _pingInProgress = false;

      // Update last discovery position for 25m check
      _lastDiscoveryPosition = position;

      // Follow with the display anchor so the map's distance readout tracks
      // discovery pings too, not just TX (#501)
      _gpsService.markActivityPosition(position);
    } catch (e) {
      _pingInProgress = false;
      debugError('[DISC] Failed to send discovery request: $e');
      if (_pendingDisable) {
        await _executePendingDisable('discovery send failed');
        return;
      }
      _scheduleNextDiscovery();
    }
  }

  /// Handle discovery window completion
  Future<void> _handleDiscoveryWindowComplete(List<DiscoveredNode> nodes) async {
    _discoveryWindowCountdown.stop();
    final position = _discoveryStartPosition;
    if (position == null) {
      debugLog('[DISC] No position recorded for discovery, skipping');
      // Notify about discovery failure for noise floor graph
      onDiscoveryWindowComplete?.call(false);
      _lastDiscPing = null;
      if (_pendingDisable) {
        await _executePendingDisable('after discovery window');
        return;
      }
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
          power: getPowerLevel?.call(),
          altitude: GpsService.altitudeOrNull(position),
        );
      }

      // Update stats
      _stats = _stats.copyWith(discCount: _stats.discCount + 1);
      onStatsUpdated?.call(_stats);
    } else {
      debugLog('[DISC] No nodes discovered');

      // Queue failed discovery to API if disc drop is enabled
      if (getDiscDropEnabled?.call() == true) {
        _apiQueue.enqueueDiscDrop(
          latitude: position.latitude,
          longitude: position.longitude,
          timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          externalAntenna: getExternalAntenna?.call() ?? false,
          noiseFloor: _pendingTxNoiseFloor,
          power: getPowerLevel?.call(),
          altitude: GpsService.altitudeOrNull(position),
        );
        debugLog('[DISC] Discovery drop queued (no response)');
      }
    }

    // Entry already added to log via onDiscPing - no need to fire onDiscoveryComplete

    // Fire noise floor callback (entry already in _discLogEntries via onDiscPing)
    onDiscoveryWindowComplete?.call(discoverySuccess);

    debugLog(
        '[DISC] Discovery window complete: ${nodes.length} nodes${discoverySuccess ? ', queued ${nodes.length} API payloads' : ''}');

    _lastDiscPing = null;
    if (_pendingDisable) {
      await _executePendingDisable('after discovery window');
      return;
    }
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

    debugLog(
        '[DISC] Next discovery scheduled in ${_discoveryInterval.inSeconds}s');
  }

  /// Schedule next hybrid ping (alternates discovery ↔ TX)
  /// Uses user-configured interval for both ping types
  void _scheduleNextHybridPing() {
    if (!_autoPingEnabled || !_hybridModeEnabled) return;

    _autoTimer?.cancel();
    _autoTimer = null;

    // Subtract listening window so interval is measured start-to-start
    // TX uses 5s RX window, discovery uses 7s window
    final listenMs = _nextPingIsDiscovery
        ? _discoveryListeningWindow.inMilliseconds
        : _rxListeningWindow.inMilliseconds;
    final waitMs =
        (_autoPingIntervalMs - listenMs).clamp(1000, _autoPingIntervalMs);

    final isNextDisc = _nextPingIsDiscovery;
    debugLog(
        '[HYBRID] Scheduling next ${isNextDisc ? "discovery" : "TX"} ping in ${waitMs}ms');

    onAutoPingScheduled?.call(waitMs, _skipReason);

    // See _scheduleNextAutoPing: the callback can stop auto mode synchronously.
    if (!_autoPingEnabled || !_hybridModeEnabled) {
      debugLog('[HYBRID] Auto mode stopped while scheduling, not arming timer');
      return;
    }

    _autoTimer = Timer(Duration(milliseconds: waitMs), () {
      if (!_autoPingEnabled || !_hybridModeEnabled) return;
      if (_connection.currentStep != ConnectionStep.connected) {
        debugLog('[HYBRID] Not connected, ignoring timer');
        return;
      }
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

  // ============================================
  // Targeted Mode (Zero-Hop Trace)
  // ============================================

  /// Start targeted mode - subscribes to trace data and sends first trace
  Future<void> _startTargetedMode() async {
    debugLog('[TRACE] Starting targeted mode for repeater $_targetRepeaterId');

    // Create trace tracker
    final tracker = TraceTracker();
    _traceTracker = tracker;
    tracker.onTraceReceived = (result) {
      debugLog(
          '[TRACE] Trace response received: localSnr=${result.localSnr}, remoteSnr=${result.remoteSnr}');
    };
    tracker.onWindowComplete = (result) {
      debugLog(
          '[TRACE] Trace window complete: ${result != null ? 'success' : 'no response'}');
      _handleTraceWindowComplete(result);
    };

    // Wire trace tracker into UnifiedRxHandler so 0x88 BLE metadata
    // gets stored for the 0x89 handler
    unifiedRxHandler?.traceTracker = tracker;

    // Subscribe to 0x89 TraceData stream for actual trace payloads
    _traceDataSubscription = _connection.traceDataStream.listen((raw) {
      final tt = _traceTracker;
      if (tt != null && tt.isListening) {
        tt.handlePacket(raw, tt.pendingBleSnr, tt.pendingBleRssi);
      }
    });

    // Send first trace immediately
    await _sendTargetedPing();
  }

  /// Stop targeted mode - cleans up tracker and subscription
  void _stopTargetedMode() {
    debugLog('[TRACE] Stopping targeted mode');
    _targetedTimer?.cancel();
    _targetedTimer = null;
    _traceDataSubscription?.cancel();
    _traceDataSubscription = null;
    unifiedRxHandler?.traceTracker = null;
    _traceTracker?.dispose();
    _traceTracker = null;
    _lastTargetedPosition = null;
  }

  /// Send a targeted ping (trace path) and start listening window
  Future<void> _sendTargetedPing() async {
    if (!_autoPingEnabled || !_targetedModeEnabled) {
      debugLog('[TRACE] Not in targeted mode, skipping trace');
      return;
    }

    final targetId = _targetRepeaterId;
    if (targetId == null || targetId.isEmpty) {
      debugLog('[TRACE] No target repeater ID, skipping trace');
      _scheduleNextTargetedPing();
      return;
    }

    // Request a fresh GPS position before the trace (same rationale as TX
    // auto-ping and discovery). On iOS in the background the position stream
    // is quiet, so this is also the only fix that feeds the airborne latch.
    final position = await _gpsService.getFreshPosition();
    if (position == null) {
      debugLog('[TRACE] No GPS position, skipping trace');
      _pingInProgress = false;
      _scheduleNextTargetedPing();
      return;
    }

    // Check minimum distance from last trace (25m)
    final lastPos = _lastTargetedPosition;
    if (lastPos != null) {
      final distance = Geolocator.distanceBetween(
        lastPos.latitude,
        lastPos.longitude,
        position.latitude,
        position.longitude,
      );
      if (distance < _gpsService.configuredMinDistance) {
        debugLog(
            '[TRACE] Too close to last trace (${distance.toStringAsFixed(1)}m < ${_gpsService.configuredMinDistance.toInt()}m), skipping');
        _skipReason = 'too close';
        _pingInProgress = false;
        _scheduleNextTargetedPing();
        return;
      }
    }

    // Clear skip reason since we're proceeding
    _skipReason = null;

    // Signal "Sending..." to UI
    _pingInProgress = true;
    onPingProgressChanged?.call();

    // Capture noise floor
    final noiseFloor = _connection.lastNoiseFloor;
    _pendingTxNoiseFloor = noiseFloor;

    // Create trace log entry immediately
    final traceEntry = TraceLogEntry(
      timestamp: DateTime.now(),
      latitude: position.latitude,
      longitude: position.longitude,
      targetRepeaterId: targetId,
      noiseFloor: noiseFloor,
      success: false, // Will be updated after window completes
    );
    onTracePing?.call(traceEntry);

    debugLog(
        '[TRACE] Sending trace to $targetId at ${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}');

    try {
      // Play transmit sound
      _audioService?.playTransmitSound();

      // Convert hex repeater ID to bytes (trace uses separate byte size: 1, 2, or 4)
      final traceBytes = _traceHopBytes;
      final repeaterIdBytes = Uint8List(traceBytes);
      for (int i = 0; i < traceBytes && i * 2 + 2 <= targetId.length; i++) {
        repeaterIdBytes[i] =
            int.parse(targetId.substring(i * 2, i * 2 + 2), radix: 16);
      }

      // Send trace path and get tag
      final tag = await _connection.sendTracePath(repeaterIdBytes,
          hopBytes: traceBytes);

      // Start tracking with the tag
      _traceTracker?.startTracking(
        tag: tag,
        targetRepeaterId: targetId,
        windowDuration: _rxListeningWindow,
      );

      // Start listening window countdown display
      _discoveryWindowCountdown.start(_rxListeningWindow.inMilliseconds);

      // Clear pingInProgress now that trace window is active
      _pingInProgress = false;

      // Update last targeted position for 25m check
      _lastTargetedPosition = position;

      // Follow with the display anchor so the map's distance readout tracks
      // traces too, not just TX (#501)
      _gpsService.markActivityPosition(position);
    } catch (e) {
      _pingInProgress = false;
      debugError('[TRACE] Failed to send trace: $e');
      if (_pendingDisable) {
        await _executePendingDisable('trace send failed');
        return;
      }
      _scheduleNextTargetedPing();
    }
  }

  /// Handle trace window completion
  Future<void> _handleTraceWindowComplete(TraceResult? result) async {
    _discoveryWindowCountdown.stop();
    final position = _lastTargetedPosition;
    final targetId = _targetRepeaterId ?? '';

    if (result != null && result.success && position != null) {
      debugLog(
          '[TRACE] Trace successful: localSnr=${result.localSnr}, remoteSnr=${result.remoteSnr}');

      // Queue to API (only successful traces)
      _apiQueue.enqueueTrace(
        latitude: position.latitude,
        longitude: position.longitude,
        repeaterId: targetId,
        localSnr: result.localSnr,
        localRssi: result.localRssi,
        remoteSnr: result.remoteSnr,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        externalAntenna: getExternalAntenna?.call() ?? false,
        noiseFloor: _pendingTxNoiseFloor,
        power: getPowerLevel?.call(),
        altitude: GpsService.altitudeOrNull(position),
      );

      // Update stats
      _stats = _stats.copyWith(traceCount: _stats.traceCount + 1);
      onStatsUpdated?.call(_stats);

      // Play receive sound for successful trace
      _audioService?.playReceiveSound();
    } else {
      debugLog('[TRACE] Trace failed: no response from $targetId');
      // Failed traces are NOT posted to API (local visual only)
    }

    // Notify for noise floor graph and log updates
    onTraceWindowComplete?.call(result);

    if (_pendingDisable) {
      await _executePendingDisable('after trace window');
      return;
    }
    _scheduleNextTargetedPing();
  }

  /// Schedule next targeted ping after interval
  void _scheduleNextTargetedPing() {
    if (!_autoPingEnabled || !_targetedModeEnabled) {
      debugLog('[TRACE] Not in targeted mode, not scheduling next trace');
      return;
    }

    _targetedTimer?.cancel();
    _targetedTimer = Timer(Duration(milliseconds: _autoPingIntervalMs), () {
      debugLog('[TRACE] Targeted ping timer fired');
      if (_connection.currentStep != ConnectionStep.connected) {
        debugLog('[TRACE] Not connected, ignoring timer');
        return;
      }
      if (_autoPingEnabled && _targetedModeEnabled) {
        if (_pingInProgress) {
          debugLog('[TRACE] Ping already in progress, skipping');
          return;
        }
        _skipReason = null;
        _sendTargetedPing();
      }
    });

    // Notify callback for countdown display
    onAutoPingScheduled?.call(_autoPingIntervalMs, _skipReason);

    debugLog(
        '[TRACE] Next targeted ping scheduled in ${_autoPingIntervalMs}ms');
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
    _pendingDisableTimeout?.cancel();
    _pendingDisableTimeout = null;
    _stopDiscoveryMode();
    _stopTargetedMode();
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

  /// Cooldown period active (< 5s since last ping)
  cooldownActive,

  /// Manual ping cooldown period active (< 15s since last manual ping)
  manualCooldownActive,

  /// TX not allowed by API (zone at capacity)
  txNotAllowed,

  /// GPS says the phone is in an aircraft (altitude or speed gate)
  airborne,

  /// Smart Pinging: the square already has a recent bidir or disc result
  recentlyCovered,
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
        return 'Move ${PingService.currentMinDistance}m before next ping';
      case PingValidation.cooldownActive:
        return 'Wait 5 seconds between pings';
      case PingValidation.manualCooldownActive:
        return 'Wait 15 seconds between manual pings';
      case PingValidation.txNotAllowed:
        return 'Zone at TX capacity (Passive Only)';
      case PingValidation.airborne:
        return 'Wardriving from an aircraft is not allowed';
      case PingValidation.recentlyCovered:
        return 'Square recently covered, skipped';
    }
  }
}
