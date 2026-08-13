import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter/widgets.dart'
    show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
import 'package:geolocator/geolocator.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams, XFile;

import '../models/connection_state.dart';
import '../models/device_model.dart';
import '../models/noise_floor_session.dart';
import '../models/ping_data.dart';
import '../models/log_entry.dart';
import '../models/remembered_device.dart';
import '../models/repeater.dart';
import '../models/user_preferences.dart';
import '../services/api_queue_service.dart';
import '../utils/mvt_cells.dart';
import '../services/api_service.dart';
import '../services/audio_service.dart';
import '../services/background_service.dart';
import '../services/debug_file_logger.dart';
import '../services/offline_session_service.dart';
import '../services/bluetooth/bluetooth_service.dart';
import '../services/transport/android_serial_service.dart';
import '../services/transport/companion_transport.dart';
import '../services/transport/tcp_service.dart';
import '../services/device_model_service.dart';
import '../services/gps_service.dart';
import '../services/gps_simulator_service.dart';
import '../services/meshcore/channel_service.dart';
import '../services/meshcore/connection.dart';
import '../services/meshcore/crypto_service.dart';
import '../services/meshcore/packet_validator.dart'
    show PacketValidator, ChannelInfo;
import '../services/meshcore/rx_logger.dart';
import '../services/meshcore/tx_tracker.dart';
import '../services/meshcore/unified_rx_handler.dart';
import '../services/ping_service.dart';
import '../services/countdown_timer_service.dart';
import '../services/live_activity/live_activity_models.dart';
import '../services/live_activity/live_activity_service.dart';
import '../services/watch/watch_bridge_service.dart';
import '../services/watch/watch_geo_builder.dart';
import '../services/watch/watch_models.dart';
import '../services/custom_api_service.dart';
import '../utils/constants.dart';
import '../utils/geo_validation.dart';
import '../utils/ping_colors.dart';
import '../services/wakelock_service.dart';
import '../utils/debug_logger_io.dart';

/// Auto-ping mode (matches MeshMapper_WebClient behavior)
enum AutoMode {
  /// Active Mode: Sends pings on movement, listens for RX responses
  active,

  /// Passive Mode: Listening only (no transmit)
  passive,

  /// Hybrid Mode: Alternates Discovery + Active pings each interval
  hybrid,

  /// Trace Mode: Zero-hop trace to specific repeater
  targeted,
}

/// Ping type for the top-heard overlay dots
enum OverlayPingType { tx, disc, trace, rx }

enum _LiveActivityOperation { sending, discovering, tracing }

/// Result of uploading an offline session
enum OfflineUploadResult {
  /// Upload completed successfully
  success,

  /// Session file not found
  notFound,

  /// Session data is invalid or empty
  invalidSession,

  /// API authentication failed (device not registered / genuine rejection)
  authFailed,

  /// Network/timeout error reaching the API (not an auth rejection) — retryable
  networkError,

  /// Some pings failed to upload
  partialFailure,

  /// Another upload is already in progress
  uploadInProgress,

  /// GPS position required but not available
  gpsRequired,

  /// Zone is disabled server-side
  zoneDisabled,
}

/// Main application state provider
class AppStateProvider extends ChangeNotifier with WidgetsBindingObserver {
  // Maximum sizes for in-memory lists to prevent unbounded growth during long sessions
  static const int _maxLogEntries = 500;
  static const int _maxMapPins = 500;
  static const int _maxErrorEntries = 200;

  final BluetoothService _bluetoothService;
  final GpsService _gpsService = GpsService(); // Initialize immediately
  late final ApiService _apiService;
  late final ApiQueueService _apiQueueService;
  late final OfflineSessionService _offlineSessionService;
  late final DeviceModelService _deviceModelService;
  late final CustomApiService _customApiService;
  final AudioService _audioService = AudioService();
  late final CooldownTimer
      _cooldownTimer; // Shared cooldown for TX Ping and Active Mode
  late final ManualPingCooldownTimer
      _manualPingCooldownTimer; // Manual ping cooldown (15 seconds)
  late final AutoPingTimer _autoPingTimer;
  late final RxWindowTimer _rxWindowTimer;
  late final DiscoveryWindowTimer
      _discoveryWindowTimer; // Discovery listening window (Passive Mode)
  late final Listenable _timerListenable;

  final LiveActivityService _liveActivityService = LiveActivityService();
  final WatchBridgeService _watchBridge = WatchBridgeService();

  /// Last position sent to the watch, held until the fix moves far enough to
  /// be worth an update. See [_resolveWatchPosition].
  WatchPosition? _lastWatchPosition;
  WatchHapticCue? _watchCue;

  /// Human-readable failure from the most recent server-side session check.
  /// The bool returned by that check controls the action; this preserves the
  /// discarded explanation for a wrist action's later failure cue.
  String? _lastSessionCheckFailureReason;
  bool _liveActivitySessionActive = false;
  bool _liveActivityManualSession = false;
  String? _liveActivitySessionId;
  DateTime? _liveActivityCycleStartedAt;
  _LiveActivityOperation? _liveActivityOperation;
  MeshCoreConnection? _meshCoreConnection;
  PingService? _pingService;
  UnifiedRxHandler? _unifiedRxHandler;
  TxTracker? _txTracker;
  RxLogger? _rxLogger;
  StreamSubscription? _logRxDataSubscription;
  StreamSubscription? _noiseFloorSubscription;
  StreamSubscription? _batterySubscription;

  // Transport selection
  TransportType _selectedTransport = TransportType.ble;
  CompanionTransport? _activeTransport;
  StreamSubscription? _transportConnectionSubscription;

  // Device identity
  String _deviceId = '';

  // Connection state
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  ConnectionStep _connectionStep = ConnectionStep.disconnected;
  String? _connectionError;
  bool _isAuthError = false; // Track if connection failed due to auth
  bool _isNetworkError = false; // Track if connection failed due to network

  // Bluetooth adapter state (on/off)
  BluetoothAdapterState _bluetoothAdapterState = BluetoothAdapterState.unknown;
  StreamSubscription? _adapterStateSubscription;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _gpsStatusSubscription;
  StreamSubscription? _gpsPositionSubscription;

  // GPS state
  GpsStatus _gpsStatus = GpsStatus.permissionDenied;
  Position? _currentPosition;
  ({double lat, double lon})? _lastKnownPosition;
  DateTime?
      _lastPositionSaveTime; // Throttle position saves to every 30 seconds
  bool _firstGpsLockLogged =
      false; // Track if we've logged first GPS lock message

  // Device info
  DeviceModel? _deviceModel;
  String? _manufacturerString;
  String? _firmwareVersionString;
  String? _devicePublicKey;
  String? _offlineContactUri;

  /// Connected device name (e.g., "MeshCore-MrAlders0n_Elecrow" for BLE, "TCP 10.0.0.1:5000" for TCP)
  String? get connectedDeviceName =>
      (_activeTransport ?? _bluetoothService).connectedDevice?.name;

  /// Display name from SelfInfo (reflects user's chosen name in MeshCore)
  /// BLE advertisement name may be cached/stale after device rename
  String? _displayDeviceName;

  /// The device name to display (prefers SelfInfo name over BLE advertisement name)
  /// SelfInfo name reflects user's chosen name in MeshCore; BLE name may be cached/stale
  String? get displayDeviceName =>
      _displayDeviceName ?? connectedDeviceName?.replaceFirst('MeshCore-', '');

  // Ping state
  PingStats _pingStats = const PingStats();
  bool _autoPingEnabled = false;
  AutoMode _autoMode = AutoMode.active;
  DateTime? _idleAutoStopReference;
  static const Duration _autoStopIdleTimeout = Duration(minutes: 30);
  bool _isPingSending = false; // True immediately when ping button clicked
  bool _autoPingStarting =
      false; // True while an auto mode is starting (before the first notify)
  int _queueSize = 0;
  int? _currentNoiseFloor;
  int? _currentBatteryPercent;

  // Discovered devices
  List<DiscoveredDevice> _discoveredDevices = [];
  bool _isScanning = false;
  StreamSubscription<DiscoveredDevice>? _activeScanSubscription;

  // TX/RX markers for map
  final List<TxPing> _txPings = [];
  final List<RxPing> _rxPings = [];

  // Track which repeaters have pins in current batch (cleared on flush)
  // Prevents duplicate pins within a batch, but allows new pins after flush
  final Set<String> _currentBatchRepeaters = {};

  // TX/RX log entries
  final List<TxLogEntry> _txLogEntries = [];
  final List<RxLogEntry> _rxLogEntries = [];
  final List<DiscLogEntry> _discLogEntries = [];
  final List<TraceLogEntry> _traceLogEntries = [];

  // Top repeaters overlay — updated live on each ping event
  List<({String repeaterId, double snr, OverlayPingType type})>
      _topRepeatersOverlay = [];
  DateTime? _topRepeatersOverlayUpdatedAt;
  ({String repeaterId, double snr})? _rxOverlaySlot;
  Timer? _rxOverlayWindowTimer;

  // Live Activity repeater snapshot. Kept separate from the map overlay so the
  // system presentation cannot change existing in-app overlay behaviour.
  List<({String repeaterId, double snr, OverlayPingType type})>
      _liveActivityRepeaters = [];
  int _liveActivityRepeaterTotalCount = 0;
  DateTime? _liveActivityRepeatersUpdatedAt;
  DateTime? _liveActivityRxUpdatedAt;

  // Targeted mode state
  String? _targetRepeaterId;

  // User error log entries
  final List<UserErrorEntry> _errorLogEntries = [];

  // User preferences
  UserPreferences _preferences = const UserPreferences();

  // Anonymous mode state
  String? _originalDeviceName; // Real name stored before rename
  bool _isAnonymousRenamed = false; // Device currently renamed to "Anonymous"

  /// Per-device real name persistence: maps device public key → real device name.
  /// Survives unexpected BLE disconnects where setAdvertName restore can't run.
  Map<String, String> _deviceRealNames = {};

  /// Per-device antenna preferences: maps companion name → external antenna bool
  Map<String, bool> _deviceAntennaPreferences = {};

  /// Whether the current antenna setting was auto-restored from a saved preference
  bool _antennaRestoredFromDevice = false;
  bool get antennaRestoredFromDevice => _antennaRestoredFromDevice;

  /// Per-device power overrides: maps companion name → {powerLevel, txPower}
  Map<String, Map<String, dynamic>> _devicePowerOverrides = {};

  /// Whether the current power setting was auto-restored from a saved override
  bool _powerRestoredFromDevice = false;
  bool get powerRestoredFromDevice => _powerRestoredFromDevice;

  // Remembered device for quick reconnection (mobile only)
  RememberedDevice? _rememberedDevice;

  // User's original preferences before zone admin overrides (single baseline).
  // Saved on initial connect; restored before applying each new zone's policies.
  int? _userOriginalAutoPingInterval;
  bool? _userOriginalHybridMode;
  bool? _userOriginalDiscDrop;
  bool? _userOriginalFloodTraffic;

  // Debug logs state (non-persistent, always starts false)
  bool _debugLogsEnabled = false;
  List<File> _debugLogFiles = [];
  String? _viewingLogContent;

  // Last connected device info (persistent, for bug reports)
  String? _lastConnectedDeviceName;
  String? _lastConnectedPublicKey;

  // Zone state for geo-auth
  bool? _inZone; // null = not checked yet, true/false = checked
  Map<String, dynamic>? _currentZone; // Zone info when inZone == true
  Map<String, dynamic>? _nearestZone; // Nearest zone info when inZone == false
  Position? _lastZoneCheckPosition;
  bool _isCheckingZone = false;

  // Zone check retry state
  String?
      _zoneCheckError; // Error message from last failed check (null = no error)
  String?
      _zoneCheckErrorReason; // 'network', 'gps_inaccurate', 'gps_stale', 'server_error'
  int _zoneCheckRetryCountdown =
      0; // Seconds until next retry (0 = not counting)
  Timer? _zoneCheckRetryTimer; // Fires to trigger the retry
  Timer? _zoneCheckCountdownTimer; // Ticks every 1s for UI countdown

  // Maintenance mode state
  bool _maintenanceMode = false;
  String? _maintenanceMessage;
  String? _maintenanceUrl;
  Timer? _maintenanceCheckTimer;

  // Post-wardrive tile refresh: coords of recently uploaded pings (with the
  // zone they belong to) and the +7s fresh-fetch timer (one retry at +10s).
  // See VECTOR_TILES.md "Flutter post-wardrive live refresh".
  Timer? _vectorFreshTimer;
  final List<List<double>> _pendingFreshCoords = []; // [lat, lon]
  String? _pendingFreshZone;
  bool _vectorOverlayActive = false;

  // Session coverage patch: the user's own freshly-pinged cells, drawn by the
  // MapWidget as a small GeoJSON layer ON TOP of the base overlay (whose
  // copies of these ids are filtered out, so translucent fills never stack).
  // The base source is never swapped/cache-busted during a session — nothing
  // may visibly change except the cells that actually changed. Keyed by
  // feature id, insertion-ordered, capped.
  final Map<int, CoverageCell> _coveragePatchCells = {};
  int _coveragePatchVersion = 0;

  // Auth type from API response (API, Mesh, Manual)
  String? _authType;

  // Mode switching state (for hot-switching offline/online while connected)
  bool _isSwitchingMode = false;
  String? _modeSwitchError; // Error message if mode switch fails

  // Connection guard — prevents concurrent connect attempts and provides instant UI feedback
  bool _isConnecting = false;

  // Auto-reconnect state
  bool _userRequestedDisconnect = false;
  bool _isAutoReconnecting = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  Timer? _reconnectTimeoutTimer;
  Timer? _restoreAutoPingTimer;
  Timer? _offlineAutoSaveTimer;
  Timer? _zoneRefreshTimer;
  bool _autoPingWasEnabled = false;
  AutoMode _autoModeBeforeReconnect = AutoMode.active;
  int _reconnectRestoreGeneration = 0;
  static const int _maxReconnectAttempts = 3;
  static const Duration _reconnectDelay = Duration(seconds: 3);
  static const Duration _reconnectDelayAfterBondError = Duration(seconds: 5);
  bool _lastReconnectWasBondError = false;

  // Idle disconnect timer — disconnects after 15 min without manual ping or auto-ping
  Timer? _idleDisconnectTimer;
  static const Duration _idleDisconnectTimeout = Duration(minutes: 15);

  // Zone grace period — pauses wardriving when outside_zone, resumes on zone re-entry
  bool _isInZoneGracePeriod = false;
  Timer? _zoneGraceTimer; // 5-minute overall timeout
  Timer? _zoneGracePollingTimer; // 5-second zone polling
  Timer? _zoneGraceCountdownTimer; // 1-second UI countdown tick
  int _zoneGraceSecondsRemaining = 0;
  DateTime? _zoneGraceEndsAt;
  bool _autoPingWasEnabledBeforeGrace = false;
  AutoMode _autoModeBeforeGrace = AutoMode.active;
  static const Duration _zoneGraceTimeout = Duration(minutes: 5);

  // Zone transfer state — tracks session zone for zone-to-zone detection
  String? _sessionZoneCode;
  bool _isZoneTransferInProgress = false;
  String? _zoneTransferFrom;
  String? _zoneTransferTo;

  // Geofence zone check log throttle (while disconnected)
  DateTime? _lastZoneCheckLogTime;
  int _zoneCheckSuppressedCount = 0;

  // Map navigation trigger (for navigating to log entry coordinates)
  ({double lat, double lon})? _mapNavigationTarget;
  int _mapNavigationTrigger = 0; // Increment to trigger navigation
  bool _requestMapTabSwitch = false; // Request switch to map tab
  bool _requestErrorLogSwitch = false; // Request switch to error log tab
  bool _isAnonymousReconnectInProgress = false;
  bool _anonymousReconnectEnabling = true;

  // Repeater markers state
  List<Repeater> _repeaters = [];
  bool _repeatersLoaded = false;
  String? _repeatersLoadedForIata;

  // Regional boundary polygons (from /border API — always displayed on map)
  List<Map<String, dynamic>> _regionBorders = [];
  String? _bordersLoadedForZone;
  bool _bordersFetchInProgress = false;

  // Regional channels from API (for UI display)
  List<String> _regionalChannels = [];

  // Regional scope from API (for UI display and flood filtering)
  String? _scope;

  // Path hash mode tracking (for multi-byte path support)
  int?
      _originalPathHashMode; // Device's mode BEFORE we changed it (from DeviceInfo)
  bool _userChangedPathMode =
      false; // True if user manually changed hopBytes while connected
  int _hopBytes =
      1; // Runtime-only: current hop byte size (read from device, not persisted)
  int _traceHopBytes =
      1; // Runtime-only: trace byte size (1, 2, or 4 — bitshift encoding)

  // Noise floor session tracking (for graph feature)
  NoiseFloorSession? _currentNoiseFloorSession;
  List<NoiseFloorSession> _storedNoiseFloorSessions = [];
  Box<NoiseFloorSession>? _noiseFloorSessionBox;

  // History session map view
  List<PingEventMarker>? _historySessionMarkers;
  bool _viewingHistorySession = false;

  // Flag to track if preferences have been loaded from storage
  bool _preferencesLoaded = false;

  // Disposed flag to prevent operations after disposal
  bool _isDisposed = false;

  AppStateProvider({required BluetoothService bluetoothService})
      : _bluetoothService = bluetoothService {
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugLog('[APP] App resumed from background');
      _checkTcpHealthAfterResume();
      // Diagnostic: timers can be suspended while backgrounded; on resume, log
      // any countdown timer stuck past its deadline (intermittent ping lockout).
      _logStuckTimers('resume');
    } else if (state == AppLifecycleState.paused) {
      debugLog('[APP] App paused (backgrounded)');
      // Save offline pings immediately on pause to prevent data loss if OS kills app
      if (_preferences.offlineMode && _apiQueueService.offlinePingCount > 0) {
        _autoSaveOfflinePings();
      }
    }
  }

  /// Probe TCP connection after iOS resume — socket may have died while suspended.
  Future<void> _checkTcpHealthAfterResume() async {
    if (_selectedTransport != TransportType.tcp) return;
    if (_connectionStep != ConnectionStep.connected) return;
    if (_isAutoReconnecting || _userRequestedDisconnect) return;

    // Let pending socket error/done events propagate first
    await Future.delayed(const Duration(milliseconds: 1500));

    // If socket events already triggered auto-reconnect, nothing to do
    if (_connectionStep != ConnectionStep.connected) return;
    if (_isAutoReconnecting) return;

    debugLog('[CONN] Probing TCP connection after resume');
    try {
      await _meshCoreConnection!.getNoiseFloor();
      debugLog('[CONN] TCP connection healthy after resume');
    } catch (e) {
      debugLog('[CONN] TCP probe failed after resume: $e');
      if (_connectionStep == ConnectionStep.connected &&
          !_isAutoReconnecting &&
          _rememberedDevice != null &&
          !_userRequestedDisconnect) {
        await _startAutoReconnect();
      }
    }
  }

  // Throttle for the stuck-timer diagnostic (driven off the ~1-2Hz GPS notify).
  DateTime? _lastStuckTimerCheck;

  /// Diagnostic ONLY (no state change, no notify): logs any countdown timer that
  /// still reports `isRunning` after its deadline has passed (`remainingMs == 0`).
  /// That is the fingerprint of the intermittent "Send Ping locks out
  /// Hybrid/Passive" lockout — a [CountdownTimerService] whose 500ms `_update()`
  /// stopped firing (e.g. iOS suspended its timers while backgrounded/driving)
  /// never self-cancels, so `isRunning` (`_timer != null`) sticks true and keeps
  /// the ping controls disabled until a force-close. A stuck `rxWindowTimer`
  /// additionally disables Send Ping itself, so the user can't ping to reset it.
  /// This logging is here to capture the real trigger on-device; the actual fix
  /// is deferred until a debug log confirms it. See countdown_timer_service.dart.
  void _logStuckTimers(String reason) {
    void check(String name, CountdownTimerService t) {
      if (t.isRunning && t.remainingMs == 0) {
        debugWarn(
            '[TIMER] $name isRunning past its deadline (stuck, remaining=0) — '
            'locks ping controls until restart [$reason]');
      }
    }

    check('rxWindowTimer', _rxWindowTimer);
    check('cooldownTimer', _cooldownTimer);
    check('manualPingCooldownTimer', _manualPingCooldownTimer);
    check('discoveryWindowTimer', _discoveryWindowTimer);
    check('autoPingTimer', _autoPingTimer);

    // pendingDisable should clear when the RX/discovery window it is waiting on
    // completes. Still true while no such window is counting down => stuck.
    if (isPendingDisable &&
        !_rxWindowTimer.isRunning &&
        !_discoveryWindowTimer.isRunning) {
      debugWarn(
          '[TIMER] pendingDisable stuck true with no RX/discovery window '
          'running — locks ping controls until restart [$reason]');
    }
  }

  /// Runs [_logStuckTimers] at most once every 5s. Called from the GPS position
  /// notify (~1-2Hz during wardriving) so the stuck condition is caught in the
  /// foreground without adding a dedicated timer. Connected-only to avoid noise.
  void _maybeLogStuckTimers() {
    if (!isConnected) return;
    final now = DateTime.now();
    final last = _lastStuckTimerCheck;
    if (last != null && now.difference(last).inSeconds < 5) return;
    _lastStuckTimerCheck = now;
    _logStuckTimers('watchdog');
  }

  // ============================================
  // Getters
  // ============================================

  String get deviceId => _deviceId;
  bool get preferencesLoaded => _preferencesLoaded;
  TransportType get selectedTransport => _selectedTransport;
  ConnectionStatus get connectionStatus => _connectionStatus;
  ConnectionStep get connectionStep => _connectionStep;
  String? get connectionError => _connectionError;
  bool get isAuthError => _isAuthError;
  bool get isNetworkError => _isNetworkError;
  BluetoothAdapterState get bluetoothAdapterState => _bluetoothAdapterState;
  bool get isBluetoothOn => _bluetoothAdapterState == BluetoothAdapterState.on;
  bool get isBluetoothOff =>
      _bluetoothAdapterState == BluetoothAdapterState.off;
  GpsStatus get gpsStatus => _gpsStatus;
  Position? get currentPosition => _currentPosition;
  ({double lat, double lon})? get lastKnownPosition => _lastKnownPosition;
  DeviceModel? get deviceModel => _deviceModel;
  String? get manufacturerString => _manufacturerString;
  String? get firmwareVersionString => _firmwareVersionString;

  /// Human-readable radio config from the connected device's SelfInfo
  /// (e.g. "910.525 MHz · 62.5 kHz · SF7 · CR5"); null on older firmware/no device.
  String? get radioConfigDisplay =>
      _meshCoreConnection?.selfInfo?.radioConfigDisplay;
  String? get devicePublicKey => _devicePublicKey;
  PingStats get pingStats => _pingStats;
  bool get autoPingEnabled => _autoPingEnabled;
  AutoMode get autoMode => _autoMode;
  bool get isPingSending => _isPingSending;
  bool get isAutoPingStarting => _autoPingStarting;
  bool get isPingInProgress =>
      _pingService?.pingInProgress ??
      false; // True during entire ping + RX window (for auto pings)
  bool get isDiscoveryListening =>
      _pingService?.isDiscoveryListening ??
      false; // True during discovery listening window (for Passive Mode)
  /// Check if auto-ping disable is pending (waiting for RX window)
  bool get isPendingDisable => _pingService?.pendingDisable ?? false;

  /// True when running any mode that does TX (Active or Hybrid)
  bool get isTxModeRunning =>
      _autoPingEnabled &&
      (_autoMode == AutoMode.active || _autoMode == AutoMode.hybrid);

  /// True when running Trace Mode (zero-hop trace)
  bool get isTargetedModeRunning =>
      _autoPingEnabled && _autoMode == AutoMode.targeted;
  String? get targetRepeaterId => _targetRepeaterId;
  int get queueSize => _queueSize;
  int? get currentNoiseFloor => _currentNoiseFloor;
  int? get currentBatteryPercent => _currentBatteryPercent;
  List<DiscoveredDevice> get discoveredDevices => _discoveredDevices;
  bool get isScanning => _isScanning;
  List<TxPing> get txPings => List.unmodifiable(_txPings);
  List<RxPing> get rxPings => List.unmodifiable(_rxPings);

  /// Top 3 repeaters by best SNR from TX/DISC/Trace pings
  List<({String repeaterId, double snr, OverlayPingType type})>
      get topRepeatersBySnr => _topRepeatersOverlay;

  /// Best RX observation in the current 5-second window
  ({String repeaterId, double snr})? get rxOverlaySlot => _rxOverlaySlot;

  /// Update the top repeaters overlay with results from the latest TX/DISC/Trace ping.
  /// Replaces all 3 slots entirely (no carryover from previous pings).
  void _updateTopRepeaters(
      List<({String repeaterId, double snr})> current, OverlayPingType type) {
    final bestSnr = <String, double>{};
    for (final r in current) {
      final key = r.repeaterId.toUpperCase();
      if (!bestSnr.containsKey(key) || r.snr > bestSnr[key]!) {
        bestSnr[key] = r.snr;
      }
    }
    final fresh = bestSnr.entries
        .map((e) => (repeaterId: e.key, snr: e.value, type: type))
        .toList()
      ..sort((a, b) => b.snr.compareTo(a.snr));
    _topRepeatersOverlay = fresh.take(3).toList();
    _topRepeatersOverlayUpdatedAt = DateTime.now();
  }

  void _updateLiveActivityRepeaters(
      Iterable<({String repeaterId, double snr})> current,
      OverlayPingType type) {
    final bestSnr = <String, double>{};
    for (final repeater in current) {
      if (!repeater.snr.isFinite) continue;
      final id = repeater.repeaterId.toUpperCase();
      final previous = bestSnr[id];
      if (previous == null || repeater.snr > previous) {
        bestSnr[id] = repeater.snr;
      }
    }

    final sorted = bestSnr.entries
        .map((entry) =>
            (repeaterId: entry.key, snr: entry.value, type: type))
        .toList()
      ..sort((a, b) => b.snr.compareTo(a.snr));
    _liveActivityRepeaters = sorted.take(3).toList(growable: false);
    _liveActivityRepeaterTotalCount = sorted.length;
    _liveActivityRepeatersUpdatedAt = DateTime.now();
  }

  /// Update the RX overlay slot — window matches auto-ping interval (best SNR wins).
  void _updateRxOverlaySlot(String repeaterId, double snr) {
    final entry = (repeaterId: repeaterId.toUpperCase(), snr: snr);
    if (_rxOverlayWindowTimer?.isActive ?? false) {
      if (_rxOverlaySlot == null || snr > _rxOverlaySlot!.snr) {
        _rxOverlaySlot = entry;
        _liveActivityRxUpdatedAt = DateTime.now();
      }
    } else {
      _rxOverlaySlot = entry;
      _liveActivityRxUpdatedAt = DateTime.now();
      _rxOverlayWindowTimer =
          Timer(Duration(seconds: _preferences.autoPingInterval), () {
        // Window closed — slot stays until next RX or cleared
      });
    }
  }

  /// Clear all overlay state (top 3 + RX slot).
  void _clearOverlayState() {
    _topRepeatersOverlay = [];
    _topRepeatersOverlayUpdatedAt = null;
    _rxOverlaySlot = null;
    _rxOverlayWindowTimer?.cancel();
    _rxOverlayWindowTimer = null;
    _liveActivityRepeaters = [];
    _liveActivityRepeaterTotalCount = 0;
    _liveActivityRepeatersUpdatedAt = null;
    _liveActivityRxUpdatedAt = null;
  }

  List<TxLogEntry> get txLogEntries => List.unmodifiable(_txLogEntries);
  List<RxLogEntry> get rxLogEntries => List.unmodifiable(_rxLogEntries);
  List<DiscLogEntry> get discLogEntries => List.unmodifiable(_discLogEntries);
  List<TraceLogEntry> get traceLogEntries =>
      List.unmodifiable(_traceLogEntries);
  List<UserErrorEntry> get errorLogEntries =>
      List.unmodifiable(_errorLogEntries);
  List<UnifiedPingLogEntry> get unifiedPingLogEntries {
    final merged = <UnifiedPingLogEntry>[
      ..._txLogEntries.map((e) => UnifiedPingLogEntry(
          type: PingLogType.tx, timestamp: e.timestamp, entry: e)),
      ..._rxLogEntries.map((e) => UnifiedPingLogEntry(
          type: PingLogType.rx, timestamp: e.timestamp, entry: e)),
      ..._discLogEntries.map((e) => UnifiedPingLogEntry(
          type: PingLogType.disc, timestamp: e.timestamp, entry: e)),
      ..._traceLogEntries.map((e) => UnifiedPingLogEntry(
          type: PingLogType.trace, timestamp: e.timestamp, entry: e)),
    ];
    merged.sort();
    return merged;
  }

  ({double lat, double lon})? get mapNavigationTarget => _mapNavigationTarget;
  int get mapNavigationTrigger => _mapNavigationTrigger;
  bool get requestMapTabSwitch => _requestMapTabSwitch;
  bool get requestErrorLogSwitch => _requestErrorLogSwitch;
  bool get isAnonymousReconnectInProgress => _isAnonymousReconnectInProgress;
  bool get anonymousReconnectEnabling => _anonymousReconnectEnabling;
  UserPreferences get preferences => _preferences;
  RememberedDevice? get rememberedDevice => _rememberedDevice;

  // Debug logs getters
  bool get debugLogsEnabled => _debugLogsEnabled;
  List<File> get debugLogFiles => List.unmodifiable(_debugLogFiles);
  String? get viewingLogContent => _viewingLogContent;

  // Last connected device info getters (persistent, for bug reports)
  String? get lastConnectedDeviceName => _lastConnectedDeviceName;
  String? get lastConnectedPublicKey => _lastConnectedPublicKey;

  // Zone state getters
  bool? get inZone => _inZone;
  Map<String, dynamic>? get currentZone => _currentZone;
  Map<String, dynamic>? get nearestZone => _nearestZone;
  bool get isCheckingZone => _isCheckingZone;
  String? get zoneName => _currentZone?['name'] as String?;
  String? get zoneCode => _currentZone?['code'] as String?;

  /// MapWidget handshake: whether the coverage overlay is currently on the
  /// map. Gates the post-wardrive fresh-tile flow — no overlay, no fetches.
  void reportVectorOverlayActive(bool active) {
    _vectorOverlayActive = active;
  }

  /// Bumped whenever the session coverage patch changes; the MapWidget
  /// watches it and re-applies the patch GeoJSON + base-layer filter.
  int get coveragePatchVersion => _coveragePatchVersion;

  /// The user's own freshly-pinged cells (feature id -> cell), authoritative
  /// server state decoded from the fresh z14 tiles.
  Map<int, CoverageCell> get coveragePatchCells => _coveragePatchCells;

  /// Drop the session patch — the cells belong to one region + grid preset
  /// (called on zone change and when the Grid Mode preference changes).
  void clearCoveragePatch() {
    _coveragePatchCells.clear();
    _coveragePatchVersion++;
  }

  /// Post-wardrive live refresh: have the server re-render (`fresh=1`) the
  /// tiles around the uploaded ping coords at z11-14, then patch the user's
  /// own cells onto the map from the fresh z14 bodies (the base overlay is
  /// never swapped — see _coveragePatchCells). z8-10 are skipped: a single
  /// ping is sub-pixel there and those whole-region renders are the expensive
  /// ones; they ride the server's longer TTL. Zooms above 14 overzoom from
  /// the z14 tile. attempt 1 fires +7s after upload; attempt 2 (+10s) runs
  /// only when attempt 1 saw no changed tiles (ingestion can lag the post).
  Future<void> _freshenAffectedVectorTiles({required int attempt}) async {
    final zone = zoneCode;
    if (zone == null ||
        zone != _pendingFreshZone ||
        _pendingFreshCoords.isEmpty) {
      // Zone changed since the coords were queued: they belong to the OLD
      // region's grid — freshening them against the new region's server
      // would be pure wasted renders.
      _pendingFreshCoords.clear();
      return;
    }
    // Snapshot: a new upload can append (and re-schedule the timer) while the
    // fetches below are in flight; only this snapshot is processed and only
    // it gets removed afterwards, so late arrivals keep their refresh.
    final coords = List<List<double>>.from(_pendingFreshCoords);

    // A ping's influence is wider than its own cell: blob dilation and cells
    // straddling a tile border are emitted in the NEIGHBOURING tile too (the
    // server pads its tile queries by ~0.005°). Freshen every tile within
    // that margin of the ping, or the spilled part of a cell stays stale in
    // the next tile over.
    const pad = 0.005;
    final tiles = <String, List<int>>{}; // 'z/x/y' -> [z, x, y]
    var capped = false;
    for (final c in coords) {
      for (var z = 11; z <= 14 && !capped; z++) {
        final n = 1 << z;
        int lonToX(double lon) {
          final x = (((lon + 180.0) / 360.0) * n).floor();
          return x < 0 ? 0 : (x >= n ? n - 1 : x);
        }
        int latToY(double lat) {
          final latRad = lat * math.pi / 180.0;
          final sinhArg = math.tan(latRad);
          final asinh = math.log(sinhArg + math.sqrt(sinhArg * sinhArg + 1));
          final y = ((1.0 - asinh / math.pi) / 2.0 * n).floor();
          return y < 0 ? 0 : (y >= n ? n - 1 : y);
        }

        // Containing tile plus any neighbour the pad reaches into (≤4 per z).
        for (final xt in {lonToX(c[1] - pad), lonToX(c[1] + pad)}) {
          for (final yt in {latToY(c[0] + pad), latToY(c[0] - pad)}) {
            if (tiles.length >= 56) {
              capped = true;
              break;
            }
            tiles['$z/$xt/$yt'] = [z, xt, yt];
          }
        }
      }
      if (capped) break;
    }
    if (capped) {
      debugLog('[COVERAGE] Fresh-tile fan-out capped at 56 tiles this batch');
    }

    debugLog(
        '[COVERAGE] Fresh-tile check (attempt $attempt): ${tiles.length} tiles for ${coords.length} ping(s), z11-14 incl. spill neighbours');
    // Throttled to 4 concurrent renders: a full-burst Future.wait can pile up
    // PHP workers and SQLite lock contention on the shared region host (each
    // fresh=1 is a live render racing the wardrive INSERT). The whole batch
    // still completes in a second or two.
    final entries = tiles.entries.toList();
    final z14Bodies = <Uint8List>[];
    var anyChanged = false;
    for (var i = 0; i < entries.length; i += 4) {
      final chunk = entries.sublist(i, math.min(i + 4, entries.length));
      await Future.wait(chunk.map((e) async {
        final result = await _apiService.freshenVectorTile(
            zone: zone,
            z: e.value[0],
            x: e.value[1],
            y: e.value[2],
            gsize: _preferences.coverageGridSize);
        if (result.changed == true) {
          anyChanged = true;
          debugLog('[COVERAGE] Retrieved new tile ${e.key}');
        } else if (result.changed == false) {
          debugLog('[COVERAGE] No new tile ${e.key} (unchanged)');
        } else {
          debugLog('[COVERAGE] Tile ${e.key} fresh check failed');
        }
        if (e.value[0] == 14 && result.body != null) {
          z14Bodies.add(result.body!);
        }
      }));
      if (_isDisposed) return;
    }

    // Patch ONLY the user's own cells onto the map. The base overlay is never
    // swapped — the fresh renders above keep the SERVER cache hot (other
    // viewers + MapLibre's own tile revalidation pick them up); the cells the
    // user is watching update instantly through the patch layer.
    final patched = _extractOwnCells(coords, z14Bodies);
    if (patched.isNotEmpty) {
      for (final cell in patched) {
        _coveragePatchCells.remove(cell.id); // re-insert: newest-last ordering
        _coveragePatchCells[cell.id] = cell;
      }
      while (_coveragePatchCells.length > 5000) {
        _coveragePatchCells.remove(_coveragePatchCells.keys.first);
      }
      _coveragePatchVersion++;
      // Status histogram of the patched cells (st = server-rendered status category),
      // so a debug log carries hard proof of what the server actually rendered for the
      // user's own pings (e.g. st={1:3,2:5}) — see the "tiles not green is server-side" note.
      final stHist = <int, int>{};
      for (final cell in patched) {
        stHist[cell.st] = (stHist[cell.st] ?? 0) + 1;
      }
      final stSummary = (stHist.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)))
          .map((e) => '${e.key}:${e.value}')
          .join(',');
      debugLog(
          '[COVERAGE] Patched ${patched.length} cell(s) at your position onto the overlay (attempt $attempt) st={$stSummary}');
      notifyListeners();
    } else {
      debugLog(
          '[COVERAGE] No cells for your position in the fresh tiles yet (attempt $attempt)');
    }

    if (attempt < 2 && !anyChanged) {
      // Re-check at +10s only when the first sweep came back unchanged —
      // ingestion can lag a few seconds behind the post. An ACTIVE timer here
      // belongs to a newer upload (it re-armed the +7s timer while this run's
      // fetches were in flight); let it own the next sweep — overwriting it
      // would sweep the new batch seconds too early.
      if (!(_vectorFreshTimer?.isActive ?? false)) {
        debugLog('[COVERAGE] No changes yet — second fresh-tile check at +10s');
        _vectorFreshTimer = Timer(const Duration(seconds: 3), () {
          _freshenAffectedVectorTiles(attempt: 2);
        });
      }
    } else {
      _pendingFreshCoords.removeRange(
          0, math.min(coords.length, _pendingFreshCoords.length));
    }
  }

  /// The cells this batch of pings actually touches — the ping's own cell
  /// plus its blob reach (Detailed dilates 3×3) — looked up by grid index in
  /// the freshly rendered z14 tiles so the patch carries the SERVER-resolved
  /// status (priority merge with whatever was already in the cell).
  List<CoverageCell> _extractOwnCells(
      List<List<double>> coords, List<Uint8List> bodies) {
    if (bodies.isEmpty) return const [];
    final steps = kCoverageGridSteps[_preferences.coverageGridSize];
    if (steps == null) return const [];
    final reach = _preferences.coverageGridSize == 100 ? 1 : 0;
    final wanted = <String>{};
    for (final c in coords) {
      final ci = (c[0] / steps[0]).floor();
      final cj = (c[1] / steps[1]).floor();
      for (var di = -reach; di <= reach; di++) {
        for (var dj = -reach; dj <= reach; dj++) {
          wanted.add('${ci + di}_${cj + dj}');
        }
      }
    }
    final out = <CoverageCell>[];
    final seen = <int>{};
    for (final body in bodies) {
      for (final cell in decodeCoverageCells(body)) {
        if (wanted.contains('${cell.i}_${cell.j}') && seen.add(cell.id)) {
          out.add(cell);
        }
      }
    }
    return out;
  }

  int? get zoneSlotsAvailable => _currentZone?['slots_available'] as int?;
  int? get zoneSlotsMax => _currentZone?['slots_max'] as int?;
  String? get nearestZoneName => _nearestZone?['name'] as String?;
  String? get nearestZoneCode => _nearestZone?['code'] as String?;
  double? get nearestZoneDistanceKm =>
      (_nearestZone?['distance_km'] as num?)?.toDouble();

  // Zone check retry getters
  String? get zoneCheckError => _zoneCheckError;
  String? get zoneCheckErrorReason => _zoneCheckErrorReason;
  int get zoneCheckRetryCountdown => _zoneCheckRetryCountdown;

  // Maintenance mode getters
  bool get maintenanceMode => _maintenanceMode;
  String? get maintenanceMessage => _maintenanceMessage;
  String? get maintenanceUrl => _maintenanceUrl;

  // Auth type getter (API, Mesh, Manual)
  String? get authType => _authType;

  // Mode switching getters
  bool get isSwitchingMode => _isSwitchingMode;
  String? get modeSwitchError => _modeSwitchError;

  // Anonymous mode getter
  bool get isAnonymousRenamed => _isAnonymousRenamed;

  // Connection guard getter
  bool get isConnecting => _isConnecting;

  // Auto-reconnect getters
  bool get isAutoReconnecting => _isAutoReconnecting;
  int get reconnectAttempt => _reconnectAttempt;

  // Zone grace period getters
  bool get isInZoneGracePeriod => _isInZoneGracePeriod;
  int get zoneGraceSecondsRemaining => _zoneGraceSecondsRemaining;
  String get zoneGraceCountdownFormatted =>
      '${(_zoneGraceSecondsRemaining ~/ 60).toString().padLeft(2, '0')}:'
      '${(_zoneGraceSecondsRemaining % 60).toString().padLeft(2, '0')}';

  // Zone transfer getters
  bool get isZoneTransferInProgress => _isZoneTransferInProgress;
  String? get zoneTransferFrom => _zoneTransferFrom;
  String? get zoneTransferTo => _zoneTransferTo;

  // Focus mode (map ping detail sheet active)
  bool _isFocusModeActive = false;
  bool get isFocusModeActive => _isFocusModeActive;
  set isFocusModeActive(bool value) {
    if (_isFocusModeActive != value) {
      _isFocusModeActive = value;
      notifyListeners();
    }
  }

  // A cell-summary / repeater-detail popup is minimized to a bottom pill — hide
  // the control panel and zero the map's bottom padding for it, like focus mode.
  bool _infoPopupMinimized = false;
  bool get infoPopupMinimized => _infoPopupMinimized;
  set infoPopupMinimized(bool value) {
    if (_infoPopupMinimized != value) {
      _infoPopupMinimized = value;
      notifyListeners();
    }
  }

  // Repeater markers getters
  List<Repeater> get repeaters => List.unmodifiable(_repeaters);

  /// Lazy tap-to-inspect: fetch raw coverage points for a clicked map cell from
  /// the current zone's app endpoint. Returns `[]` when there is no zone or on
  /// failure. The caller aggregates these into a GRID SUMMARY (read-only — no
  /// state mutation, so no `notifyListeners`).
  Future<List<Map<String, dynamic>>> fetchCellCoverage({
    required double lat,
    required double lon,
    required double radiusMeters,
  }) {
    final zone = zoneCode;
    if (zone == null || zone.isEmpty) {
      return Future.value(const <Map<String, dynamic>>[]);
    }
    return _apiService.fetchMapData(
      zone: zone,
      lat: lat,
      lon: lon,
      radiusMeters: radiusMeters,
    );
  }

  /// Lazy tap-to-inspect: fetch the coverage points referencing a repeater
  /// (hex-prefix superset) from the current zone's app endpoint. Returns `[]`
  /// when there is no zone or on failure. The caller aggregates these into the
  /// repeater's BIDIR/TX/RX/DISC/DEAD totals + max range.
  Future<List<Map<String, dynamic>>> fetchRepeaterCoveragePoints({
    required String prefix,
  }) {
    final zone = zoneCode;
    if (zone == null || zone.isEmpty) {
      return Future.value(const <Map<String, dynamic>>[]);
    }
    return _apiService.fetchRepeaterCoverage(zone: zone, prefix: prefix);
  }

  /// Regional boundary polygons loaded from the /border API.
  /// Each entry is a `{code: String, polygon: List<List<num>>}` map where
  /// `polygon` holds `[lat, lon]` pairs in the server's original order.
  List<Map<String, dynamic>> get regionBorders =>
      List.unmodifiable(_regionBorders);

  // Regional channels getter (for UI)
  List<String> get regionalChannels => List.unmodifiable(_regionalChannels);

  // Regional scope getter (for UI)
  String? get scope => _scope;

  // Noise floor session getters
  NoiseFloorSession? get currentNoiseFloorSession => _currentNoiseFloorSession;
  List<NoiseFloorSession> get storedNoiseFloorSessions =>
      List.unmodifiable(_storedNoiseFloorSessions);

  // History session map view getters
  List<PingEventMarker>? get historySessionMarkers => _historySessionMarkers;
  bool get viewingHistorySession => _viewingHistorySession;

  // Audio service getters
  bool get isSoundEnabled => _audioService.isEnabled;
  bool get isTxSoundEnabled => _audioService.isTxEnabled;
  bool get isRxSoundEnabled => _audioService.isRxEnabled;
  bool get isDisconnectAlertEnabled => _preferences.disconnectAlertEnabled;
  AudioService get audioService => _audioService;

  bool get isConnected => _connectionStep == ConnectionStep.connected;
  bool get hasGpsLock => _gpsStatus == GpsStatus.locked;
  bool get canPing => isConnected && hasGpsLock;

  // API session permissions (from geo-auth)
  bool get txAllowed => _apiService.txAllowed;
  bool get rxAllowed => _apiService.rxAllowed;
  bool get hasApiSession => _apiService.hasSession;
  bool get isApiRxOnlyMode => hasApiSession && !txAllowed && rxAllowed;
  bool get enforceHybrid => _apiService.enforceHybrid;
  bool get enforceDiscDrop => _apiService.enforceDiscDrop;
  bool get discDropEnabled =>
      _preferences.discDropEnabled || _apiService.enforceDiscDrop;

  /// Whether the current region forbids flood traffic (region override).
  bool get floodDisabled => _apiService.floodDisabled;

  /// Effective flood-traffic visibility: region veto wins over user pref.
  bool get floodTrafficEnabled =>
      !_apiService.floodDisabled && _preferences.floodTrafficEnabled;

  /// One-shot flag: true when the user had flood traffic enabled and the
  /// region forced it off on auth/zone-change. UI shows a dialog, then calls
  /// [clearFloodDisabledAlert].
  bool _floodDisabledAlertPending = false;
  bool get floodDisabledAlertPending => _floodDisabledAlertPending;
  void clearFloodDisabledAlert() {
    if (!_floodDisabledAlertPending) return;
    _floodDisabledAlertPending = false;
    notifyListeners();
  }
  int get minModeInterval => _apiService.minModeInterval;
  bool get enforceHopBytes => _apiService.enforceHopBytes;
  int get hopBytes => _hopBytes;
  int get effectiveHopBytes =>
      enforceHopBytes ? _apiService.apiHopBytes : _hopBytes;
  int get traceHopBytes => _traceHopBytes;
  bool get supportsMultiBytePaths => _originalPathHashMode != null;

  // Offline mode
  bool get offlineMode => _preferences.offlineMode;
  List<OfflineSession> get offlineSessions => _offlineSessionService.sessions;
  bool _isUploadingOfflineSession = false;
  bool get isUploadingOfflineSession => _isUploadingOfflineSession;

  // Developer mode
  bool get developerModeEnabled => _preferences.developerModeEnabled;
  int get offlinePingCount => _apiQueueService.offlinePingCount;
  OfflineSessionService get offlineSessionService => _offlineSessionService;

  /// Distance in meters from last TX ping position (like wardrive.js)
  double? get distanceFromLastPing {
    if (_currentPosition == null) return null;
    final dist = _gpsService.distanceFromLastPing(_currentPosition!);
    return dist == double.infinity ? null : dist;
  }

  // Countdown timers
  CooldownTimer get cooldownTimer =>
      _cooldownTimer; // Shared cooldown for TX Ping and Active Mode
  ManualPingCooldownTimer get manualPingCooldownTimer =>
      _manualPingCooldownTimer; // Manual ping cooldown (15 seconds)
  AutoPingTimer get autoPingTimer => _autoPingTimer;
  RxWindowTimer get rxWindowTimer => _rxWindowTimer;
  DiscoveryWindowTimer get discoveryWindowTimer =>
      _discoveryWindowTimer; // Discovery listening window (Passive Mode)
  Listenable get timerListenable => _timerListenable;

  void _handleLiveActivityTimerChange() {
    if (_liveActivityManualSession &&
        !_isPingSending &&
        !_rxWindowTimer.isRunning &&
        !_manualPingCooldownTimer.isRunning) {
      _finishLiveActivitySession();
      return;
    }
    _scheduleLiveActivitySync();
  }

  void _startLiveActivitySession({bool manual = false}) {
    if (!_liveActivityService.isSupportedPlatform) return;
    if (_liveActivitySessionActive) {
      // Starting an automatic mode while a manual-ping activity is still in
      // cooldown upgrades the existing activity instead of creating a second.
      if (!manual && _liveActivityManualSession) {
        _liveActivityManualSession = false;
        _scheduleLiveActivitySync(immediate: true);
      }
      return;
    }
    _liveActivitySessionActive = true;
    _liveActivityManualSession = manual;
    _liveActivitySessionId = const Uuid().v4();
    _liveActivityCycleStartedAt = _activeLiveActivityCycleStartedAt;
    _liveActivityOperation = null;
    _scheduleLiveActivitySync(immediate: true);
  }

  DateTime? get _activeLiveActivityCycleStartedAt {
    if (_rxWindowTimer.isRunning && _txLogEntries.isNotEmpty) {
      return _txLogEntries.last.timestamp;
    }
    if (!_discoveryWindowTimer.isRunning) return null;
    if (_autoMode == AutoMode.targeted && _traceLogEntries.isNotEmpty) {
      return _traceLogEntries.first.timestamp;
    }
    if (_discLogEntries.isNotEmpty) {
      return _discLogEntries.first.timestamp;
    }
    return null;
  }

  void _finishLiveActivitySession() {
    if (!_liveActivitySessionActive) return;
    _liveActivitySessionActive = false;
    _liveActivityManualSession = false;
    _liveActivityOperation = null;
    _liveActivityCycleStartedAt = null;
    _scheduleLiveActivitySync(immediate: true);
    _liveActivitySessionId = null;
  }

  void _markLiveActivityOperation(_LiveActivityOperation operation) {
    if (!_liveActivitySessionActive ||
        !_liveActivityService.isSupportedPlatform) {
      return;
    }
    final now = DateTime.now();
    _liveActivityOperation = operation;
    _liveActivityCycleStartedAt = now;
    _scheduleLiveActivitySync(immediate: true);
  }

  void _scheduleLiveActivitySync({bool immediate = false}) {
    if (_isDisposed) return;
    // The watch mirrors state even with no session running — otherwise you
    // could never start one from the wrist.
    _scheduleWatchSync(immediate: immediate);
    if (!_liveActivityService.isSupportedPlatform) return;
    _liveActivityService.schedule(
      _buildLiveActivitySnapshot,
      immediate: immediate,
    );
  }

  void _scheduleWatchSync({bool immediate = false}) {
    if (_isDisposed || !_watchBridge.canSync) return;
    _watchBridge.schedule(
      _buildWatchSnapshot,
      urgencyKeyBuilder: _buildWatchUrgencyKey,
      immediate: immediate,
    );
  }

  /// The bridge needs to decide whether a flush can wait before it builds the
  /// geographic payload. Keep this in the wire model's shared formatter so the
  /// cheap preflight and the eventual snapshot cannot drift on what is urgent.
  String _buildWatchUrgencyKey() {
    final phase = _resolveWatchPhase();
    final controls = _buildWatchControls();
    return WatchSnapshot.buildUrgencyKey(
      sessionId: _liveActivitySessionId ?? 'idle',
      mode: _resolvedWatchSessionModeTitle,
      phase: phase.phase,
      phaseTitle: phase.title,
      phaseDetail: phase.detail,
      phaseEndsAt: phase.endsAt,
      isConnected: isConnected,
      controls: controls,
      cue: _watchCue,
    );
  }

  /// Builds the watch payload.
  ///
  /// Unlike the Live Activity, this is never null while the app is alive: the
  /// wrist shows idle and disconnected states too, and the start button has to
  /// be reachable before a session exists.
  WatchSnapshot? _buildWatchSnapshot() {
    if (_isDisposed) return null;

    final phase = _resolveWatchPhase();
    final repeaterState = _buildLiveActivityRepeaters();
    final now = DateTime.now();
    final phaseDurationMs = _phaseDurationMsFor(phase.endsAt);
    final pingColor = _resolveWatchPingColor();

    final core = LiveActivitySnapshot(
      sessionId: _liveActivitySessionId ?? 'idle',
      // On the watch this field is also the Start button's promise, so it must
      // describe the resolver the command will use rather than the ambient
      // default that only becomes meaningful after a phone button is pressed.
      mode: _resolvedWatchSessionModeTitle,
      phase: phase.phase,
      phaseTitle: phase.title,
      phaseDetail: phase.detail,
      phaseEndsAt: phase.endsAt,
      phaseDurationMs: phaseDurationMs,
      pingColor: pingColor,
      isConnected: isConnected,
      zoneCode: zoneCode ?? _sessionZoneCode ?? _preferences.iataCode,
      txCount: _pingStats.txCount,
      rxCount: _pingStats.rxCount,
      discoveryCount: _pingStats.discCount,
      traceCount: _pingStats.traceCount,
      queueSize: _queueSize,
      repeaters: repeaterState.repeaters,
      totalHeardCount: repeaterState.totalCount,
      repeatersAreCurrent: repeaterState.isCurrent,
      updatedAt: now,
    );

    return WatchSnapshot(
      core: core,
      geo: _buildWatchGeo(),
      controls: _buildWatchControls(),
      pingColor: pingColor,
      cue: _watchCue,
      phaseDurationMs: phaseDurationMs,
      updatedAt: now,
    );
  }

  /// Total length of the countdown that owns [endsAt].
  ///
  /// The phase resolver returns a deadline without saying which timer produced
  /// it, so the owner is identified by matching end times. Returns null for
  /// deadlines no countdown owns (the zone grace period), in which case the
  /// watch shows the remaining time without a progress bar.
  int? _phaseDurationMsFor(DateTime? endsAt) {
    if (endsAt == null) return null;
    for (final timer in <CountdownTimerService>[
      _autoPingTimer,
      _rxWindowTimer,
      _discoveryWindowTimer,
      _manualPingCooldownTimer,
      _cooldownTimer,
    ]) {
      if (timer.isRunning && timer.endTime == endsAt) {
        return timer.durationMs;
      }
    }
    return null;
  }

  WatchGeo _buildWatchGeo() {
    final position = _resolveWatchPosition();

    // Repeaters heard during the current cycle get the highlight ring.
    final heardIds = _topRepeatersOverlay
        .map((r) => r.repeaterId.toUpperCase())
        .toSet();

    // The wrist mirrors the map's "Top Heard" overlay: the latest ping's top
    // three by SNR plus the current RX slot. Same source, so the two surfaces
    // can never disagree.
    final top = _topRepeatersOverlay;
    final rxSlot = _rxOverlaySlot;
    if (rxSlot != null) heardIds.add(rxSlot.repeaterId.toUpperCase());

    // Overlay IDs are hex path hashes, so resolve names by prefix at whatever
    // length this zone actually uses.
    final hexLength = top.isNotEmpty
        ? top.first.repeaterId.length
        : (rxSlot?.repeaterId.length ?? 0);
    final repeaterByHex = hexLength > 0
        ? WatchGeoBuilder.indexByHexPrefix(_repeaters, hexLength)
        : const <String, Repeater>{};

    return WatchGeo(
      you: position,
      pings: WatchGeoBuilder.buildPings(
        txPings: _txPings,
        rxPings: _rxPings,
        discLogEntries: _discLogEntries,
        traceLogEntries: _traceLogEntries,
      ),
      repeaters: WatchGeoBuilder.buildRepeaters(
        repeaters: _repeaters,
        heardThisCycle: heardIds,
        lat: position?.lat,
        lon: position?.lon,
      ),
      heard: WatchGeoBuilder.buildHeard(
        top: top,
        rxSlot: rxSlot,
        repeaterByHex: repeaterByHex,
        topAt: _topRepeatersOverlayUpdatedAt,
        rxAt: _liveActivityRxUpdatedAt,
        lat: position?.lat,
        lon: position?.lon,
      ),
      linkedRepeaterIds: [
        ...WatchGeoBuilder.resolveUniqueHexPrefixes(
          repeaters: _repeaters,
          prefixes: heardIds,
        ).keys,
      ],
    );
  }

  /// Current fix, held still until it moves meaningfully.
  ///
  /// Returning the previous position leaves the payload fingerprint unchanged,
  /// so the bridge's dedupe suppresses the send. A parked phone therefore
  /// stops talking to the watch instead of streaming GPS jitter at it.
  WatchPosition? _resolveWatchPosition() {
    final position = _currentPosition;
    if (position == null) return _lastWatchPosition;

    final previous = _lastWatchPosition;
    if (previous != null &&
        !WatchGeoBuilder.movedEnough(
          lastLat: previous.lat,
          lastLon: previous.lon,
          lat: position.latitude,
          lon: position.longitude,
        )) {
      return previous;
    }

    final resolved = WatchPosition(
      lat: position.latitude,
      lon: position.longitude,
      headingDeg: position.heading.isFinite && position.heading >= 0
          ? position.heading
          : null,
      accuracyM: position.accuracy.isFinite ? position.accuracy : null,
      fixedAt: position.timestamp,
    );
    _lastWatchPosition = resolved;
    return resolved;
  }

  ({bool allowed, String? reason}) get _manualPingAvailability {
    // This must remain the sole copy of the app button's gate. One caller says
    // what the wrist may offer while the other decides whether the radio may
    // transmit; letting those answers drift makes a stale watch payload unsafe.
    final canPingManual = manualPingValidation == PingValidation.valid;
    final isAutoStarting = isAutoPingStarting;
    final isTxModeActive = isTxModeRunning;
    final isTargetedRunning = isTargetedModeRunning;
    final cooldownActive = cooldownTimer.isRunning;
    final manualCooldownActive = manualPingCooldownTimer.isRunning;
    final txBlockedByOffline = offlineMode && isConnected;
    final txNotAllowed = isConnected && !txAllowed;
    final rxWindowActive = rxWindowTimer.isRunning;
    final pingSending = isPingSending;
    final discoveryWindowActive = discoveryWindowTimer.isRunning;
    final pendingDisable = isPendingDisable;
    final allowed = canPingManual &&
        !isAutoStarting &&
        !isTxModeActive &&
        !isTargetedRunning &&
        !cooldownActive &&
        !manualCooldownActive &&
        !txBlockedByOffline &&
        !txNotAllowed &&
        !rxWindowActive &&
        !pingSending &&
        !discoveryWindowActive &&
        !pendingDisable;

    // Only describe a refusal that is actually happening. A reason computed
    // alongside an allowed ping would surface on the wrist as a status line
    // under two working buttons.
    final String? reason;
    if (allowed) {
      reason = null;
    } else if (!isConnected) {
      reason = 'Not connected';
    } else if (!hasGpsLock) {
      reason = 'No GPS fix';
    } else if (txBlockedByOffline) {
      reason = 'Offline Mode';
    } else if (txNotAllowed) {
      reason = 'Passive Only';
    } else if (manualPingValidation == PingValidation.manualCooldownActive ||
        cooldownActive ||
        manualCooldownActive ||
        rxWindowActive ||
        discoveryWindowActive) {
      reason = 'Cooling down';
    } else if (!canPingManual) {
      reason = manualPingValidation.message;
    } else {
      reason = 'Another operation is in progress';
    }

    return (allowed: allowed, reason: reason);
  }

  AutoMode get _resolvedWatchSessionMode {
    // Phone buttons each carry an explicit mode, but the wrist has one generic
    // Start button and `_autoMode` begins as Active before any phone choice has
    // established intent. In a passive-only region inheriting that default
    // silently selects the one forbidden mode. Once running, preserve the
    // actual mode so the same resolver always stops what it started.
    if (_autoPingEnabled) return _autoMode;
    if (isConnected && !txAllowed) return AutoMode.passive;
    return _autoMode;
  }

  String get _resolvedWatchSessionModeTitle =>
      switch (_resolvedWatchSessionMode) {
        AutoMode.active => 'Active',
        AutoMode.passive => 'Passive',
        AutoMode.hybrid => 'Hybrid',
        AutoMode.targeted => 'Trace',
      };

  WatchControls _buildWatchControls() {
    final cooldownMs = _manualPingCooldownTimer.remainingMs;
    final manualPing = _manualPingAvailability;

    return WatchControls(
      canStartStop: isConnected,
      canManualPing: manualPing.allowed,
      isSessionActive: _autoPingEnabled,
      manualCooldownEndsAt: cooldownMs > 0
          ? _manualPingCooldownTimer.endTime
          : null,
      // The button already renders its cooldown deadline. The handler still
      // returns this refusal to a stale tap, but duplicating it as a status
      // line would spend wrist space without adding an explanation.
      blockedReason:
          manualPing.reason == 'Cooling down' ? null : manualPing.reason,
    );
  }

  /// Colour of the most recent completed coverage event, matching the marker
  /// beside it rather than leaving Passive mode stuck on an old TX result.
  WatchColor? _resolveWatchPingColor() => WatchGeoBuilder.latestPingColor(
        txPings: _txPings,
        rxPings: _rxPings,
        discLogEntries: _discLogEntries,
        traceLogEntries: _traceLogEntries,
      );

  /// Decides whether an intent from the wrist may begin.
  ///
  /// Returns null when accepted, or a reason to show on the watch. Every guard
  /// is re-evaluated here: the watch's view of what's permitted may be stale,
  /// and a stale payload must never be able to cause a transmit.
  ///
  /// Once admitted, the action deliberately outlives this synchronous reply:
  /// WatchConnectivity cannot wait for BLE or server work. Successful outcomes
  /// already surface through session, phase, and ping-colour snapshots; a late
  /// failure gets its own cue so dropping completion from the ack loses nothing.
  String? _handleWatchCommand(WatchCommandKind kind) {
    if (_isDisposed) return 'App closing';

    switch (kind) {
      case WatchCommandKind.requestSnapshot:
        _scheduleWatchSync(immediate: true);
        return null;

      case WatchCommandKind.startSession:
        final admission = resolveWatchSessionCommandAdmission(
          kind: kind,
          isSessionActive: _autoPingEnabled,
          isSessionStarting: _autoPingStarting,
        );
        if (admission.refusal != null) return admission.refusal;
        if (!admission.shouldRun) return null;
        if (!isConnected) return 'Not connected';
        unawaited(_runWatchStartSession(_resolvedWatchSessionMode));
        return null;

      case WatchCommandKind.stopSession:
        final admission = resolveWatchSessionCommandAdmission(
          kind: kind,
          isSessionActive: _autoPingEnabled,
          isSessionStarting: _autoPingStarting,
        );
        if (admission.refusal != null) return admission.refusal;
        if (!admission.shouldRun) return null;
        unawaited(_runWatchStopSession(_resolvedWatchSessionMode));
        return null;

      case WatchCommandKind.manualPing:
        final availability = _manualPingAvailability;
        if (!availability.allowed) {
          return availability.reason ?? 'Ping unavailable';
        }
        unawaited(_runWatchManualPing());
        return null;
    }
  }

  Future<void> _runWatchStartSession(AutoMode mode) async {
    _lastSessionCheckFailureReason = null;
    try {
      final started = await toggleAutoPing(mode);
      if (!started) {
        _emitWatchFailure(_watchStartFailureReason(mode));
      }
    } catch (error) {
      debugError('[WATCH] startSession failed after admission: $error');
      _emitWatchFailure(_watchStartFailureReason(mode));
    }
  }

  Future<void> _runWatchStopSession(AutoMode mode) async {
    try {
      final stopped = await toggleAutoPing(mode);
      if (!stopped) _emitWatchFailure('Could not stop');
    } catch (error) {
      debugError('[WATCH] stopSession failed after admission: $error');
      _emitWatchFailure('Could not stop');
    }
  }

  String _watchStartFailureReason(AutoMode mode) {
    final sessionReason = _lastSessionCheckFailureReason;
    if (sessionReason != null) return sessionReason;
    if (mode != AutoMode.passive && _cooldownTimer.isRunning) {
      return 'Cooling down';
    }
    return 'Could not start';
  }

  Future<void> _runWatchManualPing() async {
    _lastSessionCheckFailureReason = null;
    try {
      final sent = await sendPing();
      if (!sent) {
        _emitWatchFailure(_lastSessionCheckFailureReason ?? 'Ping failed');
      }
    } catch (error) {
      debugError('[WATCH] manualPing failed after admission: $error');
      _emitWatchFailure(_lastSessionCheckFailureReason ?? 'Ping failed');
    }
  }

  void _emitWatchFailure(String message) {
    if (_isDisposed) return;
    _watchCue = WatchHapticCue(
      id: const Uuid().v4(),
      kind: 'failure',
      issuedAt: DateTime.now(),
      message: message,
    );
    _scheduleWatchSync(immediate: true);
  }

  void _handleWatchSnapshotDelivered(WatchSnapshot snapshot) {
    final deliveredCue = snapshot.cue;
    if (deliveredCue != null && _watchCue?.id == deliveredCue.id) {
      // Delivery means future snapshots must stop carrying this event. The
      // watch independently age-checks the retained application context, so a
      // process restart cannot turn it back into a new failure.
      _watchCue = null;
    }
  }

  ({
    LiveActivityPhase phase,
    String title,
    String? detail,
    DateTime? endsAt,
  }) _resolveWatchPhase() {
    final shared = _resolveLiveActivityPhase();
    final watchPhase = resolveWatchSurfacePhase(
      sharedPhase: shared.phase,
      isSessionActive: _autoPingEnabled,
      isSessionStarting: _autoPingStarting,
    );
    if (watchPhase == shared.phase) return shared;

    return (
      phase: LiveActivityPhase.idle,
      title: 'Ready',
      detail: 'No session running',
      endsAt: null,
    );
  }

  LiveActivitySnapshot? _buildLiveActivitySnapshot() {
    final sessionId = _liveActivitySessionId;
    if (!_liveActivitySessionActive || sessionId == null) {
      return null;
    }

    final phase = _resolveLiveActivityPhase();
    final repeaterState = _buildLiveActivityRepeaters();
    final phaseDurationMs = _phaseDurationMsFor(phase.endsAt);
    final pingColor = _resolveWatchPingColor();

    return LiveActivitySnapshot(
      sessionId: sessionId,
      mode: _liveActivityModeTitle,
      phase: phase.phase,
      phaseTitle: phase.title,
      phaseDetail: phase.detail,
      phaseEndsAt: phase.endsAt,
      phaseDurationMs: phaseDurationMs,
      pingColor: pingColor,
      isConnected: isConnected,
      zoneCode: zoneCode ?? _sessionZoneCode ?? _preferences.iataCode,
      txCount: _pingStats.txCount,
      rxCount: _pingStats.rxCount,
      discoveryCount: _pingStats.discCount,
      traceCount: _pingStats.traceCount,
      queueSize: _queueSize,
      repeaters: repeaterState.repeaters,
      totalHeardCount: repeaterState.totalCount,
      repeatersAreCurrent: repeaterState.isCurrent,
      updatedAt: DateTime.now(),
    );
  }

  ({
    LiveActivityPhase phase,
    String title,
    String? detail,
    DateTime? endsAt,
  }) _resolveLiveActivityPhase() {
    if (_isInZoneGracePeriod) {
      return (
        phase: LiveActivityPhase.pausedOutsideZone,
        title: 'Outside service area',
        detail: 'Searching for a nearby wardriving zone',
        endsAt: _zoneGraceEndsAt,
      );
    }

    if (_isZoneTransferInProgress) {
      return (
        phase: LiveActivityPhase.pausedOutsideZone,
        title: 'Changing region…',
        detail: [_zoneTransferFrom, _zoneTransferTo]
            .whereType<String>()
            .join(' → '),
        endsAt: null,
      );
    }

    if (_isAutoReconnecting || _connectionStep == ConnectionStep.reconnecting) {
      return (
        phase: LiveActivityPhase.disconnected,
        title: 'Reconnecting…',
        detail: 'Restoring MeshCore connection',
        endsAt: null,
      );
    }

    if (!isConnected) {
      return (
        phase: LiveActivityPhase.disconnected,
        title: _connectionStep == ConnectionStep.disconnecting
            ? 'Disconnecting…'
            : 'Device disconnected',
        detail: 'Open MeshMapper to reconnect',
        endsAt: null,
      );
    }

    if (isPendingDisable) {
      return (
        phase: LiveActivityPhase.stopping,
        title: 'Stopping…',
        detail: 'Finishing the current listening window',
        endsAt: _rxWindowTimer.endTime ?? _discoveryWindowTimer.endTime,
      );
    }

    if (_gpsStatus != GpsStatus.locked) {
      return (
        phase: LiveActivityPhase.waitingForGps,
        title: 'Waiting for GPS',
        detail: _liveActivityGpsLabel,
        endsAt: null,
      );
    }

    if ((_autoMode == AutoMode.active ||
            _autoMode == AutoMode.hybrid ||
            _autoMode == AutoMode.targeted) &&
        !txAllowed) {
      return (
        phase: LiveActivityPhase.txBlocked,
        title: 'TX unavailable',
        detail: 'This zone is currently passive-only',
        endsAt: null,
      );
    }

    if (_liveActivityManualSession && _isPingSending) {
      return (
        phase: LiveActivityPhase.sending,
        title: 'Sending ping…',
        detail: null,
        endsAt: null,
      );
    }

    if (_discoveryWindowTimer.isRunning) {
      final isTrace = _autoMode == AutoMode.targeted;
      return (
        phase: isTrace
            ? LiveActivityPhase.listeningTrace
            : LiveActivityPhase.listeningDiscovery,
        title: isTrace ? 'Listening for trace…' : 'Listening…',
        detail: isTrace ? _targetRepeaterDisplayName : 'Discovery responses',
        endsAt: _discoveryWindowTimer.endTime,
      );
    }

    if (_rxWindowTimer.isRunning) {
      return (
        phase: LiveActivityPhase.listening,
        title: 'Listening…',
        detail: 'Waiting for repeater echoes',
        endsAt: _rxWindowTimer.endTime,
      );
    }

    if (_liveActivityManualSession &&
        _manualPingCooldownTimer.isRunning) {
      return (
        phase: LiveActivityPhase.cooldown,
        title: 'Cooldown',
        detail: 'Manual ping available when the timer ends',
        endsAt: _manualPingCooldownTimer.endTime,
      );
    }

    if (_autoPingTimer.isRunning) {
      if (_autoPingTimer.skipReason != null) {
        return (
          phase: LiveActivityPhase.skipped,
          title: 'Ping skipped',
          detail: 'Move at least ${PingService.currentMinDistance} m',
          endsAt: _autoPingTimer.endTime,
        );
      }

      if (_autoMode == AutoMode.passive) {
        return (
          phase: LiveActivityPhase.waitingDiscovery,
          title: 'Next discovery',
          detail: null,
          endsAt: _autoPingTimer.endTime,
        );
      }

      if (_autoMode == AutoMode.targeted) {
        return (
          phase: LiveActivityPhase.waitingTrace,
          title: 'Next trace',
          detail: _targetRepeaterDisplayName,
          endsAt: _autoPingTimer.endTime,
        );
      }

      return (
        phase: LiveActivityPhase.waiting,
        title: 'Next ping',
        detail: null,
        endsAt: _autoPingTimer.endTime,
      );
    }

    switch (_liveActivityOperation) {
      case _LiveActivityOperation.sending:
        return (
          phase: LiveActivityPhase.sending,
          title: 'Sending ping…',
          detail: null,
          endsAt: null,
        );
      case _LiveActivityOperation.discovering:
        return (
          phase: LiveActivityPhase.discovering,
          title: 'Discovering…',
          detail: 'Requesting nearby repeaters',
          endsAt: null,
        );
      case _LiveActivityOperation.tracing:
        return (
          phase: LiveActivityPhase.tracing,
          title: 'Tracing repeater…',
          detail: _targetRepeaterDisplayName,
          endsAt: null,
        );
      case null:
        break;
    }

    if (_autoPingStarting || !_autoPingEnabled) {
      return (
        phase: LiveActivityPhase.starting,
        title: 'Preparing session…',
        detail: null,
        endsAt: null,
      );
    }

    return (
      phase: LiveActivityPhase.active,
      title: '$_liveActivityModeTitle active',
      detail: 'Waiting for the next cycle',
      endsAt: null,
    );
  }

  ({
    List<LiveActivityRepeater> repeaters,
    int totalCount,
    bool isCurrent,
  }) _buildLiveActivityRepeaters() {
    final cycleStartedAt = _liveActivityCycleStartedAt;
    final topIsCurrent = cycleStartedAt != null &&
        _liveActivityRepeatersUpdatedAt != null &&
        !_liveActivityRepeatersUpdatedAt!.isBefore(cycleStartedAt);
    final rxIsCurrent = cycleStartedAt != null &&
        _liveActivityRxUpdatedAt != null &&
        !_liveActivityRxUpdatedAt!.isBefore(cycleStartedAt);
    final hasCurrent = topIsCurrent || rxIsCurrent;

    final includeTop = !hasCurrent || topIsCurrent;
    final includeRx = !hasCurrent || rxIsCurrent;
    final repeatersById = <String, LiveActivityRepeater>{};

    if (includeTop) {
      for (final repeater in _liveActivityRepeaters) {
        if (!repeater.snr.isFinite) continue;
        final id = repeater.repeaterId.toUpperCase();
        repeatersById[id] = LiveActivityRepeater(
          id: id,
          name: _resolveRepeaterDisplayName(id),
          snr: repeater.snr,
          typeColor: WatchGeoBuilder.overlayTypeColor(repeater.type),
          snrColor: WatchGeoBuilder.snrColor(repeater.snr),
        );
      }
    }

    final rx = _rxOverlaySlot;
    if (includeRx && rx != null && rx.snr.isFinite) {
      final id = rx.repeaterId.toUpperCase();
      final existing = repeatersById[id];
      if (existing == null || rx.snr > existing.snr) {
        repeatersById[id] = LiveActivityRepeater(
          id: id,
          name: _resolveRepeaterDisplayName(id),
          snr: rx.snr,
          typeColor: WatchGeoBuilder.overlayTypeColor(OverlayPingType.rx),
          snrColor: WatchGeoBuilder.snrColor(rx.snr),
        );
      }
    }

    final repeaters = repeatersById.values.toList()
      ..sort((a, b) => b.snr.compareTo(a.snr));

    var totalCount = includeTop ? _liveActivityRepeaterTotalCount : 0;
    if (includeRx &&
        rx != null &&
        rx.snr.isFinite &&
        !_liveActivityRepeaters.any(
          (entry) =>
              entry.repeaterId.toUpperCase() == rx.repeaterId.toUpperCase(),
        )) {
      totalCount++;
    }
    if (totalCount < repeaters.length) totalCount = repeaters.length;

    return (
      repeaters: repeaters.take(3).toList(growable: false),
      totalCount: totalCount,
      isCurrent: hasCurrent,
    );
  }

  String get _liveActivityModeTitle {
    if (_liveActivityManualSession) return 'Manual';
    return switch (_autoMode) {
      AutoMode.active => 'Active',
      AutoMode.passive => 'Passive',
      AutoMode.hybrid => 'Hybrid',
      AutoMode.targeted => 'Trace',
    };
  }

  String get _liveActivityGpsLabel => switch (_gpsStatus) {
        GpsStatus.permissionDenied => 'Location permission required',
        GpsStatus.disabled => 'Location services disabled',
        GpsStatus.searching => 'Searching for GPS signal',
        GpsStatus.locked => 'GPS locked',
        GpsStatus.outsideGeofence => 'Outside service area',
      };

  String? get _targetRepeaterDisplayName {
    final id = _targetRepeaterId;
    if (id == null || id.isEmpty) return null;
    return _resolveRepeaterDisplayName(id) ?? id.toUpperCase();
  }

  String? _resolveRepeaterDisplayName(String rawId) {
    final id = rawId.toUpperCase();
    final exactMatches = _repeaters.where((repeater) {
      return repeater.id.toUpperCase() == id ||
          repeater.hexId.toUpperCase() == id ||
          repeater
                  .displayHexId(overrideHopBytes: _hopBytes)
                  .toUpperCase() ==
              id;
    }).toList(growable: false);

    if (exactMatches.length == 1) {
      final name = exactMatches.single.name;
      return name == 'Unknown' ? null : name;
    }
    if (exactMatches.isNotEmpty || id.length < 2) return null;

    final prefixMatches = _repeaters.where((repeater) {
      final hexId = repeater.hexId.toUpperCase();
      return hexId.startsWith(id) || id.startsWith(hexId);
    }).toList(growable: false);
    if (prefixMatches.length != 1) return null;

    final name = prefixMatches.single.name;
    return name == 'Unknown' ? null : name;
  }

  // ============================================
  // Initialization
  // ============================================

  Future<void> _initialize() async {
    debugLog('[INIT] AppStateProvider initialization starting...');

    // Generate or load device ID
    _deviceId = const Uuid().v4();

    // Initialize services
    _apiService = ApiService();
    _apiQueueService = ApiQueueService(apiService: _apiService);

    // Initialize custom API forwarding service
    _customApiService = CustomApiService(prefsGetter: () => _preferences);
    _customApiService.onError = (message) {
      logError('Custom API: $message',
          severity: ErrorSeverity.warning, autoSwitch: false);
    };
    _customApiService.contactGetter = () {
      final pk = _devicePublicKey;
      return (pk != null && pk.length >= 8)
          ? pk.substring(0, 8).toUpperCase()
          : null;
    };
    _customApiService.iataGetter = () => zoneCode ?? _preferences.iataCode;
    _apiQueueService.customApiService = _customApiService;

    // Set up session error callback for auto-disconnect
    _apiService.onSessionError = (reason, message) async {
      debugError('[APP] Session error from API: $reason - $message');
      await handleSessionError(reason, message);
    };

    // Set up maintenance mode callback (for connected state)
    _apiService.onMaintenanceMode = (message, url) {
      debugLog('[MAINTENANCE] Callback triggered: $message');
      _handleMaintenanceModeConnected(message, url);
    };

    _offlineSessionService = OfflineSessionService();
    _deviceModelService = DeviceModelService();

    // Initialize countdown timers. They self-notify via ChangeNotifier so only
    // widgets listening to the timers directly rebuild on each 500ms tick.
    _cooldownTimer = CooldownTimer();
    _manualPingCooldownTimer = ManualPingCooldownTimer();
    _autoPingTimer = AutoPingTimer();
    _rxWindowTimer = RxWindowTimer();
    _discoveryWindowTimer = DiscoveryWindowTimer();
    _timerListenable = Listenable.merge([
      _cooldownTimer,
      _manualPingCooldownTimer,
      _autoPingTimer,
      _rxWindowTimer,
      _discoveryWindowTimer,
    ]);
    if (_liveActivityService.isSupportedPlatform) {
      _timerListenable.addListener(_handleLiveActivityTimerChange);
    }
    if (_watchBridge.isSupportedPlatform) {
      _watchBridge.attachCommandHandler(
        _handleWatchCommand,
        onRefusal: _emitWatchFailure,
        onSnapshotDelivered: _handleWatchSnapshotDelivered,
        // Availability can become true long after provider startup when a
        // watch is paired or its app is installed. Push the current state then
        // rather than waiting for an unrelated phone-side notification.
        onAvailabilityChanged: (available) {
          if (available) _scheduleWatchSync(immediate: true);
        },
      );
    }

    // Initialize debug logging (enabled by default, respects user preference)
    await _initDebugLogs();

    // Initialize channel service with Public channel only (regional channels added after auth)
    await ChannelService.initializePublicChannel();
    debugLog('[APP] Channel service initialized (Public channel only)');

    // Initialize API queue with error/cleanup callbacks
    debugLog('[INIT] Initializing API queue service...');
    _apiQueueService.onPersistenceError = (errorMessage) {
      logError(errorMessage);
    };
    _apiQueueService.onStorageCleanup = (infoMessage) {
      logError(infoMessage); // Log cleanup events to error log so user is aware
    };
    await _apiQueueService.init();
    debugLog('[INIT] API queue service initialized');
    _apiQueueService.onQueueUpdated = (size) {
      _queueSize = size;
      notifyListeners();

      // Update background service notification with queue size
      if (_autoPingEnabled) {
        final modeName = _autoMode == AutoMode.passive
            ? 'Passive Mode'
            : _autoMode == AutoMode.hybrid
                ? 'Hybrid Mode'
                : _autoMode == AutoMode.targeted
                    ? 'Trace Mode'
                    : 'Active Mode';
        BackgroundServiceManager.updateNotification(
          mode: modeName,
          txCount: _pingStats.txCount,
          rxCount: _pingStats.rxCount,
          queueSize: size,
        );
      }
    };

    _apiQueueService.onUploadSuccess = (uploadedCount, uploadedItems) {
      _pingStats = _pingStats.copyWith(
        successfulUploads: _pingStats.successfulUploads + uploadedCount,
      );
      debugLog(
          '[APP] Upload success: +$uploadedCount items (total: ${_pingStats.successfulUploads})');
      notifyListeners();

      if (_vectorOverlayActive) {
        // Queue the batch's coords for the +7s fresh-tile check; the user's
        // own cells land on the map via the session patch (see
        // _freshenAffectedVectorTiles).
        _pendingFreshZone = zoneCode;
        for (final item in uploadedItems) {
          if (_pendingFreshCoords.length >= 16) break;
          _pendingFreshCoords.add([item.latitude, item.longitude]);
        }
        _vectorFreshTimer?.cancel();
        _vectorFreshTimer = Timer(const Duration(seconds: 7), () {
          _freshenAffectedVectorTiles(attempt: 1);
        });
      }
    };

    // Initialize offline session service
    await _offlineSessionService.init();
    _offlineSessionService.onSessionsUpdated = (sessions) {
      notifyListeners();
    };

    // Load device models
    await _deviceModelService.loadModels();

    // Load stored noise floor sessions
    await _loadNoiseFloorSessions();

    // Load remembered device (mobile only)
    await _loadRememberedDevice();

    // Load user preferences
    debugLog('[INIT] Loading preferences...');
    await _loadPreferences();
    await _loadDeviceAntennaPreferences();
    await _loadDevicePowerOverrides();
    await _loadDeviceRealNames();

    // Load last known GPS position for map centering
    await _loadLastPosition();

    // Load last connected device info (for bug reports)
    await _loadLastConnectedDevice();

    // Listen to Bluetooth adapter state changes (on/off)
    debugLog('[INIT] Setting up Bluetooth adapter state listener...');
    _adapterStateSubscription =
        _bluetoothService.adapterStateStream.listen((state) {
      final previousState = _bluetoothAdapterState;
      _bluetoothAdapterState = state;

      if (state != previousState) {
        debugLog('[BLE] Adapter state changed: $state');

        // If Bluetooth was turned off while connected, the BLE disconnect handler
        // will take care of session cleanup via connectionStream
        notifyListeners();
      }
    });

    // Listen to Bluetooth connection changes
    debugLog('[INIT] Setting up BLE connection listener...');
    await _connectionSubscription?.cancel();
    _connectionSubscription =
        _bluetoothService.connectionStream.listen((status) async {
      _connectionStatus = status;
      if (status == ConnectionStatus.disconnected) {
        // Check if this is an unexpected disconnect during active wardriving
        final wasConnected = _connectionStep == ConnectionStep.connected;
        final hasRemembered = _rememberedDevice != null;
        final isUnexpected = !_userRequestedDisconnect && !_isAutoReconnecting;

        if (_isInZoneGracePeriod) {
          // BLE disconnected during zone grace period — abandon grace, full cleanup
          debugLog(
              '[CONN] BLE disconnect during zone grace period — full cleanup');
          _cancelZoneGraceTimers();
          _isInZoneGracePeriod = false;
          _zoneGraceSecondsRemaining = 0;
          if (_autoPingWasEnabledBeforeGrace) _playDisconnectAlert();
          _autoPingWasEnabledBeforeGrace = false;
          await _fullDisconnectCleanup();
        } else if (wasConnected && hasRemembered && isUnexpected && !kIsWeb) {
          debugLog(
              '[CONN] Unexpected BLE disconnect detected - starting auto-reconnect');
          await _startAutoReconnect();
        } else if (!_isAutoReconnecting) {
          // Normal disconnect (user-requested or no remembered device)
          await _fullDisconnectCleanup();
        } else {
          // Disconnected during a reconnect attempt - _attemptReconnect handles retry
          debugLog(
              '[CONN] BLE disconnect during reconnect attempt - will retry');
        }
      }
      notifyListeners();
    });

    // Listen to GPS changes
    debugLog('[INIT] Setting up GPS status listener...');
    await _gpsStatusSubscription?.cancel();
    _gpsStatusSubscription = _gpsService.statusStream.listen((status) {
      final previousStatus = _gpsStatus;
      _gpsStatus = status;

      // Only log when status actually changes
      if (previousStatus != status) {
        debugLog('[GPS] Status changed: $previousStatus → $status');

        // Log when we transition to locked state (permission granted + GPS available)
        if (status == GpsStatus.locked) {
          debugLog(
              '[GPS] GPS lock acquired - zone check should trigger on first position');
        }
        // Log when permission is denied or GPS disabled
        if (status == GpsStatus.permissionDenied) {
          debugLog(
              '[GPS] Location permission denied - zone checks will be blocked');
        } else if (status == GpsStatus.disabled) {
          debugLog(
              '[GPS] Location services disabled - zone checks will be blocked');
        }
      }
      notifyListeners();
    });
    _gpsStatus = _gpsService.status; // Sync initial status
    debugLog('[INIT] Initial GPS status: $_gpsStatus');

    debugLog('[INIT] Setting up GPS position listener...');
    await _gpsPositionSubscription?.cancel();
    _gpsPositionSubscription =
        _gpsService.positionStream.listen((position) async {
      _currentPosition = position;
      // Do NOT bump mapRevision here. Position drives the camera/puck/coords
      // directly (MapWidget._onPositionNotify listener + a Selector on the
      // GPS-info overlay) — all real-time — WITHOUT rebuilding the map, which
      // would relayout the iOS platform view (~28ms) every GPS tick. A plain
      // notifyListeners() reaches those position watchers; the map's Selector
      // (keyed on mapRevision) stays cached.
      notifyListeners();

      // Diagnostic: catch a stuck countdown timer (the intermittent ping-control
      // lockout) in the foreground. Throttled to 5s; logs only when stuck.
      _maybeLogStuckTimers();

      // Save last position for next app launch (already throttled to 30s)
      _saveLastPosition(position.latitude, position.longitude);

      // Check zone on first GPS lock (when _inZone is null)
      // Skip zone checks when offline mode is enabled
      if (_inZone == null && !_preferences.offlineMode) {
        debugLog('[GEOFENCE] First GPS lock, triggering zone check');
        await checkZoneStatus();
        _firstGpsLockLogged = true;
      } else if (_inZone == null &&
          _preferences.offlineMode &&
          !_firstGpsLockLogged) {
        debugLog('[GEOFENCE] First GPS lock skipped: offline mode enabled');
        _firstGpsLockLogged = true;
      }

      // Check zone every 100m movement (while disconnected)
      // This allows users to know if they've entered/exited a zone while moving
      // Skip zone checks when offline mode is enabled
      if (!isConnected &&
          !_preferences.offlineMode &&
          _shouldRecheckZone(position)) {
        // Throttle log to once per 30s to avoid spam while driving
        final now = DateTime.now();
        if (_lastZoneCheckLogTime == null ||
            now.difference(_lastZoneCheckLogTime!) >=
                const Duration(seconds: 30)) {
          if (_zoneCheckSuppressedCount > 0) {
            debugLog(
                '[GEOFENCE] Moved 100m+ while disconnected, rechecking zone (suppressed $_zoneCheckSuppressedCount similar in last 30s)');
          } else {
            debugLog(
                '[GEOFENCE] Moved 100m+ while disconnected, rechecking zone');
          }
          _lastZoneCheckLogTime = now;
          _zoneCheckSuppressedCount = 0;
        } else {
          _zoneCheckSuppressedCount++;
        }
        await checkZoneStatus();
      }

      // Check RX batch distance triggers when GPS position updates
      // This ensures batches flush when user moves 25m, even if no new packets arrive
      // GPS fires every 10m, but batches only flush at 25m threshold
      if (_rxLogger != null && _rxLogger!.isWardriving) {
        await _rxLogger!.checkDistanceTriggers(
          (lat: position.latitude, lon: position.longitude),
        );
      }
    });
    debugLog('[INIT] GPS position listener attached to stream');

    // Start GPS (may skip if permissions not yet granted - disclosure flow handles that)
    debugLog('[INIT] Starting GPS service...');
    await _gpsService.startWatching();
    debugLog('[INIT] GPS service started, status: ${_gpsService.status}');

    // Initialize audio service for sound notifications
    await _audioService.initialize();

    debugLog('[INIT] AppStateProvider initialization complete');
    debugLog('[INIT] Final init state: gpsStatus=$_gpsStatus, '
        'inZone=$_inZone, isCheckingZone=$_isCheckingZone, hasPosition=${_currentPosition != null}, '
        'offlineMode=${_preferences.offlineMode}');
    notifyListeners();
  }

  /// Restart GPS service after permission disclosure is accepted
  /// Called from MainScaffold after user grants location permission
  Future<void> restartGpsAfterPermission() async {
    debugLog('[GPS] restartGpsAfterPermission() called');
    debugLog('[GPS] Pre-restart state: gpsStatus=$_gpsStatus, inZone=$_inZone, '
        'isCheckingZone=$_isCheckingZone, hasPosition=${_currentPosition != null}');

    await _gpsService.startWatching();
    _gpsStatus = _gpsService.status; // Sync after restart

    debugLog('[GPS] GPS restarted, new status: $_gpsStatus');
    debugLog(
        '[GPS] Post-restart state: inZone=$_inZone, isCheckingZone=$_isCheckingZone, '
        'hasPosition=${_currentPosition != null}');

    // If we now have a position and zone hasn't been checked, trigger check
    if (_currentPosition != null &&
        _inZone == null &&
        !_preferences.offlineMode) {
      debugLog(
          '[GPS] Permission granted with existing position - triggering zone check');
      await checkZoneStatus();
    }
    notifyListeners();
  }

  // ============================================
  // Bluetooth Scanning
  // ============================================

  /// Start scanning for MeshCore devices
  Future<void> startScan() async {
    debugLog('[SCAN] startScan() called');
    if (_isScanning) return;

    // Check permissions
    try {
      final hasPermission = await _bluetoothService.requestPermissions();
      debugLog('[SCAN] BLE permissions: $hasPermission');
      if (!hasPermission) {
        debugLog('[SCAN] Bluetooth permissions not granted');
        _connectionError = 'Bluetooth permissions not granted';
        notifyListeners();
        return;
      }
    } on BlePermissionDeniedException catch (e) {
      // Permissions are permanently denied - user must enable in Settings
      debugLog('[SCAN] BLE permission permanently denied: ${e.message}');
      _connectionError = e.message;
      notifyListeners();
      return;
    }

    // Check if Bluetooth is available
    final isAvailable = await _bluetoothService.isAvailable();
    debugLog('[SCAN] BLE available: $isAvailable');
    if (!isAvailable) {
      debugLog('[SCAN] Bluetooth not available on this device');
      _connectionError = 'Bluetooth not available';
      notifyListeners();
      return;
    }

    // Check if Bluetooth is enabled (with retry for iOS permission race condition)
    // After granting Bluetooth permission on iOS, there's a brief delay before
    // the adapter state updates. Retry a few times to handle this.
    bool isEnabled = await _bluetoothService.isEnabled();
    debugLog('[SCAN] BLE enabled: $isEnabled');
    if (!isEnabled) {
      debugLog('[SCAN] Bluetooth not enabled, retrying...');
      for (int i = 0; i < 3 && !isEnabled; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        isEnabled = await _bluetoothService.isEnabled();
        debugLog('[SCAN] Retry ${i + 1}: isEnabled=$isEnabled');
      }
    }
    if (!isEnabled) {
      debugLog('[SCAN] Bluetooth still disabled after retries');
      _connectionError =
          'Bluetooth is disabled. Please enable Bluetooth and try again.';
      notifyListeners();
      return;
    }

    _isScanning = true;
    _discoveredDevices = [];
    _connectionError = null;
    _isAuthError = false;
    _isNetworkError = false;
    notifyListeners();

    // Listen for discovered devices using subscription so stopScan() can cancel
    DiscoveredDevice? selectedDevice;
    final completer = Completer<void>();
    _activeScanSubscription = _bluetoothService
        .scanForDevices(
      timeout: const Duration(seconds: 15),
    )
        .listen(
      (device) {
        if (!_discoveredDevices.any((d) => d.id == device.id)) {
          // Prefer remembered device name (from SelfInfo) over BLE cache
          var enrichedDevice = device;
          if (_rememberedDevice != null &&
              device.id == _rememberedDevice!.id &&
              device.name != _rememberedDevice!.name) {
            enrichedDevice = DiscoveredDevice(
              id: device.id,
              name: _rememberedDevice!.name,
              rssi: device.rssi,
            );
            debugLog(
                '[SCAN] Using remembered name "${_rememberedDevice!.name}" instead of BLE name "${device.name}"');
          }
          _discoveredDevices.add(enrichedDevice);
          selectedDevice = enrichedDevice;
          notifyListeners();
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (e) {
        debugError('[SCAN] Scan error: $e');
        if (!completer.isCompleted) completer.complete();
      },
    );
    await completer.future;
    _activeScanSubscription = null;

    _isScanning = false;
    notifyListeners();

    // On web platform, the Chrome BLE picker already handles device selection,
    // so auto-connect immediately after the picker returns (no second click needed)
    final webDevice = selectedDevice;
    if (kIsWeb && webDevice != null) {
      debugLog('[APP] Web platform: auto-connecting to selected device');
      await connectToDevice(webDevice);
    }
  }

  /// Stop scanning for devices
  Future<void> stopScan() async {
    await _activeScanSubscription?.cancel();
    _activeScanSubscription = null;
    await _bluetoothService.stopScan();
    _isScanning = false;
    notifyListeners();
  }

  // ============================================
  // Connection
  // ============================================

  /// Creates the two-stage auth callback for MeshCoreConnection Step 6.
  /// Shared by all transport types (BLE, TCP, USB Serial).
  Future<Map<String, dynamic>?> Function() _createAuthCallback() {
    return () async {
      final publicKey = _meshCoreConnection!.devicePublicKey;
      if (publicKey == null) {
        debugError('[APP] Cannot request auth: no public key');
        return {
          'success': false,
          'reason': 'no_public_key',
          'message': 'Device public key not available'
        };
      }

      // Anonymous mode: rename device before auth so mesh pings broadcast as "Anonymous"
      if (_preferences.anonymousMode && !_isAnonymousRenamed) {
        final realName = _meshCoreConnection!.selfInfo?.name;
        if (realName != null && realName.isNotEmpty) {
          if (realName == 'Anonymous') {
            final persisted = _deviceRealNames[publicKey];
            _originalDeviceName = persisted ?? realName;
            if (persisted != null) {
              debugLog(
                  '[CONN] Anonymous mode: recovered real name "$persisted" from Hive (firmware was stuck)');
            }
          } else {
            _originalDeviceName = realName;
          }
          try {
            await _meshCoreConnection!.setAdvertName('Anonymous');
            _isAnonymousRenamed = true;
            _displayDeviceName = 'Anonymous';
            if (_originalDeviceName != 'Anonymous') {
              _deviceRealNames[publicKey] = _originalDeviceName!;
              _saveDeviceRealNames();
            }
            debugLog(
                '[CONN] Anonymous mode: renamed from "$_originalDeviceName" to "Anonymous"');
            await Future.delayed(const Duration(milliseconds: 300));
          } catch (e) {
            debugError('[CONN] Anonymous mode: rename failed: $e');
          }
        }
      }

      // Resolve device name: use "Anonymous" if renamed, otherwise SelfInfo name
      String? deviceName;
      if (_isAnonymousRenamed) {
        deviceName = 'Anonymous';
      } else {
        var selfInfoName = _meshCoreConnection!.selfInfo?.name;
        if (selfInfoName == 'Anonymous') {
          final persistedName = _deviceRealNames[publicKey];
          if (persistedName != null) {
            debugLog(
                '[CONN] Detected stuck anonymous name, recovering to "$persistedName"');
            try {
              await _meshCoreConnection!.setAdvertName(persistedName);
              await Future.delayed(const Duration(milliseconds: 300));
              final refreshed = await _meshCoreConnection!.getSelfInfo();
              selfInfoName = refreshed.name;
              debugLog(
                  '[CONN] Confirmed firmware name restored to "$selfInfoName"');
              _clearPersistedRealName(publicKey);
            } catch (e) {
              debugError('[CONN] Failed to restore firmware name: $e');
              selfInfoName = persistedName;
            }
          } else {
            debugWarn(
                '[CONN] Firmware name is "Anonymous" but no persisted real name found');
          }
        }
        deviceName = selfInfoName ??
            connectedDeviceName?.replaceFirst('MeshCore-', '');
      }
      if (deviceName == null || deviceName.isEmpty) {
        debugError(
            '[APP] Cannot request auth: could not retrieve device name');
        return {
          'success': false,
          'reason': 'no_device_name',
          'message': 'Could not retrieve device name'
        };
      }

      // Stage 1: Try existing public_key authentication
      debugLog(
          '[APP] Stage 1: Attempting auth with public_key: ${publicKey.substring(0, 16)}...');

      final result = await _apiService.requestAuth(
        reason: 'connect',
        publicKey: publicKey,
        who: deviceName,
        appVersion: _appVersion,
        power: _preferences.powerLevel,
        iataCode: zoneCode ?? _preferences.iataCode,
        model: _meshCoreConnection!.deviceModel?.manufacturer ??
            _meshCoreConnection!.deviceInfo?.manufacturer ??
            'Unknown',
        radioFreq: _meshCoreConnection?.selfInfo?.radioConfigApi,
        lat: _currentPosition?.latitude,
        lon: _currentPosition?.longitude,
        accuracyMeters: _currentPosition?.accuracy,
      );

      if (result != null && result['maintenance'] == true) {
        _maintenanceMode = true;
        _maintenanceMessage = result['maintenance_message'] as String?;
        _maintenanceUrl = result['maintenance_url'] as String?;
        debugLog(
            '[MAINTENANCE] Auth returned maintenance: $_maintenanceMessage');
        _startMaintenancePolling();
        notifyListeners();
        return {
          'success': false,
          'reason': 'maintenance',
          'message': _maintenanceMessage ?? 'Service is under maintenance',
        };
      }

      if (result != null && result['success'] == true) {
        debugLog('[APP] Stage 1 succeeded: authenticated via public_key');
        if (result['type'] != null) {
          _authType = result['type'] as String;
          debugLog('[APP] Auth type: $_authType');
          notifyListeners();
        }
        _syncZoneCapacityFromAuth(result);
        return result;
      }

      if (result == null) {
        debugError('[APP] API unreachable - network error');
        return {
          'success': false,
          'reason': 'network_error',
          'message': 'Unable to reach the MeshMapper server',
        };
      }

      debugLog(
          '[APP] Stage 1 failed: ${result['message'] ?? 'Unknown error'}');

      final stage1Reason = result['reason'] as String?;
      if (stage1Reason == 'gps_inaccurate' || stage1Reason == 'gps_stale') {
        debugError(
            '[APP] Stage 1 failed for GPS reason ($stage1Reason), skipping Stage 2');
        return {
          'success': false,
          'reason': stage1Reason,
          'message': result['message'] as String?,
        };
      }

      // Stage 2: Auth failed, attempt registration via signed contact_uri
      debugLog('[APP] Stage 2: Attempting registration via contact_uri...');

      String? contactUri;
      try {
        debugLog('[APP] Requesting signed contact URI from device...');
        contactUri = await _meshCoreConnection!.exportContact();
        debugLog(
            '[APP] Received contact URI: ${contactUri.substring(0, 50)}...');
      } catch (e) {
        debugError('[APP] Failed to get contact URI from device: $e');
        return {
          'success': false,
          'reason': 'registration_failed',
          'message':
              'Companion not found in backend and failed to register via API'
        };
      }

      final registerResult = await _apiService.requestAuth(
        reason: 'register',
        contactUri: contactUri,
        who: deviceName,
        appVersion: _appVersion,
        power: _preferences.powerLevel,
        iataCode: zoneCode ?? _preferences.iataCode,
        model: _meshCoreConnection!.deviceModel?.manufacturer ??
            _meshCoreConnection!.deviceInfo?.manufacturer ??
            'Unknown',
        radioFreq: _meshCoreConnection?.selfInfo?.radioConfigApi,
        lat: _currentPosition?.latitude,
        lon: _currentPosition?.longitude,
        accuracyMeters: _currentPosition?.accuracy,
      );

      if (registerResult == null) {
        debugError('[APP] Stage 2 failed: network error (API unreachable)');
        return {
          'success': false,
          'reason': 'network_error',
          'message': 'Unable to reach the MeshMapper server',
        };
      }

      if (registerResult['success'] != true) {
        final serverReason =
            registerResult['reason'] as String? ?? 'registration_failed';
        final serverMessage = registerResult['message'] as String?;
        debugError(
            '[APP] Stage 2 failed: $serverReason - ${serverMessage ?? 'no message'}');

        // Diagnose stale ADVERT timestamp: the firmware refuses to set the
        // clock backwards (ERR code 6), so if the device's RTC is stuck in
        // the future the signed ADVERT will always be rejected by the server.
        // Query the device clock and surface an actionable error.
        if (serverMessage != null &&
            serverMessage.contains('Timestamp') &&
            _meshCoreConnection != null) {
          try {
            final deviceTime = await _meshCoreConnection!.getDeviceTime();
            final appTime =
                DateTime.now().millisecondsSinceEpoch ~/ 1000;
            final drift = deviceTime - appTime;
            debugError(
                '[APP] Device clock: $deviceTime, app clock: $appTime, drift: ${drift}s');
            if (drift > 3600) {
              final deviceDate = DateTime.fromMillisecondsSinceEpoch(
                  deviceTime * 1000,
                  isUtc: true);
              return {
                'success': false,
                'reason': 'clock_error',
                'message':
                    'Device clock is set to ${deviceDate.toIso8601String().substring(0, 10)}. '
                        'Power-cycle your device to reset it.',
              };
            }
          } catch (e) {
            debugWarn('[APP] Could not query device time: $e');
          }
        }

        return {
          'success': false,
          'reason': serverReason,
          'message': serverMessage ?? 'Registration rejected by server',
        };
      }

      debugLog('[APP] Stage 2 succeeded: registered and authenticated');
      if (registerResult['type'] != null) {
        _authType = registerResult['type'] as String;
        debugLog('[APP] Auth type: $_authType');
        notifyListeners();
      }
      _syncZoneCapacityFromAuth(registerResult);
      return registerResult;
    };
  }

  /// Handle connection errors — shared by all transport connection methods.
  Future<void> _handleConnectionError(Object e) async {
    debugError('[APP] Connection failed: $e');

    try {
      await _meshCoreConnection?.deleteWardrivingChannelEarly();
    } catch (channelError) {
      debugError('[APP] Cleanup channel delete failed: $channelError');
    }

    try {
      if (_meshCoreConnection != null) {
        await _meshCoreConnection!.disconnect();
      }
    } catch (disconnectError) {
      debugError('[APP] Cleanup disconnect failed: $disconnectError');
    }

    final errorStr = e.toString();
    if (errorStr.contains('AUTH_FAILED:')) {
      _isAuthError = true;
      final parts = errorStr.split('AUTH_FAILED:');
      if (parts.length > 1) {
        final errorParts = parts[1].split(':');
        final reason = errorParts.isNotEmpty ? errorParts[0] : 'unknown';
        final serverMessage =
            errorParts.length > 1 ? errorParts.sublist(1).join(':') : null;
        _isNetworkError = reason == 'network_error';
        _connectionError = _getErrorMessage(reason, serverMessage);
      } else {
        _connectionError = 'Authentication failed';
      }
    } else {
      _isAuthError = false;
      _isNetworkError = false;
      if (errorStr.contains('timeout') ||
          errorStr.contains('Timeout') ||
          errorStr.contains('timed out')) {
        _connectionError = 'Connection timed out';
      } else {
        _connectionError = errorStr.replaceFirst('Exception: ', '');
      }
    }
    _isConnecting = false;
    _connectionStep = ConnectionStep.error;
    notifyListeners();
  }

  /// Set up disconnect listener for non-BLE transports (TCP, USB Serial).
  void _setupTransportDisconnectListener(CompanionTransport transport) {
    _transportConnectionSubscription?.cancel();
    _transportConnectionSubscription =
        transport.connectionStream.listen((status) async {
      if (status == ConnectionStatus.disconnected) {
        final wasConnected = _connectionStep == ConnectionStep.connected;
        final hasRemembered = _rememberedDevice != null;
        final isUnexpected =
            !_userRequestedDisconnect && !_isAutoReconnecting;
        final canAutoReconnect = hasRemembered &&
            !kIsWeb &&
            _rememberedDevice!.transportType != TransportType.usbSerial;
        if (wasConnected && isUnexpected && canAutoReconnect) {
          debugLog(
              '[CONN] Unexpected transport disconnect - starting auto-reconnect');
          await _startAutoReconnect();
        } else if (!_isAutoReconnecting) {
          await _fullDisconnectCleanup();
        }
        notifyListeners();
      }
    });
  }

  /// Connect to a discovered device
  Future<void> connectToDevice(DiscoveredDevice device) async {
    if (_isConnecting) {
      debugLog('[APP] Connection already in progress, ignoring duplicate tap');
      return;
    }
    _isConnecting = true;
    _connectionStep = ConnectionStep.transportConnecting;
    _connectionError = null;
    _isAuthError = false;
    _isNetworkError = false;
    notifyListeners();
    try {
      // Clean up any previous connection first
      if (_meshCoreConnection != null) {
        debugLog('[APP] Disposing previous MeshCoreConnection');
        _meshCoreConnection!.dispose();
        _meshCoreConnection = null;
      }

      // ALWAYS START FRESH - clear any stale pings before connecting
      await _apiQueueService.clearBeforeConnect();

      debugLog('[APP] Connecting BLE transport to ${device.id}');
      await _bluetoothService.connect(device.id);
      _activeTransport = _bluetoothService;
      debugLog('[APP] Creating new MeshCoreConnection');
      _meshCoreConnection = MeshCoreConnection(transport: _bluetoothService);

      if (!_preferences.offlineMode) {
        _meshCoreConnection!.onRequestAuth = _createAuthCallback();
      } else {
        _meshCoreConnection!.onRequestAuth = null;
        debugLog('[APP] Offline mode: skipping API auth');
      }

      // Listen for step changes
      _meshCoreConnection!.stepStream.listen((step) {
        _connectionStep = step;
        if (step == ConnectionStep.connected) {
          // Update device info
          _manufacturerString = _meshCoreConnection!.deviceInfo?.manufacturer;
          _firmwareVersionString =
              _meshCoreConnection!.deviceInfo?.firmwareVersionString;
          _deviceModel = _meshCoreConnection!.deviceModel;
          _devicePublicKey = _meshCoreConnection!.devicePublicKey;
          debugLog(
              '[APP] Device public key stored: ${_devicePublicKey?.substring(0, 16) ?? 'null'}...');

          // Persist device info for bug reports when disconnected
          // Use original name (not "Anonymous") for bug report identification
          var lastDeviceName = _isAnonymousRenamed
              ? _originalDeviceName
              : (_meshCoreConnection!.selfInfo?.name ?? connectedDeviceName);
          if (lastDeviceName != null) {
            lastDeviceName = lastDeviceName.replaceFirst('MeshCore-', '');
          }
          // Cascade guard: never persist "Anonymous" as the last connected device
          if (lastDeviceName == 'Anonymous' && _devicePublicKey != null) {
            lastDeviceName =
                _deviceRealNames[_devicePublicKey!] ?? lastDeviceName;
          }
          if (lastDeviceName != null &&
              lastDeviceName.isNotEmpty &&
              _devicePublicKey != null) {
            _saveLastConnectedDevice(lastDeviceName, _devicePublicKey!);
          }

          // In offline mode, fetch signed contact URI for later registration during upload
          if (_preferences.offlineMode && _meshCoreConnection != null) {
            _meshCoreConnection!.exportContact().then((uri) {
              _offlineContactUri = uri;
              debugLog('[OFFLINE] Stored contact URI for offline session');
            }).catchError((e) {
              debugWarn('[OFFLINE] Failed to get contact URI: $e');
            });
          }
        }
        notifyListeners();
      });

      // Listen for noise floor updates — only rebuild UI when value changes
      _noiseFloorSubscription =
          _meshCoreConnection!.noiseFloorStream.listen((noiseFloor) {
        _recordNoiseFloorSample(noiseFloor);
        if (noiseFloor != _currentNoiseFloor) {
          _currentNoiseFloor = noiseFloor;
          notifyListeners();
        }
      });

      // Listen for battery updates — only rebuild UI when value changes
      _batterySubscription =
          _meshCoreConnection!.batteryStream.listen((batteryPercent) {
        if (batteryPercent != _currentBatteryPercent) {
          _currentBatteryPercent = batteryPercent;
          notifyListeners();
        }
      });

      // Execute connection workflow (transport already connected above)
      final connectionResult = await _meshCoreConnection!.connect(
        _deviceModelService.models,
      );

      await _postConnectionSetup(connectionResult, device);
      _isConnecting = false;
    } catch (e) {
      await _handleConnectionError(e);
    }
  }

  /// Set the selected transport type for the connection screen.
  void setSelectedTransport(TransportType type) {
    _selectedTransport = type;
    notifyListeners();
  }

  /// Connect to a MeshCore device via TCP.
  Future<void> connectViaTcp(String host, int port) async {
    if (_isConnecting) {
      debugLog('[APP] Connection already in progress, ignoring duplicate tap');
      return;
    }
    _isConnecting = true;
    _connectionStep = ConnectionStep.transportConnecting;
    _connectionError = null;
    _isAuthError = false;
    _isNetworkError = false;
    notifyListeners();
    try {
      if (_meshCoreConnection != null) {
        debugLog('[APP] Disposing previous MeshCoreConnection');
        _meshCoreConnection!.dispose();
        _meshCoreConnection = null;
      }

      await _apiQueueService.clearBeforeConnect();

      final tcpService = TcpService(host: host, port: port);
      debugLog('[APP] Connecting TCP transport to $host:$port');
      await tcpService.openConnection();
      _activeTransport = tcpService;
      _setupTransportDisconnectListener(tcpService);

      debugLog('[APP] Creating new MeshCoreConnection (TCP)');
      _meshCoreConnection = MeshCoreConnection(transport: tcpService);

      if (!_preferences.offlineMode) {
        _meshCoreConnection!.onRequestAuth = _createAuthCallback();
      } else {
        _meshCoreConnection!.onRequestAuth = null;
        debugLog('[APP] Offline mode: skipping API auth');
      }

      _meshCoreConnection!.stepStream.listen((step) {
        _connectionStep = step;
        if (step == ConnectionStep.connected) {
          _manufacturerString =
              _meshCoreConnection!.deviceInfo?.manufacturer;
          _firmwareVersionString =
              _meshCoreConnection!.deviceInfo?.firmwareVersionString;
          _deviceModel = _meshCoreConnection!.deviceModel;
          _devicePublicKey = _meshCoreConnection!.devicePublicKey;
          debugLog(
              '[APP] Device public key stored: ${_devicePublicKey?.substring(0, 16) ?? 'null'}...');

          var lastDeviceName = _isAnonymousRenamed
              ? _originalDeviceName
              : (_meshCoreConnection!.selfInfo?.name ?? connectedDeviceName);
          if (lastDeviceName != null) {
            lastDeviceName = lastDeviceName.replaceFirst('MeshCore-', '');
          }
          if (lastDeviceName == 'Anonymous' && _devicePublicKey != null) {
            lastDeviceName =
                _deviceRealNames[_devicePublicKey!] ?? lastDeviceName;
          }
          if (lastDeviceName != null &&
              lastDeviceName.isNotEmpty &&
              _devicePublicKey != null) {
            _saveLastConnectedDevice(lastDeviceName, _devicePublicKey!);
          }

          if (_preferences.offlineMode && _meshCoreConnection != null) {
            _meshCoreConnection!.exportContact().then((uri) {
              _offlineContactUri = uri;
              debugLog('[OFFLINE] Stored contact URI for offline session');
            }).catchError((e) {
              debugWarn('[OFFLINE] Failed to get contact URI: $e');
            });
          }
        }
        notifyListeners();
      });

      _noiseFloorSubscription =
          _meshCoreConnection!.noiseFloorStream.listen((noiseFloor) {
        _recordNoiseFloorSample(noiseFloor);
        if (noiseFloor != _currentNoiseFloor) {
          _currentNoiseFloor = noiseFloor;
          notifyListeners();
        }
      });

      _batterySubscription =
          _meshCoreConnection!.batteryStream.listen((batteryPercent) {
        if (batteryPercent != _currentBatteryPercent) {
          _currentBatteryPercent = batteryPercent;
          notifyListeners();
        }
      });

      final connectionResult = await _meshCoreConnection!.connect(
        _deviceModelService.models,
      );

      final device = DiscoveredDevice(
        id: '$host:$port',
        name: 'TCP $host:$port',
      );
      await _postConnectionSetup(connectionResult, device,
          tcpHost: host, tcpPort: port);

      await TcpService.saveConnection(host, port, displayDeviceName ?? '');
      _isConnecting = false;
    } catch (e) {
      await _handleConnectionError(e);
      if (_activeTransport != null && _activeTransport != _bluetoothService) {
        _activeTransport!.dispose();
      }
      _activeTransport = null;
      _transportConnectionSubscription?.cancel();
    }
  }

  /// Connect to a MeshCore device via Android USB Serial (OTG).
  Future<void> connectViaUsb(Map<String, dynamic> usbDevice) async {
    if (_isConnecting) {
      debugLog('[APP] Connection already in progress, ignoring duplicate tap');
      return;
    }
    _isConnecting = true;
    _connectionStep = ConnectionStep.transportConnecting;
    _connectionError = null;
    _isAuthError = false;
    _isNetworkError = false;
    notifyListeners();
    try {
      if (_meshCoreConnection != null) {
        debugLog('[APP] Disposing previous MeshCoreConnection');
        _meshCoreConnection!.dispose();
        _meshCoreConnection = null;
      }

      if (_activeTransport != null && _activeTransport != _bluetoothService) {
        _activeTransport!.dispose();
      }
      _activeTransport = null;
      _transportConnectionSubscription?.cancel();

      await _apiQueueService.clearBeforeConnect();

      final usbProductName =
          usbDevice['productName'] as String? ?? 'USB Serial';
      final usbDeviceName =
          usbDevice['deviceName'] as String? ?? 'USB Serial';
      final serialService = AndroidSerialService(
        deviceName: usbDeviceName,
        productName: usbProductName,
      );
      debugLog('[APP] Connecting USB Serial transport to $usbProductName');
      await serialService.openConnection();
      _activeTransport = serialService;
      _setupTransportDisconnectListener(serialService);

      debugLog('[APP] Creating new MeshCoreConnection (USB Serial)');
      _meshCoreConnection = MeshCoreConnection(transport: serialService);

      if (!_preferences.offlineMode) {
        _meshCoreConnection!.onRequestAuth = _createAuthCallback();
      } else {
        _meshCoreConnection!.onRequestAuth = null;
        debugLog('[APP] Offline mode: skipping API auth');
      }

      _meshCoreConnection!.stepStream.listen((step) {
        _connectionStep = step;
        if (step == ConnectionStep.connected) {
          _manufacturerString =
              _meshCoreConnection!.deviceInfo?.manufacturer;
          _firmwareVersionString =
              _meshCoreConnection!.deviceInfo?.firmwareVersionString;
          _deviceModel = _meshCoreConnection!.deviceModel;
          _devicePublicKey = _meshCoreConnection!.devicePublicKey;
          debugLog(
              '[APP] Device public key stored: ${_devicePublicKey?.substring(0, 16) ?? 'null'}...');

          var lastDeviceName = _isAnonymousRenamed
              ? _originalDeviceName
              : (_meshCoreConnection!.selfInfo?.name ?? connectedDeviceName);
          if (lastDeviceName != null) {
            lastDeviceName = lastDeviceName.replaceFirst('MeshCore-', '');
          }
          if (lastDeviceName == 'Anonymous' && _devicePublicKey != null) {
            lastDeviceName =
                _deviceRealNames[_devicePublicKey!] ?? lastDeviceName;
          }
          if (lastDeviceName != null &&
              lastDeviceName.isNotEmpty &&
              _devicePublicKey != null) {
            _saveLastConnectedDevice(lastDeviceName, _devicePublicKey!);
          }

          if (_preferences.offlineMode && _meshCoreConnection != null) {
            _meshCoreConnection!.exportContact().then((uri) {
              _offlineContactUri = uri;
              debugLog('[OFFLINE] Stored contact URI for offline session');
            }).catchError((e) {
              debugWarn('[OFFLINE] Failed to get contact URI: $e');
            });
          }
        }
        notifyListeners();
      });

      _noiseFloorSubscription =
          _meshCoreConnection!.noiseFloorStream.listen((noiseFloor) {
        _recordNoiseFloorSample(noiseFloor);
        if (noiseFloor != _currentNoiseFloor) {
          _currentNoiseFloor = noiseFloor;
          notifyListeners();
        }
      });

      _batterySubscription =
          _meshCoreConnection!.batteryStream.listen((batteryPercent) {
        if (batteryPercent != _currentBatteryPercent) {
          _currentBatteryPercent = batteryPercent;
          notifyListeners();
        }
      });

      final connectionResult = await _meshCoreConnection!.connect(
        _deviceModelService.models,
      );

      final vid = usbDevice['vid'] as int? ?? 0;
      final pid = usbDevice['pid'] as int? ?? 0;
      final serial = usbDevice['serial'] as String? ?? '';
      final deviceId = '$vid:$pid:$serial';
      final device = DiscoveredDevice(
        id: deviceId,
        name: usbProductName,
      );
      await _postConnectionSetup(connectionResult, device,
          serialPortPath: deviceId);
      _isConnecting = false;
    } catch (e) {
      await _handleConnectionError(e);
      if (_activeTransport != null && _activeTransport != _bluetoothService) {
        _activeTransport!.dispose();
      }
      _activeTransport = null;
      _transportConnectionSubscription?.cancel();
    }
  }

  /// Connect using a pre-opened transport (for platform-specific transports
  /// like Web Serial that can't be imported cross-platform).
  Future<void> connectWithTransport(
    CompanionTransport transport, {
    required String deviceId,
    required String deviceName,
    String? serialPortPath,
  }) async {
    if (_isConnecting) {
      debugLog('[APP] Connection already in progress, ignoring duplicate tap');
      return;
    }
    _isConnecting = true;
    _connectionStep = ConnectionStep.transportConnecting;
    _connectionError = null;
    _isAuthError = false;
    _isNetworkError = false;
    notifyListeners();
    try {
      if (_meshCoreConnection != null) {
        debugLog('[APP] Disposing previous MeshCoreConnection');
        _meshCoreConnection!.dispose();
        _meshCoreConnection = null;
      }

      await _apiQueueService.clearBeforeConnect();

      _activeTransport = transport;
      _setupTransportDisconnectListener(transport);

      debugLog('[APP] Creating new MeshCoreConnection (generic transport)');
      _meshCoreConnection = MeshCoreConnection(transport: transport);

      if (!_preferences.offlineMode) {
        _meshCoreConnection!.onRequestAuth = _createAuthCallback();
      } else {
        _meshCoreConnection!.onRequestAuth = null;
        debugLog('[APP] Offline mode: skipping API auth');
      }

      _meshCoreConnection!.stepStream.listen((step) {
        _connectionStep = step;
        if (step == ConnectionStep.connected) {
          _manufacturerString =
              _meshCoreConnection!.deviceInfo?.manufacturer;
          _firmwareVersionString =
              _meshCoreConnection!.deviceInfo?.firmwareVersionString;
          _deviceModel = _meshCoreConnection!.deviceModel;
          _devicePublicKey = _meshCoreConnection!.devicePublicKey;
          debugLog(
              '[APP] Device public key stored: ${_devicePublicKey?.substring(0, 16) ?? 'null'}...');

          var lastDeviceName = _isAnonymousRenamed
              ? _originalDeviceName
              : (_meshCoreConnection!.selfInfo?.name ?? connectedDeviceName);
          if (lastDeviceName != null) {
            lastDeviceName = lastDeviceName.replaceFirst('MeshCore-', '');
          }
          if (lastDeviceName == 'Anonymous' && _devicePublicKey != null) {
            lastDeviceName =
                _deviceRealNames[_devicePublicKey!] ?? lastDeviceName;
          }
          if (lastDeviceName != null &&
              lastDeviceName.isNotEmpty &&
              _devicePublicKey != null) {
            _saveLastConnectedDevice(lastDeviceName, _devicePublicKey!);
          }

          if (_preferences.offlineMode && _meshCoreConnection != null) {
            _meshCoreConnection!.exportContact().then((uri) {
              _offlineContactUri = uri;
              debugLog('[OFFLINE] Stored contact URI for offline session');
            }).catchError((e) {
              debugWarn('[OFFLINE] Failed to get contact URI: $e');
            });
          }
        }
        notifyListeners();
      });

      _noiseFloorSubscription =
          _meshCoreConnection!.noiseFloorStream.listen((noiseFloor) {
        _recordNoiseFloorSample(noiseFloor);
        if (noiseFloor != _currentNoiseFloor) {
          _currentNoiseFloor = noiseFloor;
          notifyListeners();
        }
      });

      _batterySubscription =
          _meshCoreConnection!.batteryStream.listen((batteryPercent) {
        if (batteryPercent != _currentBatteryPercent) {
          _currentBatteryPercent = batteryPercent;
          notifyListeners();
        }
      });

      final connectionResult = await _meshCoreConnection!.connect(
        _deviceModelService.models,
      );

      final device = DiscoveredDevice(id: deviceId, name: deviceName);
      await _postConnectionSetup(connectionResult, device,
          serialPortPath: serialPortPath);
      _isConnecting = false;
    } catch (e) {
      await _handleConnectionError(e);
      if (_activeTransport != null && _activeTransport != _bluetoothService) {
        _activeTransport!.dispose();
      }
      _activeTransport = null;
      _transportConnectionSubscription?.cancel();
    }
  }

  /// Post-connection setup shared by all transport types.
  /// Called after MeshCoreConnection.connect() completes successfully.
  Future<void> _postConnectionSetup(
    ({DeviceModel? deviceModel, bool deviceModelMatched}) connectionResult,
    DiscoveredDevice device, {
    String? tcpHost,
    int? tcpPort,
    String? serialPortPath,
  }) async {
    if (connectionResult.deviceModelMatched &&
        connectionResult.deviceModel != null) {
      final matchedDevice = connectionResult.deviceModel!;
      _preferences = _preferences.copyWith(
        powerLevel: matchedDevice.power,
        txPower: matchedDevice.txPower,
        autoPowerSet: true,
        powerLevelSet: false,
      );
      notifyListeners();
      debugLog(
          '[MODEL] Device recognized: ${matchedDevice.shortName} - reporting ${matchedDevice.power}W in API calls');
    }

    await _createUnifiedRxHandler();

    final apiChannels = _apiService.channels;
    await ChannelService.setRegionalChannels(apiChannels);
    _regionalChannels = ChannelService.getRegionalChannelNames();
    debugLog('[APP] Regional channels configured: $_regionalChannels');

    if (_unifiedRxHandler != null) {
      final allowedChannelsData =
          ChannelService.getAllowedChannelsForValidator();
      final allowedChannels = <int, ChannelInfo>{};
      for (final entry in allowedChannelsData.entries) {
        allowedChannels[entry.key] = ChannelInfo(
          channelName: entry.value.channelName,
          key: entry.value.key,
          hash: entry.value.hash,
        );
      }
      final newValidator = PacketValidator(
        allowedChannels: allowedChannels,
        disableRssiFilter: _preferences.disableRssiFilter,
      );
      _unifiedRxHandler!.updateValidator(newValidator);
      debugLog(
          '[APP] PacketValidator updated with ${allowedChannels.length} channels: '
          '${allowedChannelsData.values.map((c) => c.channelName).join(', ')}');
    }

    final apiScopes = _apiService.scopes;
    final firstScope = apiScopes.isNotEmpty ? apiScopes.first : null;
    final isWildcard =
        firstScope == null || firstScope == '*' || firstScope == '#*';
    if (!isWildcard) {
      final scopeName = firstScope;
      _scope = scopeName.startsWith('#') ? scopeName : '#$scopeName';
      final scopeKey = CryptoService.deriveScopeKey(scopeName);
      debugLog('[CONN] Setting flood scope: $scopeName');
      await _meshCoreConnection!.setFloodScope(scopeKey);
      debugLog('[CONN] Flood scope set successfully');
    } else {
      _scope = null;
      debugLog('[CONN] No regional scope — using unscoped flood');
    }

    // Snapshot user's preferences before zone admin overrides (single baseline)
    _userOriginalAutoPingInterval = _preferences.autoPingInterval;
    _userOriginalHybridMode = _preferences.hybridModeEnabled;
    _userOriginalDiscDrop = _preferences.discDropEnabled;
    _userOriginalFloodTraffic = _preferences.floodTrafficEnabled;

    if (_apiService.enforceHybrid && !_preferences.hybridModeEnabled) {
      _preferences = _preferences.copyWith(hybridModeEnabled: true);
      debugLog('[CONN] Hybrid mode force-enabled by regional admin');
    }

    if (_apiService.enforceDiscDrop && !_preferences.discDropEnabled) {
      _preferences = _preferences.copyWith(discDropEnabled: true);
      debugLog('[CONN] Discovery drop force-enabled by regional admin');
    }

    final wasFloodEnabledByUser = _preferences.floodTrafficEnabled;
    final shouldEnableFlood = !_apiService.floodDisabled;
    if (_preferences.floodTrafficEnabled != shouldEnableFlood) {
      _preferences =
          _preferences.copyWith(floodTrafficEnabled: shouldEnableFlood);
      debugLog(shouldEnableFlood
          ? '[CONN] Flood traffic auto-enabled (region permits)'
          : '[CONN] Flood traffic disabled by regional admin');
    }
    if (wasFloodEnabledByUser && _apiService.floodDisabled) {
      _floodDisabledAlertPending = true;
    }

    if (_preferences.autoPingInterval < _apiService.minModeInterval) {
      _preferences = _preferences.copyWith(
          autoPingInterval: _apiService.minModeInterval);
      debugLog(
          '[CONN] Auto-ping interval bumped to ${_apiService.minModeInterval}s by regional admin');
    }

    await _configurePathHashMode();

    _pingService = PingService(
      gpsService: _gpsService,
      connection: _meshCoreConnection!,
      apiQueue: _apiQueueService,
      wakelockService: WakelockService(),
      cooldownTimer: _cooldownTimer,
      manualPingCooldownTimer: _manualPingCooldownTimer,
      rxWindowTimer: _rxWindowTimer,
      discoveryWindowTimer: _discoveryWindowTimer,
      deviceId: _deviceId,
      txTracker: _txTracker,
      audioService: _audioService,
      disableRssiFilter: _preferences.disableRssiFilter,
      hopBytes: effectiveHopBytes,
      traceHopBytes: _traceHopBytes,
      shouldIgnoreRepeater: (String repeaterId) {
        final prefs = _preferences;
        if (prefs.ignoreCarpeater && prefs.ignoreRepeaterId != null) {
          return PacketValidator.isCarpeaterIdMatch(
              repeaterId, prefs.ignoreRepeaterId!);
        }
        return false;
      },
    );

    _pingService!.unifiedRxHandler = _unifiedRxHandler;

    _pingService!.checkExternalAntennaConfigured = () {
      return _preferences.externalAntennaSet;
    };

    _pingService!.checkPowerLevelConfigured = () {
      return _preferences.autoPowerSet ||
          _preferences.powerLevelSet ||
          _deviceModel != null;
    };

    _pingService!.getExternalAntenna = () => _preferences.externalAntenna;
    _pingService!.getPowerLevel = () => _preferences.powerLevel;
    _pingService!.checkTxAllowed = () => txAllowed;
    _pingService!.getDiscDropEnabled = () => discDropEnabled;

    // Wire-tag composition (privacy-preserving TX body by default).
    _pingService!.getSessionId = () => _apiService.sessionId;
    _pingService!.getWireKey = () => _apiService.wireKey;
    _pingService!.getNextPingCounter = () => _apiService.nextPingCounter();
    _pingService!.getBroadcastCoords = () => _preferences.broadcastCoords;
    _pingService!.getPingCounter = () => _apiService.pingCounter;
    _pingService!.onSessionLimitReached =
        () => handleSessionError('session_limit', null);

    _pingService!.onTxPing = (ping) {
      _markLiveActivityOperation(_LiveActivityOperation.sending);
      _txPings.add(ping);
      if (_txPings.length > _maxMapPins) _txPings.removeAt(0);

      _txLogEntries.add(TxLogEntry(
        timestamp: ping.timestamp,
        latitude: ping.latitude,
        longitude: ping.longitude,
        power: _preferences.powerLevel,
        events: [],
      ));
      if (_txLogEntries.length > _maxLogEntries) _txLogEntries.removeAt(0);

      _notifyMapNow();
    };

    _pingService!.onRxPing = (ping) {
      _rxPings.add(ping);
      if (_rxPings.length > _maxMapPins) _rxPings.removeAt(0);

      _rxLogEntries.add(RxLogEntry(
        timestamp: ping.timestamp,
        repeaterId: ping.repeaterId,
        snr: ping.snr,
        rssi: ping.rssi,
        pathLength: 0,
        header: 0,
        latitude: ping.latitude,
        longitude: ping.longitude,
      ));
      if (_rxLogEntries.length > _maxLogEntries) _rxLogEntries.removeAt(0);

      _updateRxOverlaySlot(ping.repeaterId, ping.snr);
      _notifyMapThrottled();
    };

    _pingService!.onStatsUpdated = (stats) {
      _pingStats = stats.copyWith(
        rxCount: _pingStats.rxCount,
        successfulUploads: _pingStats.successfulUploads,
      );
      notifyListeners();

      if (_autoPingEnabled) {
        final modeName = _autoMode == AutoMode.passive
            ? 'Passive Mode'
            : _autoMode == AutoMode.hybrid
                ? 'Hybrid Mode'
                : _autoMode == AutoMode.targeted
                    ? 'Trace Mode'
                    : 'Active Mode';
        BackgroundServiceManager.updateNotification(
          mode: modeName,
          txCount: _pingStats.txCount,
          rxCount: _pingStats.rxCount,
          queueSize: _queueSize,
        );
      }
    };

    _pingService!.onEchoReceived = (txPing, repeater, isNew) {
      debugLog('[APP] ========== ECHO CALLBACK RECEIVED ==========');
      debugLog(
          '[APP] Real-time echo: ${repeater.repeaterId} (SNR: ${repeater.snr ?? 'null'}, isNew: $isNew)');
      debugLog('[APP] TxLogEntries count: ${_txLogEntries.length}');

      if (_txLogEntries.isNotEmpty) {
        final lastEntry = _txLogEntries.last;
        final timeDiff =
            lastEntry.timestamp.difference(txPing.timestamp).inSeconds.abs();
        if (timeDiff <= 10) {
          final existingEvents = List<RxEvent>.from(lastEntry.events);
          final newEvent = RxEvent(
            repeaterId: repeater.repeaterId,
            snr: repeater.snr,
            rssi: repeater.rssi,
          );

          if (isNew) {
            existingEvents.add(newEvent);
            _audioService.playReceiveSound();
          } else {
            final idx = existingEvents
                .indexWhere((e) => e.repeaterId == repeater.repeaterId);
            if (idx >= 0) {
              existingEvents[idx] = newEvent;
            }
          }

          final updatedEntry = TxLogEntry(
            timestamp: lastEntry.timestamp,
            latitude: lastEntry.latitude,
            longitude: lastEntry.longitude,
            power: lastEntry.power,
            events: existingEvents,
            multiHopEvents: lastEntry.multiHopEvents,
          );
          _txLogEntries[_txLogEntries.length - 1] = updatedEntry;
          debugLog(
              '[APP] Updated TxLogEntry with ${existingEvents.length} direct, '
              '${lastEntry.multiHopEvents.length} multi-hop events (real-time)');

          final directRepeaters = existingEvents
              .where((event) => event.snr != null)
              .map((event) => (
                    repeaterId: event.repeaterId.toUpperCase(),
                    snr: event.snr!,
                  ))
              .toList(growable: false);
          _updateTopRepeaters(directRepeaters, OverlayPingType.tx);
          _updateLiveActivityRepeaters([
            ...directRepeaters,
            ...lastEntry.multiHopEvents
                .where((event) => event.snr != null)
                .map((event) => (
                      repeaterId: event.repeaterId.toUpperCase(),
                      snr: event.snr!,
                    )),
          ], OverlayPingType.tx);

          debugLog('[APP] Calling notifyListeners() to update UI');
          _notifyMapThrottled();
          debugLog('[APP] notifyListeners() completed');
        } else {
          debugLog(
              '[APP] Timestamp mismatch: lastEntry=${lastEntry.timestamp}, txPing=${txPing.timestamp}, diff=${timeDiff}s');
        }
      } else {
        debugLog('[APP] WARNING: _txLogEntries is empty, cannot update');
      }
    };

    _pingService!.onMultiHopEchoReceived =
        (txPing, repeaterId, snr, rssi, pathHops, isNew) {
      debugLog(
          '[APP] Multi-hop echo: $repeaterId, hops=${pathHops.length}, isNew=$isNew');

      if (_txLogEntries.isNotEmpty) {
        final lastEntry = _txLogEntries.last;
        final timeDiff =
            lastEntry.timestamp.difference(txPing.timestamp).inSeconds.abs();
        if (timeDiff <= 10) {
          final multiHopEvents =
              List<MultiHopEchoEvent>.from(lastEntry.multiHopEvents);
          final newEvent = MultiHopEchoEvent(
            repeaterId: repeaterId,
            snr: snr,
            rssi: rssi,
            pathHops: pathHops,
          );

          if (isNew) {
            multiHopEvents.add(newEvent);
            _audioService.playReceiveSound();
            _pingStats =
                _pingStats.copyWith(rxCount: _pingStats.rxCount + 1);
          } else {
            final idx = multiHopEvents
                .indexWhere((e) => e.repeaterId == repeaterId);
            if (idx >= 0) {
              multiHopEvents[idx] = newEvent;
            }
          }

          _txLogEntries[_txLogEntries.length - 1] = TxLogEntry(
            timestamp: lastEntry.timestamp,
            latitude: lastEntry.latitude,
            longitude: lastEntry.longitude,
            power: lastEntry.power,
            events: lastEntry.events,
            multiHopEvents: multiHopEvents,
          );

          _updateLiveActivityRepeaters([
            ...lastEntry.events
                .where((event) => event.snr != null)
                .map((event) => (
                      repeaterId: event.repeaterId.toUpperCase(),
                      snr: event.snr!,
                    )),
            ...multiHopEvents
                .where((event) => event.snr != null)
                .map((event) => (
                      repeaterId: event.repeaterId.toUpperCase(),
                      snr: event.snr!,
                    )),
          ], OverlayPingType.tx);

          _notifyMapThrottled();
        }
      }
    };

    _pingService!.onPingProgressChanged = notifyListeners;

    _pingService!.onAutoPingScheduled = (intervalMs, skipReason) {
      _liveActivityOperation = null;
      _autoPingTimer.startWithSkipReason(intervalMs, skipReason);

      if (skipReason != null) {
        if (_preferences.autoStopAfterIdle &&
            _idleAutoStopReference != null) {
          final elapsed =
              DateTime.now().difference(_idleAutoStopReference!);
          if (elapsed >= _autoStopIdleTimeout) {
            _triggerIdleAutoStop();
          }
        }
      } else {
        _idleAutoStopReference = DateTime.now();
      }
    };

    _pingService!.onDiscPing = (entry) {
      _markLiveActivityOperation(_LiveActivityOperation.discovering);
      _addDiscLogEntry(entry);
    };

    _pingService!.onDiscNodeDiscovered = (discPing, nodeEntry, isNew) {
      debugLog(
          '[APP] Real-time disc node: ${nodeEntry.repeaterId}, isNew=$isNew');
      if (isNew) {
        _audioService.playReceiveSound();
      }

      final heardRepeaters = discPing.discoveredNodes
          .map((node) => (
                repeaterId: node.repeaterId.toUpperCase(),
                snr: node.localSnr,
              ))
          .toList(growable: false);
      _updateTopRepeaters(heardRepeaters, OverlayPingType.disc);
      _updateLiveActivityRepeaters(heardRepeaters, OverlayPingType.disc);

      _notifyMapThrottled();
    };

    _pingService!.onTxWindowComplete = (directSuccess, multiHopEchoes) {
      _liveActivityOperation = null;
      double? lat;
      double? lon;
      List<MarkerRepeaterInfo>? allRepeaters;
      final heardRepeaters = <({String repeaterId, double snr})>[];

      if (_txLogEntries.isNotEmpty) {
        final lastTx = _txLogEntries.last;
        lat = lastTx.latitude;
        lon = lastTx.longitude;

        final directRepeaters = lastTx.events
            .map((e) => MarkerRepeaterInfo(
                  repeaterId: e.repeaterId,
                  snr: e.snr ?? 0.0,
                  rssi: e.rssi ?? 0,
                ))
            .toList();

        final multiHopRepeaters = multiHopEchoes
            .map((e) => MarkerRepeaterInfo(
                  repeaterId: e.repeaterId,
                  snr: e.snr ?? 0.0,
                  rssi: e.rssi ?? 0,
                  pathHops: e.pathHops,
                ))
            .toList();

        if (directRepeaters.isNotEmpty || multiHopRepeaters.isNotEmpty) {
          allRepeaters = [...directRepeaters, ...multiHopRepeaters];
        }

        heardRepeaters.addAll(lastTx.events
            .where((event) => event.snr?.isFinite ?? false)
            .map((event) => (
                  repeaterId: event.repeaterId.toUpperCase(),
                  snr: event.snr!,
                )));
        heardRepeaters.addAll(multiHopEchoes
            .where((event) => event.snr?.isFinite ?? false)
            .map((event) => (
                  repeaterId: event.repeaterId.toUpperCase(),
                  snr: event.snr!,
                )));
      }
      _updateLiveActivityRepeaters(heardRepeaters, OverlayPingType.tx);

      final PingEventType eventType;
      if (directSuccess) {
        eventType = PingEventType.txSuccess;
      } else if (multiHopEchoes.isNotEmpty) {
        eventType = PingEventType.txMultiHopOnly;
      } else {
        eventType = PingEventType.txFail;
      }

      recordPingEvent(
        eventType,
        latitude: lat,
        longitude: lon,
        repeaters: allRepeaters,
      );
    };

    _pingService!.onDiscoveryWindowComplete = (success) {
      _liveActivityOperation = null;
      double? lat;
      double? lon;
      List<MarkerRepeaterInfo>? repeaters;
      final heardRepeaters = <({String repeaterId, double snr})>[];

      if (_discLogEntries.isNotEmpty) {
        final lastDisc = _discLogEntries.first;
        lat = lastDisc.latitude;
        lon = lastDisc.longitude;
        if (lastDisc.discoveredNodes.isNotEmpty) {
          repeaters = lastDisc.discoveredNodes
              .map((n) => MarkerRepeaterInfo(
                    repeaterId: n.repeaterId,
                    snr: n.localSnr,
                    rssi: n.localRssi,
                    pubkeyHex: n.pubkeyHex,
                  ))
              .toList();
        }
        heardRepeaters.addAll(lastDisc.discoveredNodes
            .where((node) => node.localSnr.isFinite)
            .map((node) => (
                  repeaterId: node.repeaterId.toUpperCase(),
                  snr: node.localSnr,
                )));
      }
      _updateLiveActivityRepeaters(heardRepeaters, OverlayPingType.disc);

      PingEventType eventType;
      if (success) {
        eventType = PingEventType.discSuccess;
      } else if (discDropEnabled) {
        eventType = PingEventType.txFail;
      } else {
        eventType = PingEventType.discFail;
      }

      recordPingEvent(
        eventType,
        latitude: lat,
        longitude: lon,
        repeaters: repeaters,
      );
    };

    _pingService!.onTracePing = (entry) {
      _markLiveActivityOperation(_LiveActivityOperation.tracing);
      _addTraceLogEntry(entry);
    };

    _pingService!.onTraceWindowComplete = (result) {
      _liveActivityOperation = null;
      double? lat;
      double? lon;
      List<MarkerRepeaterInfo>? repeaters;

      if (_traceLogEntries.isNotEmpty) {
        final lastTrace = _traceLogEntries.first;
        lat = lastTrace.latitude;
        lon = lastTrace.longitude;
        if (result != null && result.success) {
          repeaters = [
            MarkerRepeaterInfo(
              repeaterId: result.targetRepeaterId,
              snr: result.localSnr,
              rssi: result.localRssi,
            )
          ];
          _traceLogEntries[0] = TraceLogEntry(
            timestamp: lastTrace.timestamp,
            latitude: lastTrace.latitude,
            longitude: lastTrace.longitude,
            targetRepeaterId: lastTrace.targetRepeaterId,
            noiseFloor: lastTrace.noiseFloor,
            localSnr: result.localSnr,
            remoteSnr: result.remoteSnr,
            localRssi: result.localRssi,
            success: true,
          );
          _notifyMapNow();
        }
      }

      final traceSnr = result?.localSnr;
      _updateLiveActivityRepeaters(
        result != null && result.success && traceSnr != null
            ? [(repeaterId: result.targetRepeaterId, snr: traceSnr)]
            : const [],
        OverlayPingType.trace,
      );

      recordPingEvent(
        result != null && result.success
            ? PingEventType.traceSuccess
            : PingEventType.traceFail,
        latitude: lat,
        longitude: lon,
        repeaters: repeaters,
      );
    };

    _pingService!.onDiscCarpeaterDrop = (String repeaterId, String reason) {
      debugLog(
          '[APP] Discovery carpeater drop: repeater=$repeaterId, reason=$reason');
      logError(
          'Discovery Dropped\nPossible carpeater: $repeaterId\n$reason',
          severity: ErrorSeverity.warning, autoSwitch: false);
    };

    _pingService!.onPendingDisableComplete = () async {
      debugLog('[APP] Pending disable completed, cleaning up');

      _pingService!.stopEchoTracking();
      _rxLogger?.stopWardriving(trigger: 'pending_disable');

      await BackgroundServiceManager.stopService();

      _autoPingTimer.stop();
      _rxWindowTimer.stop();

      if (_preferences.offlineMode) {
        await _saveOfflineSession();
      }

      await _endNoiseFloorSession();
      _apiService.disableHeartbeat();

      _autoPingEnabled = false;
      _idleAutoStopReference = null;
      _finishLiveActivitySession();

      debugLog('[APP] Pending disable cleanup complete, cooldown running');
      notifyListeners();
    };

    await _saveRememberedDevice(device,
        transportType: _selectedTransport,
        tcpHost: tcpHost,
        tcpPort: tcpPort,
        serialPortPath: serialPortPath);

    final selfInfoName = _meshCoreConnection?.selfInfo?.name;
    if (selfInfoName != null && selfInfoName.isNotEmpty) {
      _displayDeviceName = _isAnonymousRenamed ? 'Anonymous' : selfInfoName;
      debugLog('[APP] Display name set: "$_displayDeviceName"');

      String? realName;
      if (_isAnonymousRenamed) {
        realName = _originalDeviceName ?? selfInfoName;
      } else if (selfInfoName == 'Anonymous' && _devicePublicKey != null) {
        realName = _deviceRealNames[_devicePublicKey!] ?? selfInfoName;
      } else {
        realName = selfInfoName;
      }
      if (_rememberedDevice != null && _rememberedDevice!.id == device.id) {
        final updatedName = 'MeshCore-$realName';
        if (_rememberedDevice!.name != updatedName) {
          await _saveRememberedDevice(
              DiscoveredDevice(id: device.id, name: updatedName),
              transportType: _selectedTransport,
              tcpHost: tcpHost,
              tcpPort: tcpPort,
              serialPortPath: serialPortPath);
          debugLog(
              '[APP] Updated remembered device name from SelfInfo: $updatedName');
        }
      }
    }

    final resolvedName =
        _isAnonymousRenamed ? _originalDeviceName : displayDeviceName;
    if (resolvedName != null &&
        _deviceAntennaPreferences.containsKey(resolvedName)) {
      final savedAntenna = _deviceAntennaPreferences[resolvedName]!;
      _preferences = _preferences.copyWith(
        externalAntenna: savedAntenna,
        externalAntennaSet: true,
      );
      _antennaRestoredFromDevice = true;
      _savePreferences();
      debugLog(
          '[APP] Restored antenna preference for "$resolvedName": ${savedAntenna ? "external" : "device"}');
      notifyListeners();
    }

    if (resolvedName != null &&
        _devicePowerOverrides.containsKey(resolvedName)) {
      final saved = _devicePowerOverrides[resolvedName]!;
      _preferences = _preferences.copyWith(
        powerLevel: (saved['powerLevel'] as num).toDouble(),
        txPower: (saved['txPower'] as num).toInt(),
        autoPowerSet: false,
        powerLevelSet: true,
      );
      _powerRestoredFromDevice = true;
      _savePreferences();
      debugLog(
          '[APP] Restored power override for "$resolvedName": ${saved['powerLevel']}W');
      notifyListeners();
    }

    if (hasApiSession) {
      if (txAllowed && rxAllowed) {
        debugLog('[CONN] Connected with full access (TX + RX allowed)');
      } else if (rxAllowed) {
        debugLog(
            '[CONN] Connected with RX-only access (TX not allowed, zone at TX capacity)');
      } else {
        debugLog('[CONN] Connected with limited access');
      }

      _sessionZoneCode = zoneCode;

      if (!_preferences.offlineMode) {
        _startZoneRefreshTimer();
      }

      if (!_preferences.offlineMode && _apiService.hasSession) {
        _apiService.enableHeartbeat(
          gpsProvider: () {
            final pos = _gpsService.lastPosition;
            if (pos == null) return null;
            return (lat: pos.latitude, lon: pos.longitude);
          },
        );
        debugLog('[HEARTBEAT] Enabled on connection');
      }

      _startIdleDisconnectTimer();
    } else {
      debugLog('[CONN] Connected without API session (offline mode)');
    }

    final validation = pingValidation;
    if (validation != PingValidation.valid) {
      debugLog('[CONN] Ping validation after connect: $validation');
    }
  }

  /// Create and wire up unified RX handler
  Future<void> _createUnifiedRxHandler() async {
    debugLog('[APP] Creating unified RX handler');

    // Create TX tracker (stored for use by PingService)
    _txTracker = TxTracker();
    _txTracker!.disableRssiFilter = _preferences.disableRssiFilter;

    // Set CARpeater prefix for pass-through (replaces shouldIgnoreRepeater)
    _txTracker!.carpeaterPrefix =
        _preferences.ignoreCarpeater ? _preferences.ignoreRepeaterId : null;
    debugLog(
        '[APP] TxTracker.carpeaterPrefix set to ${_txTracker!.carpeaterPrefix ?? 'null'}');

    // Log TX carpeater drops to error log (without navigating to error tab)
    _txTracker!.onCarpeaterDrop = (String repeaterId, String reason) {
      debugLog('[APP] TX carpeater drop: repeater=$repeaterId, reason=$reason');
      logError('TX Echo Dropped\nPossible carpeater: $repeaterId\n$reason',
          severity: ErrorSeverity.warning, autoSwitch: false);
    };
    debugLog('[APP] TxTracker.onCarpeaterDrop callback SET');

    // Create RX logger (stored for use when enabling Passive Mode)
    _rxLogger = RxLogger(
      // CARpeater prefix for pass-through (replaces shouldIgnoreRepeater)
      carpeaterPrefix:
          _preferences.ignoreCarpeater ? _preferences.ignoreRepeaterId : null,
      // Immediate observation callback - fires when packet is first validated
      // Creates pin IMMEDIATELY for NEW repeaters (first time in current batch)
      onObservation: (observation) {
        try {
          debugLog(
              '[APP] Immediate RX observation: repeater=${observation.repeaterId}, '
              'snr=${observation.snr ?? 'null'}, location=${observation.lat.toStringAsFixed(5)},${observation.lon.toStringAsFixed(5)}');

          // Log current batch tracking state for debugging
          debugLog(
              '[APP] Current batch tracking: ${_currentBatchRepeaters.length} repeaters: $_currentBatchRepeaters');

          // Check if repeater already has a pin in CURRENT BATCH (not all-time)
          // This allows new pins after batch flushes (25m movement)
          final repeaterKey = observation.repeaterId.toUpperCase();
          if (!_currentBatchRepeaters.contains(repeaterKey)) {
            // First observation in this batch - create pin IMMEDIATELY
            final rxPing = RxPing(
              latitude: observation.lat,
              longitude: observation.lon,
              repeaterId: observation.repeaterId,
              timestamp: DateTime.now(),
              snr: observation.snr ?? 0.0,
              rssi: observation.rssi ?? 0,
              pathHops: observation.displayHops,
            );
            _rxPings.add(rxPing);
            if (_rxPings.length > _maxMapPins) _rxPings.removeAt(0);
            _currentBatchRepeaters.add(repeaterKey);

            // Increment RX count immediately when pin is created (not on batch flush)
            _pingStats = _pingStats.copyWith(rxCount: _pingStats.rxCount + 1);

            debugLog(
                '[APP] Created IMMEDIATE RX pin for repeater: ${observation.repeaterId} '
                'at ${observation.lat.toStringAsFixed(5)},${observation.lon.toStringAsFixed(5)} '
                '(batch tracking: ${_currentBatchRepeaters.length} repeaters, rxCount: ${_pingStats.rxCount})');
            // Update RX overlay slot immediately
            if (observation.snr != null) {
              _updateRxOverlaySlot(repeaterKey, observation.snr!);
            }
            // Play receive sound for new RX observation
            _audioService.playReceiveSound();
            // Record RX event for noise floor graph with location and repeater info
            recordPingEvent(
              PingEventType.rx,
              latitude: observation.lat,
              longitude: observation.lon,
              repeaters: [
                MarkerRepeaterInfo(
                  repeaterId: observation.repeaterId,
                  snr: observation.snr ?? 0.0,
                  rssi: observation.rssi ?? 0,
                ),
              ],
            );
            _notifyMapThrottled();
          } else {
            debugLog(
                '[APP] Repeater ${observation.repeaterId} already has pin in current batch, SNR will update on flush if better');
          }
        } catch (e, stackTrace) {
          debugError('[APP] Error in immediate observation callback: $e');
          debugError('[APP] Stack trace: $stackTrace');
        }
      },

      // Finalized batch callback - fires when batch is flushed (25m or 30s)
      // Updates the current batch's pin SNR to best value, then clears batch tracking
      onRxEntry: (entry) async {
        try {
          debugLog('[APP] ========== BATCH FLUSH CALLBACK ==========');
          debugLog(
              '[APP] Finalized RX entry (best SNR): repeater=${entry.repeaterId}, '
              'snr=${entry.snr ?? 'null'}, location=${entry.lat.toStringAsFixed(5)},${entry.lon.toStringAsFixed(5)}');

          final repeaterKey = entry.repeaterId.toUpperCase();

          // Find the most recent pin for this repeater (created in current batch)
          // Search from end since newest pins are at the end
          int lastPinIndex = -1;
          for (int i = _rxPings.length - 1; i >= 0; i--) {
            if (_rxPings[i].repeaterId.toUpperCase() == repeaterKey) {
              lastPinIndex = i;
              break;
            }
          }

          if (lastPinIndex != -1) {
            // Update the pin's SNR to the best from this batch
            final existingPin = _rxPings[lastPinIndex];
            // Only update if new SNR is non-null and better (null never replaces non-null)
            final shouldUpdateSnr =
                entry.snr != null && entry.snr! > existingPin.snr;
            if (shouldUpdateSnr) {
              _rxPings[lastPinIndex] = RxPing(
                latitude: existingPin.latitude, // KEEP batch start location
                longitude: existingPin.longitude, // KEEP batch start location
                repeaterId: entry.repeaterId,
                timestamp: entry.timestamp,
                snr: entry.snr ??
                    existingPin.snr, // UPDATE to best SNR from batch
                rssi: entry.rssi ?? existingPin.rssi,
                pathHops: existingPin.pathHops,
              );
              debugLog(
                  '[APP] Updated RX pin SNR for repeater=${entry.repeaterId}: '
                  '${existingPin.snr.toStringAsFixed(2)} -> ${entry.snr?.toStringAsFixed(2) ?? 'null'}');
            } else {
              debugLog(
                  '[APP] RX pin SNR unchanged for repeater=${entry.repeaterId}: '
                  'batch best ${entry.snr?.toStringAsFixed(2) ?? 'null'} <= pin ${existingPin.snr.toStringAsFixed(2)}');
            }
          } else {
            // Edge case: pin not found (should have been created in onObservation)
            final newRxPing = RxPing(
              latitude: entry.lat,
              longitude: entry.lon,
              repeaterId: entry.repeaterId,
              timestamp: entry.timestamp,
              snr: entry.snr ?? 0.0,
              rssi: entry.rssi ?? 0,
              pathHops: entry.displayHops,
            );
            _rxPings.add(newRxPing);
            if (_rxPings.length > _maxMapPins) _rxPings.removeAt(0);
            debugLog(
                '[APP] Created FALLBACK RX pin for repeater=${entry.repeaterId} '
                'at ${entry.lat.toStringAsFixed(5)},${entry.lon.toStringAsFixed(5)}');
          }

          // Clear from batch tracking - allows new pin in next batch
          final wasPresent = _currentBatchRepeaters.contains(repeaterKey);
          _currentBatchRepeaters.remove(repeaterKey);
          debugLog('[APP] Cleared batch tracking for ${entry.repeaterId}: '
              'wasPresent=$wasPresent, remaining=${_currentBatchRepeaters.length}');

          // Create RxLogEntry for log tab
          final rxLogEntry = RxLogEntry(
            timestamp: entry.timestamp,
            repeaterId: entry.repeaterId,
            snr: entry.snr,
            rssi: entry.rssi,
            pathLength: entry.pathLength,
            header: entry.header,
            latitude: entry.lat,
            longitude: entry.lon,
            pathHops: entry.displayHops,
          );

          // Add to RX log entries
          _rxLogEntries.add(rxLogEntry);
          if (_rxLogEntries.length > _maxLogEntries) _rxLogEntries.removeAt(0);
          debugLog('[APP] Added RX log entry: repeater=${entry.repeaterId}, '
              'snr=${entry.snr ?? 'null'}, pathLen=${entry.pathLength}');

          // Update RX overlay slot with this RX observation
          if (entry.snr != null) {
            _updateRxOverlaySlot(entry.repeaterId, entry.snr!);
          }

          // Note: RX count is incremented in onObservation when pin is created (immediate feedback)

          // Enqueue to API with formatted heard_repeats string
          // Format: "repeaterId(snr)" e.g. "4e(12.25)" or "4e(null)" for CARpeater pass-through
          final heardRepeats = entry.snr != null
              ? '${entry.repeaterId}(${entry.snr!.toStringAsFixed(2)})'
              : '${entry.repeaterId}(null)';
          await _apiQueueService.enqueueRx(
            latitude: entry.lat,
            longitude: entry.lon,
            heardRepeats: heardRepeats,
            timestamp: entry.timestamp.millisecondsSinceEpoch ~/ 1000,
            repeaterId: entry.repeaterId,
            externalAntenna: _preferences.externalAntenna,
            noiseFloor: _meshCoreConnection?.lastNoiseFloor,
            power: _preferences.powerLevel,
          );

          // Update UI (throttled — dense mesh RX must not churn the map)
          _notifyMapThrottled();
        } catch (e, stackTrace) {
          debugError('[APP] Error in finalized RX entry callback: $e');
          debugError('[APP] Stack trace: $stackTrace');
        }
      },

      getGpsLocation: () {
        final pos = _gpsService.lastPosition;
        if (pos == null) return null;
        return (lat: pos.latitude, lon: pos.longitude);
      },

      // Log carpeater drops to error log (without navigating to error tab)
      onCarpeaterDrop: (String repeaterId, String reason) {
        debugLog('[APP] Carpeater drop: repeater=$repeaterId, reason=$reason');
        logError('RX Dropped\nPossible carpeater: $repeaterId\n$reason',
            severity: ErrorSeverity.warning, autoSwitch: false);
      },

      // Explain RX silence when there's no GPS fix (#340): without this the RX
      // counter quietly stops and the app appears "offline despite Internet".
      onNoGpsDrop: () {
        debugLog('[APP] RX not logged: no GPS fix available');
        logError(
            'RX not logged\nNo GPS fix — waiting for location.\n'
            'Detection resumes automatically once GPS is restored.',
            severity: ErrorSeverity.warning,
            autoSwitch: false);
      },
    );

    // Create packet validator with ALL allowed channels (#wardriving, #testing, #ottawa, Public)
    final allowedChannelsData = ChannelService.getAllowedChannelsForValidator();
    final allowedChannels = <int, ChannelInfo>{};
    for (final entry in allowedChannelsData.entries) {
      allowedChannels[entry.key] = ChannelInfo(
        channelName: entry.value.channelName,
        key: entry.value.key,
        hash: entry.value.hash,
      );
    }
    debugLog(
        '[APP] PacketValidator configured with ${allowedChannels.length} channels: '
        '${allowedChannelsData.values.map((c) => c.channelName).join(', ')}');
    final validator = PacketValidator(
      allowedChannels: allowedChannels,
      disableRssiFilter: _preferences.disableRssiFilter,
    );

    // Create unified handler
    _unifiedRxHandler = UnifiedRxHandler(
      txTracker: _txTracker!,
      rxLogger: _rxLogger!,
      validator: validator,
    );

    // Subscribe to LogRxData stream
    _logRxDataSubscription =
        _meshCoreConnection!.logRxDataStream.listen((data) {
      _unifiedRxHandler!.handlePacket(data.raw, data.snr, data.rssi);
    });

    // Start listening
    _unifiedRxHandler!.startListening();

    debugLog('[APP] Unified RX handler created and listening');
  }

  /// Full disconnect cleanup - called on normal BLE disconnect (user-requested or no remembered device)
  /// Extracted from the original BLE disconnect listener
  /// Configure multi-byte path hash mode on the radio during connection
  /// Reads device's current mode, determines effective mode, and sends command if needed
  Future<void> _configurePathHashMode() async {
    final deviceInfo = _meshCoreConnection?.deviceInfo;
    if (deviceInfo == null) return;

    // Capture what the radio is CURRENTLY doing before resetting to firmware
    // default — during zone transfer this reflects the previous zone's mode
    final currentRuntimeHopBytes = _hopBytes;

    // Store the device's original firmware mode (from DeviceInfo response)
    _originalPathHashMode = deviceInfo.pathHashMode;

    // Sync runtime hopBytes from device's firmware mode
    final deviceMode =
        _originalPathHashMode ?? 0; // null = old firmware, treat as 0 (1-byte)
    final deviceHopBytes = deviceMode + 1;
    if (_originalPathHashMode != null) {
      _hopBytes = deviceHopBytes;
      _traceHopBytes = deviceHopBytes == 3 ? 4 : deviceHopBytes;
      _pingService?.traceHopBytes = _traceHopBytes;
      debugLog(
          '[PATH] Read device path mode: $deviceHopBytes-byte (trace: $_traceHopBytes-byte)');
    } else {
      _hopBytes = 1;
      _traceHopBytes = 1;
    }

    final effective = effectiveHopBytes;

    if (effective != currentRuntimeHopBytes && _originalPathHashMode != null) {
      // Need to change the radio's path hash mode
      try {
        await _meshCoreConnection!.setPathHashMode(effective - 1);
        _hopBytes = effective;
        _traceHopBytes = effective == 3 ? 4 : effective;
        _pingService?.traceHopBytes = _traceHopBytes;
        debugLog(
            '[PATH] Set path hash mode: radio was $currentRuntimeHopBytes-byte, now $effective-byte (trace: $_traceHopBytes-byte)');

        // Show warning popup if changing from 1-byte to multi-byte
        if (deviceMode == 0 && effective > 1) {
          final reason = enforceHopBytes
              ? 'set by your regional admin'
              : 'set in your app preferences';
          _pendingPathHashWarning = (hopBytes: effective, reason: reason);
          notifyListeners();
        }
      } catch (e) {
        debugError('[PATH] Failed to set path hash mode: $e');
      }
    } else if (_originalPathHashMode == null && effective > 1) {
      // Old firmware doesn't support multi-byte paths — warn user, fall back to 1-byte
      debugWarn(
          '[PATH] Device firmware does not report path_hash_mode, cannot set $effective-byte paths');
      if (enforceHopBytes) {
        _pendingPathHashWarning =
            (hopBytes: effective, reason: 'firmware_unsupported');
        notifyListeners();
      }
    } else {
      debugLog(
          '[PATH] Path hash mode OK: radio=$currentRuntimeHopBytes-byte, effective=$effective-byte');
    }
  }

  /// Restore radio to original path hash mode on clean disconnect
  /// Skipped if the user manually changed the setting — they know what they're doing
  Future<void> _restorePathHashMode() async {
    if (_originalPathHashMode == null) return;

    if (_userChangedPathMode) {
      debugLog(
          '[PATH] User manually changed path mode, not restoring on disconnect');
      _originalPathHashMode = null;
      _userChangedPathMode = false;
      return;
    }

    final originalMode = _originalPathHashMode!;
    final originalHopBytes = originalMode + 1;

    // Compare current runtime mode against what the device had before we changed it
    if (_hopBytes != originalHopBytes) {
      try {
        await _meshCoreConnection?.setPathHashMode(originalMode);
        debugLog(
            '[PATH] Restored path hash mode to original: $originalHopBytes-byte');
      } catch (e) {
        debugError('[PATH] Failed to restore path hash mode: $e');
      }
    } else {
      debugLog(
          '[PATH] Path mode unchanged from original ($originalHopBytes-byte), no restore needed');
    }
    _originalPathHashMode = null;
    _userChangedPathMode = false;
  }

  /// Send path hash mode to radio immediately when user changes setting while connected
  void _applyLivePathHashMode(int newHopBytes) {
    if (_originalPathHashMode == null) {
      // Old firmware — can't send command, show warning
      debugWarn('[PATH] Cannot change path mode: firmware does not support it');
      _pendingPathHashWarning =
          (hopBytes: newHopBytes, reason: 'firmware_unsupported');
      _hopBytes = 1; // Force back to 1
      notifyListeners();
      return;
    }

    _hopBytes = newHopBytes;
    _userChangedPathMode = true;
    _pingService?.hopBytes = newHopBytes;
    // Auto-map trace bytes when TX bytes change (3→4, others stay same)
    final oldTraceHopBytes = _traceHopBytes;
    _traceHopBytes = newHopBytes == 3 ? 4 : newHopBytes;
    _pingService?.traceHopBytes = _traceHopBytes;
    // Clear target repeater if trace bytes changed — old hex ID has wrong byte length
    if (_traceHopBytes != oldTraceHopBytes) {
      _targetRepeaterId = null;
    }
    final mode = newHopBytes - 1; // Convert 1/2/3 → mode 0/1/2
    _meshCoreConnection?.setPathHashMode(mode);
    debugLog(
        '[PATH] User changed path mode to $newHopBytes-byte (trace: $_traceHopBytes-byte, sent to radio)');
    notifyListeners();
  }

  /// Set hop bytes (called from settings UI). Each companion device may differ.
  void setHopBytes(int value) {
    if (value < 1 || value > 3) return;
    if (value == _hopBytes) return;

    if (isConnected) {
      _applyLivePathHashMode(value);
    } else {
      _hopBytes = value;
      notifyListeners();
    }
  }

  /// Set trace hop bytes (called from settings UI). Valid values: 1, 2, 4.
  void setTraceHopBytes(int value) {
    if (value != 1 && value != 2 && value != 4) return;
    if (value == _traceHopBytes) return;
    _traceHopBytes = value;
    _pingService?.traceHopBytes = value;
    // Clear target repeater — old hex ID has wrong byte length
    _targetRepeaterId = null;
    debugLog('[TRACE] User changed trace bytes to $value');
    notifyListeners();
  }

  /// Pending path hash warning data (for UI to show dialog)
  ({int hopBytes, String reason})? _pendingPathHashWarning;
  ({int hopBytes, String reason})? get pendingPathHashWarning =>
      _pendingPathHashWarning;

  /// Clear the pending warning after UI has shown it
  void clearPathHashWarning() {
    _pendingPathHashWarning = null;
  }

  Future<void> _fullDisconnectCleanup() async {
    _finishLiveActivitySession();
    // Guard against double cleanup (e.g., reconnect timeout + BLE disconnect event)
    if (_connectionStep == ConnectionStep.disconnected) {
      debugLog('[CONN] Already disconnected, skipping duplicate cleanup');
      return;
    }
    _cancelPendingAutoPingRestore();
    _isConnecting = false;
    _connectionStep = ConnectionStep.disconnected;

    // Cancel any active zone grace period
    _cancelZoneGraceTimers();
    _isInZoneGracePeriod = false;
    _zoneGraceSecondsRemaining = 0;
    _autoPingWasEnabledBeforeGrace = false;

    _apiService.disableHeartbeat();
    debugLog('[CONN] Heartbeat disabled due to disconnect');

    // Stop zone refresh timer
    _stopZoneRefreshTimer();

    // Stop auto-ping timers
    _autoPingTimer.stop();
    _rxWindowTimer.stop();
    _cooldownTimer.stop();
    if (_autoPingEnabled) {
      if (!_userRequestedDisconnect) {
        _playDisconnectAlert();
      }
      _autoPingEnabled = false;
      _idleAutoStopReference = null;
      debugLog('[AUTO] Auto-ping disabled due to disconnect');
    }

    // End noise floor session on BLE disconnect
    await _endNoiseFloorSession();

    // Stop RX logger
    _rxLogger?.stopWardriving(trigger: 'ble_disconnect');

    // Force upload any pending items BEFORE releasing session
    if (_apiService.hasSession) {
      debugLog('[CONN] Flushing API queue before session release');
      try {
        await _apiQueueService.forceUploadWithHoldWait();
      } catch (e) {
        debugError('[CONN] Failed to flush API queue: $e');
      }
    }

    // Clear any remaining items and stop batch timer
    await _apiQueueService.clearOnDisconnect();

    // Release API session (best effort - don't block on failure)
    if (_devicePublicKey != null && _apiService.hasSession) {
      debugLog('[CONN] Releasing API session due to disconnect');
      try {
        await _apiService.requestAuth(
          reason: 'disconnect',
          publicKey: _devicePublicKey!,
        );
        debugLog('[CONN] API session released successfully');
      } catch (e) {
        debugError('[CONN] Failed to release API session: $e');
      }
    }

    _isAnonymousRenamed = false;
    _originalDeviceName = null;

    _clearOverlayState();

    _meshCoreConnection?.dispose();
    _meshCoreConnection = null;
    _pingService?.dispose();
    _pingService = null;

    // Clean up non-BLE transport
    _transportConnectionSubscription?.cancel();
    _transportConnectionSubscription = null;
    if (_activeTransport != null && _activeTransport != _bluetoothService) {
      _activeTransport!.dispose();
    }
    _activeTransport = null;
  }

  /// Start auto-reconnect after unexpected transport disconnect
  Future<void> _startAutoReconnect() async {
    // Defensive: cancel zone grace period if active
    if (_isInZoneGracePeriod) {
      _cancelZoneGraceTimers();
      _isInZoneGracePeriod = false;
      _zoneGraceSecondsRemaining = 0;
      _autoPingWasEnabledBeforeGrace = false;
    }
    _cancelPendingAutoPingRestore();
    _cancelIdleDisconnectTimer();
    _isAutoReconnecting = true;
    _reconnectAttempt = 0;
    _lastReconnectWasBondError = false;
    _connectionStep = ConnectionStep.reconnecting;

    // Remember auto-ping state before cleanup
    _autoPingWasEnabled = _autoPingEnabled;
    _autoModeBeforeReconnect = _autoMode;

    // Stop auto-ping timers (don't dispose)
    _autoPingTimer.stop();
    _rxWindowTimer.stop();
    _cooldownTimer.stop();
    _autoPingEnabled = false;
    _idleAutoStopReference = null;

    // Stop heartbeat
    _apiService.disableHeartbeat();

    // Preserve noise floor session for continuation after reconnect
    // (will be ended by _fullDisconnectCleanup if reconnect fails)

    // Flush RX logger
    _rxLogger?.stopWardriving(trigger: 'reconnect');

    // Stop background service
    await BackgroundServiceManager.stopService();

    // Clean up dead BLE-dependent objects
    _logRxDataSubscription?.cancel();
    _logRxDataSubscription = null;
    _unifiedRxHandler?.dispose();
    _unifiedRxHandler = null;
    _txTracker = null;
    _rxLogger = null;
    await _noiseFloorSubscription?.cancel();
    _noiseFloorSubscription = null;
    await _batterySubscription?.cancel();
    _batterySubscription = null;
    _meshCoreConnection?.dispose();
    _meshCoreConnection = null;
    _pingService?.dispose();
    _pingService = null;

    // Do NOT release API session or clear API queue
    debugLog(
        '[CONN] Auto-reconnect: preserved API session, cleaned up BLE objects');

    notifyListeners();

    // Start overall timeout (30 seconds)
    _reconnectTimeoutTimer = Timer(const Duration(seconds: 30), () {
      debugLog('[CONN] Auto-reconnect timed out after 30s');
      _abandonAutoReconnect();
    });

    // Start first attempt
    _attemptReconnect();
  }

  /// Attempt a single reconnection
  void _attemptReconnect() {
    if (_reconnectAttempt >= _maxReconnectAttempts) {
      debugLog(
          '[CONN] Auto-reconnect: max attempts reached ($_maxReconnectAttempts)');
      _abandonAutoReconnect();
      return;
    }

    _reconnectAttempt++;
    debugLog(
        '[CONN] Auto-reconnect attempt $_reconnectAttempt of $_maxReconnectAttempts');
    notifyListeners();

    // Use longer delay after bond errors to give iOS time to clear stale keys
    final delay = _lastReconnectWasBondError
        ? _reconnectDelayAfterBondError
        : _reconnectDelay;

    // Delay before attempting reconnection
    _reconnectTimer = Timer(delay, () async {
      if (!_isAutoReconnecting) return; // Cancelled while waiting

      try {
        debugLog(
            '[CONN] Auto-reconnect: calling reconnectToRememberedDevice()');
        await reconnectToRememberedDevice();

        // Timeout or cancel fired while connection was in-flight.
        // Disconnect the orphaned connection — abandon already cleaned up state.
        if (!_isAutoReconnecting) {
          if (_connectionStep == ConnectionStep.connected) {
            debugLog(
                '[CONN] Auto-reconnect completed after timeout — disconnecting orphaned connection');
            disconnect();
          }
          return;
        }

        // If we get here and connection step is 'connected', success!
        if (_connectionStep == ConnectionStep.connected) {
          debugLog(
              '[CONN] Auto-reconnect succeeded on attempt $_reconnectAttempt');
          _lastReconnectWasBondError = false;
          _onReconnectSuccess();
        } else if (_isAutoReconnecting) {
          // Connection failed but didn't throw - try again
          debugLog(
              '[CONN] Auto-reconnect: connection did not complete, retrying...');
          _connectionStep = ConnectionStep.reconnecting;
          notifyListeners();
          _attemptReconnect();
        }
      } catch (e) {
        debugError(
            '[CONN] Auto-reconnect attempt $_reconnectAttempt failed: $e');
        if (_isAutoReconnecting) {
          // Check for iOS apple-code 14 (Peer removed pairing information)
          // The MeshCore device cleared its bond keys — clear iOS stale bond before retrying
          await _handleBondErrorIfNeeded(e);

          // Reset step back to reconnecting for UI
          _connectionStep = ConnectionStep.reconnecting;
          _connectionError = null;
          notifyListeners();
          _attemptReconnect();
        }
      }
    });
  }

  /// Start 15-minute idle disconnect timer.
  /// Fires if user does not send a manual ping or start auto-ping within 15 minutes.
  void _startIdleDisconnectTimer() {
    _idleDisconnectTimer?.cancel();
    _idleDisconnectTimer = Timer(_idleDisconnectTimeout, () {
      if (!isConnected || _autoPingEnabled) return;
      debugLog('[IDLE] 15-minute idle timeout reached — disconnecting');
      logError('Disconnected: 15 minutes of inactivity',
          severity: ErrorSeverity.warning);
      disconnect();
    });
    debugLog(
        '[IDLE] Idle disconnect timer started (${_idleDisconnectTimeout.inMinutes} min)');
  }

  /// Cancel the idle disconnect timer
  void _cancelIdleDisconnectTimer() {
    if (_idleDisconnectTimer != null) {
      _idleDisconnectTimer!.cancel();
      _idleDisconnectTimer = null;
      debugLog('[IDLE] Idle disconnect timer cancelled');
    }
  }

  /// Detect iOS apple-code 14/15 bond errors and clear the stale bond before retry.
  /// Only applies to BLE transports.
  Future<void> _handleBondErrorIfNeeded(Object error) async {
    if (_selectedTransport != TransportType.ble) return;
    final errorStr = error.toString();
    if (errorStr.contains('apple-code: 14') ||
        errorStr.contains('apple-code: 15') ||
        errorStr.contains('Peer removed pairing information')) {
      _lastReconnectWasBondError = true;
      final deviceId = _rememberedDevice?.id;
      if (deviceId != null) {
        debugLog(
            '[CONN] Bond error detected (apple-code 14/15) — clearing stale bond for $deviceId');
        await _bluetoothService.removeBond(deviceId);
      }
    }
  }

  /// Called when auto-reconnect succeeds
  void _onReconnectSuccess() {
    // Cancel timers
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectTimeoutTimer?.cancel();
    _reconnectTimeoutTimer = null;

    final wasAutoPing = _autoPingWasEnabled;
    final previousMode = _autoModeBeforeReconnect;

    // Clear reconnect state
    _isAutoReconnecting = false;
    _reconnectAttempt = 0;
    _autoPingWasEnabled = false;

    debugLog(
        '[CONN] Auto-reconnect complete, restoring state (autoPing=$wasAutoPing, mode=$previousMode)');

    // Restore auto-ping if it was active
    if (wasAutoPing) {
      final restoreGeneration = _reconnectRestoreGeneration;
      // Use a short delay to ensure connection is fully set up
      _restoreAutoPingTimer?.cancel();
      _restoreAutoPingTimer = Timer(const Duration(milliseconds: 500), () {
        _restoreAutoPingTimer = null;
        if (_isDisposed ||
            restoreGeneration != _reconnectRestoreGeneration ||
            _userRequestedDisconnect ||
            _connectionStep != ConnectionStep.connected ||
            _pingService == null) {
          debugLog(
              '[CONN] Skipping delayed auto-ping restore (stale or disconnected state)');
          return;
        }

        if (!_autoPingEnabled) {
          _cooldownTimer.stop();
          _pingService!.clearCooldown();
          toggleAutoPing(previousMode);
          debugLog(
              '[CONN] Auto-ping restored after reconnect (mode=$previousMode)');
        }
      });
    } else {
      // No auto-ping to restore — start idle timer
      _startIdleDisconnectTimer();
    }

    notifyListeners();
  }

  /// Cancel auto-reconnect (called from UI cancel button)
  void cancelAutoReconnect() {
    debugLog('[CONN] Auto-reconnect cancelled by user');
    _abandonAutoReconnect();
  }

  /// Abandon auto-reconnect and do full cleanup
  void _abandonAutoReconnect() {
    // Cancel timers
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectTimeoutTimer?.cancel();
    _reconnectTimeoutTimer = null;
    _cancelPendingAutoPingRestore();

    // Alert if auto-ping was running before disconnect
    if (_autoPingWasEnabled) {
      _playDisconnectAlert();
    }

    // Clear reconnect state
    _isAutoReconnecting = false;
    _reconnectAttempt = 0;
    _autoPingWasEnabled = false;

    // Reset antenna and power settings so user must choose again on next connect
    _antennaRestoredFromDevice = false;
    _powerRestoredFromDevice = false;
    _preferences = _preferences.copyWith(
        externalAntenna: false, externalAntennaSet: false);
    _savePreferences();

    // Reset anonymous mode state (BLE already gone, can't restore name)
    _isAnonymousRenamed = false;
    _originalDeviceName = null;

    // Do full disconnect cleanup (releases API session, etc.)
    _fullDisconnectCleanup();
    notifyListeners();
  }

  /// Disconnect from current device
  Future<void> disconnect() async {
    _finishLiveActivitySession();
    // Mark as user-requested so BLE disconnect listener doesn't trigger auto-reconnect
    _userRequestedDisconnect = true;

    // Immediate UI feedback
    _connectionStep = ConnectionStep.disconnecting;
    notifyListeners();

    // Cancel idle disconnect timer
    _cancelIdleDisconnectTimer();

    // Cancel any active auto-reconnect
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectTimeoutTimer?.cancel();
    _reconnectTimeoutTimer = null;
    _cancelPendingAutoPingRestore();
    _isAutoReconnecting = false;
    _reconnectAttempt = 0;
    _autoPingWasEnabled = false;

    // Cancel any active zone grace period
    _cancelZoneGraceTimers();
    _isInZoneGracePeriod = false;
    _zoneGraceSecondsRemaining = 0;
    _autoPingWasEnabledBeforeGrace = false;

    // Disable heartbeat immediately on disconnect
    _apiService.disableHeartbeat();

    // Stop zone refresh timer
    _stopZoneRefreshTimer();

    // Stop auto-ping if running (before releasing session)
    if (_autoPingEnabled) {
      await _pingService?.forceDisableAutoPing();
      _autoPingEnabled = false;
      _idleAutoStopReference = null;
    }

    // End noise floor session on disconnect
    await _endNoiseFloorSession();

    // Stop background service
    await BackgroundServiceManager.stopService();

    // Stop all countdown timers
    _cooldownTimer.stop();
    _autoPingTimer.stop();
    _rxWindowTimer.stop();

    // Stop RX wardriving if active (flushes batches to queue)
    _rxLogger?.stopWardriving(trigger: 'disconnect');

    // Save offline pings before clearing queue (no-op if not in offline mode or no pings)
    await _saveOfflineSession();

    // ALWAYS START FRESH - clear any queued data on disconnect
    // Pings without a valid session cannot be uploaded later
    await _apiQueueService.clearOnDisconnect();

    // Release API session (best effort - always cleanup locally)
    if (_devicePublicKey != null && _apiService.hasSession) {
      debugLog('[APP] Releasing API session');
      try {
        await _apiService.requestAuth(
          reason: 'disconnect',
          publicKey: _devicePublicKey!,
        );
        debugLog('[APP] API session released successfully');
      } catch (e) {
        debugError('[APP] Failed to release API session: $e');
        // Continue with disconnect anyway
      }
    }

    // Restore original device name if anonymous mode renamed it (BLE must still be connected)
    if (_isAnonymousRenamed && _originalDeviceName != null) {
      try {
        await _meshCoreConnection?.setAdvertName(_originalDeviceName!);
        debugLog(
            '[CONN] Anonymous mode: restored name to "$_originalDeviceName"');
        if (_devicePublicKey != null) {
          _clearPersistedRealName(_devicePublicKey!);
        }
      } catch (e) {
        debugError('[CONN] Anonymous mode: failed to restore name: $e');
        logError(
            'Anonymous Mode: Failed to restore device name. Device may still show as "Anonymous".',
            severity: ErrorSeverity.warning,
            autoSwitch: false);
      }
      _isAnonymousRenamed = false;
      _originalDeviceName = null;
    }

    // Restore original path hash mode before disconnect (while BLE still connected)
    await _restorePathHashMode();

    // Clear flood scope before disconnect (safety — BLE disconnect resets radio state anyway)
    try {
      await _meshCoreConnection?.clearFloodScope();
    } catch (e) {
      debugLog('[CONN] Failed to clear flood scope: $e');
    }

    // Delete wardriving channel FIRST, while BLE connection is still active
    // This prevents "GATT Server is disconnected" errors
    if (_preferences.deleteChannelOnDisconnect) {
      await _meshCoreConnection?.deleteWardrivingChannelEarly();
    } else {
      debugLog('[CHANNEL] Skipping channel deletion (user preference)');
    }

    // Cleanup unified RX handler and TX tracker
    _logRxDataSubscription?.cancel();
    _logRxDataSubscription = null;
    _unifiedRxHandler?.dispose();
    _unifiedRxHandler = null;
    _txTracker = null; // TxTracker is disposed by UnifiedRxHandler
    _rxLogger = null; // RxLogger is disposed by UnifiedRxHandler

    await _meshCoreConnection?.disconnect();

    // Cancel stream subscriptions
    await _noiseFloorSubscription?.cancel();
    _noiseFloorSubscription = null;
    await _batterySubscription?.cancel();
    _batterySubscription = null;

    // Clean up non-BLE transport (TCP/USB instances are owned by us, not shared)
    _transportConnectionSubscription?.cancel();
    _transportConnectionSubscription = null;
    if (_activeTransport != null && _activeTransport != _bluetoothService) {
      _activeTransport!.dispose();
    }
    _activeTransport = null;

    // Restore transport tab selection so connection screen shows the right tab
    if (_rememberedDevice != null) {
      _selectedTransport = _rememberedDevice!.transportType;
    }

    _meshCoreConnection?.dispose();
    _meshCoreConnection = null;
    _pingService?.dispose();
    _pingService = null;

    _connectionStep = ConnectionStep.disconnected;
    _deviceModel = null;
    _manufacturerString = null;
    _firmwareVersionString = null;
    _devicePublicKey = null;
    _offlineContactUri = null;
    _displayDeviceName = null;
    _antennaRestoredFromDevice = false;
    _powerRestoredFromDevice = false;
    _preferences = _preferences.copyWith(
        externalAntenna: false, externalAntennaSet: false);
    _savePreferences();
    _currentNoiseFloor = null;
    _currentBatteryPercent = null;
    _authType = null;
    _originalPathHashMode = null;
    _userChangedPathMode = false;
    _hopBytes = 1;
    _traceHopBytes = 1;

    // Clear regional channels (keeps only Public) and scope
    ChannelService.clearRegionalChannels();
    _regionalChannels = [];
    _scope = null;

    // Clear user-original preference tracking
    _userOriginalAutoPingInterval = null;
    _userOriginalHybridMode = null;
    _userOriginalDiscDrop = null;
    _userOriginalFloodTraffic = null;

    // Clear zone transfer state
    _sessionZoneCode = null;
    _isZoneTransferInProgress = false;
    _zoneTransferFrom = null;
    _zoneTransferTo = null;

    // Clear discovered devices so user must scan fresh
    _discoveredDevices = [];

    // Reset user-requested flag
    _userRequestedDisconnect = false;

    notifyListeners();

    // Auto-exit app if preference is enabled (Android only)
    if (_preferences.closeAppAfterDisconnect && Platform.isAndroid) {
      debugLog('[APP] Auto-closing app after disconnect (preference enabled)');
      // Small delay to ensure cleanup completes
      Future.delayed(const Duration(milliseconds: 500), () {
        SystemNavigator.pop();
      });
    }
  }

  // ============================================
  // Ping Controls
  // ============================================

  /// Get current ping validation status (for auto mode - uses 25m distance check)
  PingValidation get pingValidation {
    return _pingService?.canPing() ?? PingValidation.notConnected;
  }

  /// Get manual ping validation status (no distance check, 15s cooldown)
  PingValidation get manualPingValidation {
    return _pingService?.canPingManual() ?? PingValidation.notConnected;
  }

  /// Get auto mode validation status (excludes distance check)
  /// Allows starting auto mode while stationary - pings will be skipped until user moves
  PingValidation get autoModeValidation {
    return _pingService?.canStartAutoMode() ?? PingValidation.notConnected;
  }

  /// Send a manual TX ping
  Future<bool> sendPing() async {
    if (_pingService == null) return false;
    if (_isAutoReconnecting) {
      debugLog('[PING] Ignoring ping during auto-reconnect');
      return false;
    }

    // Ignore re-taps while a ping is already being sent (prevents the
    // double-tap / concurrent-heartbeat storm during the session check)
    if (_isPingSending) {
      debugLog('[PING] Ignoring tap — ping already sending');
      return false;
    }

    // Set sending state immediately for instant UI feedback, BEFORE the
    // (awaited, network) session check so the button locks the moment it's tapped
    _isPingSending = true;
    notifyListeners();

    var ownsLiveActivity = false;
    var keepLiveActivity = false;
    try {
      // Check session validity before starting (skip in offline mode)
      if (!_preferences.offlineMode) {
        final sessionCheck = await _checkSessionBeforeAction();
        if (!sessionCheck) return false;
      }

      // Reset idle disconnect timer (user is actively pinging)
      _startIdleDisconnectTimer();

      debugLog('[PING] Sending manual TX ping');
      ownsLiveActivity = !_liveActivitySessionActive;
      if (ownsLiveActivity) {
        _startLiveActivitySession(manual: true);
      }
      final sent = await _pingService!.sendTxPing(manual: true);
      keepLiveActivity = sent;
      return sent;
    } finally {
      if (ownsLiveActivity && !keepLiveActivity) {
        _finishLiveActivitySession();
      }
      // Clear sending state on every path: session-check failure, exception,
      // or success (RX window timer takes over showing the listening state)
      _isPingSending = false;
      notifyListeners();
    }
  }

  /// Check session validity before starting a wardrive action
  /// Returns true if session is valid, false if expired (triggers disconnect)
  Future<bool> _checkSessionBeforeAction() async {
    _lastSessionCheckFailureReason = null;
    final pos = _gpsService.lastPosition;
    final result = await _apiService.checkSessionValid(
      lat: pos?.latitude,
      lon: pos?.longitude,
    );

    if (!result.isValid) {
      _lastSessionCheckFailureReason = _sessionCheckFailureMessage(
        result.reason,
        result.message,
      );
      debugWarn(
          '[API] Session check failed: ${result.reason} - ${result.message ?? "Session expired"}');
      // Note: onSessionError callback will trigger disconnect for critical errors
      return false;
    }
    return true;
  }

  String _sessionCheckFailureMessage(String? reason, String? message) {
    // `zone_full` is the server-side form of the same TX prohibition already
    // named "Passive Only" by watch controls. Reusing it avoids three wrist
    // phrasings for one condition; other presentable server text stays intact.
    if (reason == 'zone_full') return 'Passive Only';

    final serverMessage = message?.trim();
    if (serverMessage != null && serverMessage.isNotEmpty) {
      return serverMessage;
    }
    return _getErrorMessage(reason, null);
  }

  /// Set the target repeater ID for targeted mode
  void setTargetRepeaterId(String? id) {
    _targetRepeaterId = id;
    notifyListeners();
  }

  /// Auto-stop auto-ping after prolonged idle (no movement)
  void _triggerIdleAutoStop() {
    if (!_autoPingEnabled) return;
    _playDisconnectAlert();
    final elapsed = _idleAutoStopReference != null
        ? DateTime.now().difference(_idleAutoStopReference!).inMinutes
        : 30;
    debugLog('[AUTO] Auto-stop triggered: idle for $elapsed minutes');
    logError('Auto-ping stopped: no movement for 30 minutes',
        severity: ErrorSeverity.warning, autoSwitch: false);
    _idleAutoStopReference = null;
    toggleAutoPing(_autoMode);
  }

  /// Toggle auto-ping mode (Active, Passive, Hybrid, or Trace)
  /// Returns false if blocked by cooldown (Active/Hybrid/Trace Mode only - Passive Mode ignores cooldown)
  Future<bool> toggleAutoPing(AutoMode mode) async {
    if (_pingService == null) return false;

    final isPassive = mode == AutoMode.passive;
    final isHybrid = mode == AutoMode.hybrid;
    final isTargeted = mode == AutoMode.targeted;
    final isTxMode = !isPassive; // Active, Hybrid, and Targeted all do TX

    // If currently running the same mode, stop it (always allow stopping)
    if (_autoPingEnabled && _autoMode == mode) {
      debugLog('[PING] Stopping auto mode: ${mode.name}');

      // Try graceful disable first - this queues disable if ping is in progress
      await _pingService!.disableAutoPing();

      // If ping was in progress, disableAutoPing() queued the disable
      // Just update UI state - actual disable happens after RX window
      if (_pingService!.pendingDisable) {
        debugLog('[PING] Disable pending, will complete after RX window');
        // Don't change _autoPingEnabled yet - let RX window complete
        // But notify listeners so UI can grey out buttons and show "Stopping..."
        notifyListeners();
        return true;
      }

      // No ping in progress - immediate disable path
      // Stop TX echo tracking to prevent late timer callbacks from triggering pings
      // This fixes race condition where RX window timer fires after mode is disabled
      _pingService!.stopEchoTracking();
      // Stop RX wardriving (flushes batches)
      _rxLogger?.stopWardriving(trigger: 'user_stop');

      // Stop background service
      await BackgroundServiceManager.stopService();

      // Stop countdown timers (fixes "Next ping in Xs" continuing after stop)
      _autoPingTimer.stop();
      _rxWindowTimer.stop();

      // Save offline session if offline mode is enabled
      if (_preferences.offlineMode) {
        await _saveOfflineSession();
      }

      // End noise floor session when mode is disabled
      await _endNoiseFloorSession();

      // Keep heartbeat enabled (stays on while connected to prevent session expiry)
      // Re-start idle disconnect timer now that user is idle again
      _startIdleDisconnectTimer();

      _autoPingEnabled = false;
      _idleAutoStopReference = null;
      _finishLiveActivitySession();

      // Clear top-heard overlay on stop
      _clearOverlayState();

      // Start 5-second shared cooldown for TX modes (Active/Hybrid), not Passive Mode
      // Passive Mode is listening only, no cooldown needed
      if (isTxMode) {
        _cooldownTimer.start(5000);
        debugLog(
            '[${mode.name.toUpperCase()} MODE] Shared cooldown started (5s) - blocks TX Ping and TX modes');
      } else {
        debugLog('[PASSIVE MODE] Stopped - no cooldown (listen-only mode)');
      }
    } else {
      // Ignore re-taps while a start is already in flight (prevents the
      // double-tap / concurrent-heartbeat storm during the session check)
      if (_autoPingStarting) return false;

      // Set starting state immediately for instant UI feedback, BEFORE the
      // (awaited, network) session check so the buttons lock the moment it's tapped
      _autoPingStarting = true;
      notifyListeners();

      try {
        // Cancel idle disconnect timer — auto-ping keeps the session active
        _cancelIdleDisconnectTimer();

        // Check session validity before starting (skip in offline mode)
        if (!_preferences.offlineMode) {
          final sessionCheck = await _checkSessionBeforeAction();
          if (!sessionCheck) return false;
        }

        // Block starting if shared cooldown is active (TX modes only)
        // Passive Mode is listening only and can start during cooldown
        if (isTxMode && _cooldownTimer.isRunning) {
          debugLog(
              '[${mode.name.toUpperCase()} MODE] Start blocked by shared cooldown');
          return false;
        }

        // Stop any existing mode first
        if (_autoPingEnabled) {
          await _pingService!.forceDisableAutoPing();
          // Stop TX echo tracking to prevent late timer callbacks
          _pingService!.stopEchoTracking();
          _rxLogger?.stopWardriving(trigger: 'mode_switch');
          await BackgroundServiceManager.stopService();
          // Stop countdown timers when switching modes
          _autoPingTimer.stop();
          _rxWindowTimer.stop();
          // Clear top-heard overlay on mode switch
          _clearOverlayState();
          // Save offline session if offline mode is enabled
          if (_preferences.offlineMode) {
            await _saveOfflineSession();
          }
          // End existing noise floor session before starting new mode
          await _endNoiseFloorSession();
        }

        // Start new mode
        debugLog('[PING] Starting auto mode: ${mode.name}');
        _autoMode = mode;

        // Set interval from user preferences before starting
        final intervalMs = _preferences.autoPingInterval * 1000;
        _pingService!.setAutoPingInterval(intervalMs);
        debugLog(
            '[PING] Using interval from preferences: ${_preferences.autoPingInterval}s (${intervalMs}ms)');

        final started = await _pingService!.enableAutoPing(
          passiveMode: isPassive,
          hybridMode: isHybrid,
          targetedMode: isTargeted,
          targetRepeaterId: isTargeted ? _targetRepeaterId : null,
        );
        if (!started) {
          // Blocked by cooldown or already enabled
          if (_pingService!.isInCooldown()) {
            debugLog(
                '[PING] Auto mode start blocked by cooldown (${_pingService!.getRemainingCooldownSeconds()}s remaining)');
          } else {
            debugLog('[PING] Auto mode start blocked');
          }
          return false;
        }
        // Start RX wardriving for all modes
        // Reference: state.rxTracking.isWardriving = true in wardrive.js
        _rxLogger?.startWardriving();
        _autoPingEnabled = true;
        _idleAutoStopReference = DateTime.now();
        _startLiveActivitySession();

        // Start noise floor session for graph tracking
        final sessionLabel = isPassive
            ? 'passive'
            : isHybrid
                ? 'hybrid'
                : isTargeted
                    ? 'targeted'
                    : 'active';
        _startNoiseFloorSession(sessionLabel);

        // Enable heartbeat for all auto-ping modes (not offline mode)
        // Heartbeat sends keepalive ~1 min before session expiry (4 min timer)
        // Active/Hybrid pings renew session when moving, but heartbeat is the
        // safety net when stationary (25m distance filter skips TX pings)
        if (!_preferences.offlineMode) {
          _apiService.enableHeartbeat(
            gpsProvider: () {
              // Provide current GPS coordinates for heartbeat (matching wardrive.js)
              final pos = _gpsService.lastPosition;
              if (pos == null) return null;
              return (lat: pos.latitude, lon: pos.longitude);
            },
          );
          debugLog('[HEARTBEAT] Enabled for ${mode.name} Mode');
        }

        // Start background service for continuous operation
        final modeName = isPassive
            ? 'Passive Mode'
            : isHybrid
                ? 'Hybrid Mode'
                : isTargeted
                    ? 'Trace Mode'
                    : 'Active Mode';
        await BackgroundServiceManager.startService(
          mode: modeName,
          txCount: _pingStats.txCount,
          rxCount: _pingStats.rxCount,
          queueSize: _queueSize,
        );
      } finally {
        // Clear starting state on every path (session/cooldown/blocked early
        // returns, exceptions, and success) so the buttons never stay disabled
        _autoPingStarting = false;
        notifyListeners();
      }
    }

    notifyListeners();
    return true;
  }

  /// Clear ping markers from map
  void clearPings() {
    _txPings.clear();
    _rxPings.clear();
    _discLogEntries.clear();
    _traceLogEntries.clear();
    _clearOverlayState();
    _pingService?.resetStats();
    _notifyMapNow();
  }

  /// Clear log entries
  void clearLogs() {
    _txLogEntries.clear();
    _rxLogEntries.clear();
    _discLogEntries.clear();
    _traceLogEntries.clear();
    _errorLogEntries.clear();
    _clearOverlayState();
    _notifyMapNow();
  }

  /// Add a discovery log entry (from Passive Mode)
  void _addDiscLogEntry(DiscLogEntry entry) {
    _discLogEntries.insert(0, entry);
    if (_discLogEntries.length > _maxLogEntries) {
      _discLogEntries.removeLast();
    }
    debugLog(
        '[APP] Discovery log entry added: ${entry.nodeCount} nodes discovered');
    _notifyMapNow();
  }

  /// Add a trace log entry (from Trace Mode)
  void _addTraceLogEntry(TraceLogEntry entry) {
    _traceLogEntries.insert(0, entry);
    if (_traceLogEntries.length > _maxLogEntries) {
      _traceLogEntries.removeLast();
    }
    debugLog(
        '[APP] Trace log entry added: target=${entry.targetRepeaterId}, success=${entry.success}');

    // Update top repeaters overlay with successful trace result
    if (entry.success && entry.localSnr != null) {
      // Truncate 4-byte trace IDs to 3 bytes (6 hex chars) to fit overlay
      final id = entry.targetRepeaterId.toUpperCase();
      final displayId = id.length > 6 ? id.substring(0, 6) : id;
      _updateTopRepeaters([(repeaterId: displayId, snr: entry.localSnr!)],
          OverlayPingType.trace);
    }

    _notifyMapNow();
  }

  /// Log a user-facing error message
  /// Set [autoSwitch] to false to log without navigating to error log tab
  void logError(String message,
      {ErrorSeverity severity = ErrorSeverity.error, bool autoSwitch = true}) {
    _errorLogEntries.add(UserErrorEntry(
      timestamp: DateTime.now(),
      message: message,
      severity: severity,
    ));
    if (_errorLogEntries.length > _maxErrorEntries) {
      _errorLogEntries.removeAt(0);
    }
    if (autoSwitch) {
      _requestErrorLogSwitch = true; // Auto-switch to error log
    }
    notifyListeners();
  }

  // ============================================
  // Queue Controls
  // ============================================

  /// Force upload queued pings
  Future<void> forceUploadQueue() async {
    await _apiQueueService.forceUpload();
  }

  /// Clear the queue
  Future<void> clearQueue() async {
    await _apiQueueService.clear();
    notifyListeners();
  }

  // ============================================
  // Offline Mode
  // ============================================

  /// Toggle offline mode
  ///
  /// Returns a record with:
  /// - `success`: true if mode was changed successfully
  /// - `error`: optional error message if mode switch failed
  ///
  /// When connected, performs hot-switch between modes:
  /// - Online → Offline: waits for ping, flushes queue, releases API session
  /// - Offline → Online: waits for ping, saves offline session, requests new auth
  Future<({bool success, String? error})> setOfflineMode(bool enabled) async {
    // If already in requested mode, nothing to do
    if (_preferences.offlineMode == enabled) {
      debugLog('[APP] Already in ${enabled ? 'offline' : 'online'} mode');
      return (success: true, error: null);
    }

    // If not connected, simple mode change
    if (!isConnected) {
      return _setOfflineModeSimple(enabled);
    }

    // Hot-switch while connected
    return enabled ? await _switchToOfflineMode() : await _switchToOnlineMode();
  }

  /// Simple offline mode change (when not connected)
  ({bool success, String? error}) _setOfflineModeSimple(bool enabled) {
    _preferences = _preferences.copyWith(offlineMode: enabled);
    _apiQueueService.offlineMode = enabled;
    debugLog('[APP] Offline mode ${enabled ? 'enabled' : 'disabled'}');

    if (enabled) {
      // Cancel zone check retries — offline mode doesn't need zone validation
      _clearZoneCheckError();
      _isCheckingZone = false;
      _stopMaintenancePolling();
      // Start periodic auto-save to prevent data loss from app kill
      _startOfflineAutoSaveTimer();
      // Clear zone data when entering offline mode
      _inZone = null;
      _currentZone = null;
      _nearestZone = null;
      _lastZoneCheckPosition = null;
      _regionBorders = [];
      _bordersLoadedForZone = null;
      debugLog('[GEOFENCE] Cleared zone data for offline mode');
    } else {
      // Stop auto-save timer when leaving offline mode
      _stopOfflineAutoSaveTimer();
      // Re-check zone status when exiting offline mode
      if (_currentPosition != null) {
        debugLog(
            '[GEOFENCE] Re-checking zone status after offline mode disabled');
        checkZoneStatus();
      }
    }

    notifyListeners();
    return (success: true, error: null);
  }

  /// Switch from online to offline mode while connected
  Future<({bool success, String? error})> _switchToOfflineMode() async {
    debugLog('[APP] Hot-switching to offline mode while connected');
    _isSwitchingMode = true;
    _modeSwitchError = null;
    notifyListeners();

    try {
      // 1. Gracefully stop auto-ping if running (waits for RX window to complete)
      await _stopAutoPingGracefully();

      // 2. Flush API queue (waits for TX hold period)
      if (_apiService.hasSession) {
        debugLog('[APP] Flushing API queue before releasing session');
        try {
          await _apiQueueService.forceUploadWithHoldWait();
        } catch (e) {
          debugError('[APP] Failed to flush API queue: $e');
          // Continue anyway - don't block mode switch for queue errors
        }
      }

      // 4. Release API session
      if (_devicePublicKey != null && _apiService.hasSession) {
        debugLog('[APP] Releasing API session for offline mode');
        try {
          await _apiService.requestAuth(
            reason: 'disconnect',
            publicKey: _devicePublicKey!,
          );
          debugLog('[APP] API session released successfully');
        } catch (e) {
          debugError('[APP] Failed to release API session: $e');
          // Continue anyway - session will timeout naturally
        }
      }

      // 5. Update preferences and queue service
      _preferences = _preferences.copyWith(offlineMode: true);
      _apiQueueService.offlineMode = true;

      // 5b. Start periodic auto-save to prevent data loss from app kill
      _startOfflineAutoSaveTimer();

      // 5c. Cancel zone check retries and maintenance polling
      _clearZoneCheckError();
      _isCheckingZone = false;
      _stopMaintenancePolling();

      // 6. Clear zone data
      _inZone = null;
      _currentZone = null;
      _nearestZone = null;
      _lastZoneCheckPosition = null;
      _regionBorders = [];
      _bordersLoadedForZone = null;
      debugLog('[GEOFENCE] Cleared zone data for offline mode');

      debugLog('[APP] Successfully switched to offline mode');
      return (success: true, error: null);
    } catch (e) {
      debugError('[APP] Error switching to offline mode: $e');
      _modeSwitchError = 'Failed to switch to offline mode: $e';
      return (success: false, error: _modeSwitchError);
    } finally {
      _isSwitchingMode = false;
      notifyListeners();
    }
  }

  /// Switch from offline to online mode while connected
  Future<({bool success, String? error})> _switchToOnlineMode() async {
    debugLog('[APP] Hot-switching to online mode while connected');
    _isSwitchingMode = true;
    _modeSwitchError = null;
    var switchSucceeded = false;
    notifyListeners();

    try {
      // 1. Gracefully stop auto-ping if running (waits for RX window to complete)
      await _stopAutoPingGracefully();

      // 2. Save accumulated offline pings as session file
      await _saveOfflineSession();

      // 4. Request new auth session
      // Use "Anonymous" if renamed, otherwise real name
      final deviceName = _isAnonymousRenamed
          ? 'Anonymous'
          : (_meshCoreConnection?.selfInfo?.name ??
              connectedDeviceName?.replaceFirst('MeshCore-', ''));

      if (deviceName == null || deviceName.isEmpty) {
        debugError(
            '[APP] Cannot switch to online mode: no device name available');
        _modeSwitchError = 'Device name not available';
        return (success: false, error: _modeSwitchError);
      }

      if (_devicePublicKey == null) {
        debugError(
            '[APP] Cannot switch to online mode: no public key available');
        _modeSwitchError = 'Device public key not available';
        return (success: false, error: _modeSwitchError);
      }

      if (_currentPosition == null) {
        debugError('[APP] Cannot switch to online mode: no GPS position');
        _modeSwitchError = 'GPS position required for online mode';
        return (success: false, error: _modeSwitchError);
      }

      // Clear offline mode before zone check so checkZoneStatus() doesn't skip the API call
      _preferences = _preferences.copyWith(offlineMode: false);
      _apiQueueService.offlineMode = false;

      debugLog('[APP] Re-checking zone status before auth...');
      await checkZoneStatus();

      if (zoneCode == null) {
        debugError('[APP] Cannot switch to online mode: not in a zone');
        _modeSwitchError =
            'Could not determine your zone. Check GPS and internet connection.';
        return (success: false, error: _modeSwitchError);
      }

      // ============================================================
      // STAGE 1: Try existing public_key authentication
      // ============================================================
      debugLog(
          '[APP] Stage 1: Attempting auth with public_key: ${_devicePublicKey!.substring(0, 16)}...');

      final modelString = _meshCoreConnection?.deviceModel?.manufacturer ??
          _meshCoreConnection?.deviceInfo?.manufacturer ??
          'Unknown';

      var result = await _apiService.requestAuth(
        reason: 'connect',
        publicKey: _devicePublicKey!,
        who: deviceName,
        appVersion: _appVersion,
        power: _preferences.powerLevel,
        iataCode: zoneCode ?? _preferences.iataCode,
        model: modelString,
        radioFreq: _meshCoreConnection?.selfInfo?.radioConfigApi,
        lat: _currentPosition!.latitude,
        lon: _currentPosition!.longitude,
        accuracyMeters: _currentPosition!.accuracy,
      );

      // Check for maintenance mode
      if (result != null && result['maintenance'] == true) {
        _maintenanceMode = true;
        _maintenanceMessage = result['maintenance_message'] as String?;
        _maintenanceUrl = result['maintenance_url'] as String?;
        debugLog(
            '[MAINTENANCE] Auth returned maintenance: $_maintenanceMessage');
        _startMaintenancePolling();
        notifyListeners();
        _modeSwitchError =
            _maintenanceMessage ?? 'Service is under maintenance';
        return (success: false, error: _modeSwitchError);
      }

      // Check if Stage 1 succeeded
      if (result != null && result['success'] == true) {
        debugLog('[APP] Stage 1 succeeded: authenticated via public_key');
        if (result['type'] != null) {
          _authType = result['type'] as String;
          debugLog('[APP] Auth type: $_authType');
          notifyListeners();
        }
        _syncZoneCapacityFromAuth(result);
      } else if (result == null) {
        // API unreachable (null = network/timeout error)
        debugError('[APP] API unreachable - network error');
        _modeSwitchError = 'Unable to reach the MeshMapper server';
        return (success: false, error: _modeSwitchError);
      } else {
        // Stage 1 failed — check if Stage 2 is worth attempting
        debugLog(
            '[APP] Stage 1 failed: ${result['message'] ?? 'Unknown error'}');

        final stage1Reason = result['reason'] as String?;
        if (stage1Reason == 'gps_inaccurate' || stage1Reason == 'gps_stale') {
          debugError(
              '[APP] Stage 1 failed for GPS reason ($stage1Reason), skipping Stage 2');
          _modeSwitchError = result['message'] as String? ?? 'GPS error';
          return (success: false, error: _modeSwitchError);
        }

        // ============================================================
        // STAGE 2: Auth failed, attempt registration via signed contact_uri
        // ============================================================
        debugLog('[APP] Stage 2: Attempting registration via contact_uri...');

        String? contactUri;
        try {
          debugLog('[APP] Requesting signed contact URI from device...');
          contactUri = await _meshCoreConnection!.exportContact();
          debugLog(
              '[APP] Received contact URI: ${contactUri.substring(0, 50)}...');
        } catch (e) {
          debugError('[APP] Failed to get contact URI from device: $e');
          _modeSwitchError =
              'Companion not found in backend and failed to register via API';
          return (success: false, error: _modeSwitchError);
        }

        final registerResult = await _apiService.requestAuth(
          reason: 'register',
          contactUri: contactUri,
          who: deviceName,
          appVersion: _appVersion,
          power: _preferences.powerLevel,
          iataCode: zoneCode ?? _preferences.iataCode,
          model: modelString,
          radioFreq: _meshCoreConnection?.selfInfo?.radioConfigApi,
          lat: _currentPosition!.latitude,
          lon: _currentPosition!.longitude,
          accuracyMeters: _currentPosition!.accuracy,
        );

        if (registerResult == null) {
          debugError('[APP] Stage 2 failed: network error (API unreachable)');
          _modeSwitchError = 'Unable to reach the MeshMapper server';
          return (success: false, error: _modeSwitchError);
        }

        if (registerResult['success'] != true) {
          final serverReason =
              registerResult['reason'] as String? ?? 'registration_failed';
          final serverMessage = registerResult['message'] as String?;
          debugError(
              '[APP] Stage 2 failed: $serverReason - ${serverMessage ?? 'no message'}');
          _modeSwitchError = serverMessage ?? 'Registration rejected by server';
          return (success: false, error: _modeSwitchError);
        }

        // Registration successful
        debugLog('[APP] Stage 2 succeeded: registered and authenticated');
        if (registerResult['type'] != null) {
          _authType = registerResult['type'] as String;
          debugLog('[APP] Auth type: $_authType');
          notifyListeners();
        }
        _syncZoneCapacityFromAuth(registerResult);

        result = registerResult;
      }

      // 5. Auth successful - update state
      switchSucceeded = true;

      // 6. Update regional channels from auth response
      final channels = result['channels'];
      if (channels is List) {
        _regionalChannels = channels.cast<String>().toList();
        debugLog('[APP] Regional channels updated: $_regionalChannels');

        // Re-initialize channel service with regional channels
        await ChannelService.setRegionalChannels(_regionalChannels);
      }

      // Track session zone for zone-to-zone transfer detection
      _sessionZoneCode = zoneCode;

      debugLog('[APP] Successfully switched to online mode');
      return (success: true, error: null);
    } catch (e) {
      debugError('[APP] Error switching to online mode: $e');
      _modeSwitchError = 'Failed to switch to online mode: $e';
      return (success: false, error: _modeSwitchError);
    } finally {
      if (!switchSucceeded) {
        _preferences = _preferences.copyWith(offlineMode: true);
        _apiQueueService.offlineMode = true;
      }
      _isSwitchingMode = false;
      notifyListeners();
    }
  }

  /// Gracefully stop auto-ping mode if running, waiting for RX window to complete
  /// This prevents data loss by letting the TX echo tracking finish naturally
  Future<void> _stopAutoPingGracefully() async {
    if (!_autoPingEnabled || _pingService == null) return;

    debugLog('[APP] Gracefully stopping auto-ping mode for mode switch');

    // 1. Request graceful disable (sets pendingDisable if ping in progress)
    //    This prevents new pings from being scheduled after RX window ends
    await _pingService!.disableAutoPing();
    notifyListeners(); // UI shows "Stopping..." state

    // 2. Wait for TX echo tracking / RX window to finish naturally (~7 seconds)
    //    Don't wait for cooldown - proceed immediately after RX window ends
    await _waitForPingToComplete();

    // 3. Now do cleanup in order
    _pingService!.stopEchoTracking();

    // 4. Stop RX wardriving (flushes batches)
    _rxLogger?.stopWardriving(trigger: 'mode_switch');

    // 5. Stop background service
    await BackgroundServiceManager.stopService();

    // 6. Stop timers (including any cooldown that may have started)
    _autoPingTimer.stop();
    _rxWindowTimer.stop();
    _discoveryWindowTimer.stop();
    _cooldownTimer.stop();

    // 7. End noise floor session
    await _endNoiseFloorSession();

    // 8. Stop heartbeat
    _apiService.disableHeartbeat();

    // 9. Update state
    _autoPingEnabled = false;
    _idleAutoStopReference = null;
    _finishLiveActivitySession();
    debugLog('[APP] Auto-ping mode stopped gracefully');
    notifyListeners();
  }

  /// Wait for any ping operation to complete (TX sending or RX window)
  Future<void> _waitForPingToComplete() async {
    const pollInterval = Duration(milliseconds: 100);
    const maxWaitTime = Duration(seconds: 10); // Safety timeout
    final startTime = DateTime.now();

    while (isPingInProgress) {
      if (DateTime.now().difference(startTime) > maxWaitTime) {
        debugWarn('[APP] Timeout waiting for ping to complete');
        break;
      }
      debugLog('[APP] Waiting for ping to complete...');
      await Future.delayed(pollInterval);
    }
  }

  /// Retry switching to online mode after a failed attempt
  Future<({bool success, String? error})> retryOnlineMode() async {
    if (!isConnected) {
      return (success: false, error: 'Not connected to device');
    }
    if (!_preferences.offlineMode) {
      return (success: true, error: null); // Already online
    }
    return _switchToOnlineMode();
  }

  /// Save accumulated offline pings to a session file
  Future<void> _saveOfflineSession() async {
    final pings = _apiQueueService.getAndClearOfflinePings();
    if (pings.isEmpty) {
      debugLog('[APP] No offline pings to save');
      // Still break the auto-save tracker so the next offline session starts a
      // fresh file instead of appending to the previously tracked session.
      // No-op when nothing is tracked.
      _offlineSessionService.finalizeCurrentSession();
      return;
    }

    // Include device info for auth during upload (use real name, not "Anonymous" — sessions upload later)
    // Note: Connection already validates device name exists, so this should never be null
    final offlineDeviceName = _isAnonymousRenamed
        ? _originalDeviceName
        : (_meshCoreConnection?.selfInfo?.name ??
            connectedDeviceName?.replaceFirst('MeshCore-', ''));
    // Finalize the in-progress session (created by periodic auto-save) in place
    // rather than creating a new one — otherwise the auto-saved session and this
    // final save become two identical sessions at the same time. updateCurrentSession
    // creates a fresh session only when no auto-save has run yet.
    await _offlineSessionService.updateCurrentSession(
      pings,
      devicePublicKey: _devicePublicKey,
      deviceName: offlineDeviceName,
      contactUri: _offlineContactUri,
      radioConfig: _meshCoreConnection?.selfInfo?.radioConfigApi,
      deviceModel: _meshCoreConnection?.deviceModel?.manufacturer ??
          _meshCoreConnection?.deviceInfo?.manufacturer ??
          _manufacturerString,
      powerLevel: _preferences.powerLevel,
      appVersion: _appVersion,
    );
    _offlineSessionService.finalizeCurrentSession();
    debugLog('[APP] Saved offline session with ${pings.length} pings');
    _stopOfflineAutoSaveTimer();
    notifyListeners();
  }

  /// Periodically auto-save offline pings to prevent data loss from app kill.
  /// Uses a non-destructive snapshot so in-memory accumulation continues.
  void _autoSaveOfflinePings() {
    if (!_preferences.offlineMode || _apiQueueService.offlinePingCount == 0) {
      return;
    }

    final pings = _apiQueueService.getOfflinePingsSnapshot();
    if (pings.isEmpty) return;

    final offlineDeviceName = _isAnonymousRenamed
        ? _originalDeviceName
        : (_meshCoreConnection?.selfInfo?.name ??
            connectedDeviceName?.replaceFirst('MeshCore-', ''));

    _offlineSessionService.updateCurrentSession(
      pings,
      devicePublicKey: _devicePublicKey,
      deviceName: offlineDeviceName,
      contactUri: _offlineContactUri,
      radioConfig: _meshCoreConnection?.selfInfo?.radioConfigApi,
      deviceModel: _meshCoreConnection?.deviceModel?.manufacturer ??
          _meshCoreConnection?.deviceInfo?.manufacturer ??
          _manufacturerString,
      powerLevel: _preferences.powerLevel,
      appVersion: _appVersion,
    );
  }

  void _startOfflineAutoSaveTimer() {
    _offlineAutoSaveTimer?.cancel();
    _offlineAutoSaveTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      _autoSaveOfflinePings();
    });
    debugLog('[OFFLINE] Auto-save timer started (60s interval)');
  }

  void _stopOfflineAutoSaveTimer() {
    if (_offlineAutoSaveTimer != null) {
      _offlineAutoSaveTimer!.cancel();
      _offlineAutoSaveTimer = null;
      debugLog('[OFFLINE] Auto-save timer stopped');
    }
  }

  /// Upload a stored offline session
  Future<bool> uploadOfflineSession(String filename) async {
    final sessionData = _offlineSessionService.getSessionData(filename);
    if (sessionData == null) {
      debugLog('[APP] Session not found: $filename');
      return false;
    }

    try {
      final pings = (sessionData['pings'] as List<dynamic>)
          .map((p) => Map<String, dynamic>.from(p as Map))
          .toList();

      if (pings.isEmpty) {
        debugLog('[APP] Session has no pings: $filename');
        return false;
      }

      // Upload the batch
      final result = await _apiService.uploadBatch(pings);
      final success = result == UploadResult.success;
      if (success) {
        // Delete the session file on successful upload
        await _offlineSessionService.deleteSession(filename);
        debugLog(
            '[API] Uploaded and deleted offline session: $filename (${pings.length} pings)');
      } else {
        debugError('[API] Failed to upload offline session: $filename');
      }
      notifyListeners();
      return success;
    } catch (e) {
      debugError('[API] Error uploading offline session $filename: $e');
      return false;
    }
  }

  /// Upload an offline session with authenticated API session
  /// Uses stored device credentials to authenticate before uploading.
  /// Session is fully isolated from the shared ApiService state — offline uploads
  /// never touch _sessionId and cannot trigger BLE disconnect on failure.
  ///
  /// @param onProgress Optional callback for progress updates (e.g., "Batch 1/3")
  /// Returns the result of the upload operation
  Future<OfflineUploadResult> uploadOfflineSessionWithAuth(
    String filename, {
    void Function(String status)? onProgress,
  }) async {
    // Concurrency guard — only one offline upload at a time
    if (_isUploadingOfflineSession) {
      debugWarn(
          '[OFFLINE] Upload already in progress, rejecting concurrent request');
      return OfflineUploadResult.uploadInProgress;
    }

    _isUploadingOfflineSession = true;
    notifyListeners();

    try {
      return await _uploadOfflineSessionIsolated(filename,
          onProgress: onProgress);
    } finally {
      _isUploadingOfflineSession = false;
      notifyListeners();
    }
  }

  /// Internal implementation of offline session upload with isolated session
  Future<OfflineUploadResult> _uploadOfflineSessionIsolated(
    String filename, {
    void Function(String status)? onProgress,
  }) async {
    // 1. Get session with stored device credentials
    final session = _offlineSessionService.getSession(filename);
    if (session == null) {
      debugLog('[OFFLINE] Session not found: $filename');
      return OfflineUploadResult.notFound;
    }

    // Check if session has pings
    final sessionData = session.data;
    final pings = (sessionData['pings'] as List<dynamic>?)
        ?.map((p) => Map<String, dynamic>.from(p as Map))
        .toList();

    if (pings == null || pings.isEmpty) {
      debugLog('[OFFLINE] Session has no pings: $filename');
      return OfflineUploadResult.invalidSession;
    }

    // 2. Get device credentials from session, falling back to connected device
    var publicKey = session.devicePublicKey;
    var deviceName = session.deviceName;

    if (publicKey == null || deviceName == null || deviceName.isEmpty) {
      if (_devicePublicKey != null && displayDeviceName != null) {
        publicKey ??= _devicePublicKey;
        if (deviceName == null || deviceName.isEmpty) {
          deviceName = displayDeviceName;
        }
        debugLog(
            '[OFFLINE] Legacy session $filename: using connected device credentials');
      } else {
        debugLog(
            '[OFFLINE] Session missing credentials and no device connected: $filename');
        return OfflineUploadResult.invalidSession;
      }
    }

    onProgress?.call('Authenticating...');

    // 3. Check GPS before auth — the server requires current coordinates for geo-auth
    if (_currentPosition == null) {
      debugError(
          '[OFFLINE] Upload requires GPS - location services not available');
      return OfflineUploadResult.gpsRequired;
    }

    // 4. Authenticate with offline_mode: true, skipSessionStore: true
    //    This prevents writing to shared _sessionId/_txAllowed/etc.
    // Use the device/radio metadata snapshotted when the session was recorded so the upload
    // matches a live session (feature parity); fall back to current values for legacy
    // sessions saved before these fields were captured.
    final uploadModel = session.deviceModel ?? 'Offline Upload';
    final uploadPower = session.powerLevel ?? _preferences.powerLevel;
    final uploadVersion = session.appVersion ?? _appVersion;
    debugLog(
        '[OFFLINE] Authenticating for offline upload with device: $deviceName '
        '(model: $uploadModel, power: ${uploadPower}w, ver: $uploadVersion)');
    // Retry the auth on transient network/timeout errors — requestAuth returns null
    // on a TimeoutException. A single slow first request shouldn't abort the upload
    // and surface a misleading "auth failed" (mirrors the batch-upload retry below).
    const authRetryBackoff = [2, 4]; // seconds, after the initial attempt
    Map<String, dynamic>? authResult;
    for (var attempt = 0;; attempt++) {
      authResult = await _apiService.requestAuth(
        reason: 'connect',
        publicKey: publicKey,
        who: deviceName,
        appVersion: uploadVersion,
        power: uploadPower,
        iataCode: zoneCode ?? _preferences.iataCode,
        model: uploadModel,
        radioFreq: session.radioConfig,
        lat: _currentPosition?.latitude,
        lon: _currentPosition?.longitude,
        accuracyMeters: _currentPosition?.accuracy,
        offlineMode: true,
        skipSessionStore: true,
      );
      if (authResult != null) break; // got a response (success OR a real rejection)
      if (attempt >= authRetryBackoff.length) break; // retries exhausted
      final delay = authRetryBackoff[attempt];
      debugWarn(
          '[OFFLINE] Auth network error, retry ${attempt + 1}/${authRetryBackoff.length} after ${delay}s');
      onProgress?.call('Authenticating (retry ${attempt + 1})...');
      await Future.delayed(Duration(seconds: delay));
    }

    Map<String, dynamic>? effectiveAuth = authResult;

    if (authResult == null) {
      debugError('[OFFLINE] Auth failed: network error after retries');
      return OfflineUploadResult.networkError;
    }

    if (authResult['success'] != true) {
      final reason = authResult['reason'] as String? ?? 'unknown';
      debugLog('[OFFLINE] Stage 1 failed: $reason');

      // Stage 2: If unknown_device and we have a stored contactUri, attempt registration
      if (reason == 'unknown_device' && session.contactUri != null) {
        debugLog(
            '[OFFLINE] Stage 2: Attempting registration via stored contact URI...');
        final registerResult = await _apiService.requestAuth(
          reason: 'register',
          contactUri: session.contactUri,
          who: deviceName,
          appVersion: uploadVersion,
          power: uploadPower,
          iataCode: zoneCode ?? _preferences.iataCode,
          model: uploadModel,
          radioFreq: session.radioConfig,
          lat: _currentPosition?.latitude,
          lon: _currentPosition?.longitude,
          accuracyMeters: _currentPosition?.accuracy,
          offlineMode: true,
          skipSessionStore: true,
        );

        if (registerResult == null) {
          debugError('[OFFLINE] Stage 2 registration network error');
          return OfflineUploadResult.networkError;
        }
        if (registerResult['success'] != true) {
          final regReason = registerResult['reason'] as String? ?? 'unknown';
          debugError('[OFFLINE] Stage 2 registration failed: $regReason');
          return OfflineUploadResult.authFailed;
        }

        debugLog(
            '[OFFLINE] Stage 2 succeeded: device registered for offline upload');
        effectiveAuth = registerResult;
      } else {
        debugError('[OFFLINE] Auth failed: $reason');
        return OfflineUploadResult.authFailed;
      }
    }

    // Extract session_id into local variable — never stored in shared state
    final offlineSessionId = effectiveAuth!['session_id'] as String?;
    if (offlineSessionId == null) {
      debugError('[OFFLINE] Auth succeeded but no session_id in response');
      return OfflineUploadResult.authFailed;
    }

    debugLog(
        '[OFFLINE] Authenticated with isolated session: $offlineSessionId');

    // Server can take several seconds to make a freshly-created offline session
    // visible to /wardrive (read-after-write propagation). Give it a brief settle,
    // then let the FIRST batch wait it out with a generous backoff — once any batch
    // lands the session is valid for the rest.
    await Future.delayed(const Duration(seconds: 2));

    // 4. Upload pings in batches of 50, retrying session/transient errors.
    const batchSize = 50;
    var uploadedCount = 0;
    final totalBatches = (pings.length + batchSize - 1) ~/ batchSize;

    // Accumulate the server's per-region placement summary across all batches so the uploaded
    // session can show where its pings landed (e.g. "DSA 88 · EMA 157 · too far 3"). Offline
    // uploads route each ping to its own region server-side; these come back per batch.
    final Map<String, int> placementTotals = {};
    var tooFarTotal = 0;
    void accumulatePlacement(Map<String, dynamic> resp) {
      final pc = resp['placement_counts'];
      if (pc is Map) {
        pc.forEach((k, v) {
          final n = (v is int) ? v : (int.tryParse('$v') ?? 0);
          placementTotals[k.toString()] = (placementTotals[k.toString()] ?? 0) + n;
        });
      }
      final tf = resp['too_far_region'];
      if (tf is int) {
        tooFarTotal += tf;
      } else if (tf != null) {
        tooFarTotal += int.tryParse('$tf') ?? 0;
      }
    }

    // Backoff (seconds) for session-propagation / transient errors. The first batch
    // absorbs the session-propagation delay, so it gets a much longer budget than
    // later batches (which only see a session error if it genuinely expired/revoked).
    const firstBatchBackoff = [2, 3, 4, 5, 6, 8, 10];
    const laterBatchBackoff = [2, 4];

    for (var i = 0; i < pings.length; i += batchSize) {
      final batchNum = (i ~/ batchSize) + 1;
      onProgress?.call('Batch $batchNum/$totalBatches');

      final batch = pings.skip(i).take(batchSize).toList();
      final backoff = i == 0 ? firstBatchBackoff : laterBatchBackoff;

      var result =
          await _apiService.uploadBatchWithSessionId(batch, offlineSessionId,
              onResponse: accumulatePlacement);

      // Retry only session-propagation / transient errors. nonRetryable
      // (data/zone/key) errors are NOT retried — we stop and preserve instead.
      for (var retry = 0;
          retry < backoff.length &&
              (result == UploadResult.sessionError ||
                  result == UploadResult.retryable);
          retry++) {
        final delay = backoff[retry];
        final kind =
            result == UploadResult.sessionError ? 'session' : 'transient';
        debugLog(
            '[OFFLINE] Batch $batchNum $kind error, retry ${retry + 1}/${backoff.length} after ${delay}s');
        onProgress?.call('Batch $batchNum/$totalBatches (retry ${retry + 1})');
        await Future.delayed(Duration(seconds: delay));
        result =
            await _apiService.uploadBatchWithSessionId(batch, offlineSessionId,
              onResponse: accumulatePlacement);
      }

      if (result == UploadResult.success) {
        uploadedCount += batch.length;
        debugLog('[OFFLINE] Uploaded batch $batchNum: ${batch.length} pings');
        continue;
      }

      // Any non-success after retries: STOP and preserve the remaining pings.
      // We never discard un-uploaded data — it stays in the file for a later retry.
      final stopReason = result == UploadResult.sessionError
          ? 'session error'
          : result == UploadResult.nonRetryable
              ? 'data/zone error'
              : 'network error';
      debugWarn(
          '[OFFLINE] Batch $batchNum stopped ($stopReason) — preserving remaining pings');
      break;
    }

    // Delay after posting before disconnect
    await Future.delayed(const Duration(seconds: 1));

    // 5. Release isolated API session (does not clear shared state)
    onProgress?.call('Finalizing...');
    await _apiService.requestAuth(
      reason: 'disconnect',
      publicKey: publicKey,
      sessionId: offlineSessionId,
    );
    debugLog('[OFFLINE] Isolated upload session released');

    // 6. Clean up session based on results — prune ONLY successfully-uploaded
    //    pings; everything not uploaded is preserved in the file for a later retry.
    final remainingPings = pings.length - uploadedCount;

    if (remainingPings <= 0) {
      await _offlineSessionService.markAsUploaded(
        filename,
        placementCounts: placementTotals.isNotEmpty ? placementTotals : null,
        tooFarRegion: tooFarTotal,
      );
      debugLog(
          '[OFFLINE] Session complete: $uploadedCount uploaded from $filename');
      notifyListeners();
      return OfflineUploadResult.success;
    } else {
      if (uploadedCount > 0) {
        await _offlineSessionService.removeProcessedPings(
            filename, uploadedCount);
        debugLog(
            '[OFFLINE] Removed $uploadedCount uploaded pings, $remainingPings preserved in $filename');
      }
      debugWarn(
          '[OFFLINE] Partial upload: $uploadedCount uploaded, $remainingPings preserved in $filename');
      notifyListeners();
      return OfflineUploadResult.partialFailure;
    }
  }

  /// Delete an offline session without uploading
  Future<void> deleteOfflineSession(String filename) async {
    await _offlineSessionService.deleteSession(filename);
    notifyListeners();
  }

  /// Clear all offline sessions
  Future<void> clearOfflineSessions() async {
    await _offlineSessionService.clearAll();
    notifyListeners();
  }

  // ============================================
  // User Preferences
  // ============================================

  /// Update user preferences
  void updatePreferences(UserPreferences preferences) {
    debugLog(
        '[APP] Preferences updated: externalAntennaSet=${preferences.externalAntennaSet}, '
        'externalAntenna=${preferences.externalAntenna}, autoPowerSet=${preferences.autoPowerSet}');

    _preferences = preferences;

    // Update user-original baseline when user changes zone-overridable settings
    if (_userOriginalAutoPingInterval != null) {
      _userOriginalAutoPingInterval = preferences.autoPingInterval;
      _userOriginalHybridMode = preferences.hybridModeEnabled;
      _userOriginalDiscDrop = preferences.discDropEnabled;
      _userOriginalFloodTraffic = preferences.floodTrafficEnabled;
    }

    // Clear restored flags — user is making a manual choice now
    _antennaRestoredFromDevice = false;
    _powerRestoredFromDevice = false;

    // Persist antenna choice per device name (use original name, not "Anonymous")
    final deviceName =
        _isAnonymousRenamed ? _originalDeviceName : displayDeviceName;
    if (deviceName != null && preferences.externalAntennaSet) {
      _deviceAntennaPreferences[deviceName] = preferences.externalAntenna;
      _saveDeviceAntennaPreferences();
      debugLog(
          '[APP] Saved antenna preference for "$deviceName": ${preferences.externalAntenna ? "external" : "device"}');
    }

    // Persist power override per device name
    if (deviceName != null &&
        preferences.powerLevelSet &&
        !preferences.autoPowerSet) {
      _devicePowerOverrides[deviceName] = {
        'powerLevel': preferences.powerLevel,
        'txPower': preferences.txPower,
      };
      _saveDevicePowerOverrides();
      debugLog(
          '[APP] Saved power override for "$deviceName": ${preferences.powerLevel}W');
    } else if (deviceName != null && preferences.autoPowerSet) {
      // User re-selected the auto-detected value — clear any saved override
      if (_devicePowerOverrides.remove(deviceName) != null) {
        _saveDevicePowerOverrides();
        debugLog(
            '[APP] Cleared power override for "$deviceName" (auto-detected selected)');
      }
    }

    // Propagate RSSI filter setting to live trackers/validators
    _syncRssiFilterSetting(preferences.disableRssiFilter);

    // Propagate CARpeater prefix to live trackers
    _syncCarpeaterPrefix();

    // Propagate min ping distance to GpsService and PingService
    _gpsService
        .setMinPingDistance(preferences.minPingDistanceMeters.toDouble());
    PingService.currentMinDistance = preferences.minPingDistanceMeters;

    // Marker-style / GPS-marker prefs can change here — bump the map.
    _notifyMapNow();
    _savePreferences();
  }

  /// Set anonymous mode, disconnecting and reconnecting if currently connected
  Future<void> setAnonymousMode(bool enabled) async {
    if (enabled == _preferences.anonymousMode) return;

    _preferences = _preferences.copyWith(anonymousMode: enabled);
    _savePreferences();
    notifyListeners();

    // If connected, disconnect and reconnect for clean auth session
    if (_connectionStatus == ConnectionStatus.connected &&
        _meshCoreConnection != null) {
      final deviceToReconnect = _bluetoothService.connectedDevice;
      if (deviceToReconnect != null) {
        _isAnonymousReconnectInProgress = true;
        _anonymousReconnectEnabling = enabled;
        _connectionStep = ConnectionStep.disconnected;
        notifyListeners();
        try {
          await disconnect();
          await Future.delayed(const Duration(milliseconds: 500));
          await connectToDevice(deviceToReconnect);
        } catch (e) {
          debugError('[APP] Anonymous mode reconnect error: $e');
        } finally {
          _isAnonymousReconnectInProgress = false;
          notifyListeners();
        }
      }
    }
  }

  /// Propagate carpeaterPrefix to live TxTracker and RxLogger
  void _syncCarpeaterPrefix() {
    final prefix =
        _preferences.ignoreCarpeater ? _preferences.ignoreRepeaterId : null;
    if (_txTracker != null) {
      _txTracker!.carpeaterPrefix = prefix;
      debugLog('[APP] Synced TxTracker.carpeaterPrefix = ${prefix ?? 'null'}');
    }
    if (_rxLogger != null) {
      _rxLogger!.carpeaterPrefix = prefix;
      debugLog('[APP] Synced RxLogger.carpeaterPrefix = ${prefix ?? 'null'}');
    }
  }

  /// Propagate disableRssiFilter to all active trackers and validators
  void _syncRssiFilterSetting(bool disableRssiFilter) {
    if (_txTracker != null) {
      _txTracker!.disableRssiFilter = disableRssiFilter;
    }
    if (_unifiedRxHandler != null) {
      final oldValidator = _unifiedRxHandler!.validator;
      final newValidator = PacketValidator(
        allowedChannels: oldValidator.allowedChannels,
        disableRssiFilter: disableRssiFilter,
      );
      _unifiedRxHandler!.updateValidator(newValidator);
    }
    if (_pingService != null) {
      _pingService!.disableRssiFilter = disableRssiFilter;
    }
  }

  /// Set developer mode (unlocked by tapping version 7 times)
  void setDeveloperMode(bool enabled) {
    _preferences = _preferences.copyWith(developerModeEnabled: enabled);
    debugLog('[APP] Developer mode ${enabled ? 'enabled' : 'disabled'}');
    notifyListeners();
    _savePreferences();
  }

  /// Set map style (dark, light, satellite) and persist.
  /// The base map style is map-rendered state: `MapWidget._buildMap` reads
  /// `preferences.mapStyle` and feeds it to `MapLibreMap.styleString`, but the
  /// map is isolated behind the `mapRevision` Selector (see Critical Rule 9) and
  /// uses `context.read`. Plain `notifyListeners()` leaves `mapRevision`
  /// untouched, so the map never rebuilds and the new style never reaches the
  /// native `setStyle` — the log fires but the map stays on the old style. Bump
  /// the revision via `_notifyMapNow()` so the rebuild applies the style.
  void setMapStyle(String style) {
    _preferences = _preferences.copyWith(mapStyle: style);
    debugLog('[MAP] Map style set to $style');
    _notifyMapNow();
    _savePreferences();
  }

  /// Set coverage overlay opacity (0.3–1.0) and persist.
  /// MapWidget watches `preferences.coverageOverlayOpacity` and applies the
  /// new value to the raster layer at runtime via setLayerProperties, so the
  /// overlay fades live as the slider moves. Lower bound of 0.3 prevents the
  /// overlay from disappearing entirely.
  void setCoverageOverlayOpacity(double opacity) {
    final clamped = opacity.clamp(0.3, 1.0);
    _preferences = _preferences.copyWith(coverageOverlayOpacity: clamped);
    debugLog(
        '[MAP] Coverage overlay opacity set to ${clamped.toStringAsFixed(2)}');
    notifyListeners();
    _savePreferences();
  }

  /// Set app theme mode (dark/light) and persist
  void setThemeMode(String mode) {
    _preferences = _preferences.copyWith(themeMode: mode);
    debugLog('[THEME] Theme mode set to $mode');
    notifyListeners();
    _savePreferences();
  }

  /// Set color vision type for accessibility and persist
  void setColorVisionType(String type) {
    _preferences = _preferences.copyWith(colorVisionType: type);
    PingColors.setColorVisionType(
      ColorVisionType.values.firstWhere((e) => e.name == type,
          orElse: () => ColorVisionType.none),
    );
    debugLog('[A11Y] Color vision type set to $type');
    // Map-rendered state: the CVD palette recolours both the coverage overlay
    // (detected via `overlayPrefChanged` in `MapWidget._buildMap`) and the ping
    // markers (`PingColors`). Both only re-apply on a map rebuild, which is
    // gated by `mapRevision` (Critical Rule 9) — plain `notifyListeners()` would
    // update the preference but leave the map on the old colours. Bump the
    // revision via `_notifyMapNow()` so the rebuild applies the new palette.
    _notifyMapNow();
    _savePreferences();
  }

  /// Set unit system preference (metric or imperial)
  void setUnitSystem(String system) {
    _preferences = _preferences.copyWith(unitSystem: system);
    debugLog('[UI] Unit system set to $system');
    notifyListeners();
    _savePreferences();
  }

  /// Set close app after disconnect preference (Android only)
  void setCloseAppAfterDisconnect(bool value) {
    _preferences = _preferences.copyWith(closeAppAfterDisconnect: value);
    debugLog('[APP] Close app after disconnect set to: $value');
    notifyListeners();
    _savePreferences();
  }

  /// Set map auto-follow preference and persist
  void setMapAutoFollow(bool value) {
    _preferences = _preferences.copyWith(mapAutoFollow: value);
    debugLog('[MAP] Map auto-follow set to $value');
    notifyListeners();
    _savePreferences();
  }

  /// Set map always-north preference and persist
  void setMapAlwaysNorth(bool value) {
    _preferences = _preferences.copyWith(mapAlwaysNorth: value);
    debugLog('[MAP] Map always-north set to $value');
    notifyListeners();
    _savePreferences();
  }

  /// Set map rotation-locked preference and persist
  void setMapRotationLocked(bool value) {
    _preferences = _preferences.copyWith(mapRotationLocked: value);
    debugLog('[MAP] Map rotation-locked set to $value');
    notifyListeners();
    _savePreferences();
  }

  /// Toggle sound notifications on/off
  Future<void> toggleSoundEnabled() async {
    await _audioService.toggle();
    notifyListeners();
  }

  /// Set sound notifications enabled state
  Future<void> setSoundEnabled(bool enabled) async {
    await _audioService.setEnabled(enabled);
    notifyListeners();
  }

  /// Set TX sound enabled state (ping sent / discovery sent)
  Future<void> setTxSoundEnabled(bool enabled) async {
    await _audioService.setTxEnabled(enabled);
    notifyListeners();
  }

  /// Set RX sound enabled state (repeater echo / RX observation)
  Future<void> setRxSoundEnabled(bool enabled) async {
    await _audioService.setRxEnabled(enabled);
    notifyListeners();
  }

  /// Set disconnect alert enabled state
  Future<void> setDisconnectAlertEnabled(bool enabled) async {
    _preferences = _preferences.copyWith(disconnectAlertEnabled: enabled);
    await _savePreferences();
    debugLog('[AUDIO] Disconnect alert ${enabled ? 'enabled' : 'disabled'}');
    notifyListeners();
  }

  /// Broadcast my coordinates: when true, TX pings put real GPS on the air
  /// (legacy). When false (default), pings broadcast the privacy-preserving wire
  /// tag and coords travel only via the API.
  Future<void> setBroadcastCoords(bool enabled) async {
    _preferences = _preferences.copyWith(broadcastCoords: enabled);
    await _savePreferences();
    debugLog('[PING] Broadcast coordinates ${enabled ? 'enabled' : 'disabled'}');
    notifyListeners();
  }

  /// Play disconnect alert if enabled (triple beep for unexpected ping stop)
  void _playDisconnectAlert() {
    if (!_audioService.isEnabled || !_preferences.disconnectAlertEnabled) {
      return;
    }
    debugLog('[AUDIO] Playing disconnect alert — pinging stopped unexpectedly');
    _audioService.playAlertSound();
  }

  /// Navigate to coordinates on map (triggered from log entries)
  void navigateToMapCoordinates(double latitude, double longitude) {
    _mapNavigationTarget = (lat: latitude, lon: longitude);
    _mapNavigationTrigger++; // Increment to trigger listeners
    _requestMapTabSwitch = true; // Request tab switch
    // Map-relevant: the build()-side nav block reads mapNavigationTrigger, so
    // the map must rebuild for the camera jump to fire (GPS no longer forces
    // frequent rebuilds after the position/map-rebuild decouple).
    _notifyMapNow();
  }

  /// Clear the map tab switch request (called by main scaffold after switching)
  void clearMapTabSwitchRequest() {
    _requestMapTabSwitch = false;
  }

  /// Clear the error log switch request (called by log screen after switching)
  void clearErrorLogSwitchRequest() {
    _requestErrorLogSwitch = false;
  }


  // ============================================
  // API Error Handling
  // ============================================

  /// Handle API error codes with user-friendly messages
  /// Returns a user-friendly message for the error code
  String _getErrorMessage(String? reason, String? serverMessage) {
    switch (reason) {
      case 'unknown_device':
        return 'Unknown device. Please advertise yourself on the mesh using the official MeshCore app.';
      case 'outside_zone':
        return 'Not in any wardriving zone. Move closer to a zone and try again.';
      case 'zone_disabled':
        return 'This zone is currently disabled. Try again later.';
      case 'zone_full':
        return 'Zone is at TX capacity. You can still receive (RX-only mode).';
      case 'gps_stale':
        return 'GPS data is too old. Acquiring fresh position...';
      case 'gps_inaccurate':
        return 'GPS accuracy insufficient (need <50m). Waiting for better signal...';
      case 'bad_key':
        return 'Invalid API key. Please check configuration.';
      case 'invalid_request':
        return serverMessage ?? 'Invalid request to API.';
      case 'session_expired':
        return 'Session has expired. Please reconnect.';
      case 'session_limit':
        return 'Reached session limit. Please reconnect to continue.';
      case 'bad_session':
        return 'Invalid session. Please reconnect.';
      case 'outofdate':
        return 'App version outdated. Please update to the latest version.';
      case 'session_invalid':
        return 'Session is invalid. Please reconnect.';
      case 'session_revoked':
        return 'Session was revoked. Please reconnect.';
      case 'invalid_key':
        return 'Invalid API key. Please check configuration.';
      case 'unauthorized':
        return 'Unauthorized. Please reconnect.';
      case 'rate_limited':
        return 'Rate limited. Please slow down.';
      case 'maintenance':
        return 'Service is under maintenance. Try again later.';
      case 'network_error':
        return 'Unable to connect to the MeshMapper server. Please check your internet connection and try again.';
      case 'clock_error':
        return serverMessage ?? 'Device clock error. Power-cycle your device to reset it.';
      default:
        return serverMessage ?? 'Unknown error occurred.';
    }
  }

  /// Handle session error from wardrive/heartbeat API calls
  /// This may trigger auto-disconnect
  Future<void> handleSessionError(String? reason, String? message) async {
    final userMessage = _getErrorMessage(reason, message);

    // Session ping-counter exhausted (wire tag's 11-bit cap). The session is still
    // valid here, so flush the queue under it BEFORE disconnecting: clearOnDisconnect()
    // drops pending pings, and token-ping wire tags would fail validation if re-uploaded
    // later under a new session.
    if (reason == 'session_limit') {
      debugError('[SESSION] $userMessage');
      logError(userMessage, severity: ErrorSeverity.warning);
      try {
        await _apiQueueService.flushQueue();
      } catch (e) {
        debugError('[SESSION] Queue flush before session-limit disconnect failed: $e');
      }
      await disconnect();
      return;
    }

    // Rate limiting should warn but not disconnect (per PORTED_APP behavior)
    if (reason == 'rate_limited') {
      debugWarn(
          '[API] Rate limited - continuing without disconnect: $userMessage');
      return;
    }

    // Zone grace period: intercept outside_zone during active session
    if (reason == 'outside_zone' && _isInZoneGracePeriod) {
      debugLog(
          '[ZONE GRACE] outside_zone during grace period — already handling');
      return;
    }
    if (reason == 'outside_zone' && isConnected && !_isInZoneGracePeriod) {
      debugLog('[ZONE GRACE] outside_zone — entering grace period');
      await _startZoneGracePeriod();
      return;
    }

    // Log error
    debugError('[API] Session error: $reason - $userMessage');
    logError(userMessage, severity: ErrorSeverity.error);

    // Session errors that require disconnect
    const sessionErrors = {
      'session_expired',
      'session_invalid',
      'session_revoked',
      'bad_session',
    };

    // Authorization errors that require disconnect
    const authErrors = {
      'invalid_key',
      'unauthorized',
      'bad_key',
    };

    // Zone errors that require disconnect
    const zoneErrors = {
      'outside_zone',
      'zone_full',
      'zone_disabled',
    };

    // Handle errors that require disconnect
    if (sessionErrors.contains(reason) ||
        authErrors.contains(reason) ||
        zoneErrors.contains(reason)) {
      debugLog('[API] Session error requires disconnect: $reason');

      // Preserve queued wardrive data to offline storage before disconnect clears it
      if (sessionErrors.contains(reason)) {
        try {
          final queuedPings = await _apiQueueService.extractAllAsJson();
          if (queuedPings.isNotEmpty) {
            final offlineDeviceName = _isAnonymousRenamed
                ? _originalDeviceName
                : (_meshCoreConnection?.selfInfo?.name ??
                    connectedDeviceName?.replaceFirst('MeshCore-', ''));
            await _offlineSessionService.saveSession(
              queuedPings,
              devicePublicKey: _devicePublicKey,
              deviceName: offlineDeviceName,
              contactUri: _offlineContactUri,
              radioConfig: _meshCoreConnection?.selfInfo?.radioConfigApi,
            );
            debugLog(
                '[APP] Preserved ${queuedPings.length} queued pings to offline storage on session expiry');
          }
        } catch (e) {
          debugError('[APP] Failed to preserve queue to offline storage: $e');
        }
      }

      // Don't call requestAuth disconnect - session is already invalid on server
      // Just cleanup locally and disconnect
      await disconnect();
    }
  }

  /// Handle maintenance mode while connected - end session and log error
  Future<void> _handleMaintenanceModeConnected(
      String message, String? url) async {
    debugLog('[MAINTENANCE] Ending session due to maintenance mode');

    // Alert if auto-ping was running (maintenance is not user-initiated)
    if (_autoPingEnabled) {
      _playDisconnectAlert();
    }

    // Log to error log (this sets _requestErrorLogSwitch = true)
    logError('Maintenance Mode Enabled: $message',
        severity: ErrorSeverity.warning);

    // Disconnect (ends session, cleans up)
    await disconnect();

    // Update maintenance state for UI
    _maintenanceMode = true;
    _maintenanceMessage = message;
    _maintenanceUrl = url;

    // Start polling to detect when maintenance ends
    _startMaintenancePolling();

    notifyListeners();
  }

  /// Clear maintenance mode when API returns normal response
  void _clearMaintenanceMode() {
    if (_maintenanceMode) {
      debugLog('[MAINTENANCE] Mode cleared');
      _maintenanceMode = false;
      _maintenanceMessage = null;
      _maintenanceUrl = null;
      _stopMaintenancePolling();
      notifyListeners();
    }
  }

  /// Start periodic polling to check if maintenance mode has ended
  void _startMaintenancePolling() {
    _maintenanceCheckTimer?.cancel();
    _maintenanceCheckTimer =
        Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!_maintenanceMode) {
        _maintenanceCheckTimer?.cancel();
        _maintenanceCheckTimer = null;
        return;
      }
      debugLog('[MAINTENANCE] Polling to check if maintenance ended...');
      await checkZoneStatus();
    });
    debugLog('[MAINTENANCE] Started 30s polling for maintenance end');
  }

  /// Stop maintenance polling
  void _stopMaintenancePolling() {
    _maintenanceCheckTimer?.cancel();
    _maintenanceCheckTimer = null;
  }

  // ============================================
  // GPS Validation
  // ============================================

  /// Maximum age for GPS data in API calls (60 seconds)
  static const int _maxGpsAgeSeconds = 60;

  /// Maximum acceptable GPS accuracy for API calls (50 meters)
  static const double _maxGpsAccuracyMeters = 50.0;

  /// Validate GPS position for API calls
  /// Returns (isValid, errorMessage, errorCode) tuple
  ({bool isValid, String? errorMessage, String? errorCode}) _validateGps(
      Position? position) {
    if (position == null) {
      return (
        isValid: false,
        errorMessage: 'No GPS position available',
        errorCode: 'no_gps',
      );
    }

    // Check staleness
    final ageSeconds = DateTime.now().difference(position.timestamp).inSeconds;
    if (ageSeconds > _maxGpsAgeSeconds) {
      return (
        isValid: false,
        errorMessage:
            'GPS data is ${ageSeconds}s old (max ${_maxGpsAgeSeconds}s)',
        errorCode: 'gps_stale',
      );
    }

    // Check accuracy
    if (position.accuracy > _maxGpsAccuracyMeters) {
      return (
        isValid: false,
        errorMessage:
            'GPS accuracy is ${position.accuracy.toStringAsFixed(0)}m (max ${_maxGpsAccuracyMeters.toStringAsFixed(0)}m)',
        errorCode: 'gps_inaccurate',
      );
    }

    return (isValid: true, errorMessage: null, errorCode: null);
  }

  /// Check if current GPS position is valid for API calls
  bool get isGpsValidForApi {
    final validation = _validateGps(_currentPosition);
    return validation.isValid;
  }

  // ============================================
  // Zone Status (Pre-Flight Checks)
  // ============================================

  /// App version for API calls (uses AppConstants.appVersion as single source of truth)
  static String get _appVersion => AppConstants.appVersion;

  /// Zone check distance threshold (100 meters)
  static const double _zoneCheckDistanceThreshold = 100.0;

  /// Check if zone status should be re-checked based on GPS movement
  bool _shouldRecheckZone(Position position) {
    if (_lastZoneCheckPosition == null) return true;

    final distance = Geolocator.distanceBetween(
      _lastZoneCheckPosition!.latitude,
      _lastZoneCheckPosition!.longitude,
      position.latitude,
      position.longitude,
    );

    return distance >= _zoneCheckDistanceThreshold;
  }

  /// Schedule a zone check retry with countdown timer for UI feedback
  void _scheduleZoneCheckRetry(
      {required int seconds, required String error, required String reason}) {
    // Cancel any existing timers
    _zoneCheckRetryTimer?.cancel();
    _zoneCheckCountdownTimer?.cancel();

    _zoneCheckError = error;
    _zoneCheckErrorReason = reason;
    _zoneCheckRetryCountdown = seconds;
    notifyListeners();

    // Single timer: ticks every 1s, retries at 0
    _zoneCheckCountdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _zoneCheckRetryCountdown--;
      notifyListeners();
      if (_zoneCheckRetryCountdown <= 0) {
        // Cancel timers but keep error message visible during retry
        _zoneCheckCountdownTimer?.cancel();
        _zoneCheckCountdownTimer = null;
        _zoneCheckRetryTimer?.cancel();
        _zoneCheckRetryTimer = null;
        checkZoneStatus();
      }
    });
  }

  /// Clear zone check error state and cancel retry timers
  void _clearZoneCheckError() {
    _zoneCheckRetryTimer?.cancel();
    _zoneCheckCountdownTimer?.cancel();
    _zoneCheckRetryTimer = null;
    _zoneCheckCountdownTimer = null;
    _zoneCheckError = null;
    _zoneCheckErrorReason = null;
    _zoneCheckRetryCountdown = 0;
    // Don't notifyListeners here — caller will do it or checkZoneStatus will
  }

  /// Check zone status via API
  /// Should be called on app launch and every 100m of GPS movement while disconnected
  Future<void> checkZoneStatus() async {
    debugLog('[GEOFENCE] checkZoneStatus() called');
    debugLog(
        '[GEOFENCE] Pre-check state: inZone=$_inZone, isCheckingZone=$_isCheckingZone, '
        'hasPosition=${_currentPosition != null}, gpsStatus=$_gpsStatus');

    if (_currentPosition == null) {
      debugLog(
          '[GEOFENCE] Cannot check zone status: no GPS position (gpsStatus=$_gpsStatus)');
      return;
    }

    if (_preferences.offlineMode) {
      debugLog('[GEOFENCE] Skipping zone check: offline mode enabled');
      return;
    }

    if (_isCheckingZone) {
      debugLog(
          '[GEOFENCE] Zone check already in progress, skipping duplicate call');
      return;
    }

    debugLog(
        '[GEOFENCE] Starting zone check - setting isCheckingZone=true (previous inZone=$_inZone)');
    _isCheckingZone = true;
    // Don't clear error or notify here — keep current error view visible during retry
    // to avoid a full-screen flash. Error is cleared in finally block on success,
    // or overwritten by _scheduleZoneCheckRetry on failure.

    try {
      debugLog(
          '[GEOFENCE] Making API call to check zone at ${_currentPosition!.latitude.toStringAsFixed(5)}, '
          '${_currentPosition!.longitude.toStringAsFixed(5)} (accuracy: ${_currentPosition!.accuracy.toStringAsFixed(1)}m)');

      final result = await _apiService.checkZoneStatus(
        lat: _currentPosition!.latitude,
        lon: _currentPosition!.longitude,
        accuracyMeters: _currentPosition!.accuracy,
        appVersion: _appVersion,
      );

      debugLog(
          '[GEOFENCE] API response received: ${result != null ? 'valid' : 'null'}');

      if (result == null) {
        // Update position even on failure to prevent zone check flooding
        // (without this, every GPS update re-triggers a zone check while driving)
        _lastZoneCheckPosition = _currentPosition;
        debugError('[GEOFENCE] Zone status check failed: no response from API');
        _scheduleZoneCheckRetry(
          seconds: 5,
          error: 'Verify your internet connection',
          reason: 'network',
        );
        return;
      }

      // Got a real response — clear any previous retry error state
      _clearZoneCheckError();

      // Check for maintenance mode FIRST
      if (result['maintenance'] == true) {
        _maintenanceMode = true;
        _maintenanceMessage = result['maintenance_message'] as String?;
        _maintenanceUrl = result['maintenance_url'] as String?;
        debugLog(
            '[MAINTENANCE] Zone check returned maintenance: $_maintenanceMessage');

        // Start polling to detect when maintenance ends
        _startMaintenancePolling();

        notifyListeners();
        return; // Don't process zone data
      }

      // Clear maintenance if normal response
      _clearMaintenanceMode();

      _lastZoneCheckPosition = _currentPosition;

      final success = result['success'] == true;
      if (!success) {
        final reason = result['reason'] as String?;
        final message =
            result['message'] as String? ?? 'Zone status check failed';
        debugError(
            '[GEOFENCE] Zone status check failed: reason=$reason, message=$message');

        if (reason == 'gps_inaccurate') {
          logError('GPS Accuracy Error\n$message', autoSwitch: false);
          // Schedule a retry so we don't depend solely on the GPS stream firing
          // again — on first launch the stream may stall on a low-accuracy fix
          // and the coverage tile overlay would never load.
          _scheduleZoneCheckRetry(
              seconds: 10, error: message, reason: 'gps_inaccurate');
        } else if (reason == 'gps_stale') {
          logError('GPS Stale Error\n$message', autoSwitch: false);
          _scheduleZoneCheckRetry(
              seconds: 10, error: message, reason: 'gps_stale');
        } else if (reason == 'zone_disabled') {
          final errorMsg = _getErrorMessage(reason, message);
          logError(errorMsg);
          _scheduleZoneCheckRetry(
              seconds: 30, error: errorMsg, reason: reason!);
        } else if (reason == 'bad_key' || reason == 'invalid_request') {
          final errorMsg = _getErrorMessage(reason, message);
          logError(errorMsg);
          _scheduleZoneCheckRetry(
              seconds: 60, error: errorMsg, reason: reason!);
        } else {
          // Unknown server errors — use server message
          _scheduleZoneCheckRetry(
              seconds: 15, error: message, reason: 'server_error');
        }

        return;
      }

      _inZone = result['in_zone'] == true;

      if (_inZone!) {
        final newZone = result['zone'] as Map<String, dynamic>?;
        final newZoneCode = newZone?['code'] as String? ?? '';
        final newZoneName = newZone?['name'] ?? 'Unknown';

        // Detect zone-to-zone transition during active session
        if (isConnected &&
            !_preferences.offlineMode &&
            _sessionZoneCode != null &&
            newZoneCode.isNotEmpty &&
            newZoneCode != _sessionZoneCode &&
            !_isInZoneGracePeriod &&
            !_isZoneTransferInProgress) {
          _currentZone = newZone;
          _nearestZone = null;
          await _handleZoneTransfer(newZoneCode, newZoneName);
          return;
        }

        _currentZone = newZone;
        _nearestZone = null;

        final staleHours = result['stale_repeater_hours'];
        if (staleHours is int && staleHours > 0) {
          Repeater.staleHoursFallback = staleHours;
          debugLog('[GEOFENCE] Zone stale repeater threshold: ${staleHours}h');
        }

        debugLog('[GEOFENCE] In zone: $newZoneName ($newZoneCode)');

        if (newZoneCode.isNotEmpty) {
          _fetchRepeatersForZone(
              newZoneCode); // fire-and-forget — don't block zone check
          _fetchBorderPolygons(newZoneCode); // fire-and-forget
        }
      } else {
        _regionBorders = [];
        _bordersLoadedForZone = null;
        _currentZone = null;
        _nearestZone = result['nearest_zone'] as Map<String, dynamic>?;
        final nearestName = _nearestZone?['name'] ?? 'Unknown';
        final distanceKm =
            (_nearestZone?['distance_km'] as num?)?.toStringAsFixed(1) ?? '?';
        debugWarn(
            '[GEOFENCE] Outside zone. Nearest: $nearestName (${distanceKm}km away)');

        // Clear repeaters when exiting zone
        _repeaters = [];
        _repeatersLoaded = false;
        _repeatersLoadedForIata = null;
      }
    } catch (e) {
      debugError('[GEOFENCE] Zone status check error: $e');
    } finally {
      _isCheckingZone = false;
      debugLog(
          '[GEOFENCE] Zone check complete - final state: inZone=$_inZone, isCheckingZone=$_isCheckingZone, '
          'zoneName=${_currentZone?['name']}, zoneCode=${_currentZone?['code']}');
      notifyListeners();
    }
  }

  /// Sync zone capacity display with auth result.
  /// The /status API (pre-connection) and /auth API (during connection) can
  /// return different capacity views. This keeps the connection screen's slot
  /// display consistent with the map tab's txAllowed flag.
  void _syncZoneCapacityFromAuth(Map<String, dynamic> authResult) {
    if (_currentZone == null) return;

    // If auth response includes slot data, use it directly (forward-compatible)
    if (authResult.containsKey('slots_available')) {
      _currentZone!['slots_available'] = authResult['slots_available'];
      debugLog(
          '[CAPACITY] Updated slots_available from auth: ${authResult['slots_available']}');
    }
    if (authResult.containsKey('slots_max')) {
      _currentZone!['slots_max'] = authResult['slots_max'];
      debugLog(
          '[CAPACITY] Updated slots_max from auth: ${authResult['slots_max']}');
    }

    // Sync at_capacity with tx_allowed
    final authTxAllowed = authResult['tx_allowed'] == true;
    _currentZone!['at_capacity'] = !authTxAllowed;

    // If auth says TX not allowed and server didn't provide slot data, set slots to 0
    if (!authTxAllowed && !authResult.containsKey('slots_available')) {
      _currentZone!['slots_available'] = 0;
      debugLog(
          '[CAPACITY] Zone at TX capacity per auth, set slots_available=0');
    }

    // If auth says TX allowed and we have slot data but server didn't provide updated count,
    // decrement by 1 (we just took a slot)
    if (authTxAllowed && !authResult.containsKey('slots_available')) {
      final available = _currentZone!['slots_available'] as int?;
      if (available != null && available > 0) {
        _currentZone!['slots_available'] = available - 1;
        debugLog('[CAPACITY] Took a slot, slots_available=${available - 1}');
      }
    }

    notifyListeners();
  }

  /// Start periodic zone status refresh while connected.
  /// Keeps slot counts and capacity status fresh during a session.
  void _startZoneRefreshTimer() {
    _zoneRefreshTimer?.cancel();
    _zoneRefreshTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (!isConnected || _preferences.offlineMode) {
        _zoneRefreshTimer?.cancel();
        _zoneRefreshTimer = null;
        return;
      }
      debugLog('[CAPACITY] Periodic zone refresh');
      await checkZoneStatus();
    });
    debugLog('[CAPACITY] Started 60s zone refresh timer');
  }

  /// Stop zone status refresh timer.
  void _stopZoneRefreshTimer() {
    _zoneRefreshTimer?.cancel();
    _zoneRefreshTimer = null;
  }

  // ============================================
  // Zone Grace Period
  // ============================================

  /// Cancel all zone grace period timers.
  void _cancelZoneGraceTimers() {
    _zoneGraceEndsAt = null;
    _zoneGraceTimer?.cancel();
    _zoneGraceTimer = null;
    _zoneGracePollingTimer?.cancel();
    _zoneGracePollingTimer = null;
    _zoneGraceCountdownTimer?.cancel();
    _zoneGraceCountdownTimer = null;
  }

  /// Enter zone grace period when outside_zone is detected during an active session.
  /// Pauses wardriving but keeps BLE and API session alive.
  /// Polls for zone re-entry every 5s; auto-disconnects after 5 minutes.
  Future<void> _startZoneGracePeriod() async {
    if (_isInZoneGracePeriod) return;
    _isInZoneGracePeriod = true;
    debugLog(
        '[ZONE GRACE] Entering zone grace period (${_zoneGraceTimeout.inMinutes}m timeout)');
    logError('Left wardriving zone. Searching for nearby zone...',
        severity: ErrorSeverity.warning, autoSwitch: false);

    // Save auto-ping state for restoration on zone re-entry
    _autoPingWasEnabledBeforeGrace = _autoPingEnabled;
    _autoModeBeforeGrace = _autoMode;

    // Stop auto-ping timers and disable
    _autoPingTimer.stop();
    _rxWindowTimer.stop();
    _cooldownTimer.stop();
    if (_autoPingEnabled) {
      _autoPingEnabled = false;
      _idleAutoStopReference = null;
      await _pingService?.forceDisableAutoPing();
      debugLog('[ZONE GRACE] Auto-ping paused');
    }

    // Disable heartbeat (no point while outside zone)
    _apiService.disableHeartbeat();

    // Stop RX logger (no session context for RX data)
    _rxLogger?.stopWardriving(trigger: 'zone_grace');

    // Stop zone refresh timer (replaced by 5s grace polling)
    _stopZoneRefreshTimer();

    // Cancel idle disconnect timer
    _cancelIdleDisconnectTimer();

    // Stop background service
    await BackgroundServiceManager.stopService();

    // Clear API queue — items have gap-GPS coords that would be rejected again
    await _apiQueueService.clearOnDisconnect();

    // Keep alive: BLE, _meshCoreConnection, _pingService, _unifiedRxHandler,
    // noise floor, and API session (backend auto-transfers on zone re-entry)

    // Start 5-minute countdown. Keep an absolute deadline so ActivityKit can
    // render the timer without receiving an update every second.
    _zoneGraceEndsAt = DateTime.now().add(_zoneGraceTimeout);
    _zoneGraceSecondsRemaining = _zoneGraceTimeout.inSeconds;

    // Overall timeout — abandon grace period after 5 minutes
    _zoneGraceTimer = Timer(_zoneGraceTimeout, () {
      debugLog('[ZONE GRACE] Timeout expired — abandoning');
      _abandonZoneGracePeriod();
    });

    // 1-second countdown tick for UI
    _zoneGraceCountdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_zoneGraceSecondsRemaining > 0) {
        _zoneGraceSecondsRemaining--;
        notifyListeners();
      }
    });

    // Trigger immediate zone check, then start 5-second polling
    _pollZoneDuringGracePeriod();
    _zoneGracePollingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _pollZoneDuringGracePeriod();
    });

    notifyListeners();
  }

  /// Poll zone status during grace period (called every 5s).
  Future<void> _pollZoneDuringGracePeriod() async {
    if (!_isInZoneGracePeriod) {
      _zoneGracePollingTimer?.cancel();
      _zoneGracePollingTimer = null;
      return;
    }

    debugLog('[ZONE GRACE] Polling zone status...');
    try {
      await checkZoneStatus();
    } catch (e) {
      debugWarn('[ZONE GRACE] Zone check failed: $e');
      return; // Retry on next tick
    }

    // checkZoneStatus updates _inZone and calls notifyListeners (overlay auto-updates)
    if (_inZone == true) {
      final reEnteredZoneCode = _currentZone?['code'] as String? ?? '';
      debugLog(
          '[ZONE GRACE] Zone re-entered: ${_currentZone?['name']} ($reEnteredZoneCode)');

      // If re-entering a DIFFERENT zone, do a full zone transfer instead of simple resume
      if (_sessionZoneCode != null &&
          reEnteredZoneCode.isNotEmpty &&
          reEnteredZoneCode != _sessionZoneCode) {
        debugLog(
            '[ZONE GRACE] Re-entered different zone ($reEnteredZoneCode vs session $_sessionZoneCode) — transferring');
        _cancelZoneGraceTimers();
        _isInZoneGracePeriod = false;
        _zoneGraceSecondsRemaining = 0;
        final savedAutoPing = _autoPingWasEnabledBeforeGrace;
        final savedMode = _autoModeBeforeGrace;
        _autoPingWasEnabledBeforeGrace = false;
        await _handleZoneTransfer(
            reEnteredZoneCode, _currentZone?['name'] ?? 'Unknown',
            wasAutoPingOverride: savedAutoPing,
            previousModeOverride: savedMode);
        return;
      }

      await _onZoneGraceReEntry();
    }
  }

  /// Zone re-entered during grace period — resume wardriving.
  /// Session is preserved; backend auto-transfers to the new zone.
  Future<void> _onZoneGraceReEntry() async {
    _cancelZoneGraceTimers();

    final wasAutoPing = _autoPingWasEnabledBeforeGrace;
    final previousMode = _autoModeBeforeGrace;

    // Clear grace state
    _isInZoneGracePeriod = false;
    _zoneGraceSecondsRemaining = 0;
    _autoPingWasEnabledBeforeGrace = false;

    debugLog(
        '[ZONE GRACE] Resuming wardriving (autoPing=$wasAutoPing, mode=$previousMode)');
    logError('Re-entered wardriving zone. Resuming...',
        severity: ErrorSeverity.info, autoSwitch: false);

    // Re-enable heartbeat
    _apiService.enableHeartbeat(
      gpsProvider: () {
        final pos = _gpsService.lastPosition;
        if (pos == null) return null;
        return (lat: pos.latitude, lon: pos.longitude);
      },
    );

    // Restart zone refresh timer (60s)
    _startZoneRefreshTimer();

    // Prepare API queue for fresh data
    await _apiQueueService.clearBeforeConnect();

    // Restore auto-ping if it was active
    if (wasAutoPing) {
      _restoreAutoPingTimer?.cancel();
      _restoreAutoPingTimer = Timer(const Duration(milliseconds: 500), () {
        _restoreAutoPingTimer = null;
        if (_isDisposed ||
            _userRequestedDisconnect ||
            _connectionStep != ConnectionStep.connected ||
            _pingService == null) {
          debugLog(
              '[ZONE GRACE] Skipping auto-ping restore (stale or disconnected state)');
          return;
        }
        if (!_autoPingEnabled) {
          _cooldownTimer.stop();
          _pingService!.clearCooldown();
          final resolvedMode = _resolveAutoModeForZone(previousMode);
          debugLog(
              '[ZONE GRACE] Mode resolved: $previousMode → $resolvedMode');
          toggleAutoPing(resolvedMode);
        }
      });
    } else {
      _startIdleDisconnectTimer();
    }

    notifyListeners();
  }

  /// Abandon zone grace period — timeout, failure, or BLE disconnect.
  Future<void> _abandonZoneGracePeriod() async {
    _cancelZoneGraceTimers();

    if (_autoPingWasEnabledBeforeGrace) {
      _playDisconnectAlert();
    }

    // Clear grace state
    _isInZoneGracePeriod = false;
    _zoneGraceSecondsRemaining = 0;
    _autoPingWasEnabledBeforeGrace = false;

    debugLog('[ZONE GRACE] Abandoned — performing full disconnect');

    // Full disconnect cleanup
    await disconnect();
  }

  /// Cancel zone grace period (user-triggered from UI cancel button).
  Future<void> cancelZoneGracePeriod() async {
    debugLog('[ZONE GRACE] Cancelled by user');
    await _abandonZoneGracePeriod();
  }

  /// Resolve the desired auto-ping mode against the current zone's permissions.
  /// Maps invalid modes to the best valid alternative for the new zone.
  AutoMode _resolveAutoModeForZone(AutoMode desired) {
    final txOk = _apiService.txAllowed;
    final rxOk = _apiService.rxAllowed;
    final hybrid = _apiService.enforceHybrid;

    // No TX allowed → passive only
    if (!txOk && rxOk) return AutoMode.passive;

    // TX allowed but zone enforces hybrid → map active to hybrid
    if (txOk && hybrid && desired == AutoMode.active) return AutoMode.hybrid;

    // TX allowed, zone doesn't enforce hybrid → map hybrid back to active
    // (unless user explicitly chose hybrid via _userOriginalHybridMode)
    if (txOk && !hybrid && desired == AutoMode.hybrid) {
      if (_userOriginalHybridMode != true) return AutoMode.active;
    }

    // Targeted/trace mode is transport-level, not channel TX — keep as-is
    return desired;
  }

  // ============================================
  // Zone-to-Zone Transfer
  // ============================================

  /// Handle zone-to-zone transfer during active wardriving session.
  /// Releases old zone session and acquires new session for target zone.
  /// Preserves BLE connection and radio configuration.
  Future<void> _handleZoneTransfer(
      String newZoneCode, String newZoneName,
      {bool? wasAutoPingOverride, AutoMode? previousModeOverride}) async {
    if (_isZoneTransferInProgress) {
      debugLog('[ZONE] Transfer already in progress, skipping');
      return;
    }

    final oldZoneCode = _sessionZoneCode ?? 'unknown';
    _isZoneTransferInProgress = true;
    _zoneTransferFrom = oldZoneCode;
    _zoneTransferTo = newZoneCode;
    debugLog('[ZONE] Starting zone transfer: $oldZoneCode → $newZoneCode');
    notifyListeners();

    try {
      // 1. Save auto-ping state for restoration
      // Prefer overrides from grace period (where provider state was already cleared)
      final wasAutoPing = wasAutoPingOverride ?? _autoPingEnabled;
      final previousMode = previousModeOverride ?? _autoMode;

      // 2. Pause auto-ping and wardriving activity
      _autoPingTimer.stop();
      _rxWindowTimer.stop();
      _cooldownTimer.stop();
      if (_autoPingEnabled) {
        _autoPingEnabled = false;
        _idleAutoStopReference = null;
        await _pingService?.forceDisableAutoPing();
        debugLog('[ZONE] Auto-ping paused for zone transfer');
      }

      // 3. Disable heartbeat (old session is about to be released)
      _apiService.disableHeartbeat();

      // 4. Stop RX logger (no valid session context during transfer)
      _rxLogger?.stopWardriving(trigger: 'zone_transfer');

      // 5. Stop zone refresh timer (we're handling the zone change now)
      _stopZoneRefreshTimer();

      // 6. Cancel idle disconnect timer
      _cancelIdleDisconnectTimer();

      // 7. Clear API queue (items were created for old zone's session)
      await _apiQueueService.clearOnDisconnect();

      // 8. Release old session (best effort)
      if (_devicePublicKey != null && _apiService.hasSession) {
        debugLog('[ZONE] Releasing old session for zone $oldZoneCode');
        try {
          await _apiService.requestAuth(
            reason: 'disconnect',
            publicKey: _devicePublicKey!,
          );
          debugLog('[ZONE] Old session released');
        } catch (e) {
          debugError('[ZONE] Failed to release old session: $e');
        }
      }

      // 9. Acquire new session for target zone
      final deviceName = _isAnonymousRenamed
          ? 'Anonymous'
          : (_meshCoreConnection?.selfInfo?.name ??
              connectedDeviceName?.replaceFirst('MeshCore-', ''));

      if (_devicePublicKey == null ||
          deviceName == null ||
          _currentPosition == null) {
        debugError('[ZONE] Cannot transfer: missing device key, name, or GPS');
        await disconnect();
        return;
      }

      debugLog('[ZONE] Requesting auth for zone $newZoneCode');
      final modelString = _meshCoreConnection?.deviceModel?.manufacturer ??
          _meshCoreConnection?.deviceInfo?.manufacturer ??
          'Unknown';
      var result = await _apiService.requestAuth(
        reason: 'connect',
        publicKey: _devicePublicKey!,
        who: deviceName,
        appVersion: _appVersion,
        power: _preferences.powerLevel,
        iataCode: newZoneCode,
        model: modelString,
        radioFreq: _meshCoreConnection?.selfInfo?.radioConfigApi,
        lat: _currentPosition!.latitude,
        lon: _currentPosition!.longitude,
        accuracyMeters: _currentPosition!.accuracy,
      );

      // 10. Check auth result
      if (result == null) {
        debugError('[ZONE] Auth failed for zone $newZoneCode: network error');
        logError('Zone transfer failed: unable to reach server',
            severity: ErrorSeverity.error);
        await disconnect();
        return;
      }

      if (result['maintenance'] == true) {
        _maintenanceMode = true;
        _maintenanceMessage = result['maintenance_message'] as String?;
        _maintenanceUrl = result['maintenance_url'] as String?;
        _startMaintenancePolling();
        notifyListeners();
        await disconnect();
        return;
      }

      if (result['success'] != true) {
        final reason = result['reason'] as String? ?? 'unknown';
        final message = result['message'] as String? ?? 'Auth failed';
        debugError(
            '[ZONE] Auth failed for zone $newZoneCode: $reason - $message');

        // Stage 2: unknown_device → register via signed contact URI (mirrors initial connect)
        if (reason == 'unknown_device' && _meshCoreConnection != null) {
          debugLog(
              '[ZONE] Stage 2: Attempting registration via contact_uri for zone $newZoneCode');

          String? contactUri;
          try {
            contactUri = await _meshCoreConnection!.exportContact();
            debugLog(
                '[ZONE] Received contact URI: ${contactUri.substring(0, contactUri.length < 50 ? contactUri.length : 50)}...');
          } catch (e) {
            debugError('[ZONE] Stage 2 failed: could not export contact: $e');
            logError('Zone transfer failed: $message',
                severity: ErrorSeverity.error);
            await disconnect();
            return;
          }

          final registerResult = await _apiService.requestAuth(
            reason: 'register',
            contactUri: contactUri,
            who: deviceName,
            appVersion: _appVersion,
            power: _preferences.powerLevel,
            iataCode: newZoneCode,
            model: modelString,
            radioFreq: _meshCoreConnection?.selfInfo?.radioConfigApi,
            lat: _currentPosition!.latitude,
            lon: _currentPosition!.longitude,
            accuracyMeters: _currentPosition!.accuracy,
          );

          if (registerResult == null) {
            debugError('[ZONE] Stage 2 failed: network error');
            logError('Zone transfer failed: unable to register with server',
                severity: ErrorSeverity.error);
            await disconnect();
            return;
          }

          if (registerResult['success'] != true) {
            final regReason =
                registerResult['reason'] as String? ?? 'registration_failed';
            final regMessage = registerResult['message'] as String? ??
                'Registration rejected by server';
            debugError('[ZONE] Stage 2 failed: $regReason - $regMessage');
            logError('Zone transfer failed: $regMessage',
                severity: ErrorSeverity.error);
            await disconnect();
            return;
          }

          debugLog(
              '[ZONE] Stage 2 succeeded: registered for zone $newZoneCode');
          result = registerResult;
        } else {
          logError('Zone transfer failed: $message',
              severity: ErrorSeverity.error);
          await disconnect();
          return;
        }
      }

      // 11. Auth succeeded — update session zone code
      _sessionZoneCode = newZoneCode;
      debugLog('[ZONE] Auth succeeded for zone $newZoneCode');

      if (result['type'] != null) {
        _authType = result['type'] as String;
      }

      _syncZoneCapacityFromAuth(result);

      // 12. Update regional channels from new auth response
      final apiChannels = _apiService.channels;
      await ChannelService.setRegionalChannels(apiChannels);
      _regionalChannels = ChannelService.getRegionalChannelNames();
      debugLog('[ZONE] Regional channels updated: $_regionalChannels');

      // 13. Update PacketValidator with new channel configuration
      if (_unifiedRxHandler != null) {
        final allowedChannelsData =
            ChannelService.getAllowedChannelsForValidator();
        final allowedChannels = <int, ChannelInfo>{};
        for (final entry in allowedChannelsData.entries) {
          allowedChannels[entry.key] = ChannelInfo(
            channelName: entry.value.channelName,
            key: entry.value.key,
            hash: entry.value.hash,
          );
        }
        final newValidator = PacketValidator(
          allowedChannels: allowedChannels,
          disableRssiFilter: _preferences.disableRssiFilter,
        );
        _unifiedRxHandler!.updateValidator(newValidator);
        debugLog(
            '[ZONE] PacketValidator updated with ${allowedChannels.length} channels');
      }

      // 14. Update flood scope from new auth response
      final apiScopes = _apiService.scopes;
      final firstScope = apiScopes.isNotEmpty ? apiScopes.first : null;
      final isWildcard =
          firstScope == null || firstScope == '*' || firstScope == '#*';
      if (!isWildcard) {
        final scopeName = firstScope;
        _scope = scopeName.startsWith('#') ? scopeName : '#$scopeName';
        final scopeKey = CryptoService.deriveScopeKey(scopeName);
        debugLog('[ZONE] Setting flood scope: $scopeName');
        await _meshCoreConnection!.setFloodScope(scopeKey);
      } else {
        if (_scope != null) {
          try {
            await _meshCoreConnection?.clearFloodScope();
          } catch (e) {
            debugLog('[ZONE] Failed to clear flood scope: $e');
          }
        }
        _scope = null;
        debugLog('[ZONE] No regional scope — using unscoped flood');
      }

      // 15. Restore user's original preferences, then apply new zone's policies
      if (_userOriginalAutoPingInterval != null) {
        _preferences = _preferences.copyWith(
            autoPingInterval: _userOriginalAutoPingInterval!);
      }
      if (_userOriginalHybridMode != null) {
        _preferences =
            _preferences.copyWith(hybridModeEnabled: _userOriginalHybridMode!);
      }
      if (_userOriginalDiscDrop != null) {
        _preferences =
            _preferences.copyWith(discDropEnabled: _userOriginalDiscDrop!);
      }
      if (_userOriginalFloodTraffic != null) {
        _preferences =
            _preferences.copyWith(floodTrafficEnabled: _userOriginalFloodTraffic!);
      }
      debugLog(
          '[ZONE] Preferences restored to user baseline before applying new zone policies');

      if (_apiService.enforceHybrid && !_preferences.hybridModeEnabled) {
        _preferences = _preferences.copyWith(hybridModeEnabled: true);
        debugLog('[ZONE] Hybrid mode force-enabled by new zone admin');
      }
      if (_apiService.enforceDiscDrop && !_preferences.discDropEnabled) {
        _preferences = _preferences.copyWith(discDropEnabled: true);
        debugLog('[ZONE] Discovery drop force-enabled by new zone admin');
      }
      final wasFloodEnabledByUser = _preferences.floodTrafficEnabled;
      final shouldEnableFlood = !_apiService.floodDisabled;
      if (_preferences.floodTrafficEnabled != shouldEnableFlood) {
        _preferences =
            _preferences.copyWith(floodTrafficEnabled: shouldEnableFlood);
        debugLog(shouldEnableFlood
            ? '[ZONE] Flood traffic auto-enabled (new zone permits)'
            : '[ZONE] Flood traffic disabled by new zone admin');
      }
      if (wasFloodEnabledByUser && _apiService.floodDisabled) {
        _floodDisabledAlertPending = true;
      }
      if (_preferences.autoPingInterval < _apiService.minModeInterval) {
        _preferences = _preferences.copyWith(
            autoPingInterval: _apiService.minModeInterval);
        debugLog(
            '[ZONE] Auto-ping interval bumped to ${_apiService.minModeInterval}s by new zone admin');
      }

      // 16. Reconfigure path hash mode if new zone requires different hop bytes
      await _configurePathHashMode();
      if (_pingService != null) {
        _pingService!.hopBytes = effectiveHopBytes;
        _pingService!.traceHopBytes = _traceHopBytes;
      }

      // 17. Fetch repeaters for the new zone
      _repeatersLoaded = false;
      _repeatersLoadedForIata = null;
      await _fetchRepeatersForZone(newZoneCode);

      // Fetch updated boundary polygons for the new zone
      _bordersLoadedForZone = null;
      _regionBorders = [];
      _fetchBorderPolygons(newZoneCode); // fire-and-forget

      // 18. Re-enable heartbeat
      _apiService.enableHeartbeat(
        gpsProvider: () {
          final pos = _gpsService.lastPosition;
          if (pos == null) return null;
          return (lat: pos.latitude, lon: pos.longitude);
        },
      );

      // 19. Restart zone refresh timer
      _startZoneRefreshTimer();

      // 20. Prepare API queue for fresh data in new zone
      await _apiQueueService.clearBeforeConnect();

      // 21. Restore auto-ping if it was active
      if (wasAutoPing) {
        _restoreAutoPingTimer?.cancel();
        _restoreAutoPingTimer = Timer(const Duration(milliseconds: 500), () {
          _restoreAutoPingTimer = null;
          if (_isDisposed ||
              _userRequestedDisconnect ||
              _connectionStep != ConnectionStep.connected ||
              _pingService == null) {
            debugLog(
                '[ZONE] Skipping auto-ping restore (stale or disconnected state)');
            return;
          }
          if (!_autoPingEnabled) {
            _cooldownTimer.stop();
            _pingService!.clearCooldown();
            final resolvedMode = _resolveAutoModeForZone(previousMode);
            debugLog(
                '[ZONE] Mode resolved for new zone: $previousMode → $resolvedMode');
            toggleAutoPing(resolvedMode);
          }
        });
      } else {
        _startIdleDisconnectTimer();
      }

      debugLog('[ZONE] Zone transfer complete: $oldZoneCode → $newZoneCode');
    } catch (e) {
      debugError('[ZONE] Zone transfer error: $e');
      logError('Zone transfer failed: $e', severity: ErrorSeverity.error);
      await disconnect();
    } finally {
      _isZoneTransferInProgress = false;
      _zoneTransferFrom = null;
      _zoneTransferTo = null;
      notifyListeners();
    }
  }

  /// Cancel zone transfer (user-triggered from UI cancel button).
  Future<void> cancelZoneTransfer() async {
    debugLog('[ZONE] Zone transfer cancelled by user');
    _isZoneTransferInProgress = false;
    _zoneTransferFrom = null;
    _zoneTransferTo = null;
    await disconnect();
  }

  /// Fetch repeaters for a zone (called when zone is discovered)
  /// Only fetches once per IATA code to avoid redundant network requests
  Future<void> _fetchRepeatersForZone(String iata) async {
    // Skip if already loaded for this IATA
    if (_repeatersLoaded && _repeatersLoadedForIata == iata) {
      debugLog('[MAP] Repeaters already loaded for zone: $iata');
      return;
    }

    debugLog('[MAP] Fetching repeaters for zone: $iata');
    try {
      final fetchedRepeaters = await _apiService.fetchRepeaters(iata);
      if (fetchedRepeaters.isNotEmpty) {
        _repeaters = fetchedRepeaters;
        _repeatersLoaded = true;
        _repeatersLoadedForIata = iata;
        debugLog('[MAP] Loaded ${_repeaters.length} repeaters for zone $iata');
        _notifyMapNow();
      } else {
        debugWarn(
            '[MAP] No repeaters returned for zone $iata — will retry on next zone check');
      }
    } catch (e) {
      debugError('[MAP] Failed to fetch repeaters: $e');
    }
  }

  /// Fetch regional boundary polygons for the current zone.
  /// Called after a successful zone check; idempotent per IATA so the
  /// /border endpoint is only hit once per zone transition.
  Future<void> _fetchBorderPolygons(String iata) async {
    if (_bordersLoadedForZone == iata) return;
    if (_bordersFetchInProgress) return;
    if (_currentPosition == null) return;

    _bordersFetchInProgress = true;
    try {
      final result = await _apiService.fetchBorderPolygons(
        lat: _currentPosition!.latitude,
        lon: _currentPosition!.longitude,
        appVersion: _appVersion,
      );
      if (result != null && result.isNotEmpty) {
        _regionBorders = result;
        _bordersLoadedForZone = iata;
        debugLog('[BORDER] Loaded ${result.length} polygon(s) for $iata');
        notifyListeners();
      } else {
        debugWarn(
            '[BORDER] No polygons returned for zone $iata — will retry on next zone check');
      }
    } finally {
      _bordersFetchInProgress = false;
    }
  }

  // ============================================
  // Debug File Logging (Mobile Only)
  // ============================================

  /// Initialize debug file logging, respecting persisted user preference.
  /// Enabled by default on all builds. If the user previously disabled it,
  /// that preference is restored.
  Future<void> _initDebugLogs() async {
    if (kIsWeb) return; // File logging not available on web

    try {
      final box = await _openBoxSafely(_preferencesBoxName);
      if (box == null) {
        // Can't read preference — keep default (enabled, already started in main.dart)
        _debugLogsEnabled = true;
        await _refreshDebugLogFiles();
        return;
      }

      final userDisabled = box.get('debug_logs_enabled') == false;

      if (userDisabled) {
        debugLog('[INIT] Debug logs disabled by user preference, turning off');
        await DebugFileLogger.disable();
        _debugLogsEnabled = false;
        DebugLogger.setEnabled(false);
      } else {
        debugLog('[INIT] Debug logging enabled (${AppConstants.appVersion})');
        // DebugFileLogger already enabled in main.dart
        _debugLogsEnabled = true;
        await _refreshDebugLogFiles();
      }
    } catch (e) {
      debugError('[INIT] Failed to init debug logs: $e');
      // Fallback: keep enabled (already started in main.dart)
      _debugLogsEnabled = true;
    }
  }

  /// Enable debug file logging
  ///
  /// Creates a new log file and starts writing debug output to it.
  /// Also enables console debug logging via DebugLogger.
  Future<void> enableDebugLogs() async {
    if (_debugLogsEnabled) return;

    debugLog('[DEBUG] Enabling debug file logging');
    try {
      await DebugFileLogger.enable();
      _debugLogsEnabled = true;
      DebugLogger.setEnabled(true);
      await _refreshDebugLogFiles();
      // Persist user preference
      final box = await _openBoxSafely(_preferencesBoxName);
      await box?.put('debug_logs_enabled', true);
      notifyListeners();
      debugLog('[DEBUG] Debug file logging enabled');
    } catch (e) {
      debugError('[DEBUG] Failed to enable debug file logging: $e');
    }
  }

  /// Disable debug file logging
  ///
  /// Closes the current log file but does NOT delete it.
  /// Disables console debug logging via DebugLogger.
  Future<void> disableDebugLogs() async {
    if (!_debugLogsEnabled) return;

    debugLog('[DEBUG] Disabling debug file logging');
    try {
      await DebugFileLogger.disable();
      _debugLogsEnabled = false;
      DebugLogger.setEnabled(false);
      // Persist user preference
      final box = await _openBoxSafely(_preferencesBoxName);
      await box?.put('debug_logs_enabled', false);
      notifyListeners();
    } catch (e) {
      debugError('[DEBUG] Failed to disable debug file logging: $e');
    }
  }

  /// Refresh the list of debug log files
  ///
  /// Called after enabling logging or deleting files to update the UI.
  Future<void> _refreshDebugLogFiles() async {
    try {
      _debugLogFiles = await DebugFileLogger.listLogFiles();
      notifyListeners();
    } catch (e) {
      debugError('[DEBUG] Failed to refresh debug log files: $e');
    }
  }

  /// Prepare debug logs for upload by rotating the current log file
  ///
  /// This ensures the files being uploaded are complete and not actively being written to.
  /// Returns the list of files that are safe to upload (excludes the new current log).
  Future<List<File>> prepareDebugLogsForUpload() async {
    try {
      // Rotate the current log file if logging is enabled
      if (_debugLogsEnabled) {
        debugLog('[DEBUG] Rotating log file for upload...');
        await DebugFileLogger.rotateLogFile();
      }

      // Get uploadable files (excludes current log file)
      final files = await DebugFileLogger.listUploadableLogFiles();
      debugLog('[DEBUG] Found ${files.length} log files available for upload');

      // Also refresh the main list
      _debugLogFiles = await DebugFileLogger.listLogFiles();
      notifyListeners();

      return files;
    } catch (e) {
      debugError('[DEBUG] Failed to prepare debug logs for upload: $e');
      // Fall back to returning all files
      return await DebugFileLogger.listLogFiles();
    }
  }

  /// Delete all debug log files
  ///
  /// Disables logging if active, then deletes all log files.
  Future<void> deleteAllDebugLogs() async {
    debugLog('[DEBUG] Deleting all debug logs');
    try {
      await DebugFileLogger.deleteAll();
      await _refreshDebugLogFiles();
      debugLog('[DEBUG] All debug logs deleted');
    } catch (e) {
      debugError('[DEBUG] Failed to delete all debug logs: $e');
    }
  }

  /// Share a debug log file
  ///
  /// Uses the native share sheet to allow users to share logs via email, messaging, etc.
  Future<void> shareDebugLog(File file) async {
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'MeshMapper Debug Log',
        ),
      );
      debugLog('[DEBUG] Shared log: ${file.path}, status: ${result.status}');
    } catch (e) {
      debugError('[DEBUG] Failed to share log: $e');
    }
  }

  /// Export an offline session to a file and open the native share sheet (Save
  /// to Files, Drive, email, …) — the mobile equivalent of the web JSON
  /// download. Mirrors [shareDebugLog]; writes the same pretty JSON the web
  /// path produces. Throws on failure so the caller can surface an error.
  Future<void> shareOfflineSession(String filename) async {
    final data = _offlineSessionService.getSessionData(filename);
    if (data == null) {
      throw Exception('Session "$filename" not found');
    }
    final jsonString = const JsonEncoder.withIndent('  ').convert(data);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsString(jsonString);
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        subject: 'MeshMapper Offline Session',
      ),
    );
    debugLog('[OFFLINE] Shared session: $filename, status: ${result.status}');
  }

  /// View a debug log file in-app
  ///
  /// Reads the file contents and stores them for display in a dialog.
  Future<void> viewDebugLog(File file) async {
    try {
      debugLog('[DEBUG] Viewing log: ${file.path}');
      _viewingLogContent = await file.readAsString();
      notifyListeners();
    } catch (e) {
      debugError('[DEBUG] Failed to read log file: $e');
    }
  }

  /// Close the log viewer
  ///
  /// Clears the viewed log content from memory.
  void closeLogViewer() {
    _viewingLogContent = null;
    notifyListeners();
  }

  // ============================================
  // GPS Simulator (Debug/Testing)
  // ============================================

  /// Simulator state tracking
  double _gpsSimulatorSpeed = 50.0;
  SimulatorPattern _gpsSimulatorPattern = SimulatorPattern.randomWalk;

  /// Check if GPS simulator is enabled
  bool get isGpsSimulatorEnabled => _gpsService.isSimulatorEnabled;

  /// Get current simulator speed
  double get gpsSimulatorSpeed => _gpsSimulatorSpeed;

  /// Get current simulator pattern
  SimulatorPattern get gpsSimulatorPattern => _gpsSimulatorPattern;

  /// Enable GPS simulator for testing
  void enableGpsSimulator() {
    debugLog('[APP] Enabling GPS simulator');
    _gpsService.enableSimulator(
      speed: _gpsSimulatorSpeed,
      pattern: _gpsSimulatorPattern,
    );
    notifyListeners();
  }

  /// Disable GPS simulator and return to real GPS
  void disableGpsSimulator() {
    debugLog('[APP] Disabling GPS simulator');
    _gpsService.disableSimulator();
    notifyListeners();
  }

  /// Set GPS simulator speed
  void setGpsSimulatorSpeed(double speed) {
    _gpsSimulatorSpeed = speed;
    if (_gpsService.isSimulatorEnabled) {
      _gpsService.configureSimulator(speed: speed);
    }
    notifyListeners();
  }

  /// Set GPS simulator pattern
  void setGpsSimulatorPattern(SimulatorPattern pattern) {
    _gpsSimulatorPattern = pattern;
    if (_gpsService.isSimulatorEnabled) {
      _gpsService.configureSimulator(pattern: pattern);
    }
    notifyListeners();
  }

  /// Reset GPS simulator position to Ottawa
  void resetGpsSimulator() {
    _gpsService.simulator.reset();
    notifyListeners();
  }

  /// Check if a route is loaded
  bool get hasSimulatorRoute => _gpsService.simulator.hasRoute;

  /// Get loaded route name
  String? get simulatorRouteName => _gpsService.simulator.routeName;

  /// Get loaded route point count
  int get simulatorRoutePointCount => _gpsService.simulator.routePointCount;

  /// Load a route file (KML or GPX)
  bool loadSimulatorRoute(String content, {String? filename}) {
    final success =
        _gpsService.simulator.loadRoute(content, filename: filename);
    if (success) {
      _gpsSimulatorPattern = SimulatorPattern.route;
      // If simulator is running, it will automatically use the new route
    }
    notifyListeners();
    return success;
  }

  /// Clear loaded route
  void clearSimulatorRoute() {
    _gpsService.simulator.clearRoute();
    if (_gpsSimulatorPattern == SimulatorPattern.route) {
      _gpsSimulatorPattern = SimulatorPattern.randomWalk;
    }
    notifyListeners();
  }

  // ============================================
  // Background Location Permission (iOS)
  // ============================================

  /// Check if "Always" location permission is granted
  Future<bool> hasAlwaysLocationPermission() async {
    return await _gpsService.hasAlwaysPermission();
  }

  /// Request "Always" location permission for background mode
  Future<bool> requestAlwaysLocationPermission() async {
    return await _gpsService.requestAlwaysPermission();
  }

  // ============================================
  // Remembered Device (Mobile Only)
  // ============================================

  static const String _rememberedDeviceBoxName = 'remembered_device';
  static const String _preferencesBoxName = 'user_preferences';

  /// Open Hive box with timeout and automatic recovery from corruption
  Future<Box<dynamic>?> _openBoxSafely(String boxName) async {
    const timeout = Duration(seconds: 5);

    debugLog('[HIVE] Opening box "$boxName"...');

    try {
      final box = await Hive.openBox(boxName).timeout(timeout);
      debugLog('[HIVE] Box "$boxName" opened successfully');
      return box;
    } on TimeoutException {
      debugError('[HIVE] Box "$boxName" timed out - attempting recovery');
      return _attemptHiveRecovery(boxName, timeout);
    } catch (e) {
      debugError('[HIVE] Box "$boxName" failed: $e - attempting recovery');
      return _attemptHiveRecovery(boxName, timeout);
    }
  }

  /// Attempt to recover from Hive corruption
  Future<Box<dynamic>?> _attemptHiveRecovery(
      String boxName, Duration timeout) async {
    try {
      debugLog('[HIVE] Deleting corrupted box "$boxName"...');
      await Hive.deleteBoxFromDisk(boxName);
      debugLog('[HIVE] Retrying open...');

      // Notify user that cleanup happened
      logError('Storage for "$boxName" was corrupted and has been reset');

      final box = await Hive.openBox(boxName).timeout(timeout);
      debugLog('[HIVE] Box "$boxName" opened after recovery');
      return box;
    } catch (e) {
      debugError('[HIVE] Recovery failed for "$boxName": $e');
      logError(
          'Storage for "$boxName" unavailable - some settings may not persist');
      return null;
    }
  }

  /// Load remembered device from Hive storage
  Future<void> _loadRememberedDevice() async {
    // Skip on web - Web Bluetooth requires user interaction for each connection
    if (kIsWeb) return;

    final box = await _openBoxSafely(_rememberedDeviceBoxName);
    if (box == null) return;

    try {
      final json = box.get('device');
      if (json != null) {
        _rememberedDevice =
            RememberedDevice.fromJson(Map<String, dynamic>.from(json));
        _selectedTransport = _rememberedDevice!.transportType;
        debugLog('[APP] Loaded remembered device: ${_rememberedDevice!.name} (${_rememberedDevice!.transportType.name})');
        notifyListeners();
      }
    } catch (e) {
      debugLog('[APP] Failed to load remembered device: $e');
    }
  }

  /// Save device for quick reconnection
  Future<void> _saveRememberedDevice(
    DiscoveredDevice device, {
    TransportType transportType = TransportType.ble,
    String? tcpHost,
    int? tcpPort,
    String? serialPortPath,
  }) async {
    if (kIsWeb) return;

    final box = await _openBoxSafely(_rememberedDeviceBoxName);
    if (box == null) return;

    try {
      final remembered = RememberedDevice(
        id: device.id,
        name: device.name,
        lastConnected: DateTime.now(),
        transportType: transportType,
        tcpHost: tcpHost,
        tcpPort: tcpPort,
        serialPortPath: serialPortPath,
      );

      await box.put('device', remembered.toJson());

      _rememberedDevice = remembered;
      debugLog(
          '[APP] Saved remembered device: ${device.name} (${transportType.name})');
      notifyListeners();
    } catch (e) {
      debugLog('[APP] Failed to save remembered device: $e');
    }
  }

  /// Reconnect to remembered device without scanning.
  /// Routes to the correct transport based on the remembered device's type.
  Future<void> reconnectToRememberedDevice() async {
    if (_rememberedDevice == null) return;
    if (kIsWeb) return;

    switch (_rememberedDevice!.transportType) {
      case TransportType.ble:
        final device = DiscoveredDevice(
          id: _rememberedDevice!.id,
          name: _rememberedDevice!.name,
        );
        _bluetoothService.cacheDeviceInfo(device);
        await connectToDevice(device);
        break;
      case TransportType.tcp:
        final host = _rememberedDevice!.tcpHost;
        final port = _rememberedDevice!.tcpPort;
        if (host != null && port != null) {
          await connectViaTcp(host, port);
        } else {
          debugError('[APP] Cannot reconnect via TCP: missing host/port');
        }
        break;
      case TransportType.usbSerial:
        debugLog('[APP] USB Serial reconnect requires user to select device');
        break;
    }
  }

  /// Clear remembered device
  Future<void> clearRememberedDevice() async {
    if (kIsWeb) return;

    final box = await _openBoxSafely(_rememberedDeviceBoxName);
    if (box == null) return;

    try {
      await box.delete('device');
      _rememberedDevice = null;
      debugLog('[APP] Cleared remembered device');
      notifyListeners();
    } catch (e) {
      debugLog('[APP] Failed to clear remembered device: $e');
    }
  }

  // ============================================
  // User Preferences Persistence
  // ============================================

  /// Load user preferences from Hive storage
  Future<void> _loadPreferences() async {
    final box = await _openBoxSafely(_preferencesBoxName);
    if (box == null) {
      _preferencesLoaded = true;
      notifyListeners();
      return;
    }

    try {
      final json = box.get('preferences');
      if (json != null) {
        _preferences =
            UserPreferences.fromJson(Map<String, dynamic>.from(json));
        debugLog(
            '[APP] Loaded preferences: interval=${_preferences.autoPingInterval}s, '
            'ignoreCarpeater=${_preferences.ignoreCarpeater}, '
            'ignoreRepeaterId=${_preferences.ignoreRepeaterId}');

        // Apply saved min ping distance to GpsService and PingService
        _gpsService
            .setMinPingDistance(_preferences.minPingDistanceMeters.toDouble());
        PingService.currentMinDistance = _preferences.minPingDistanceMeters;

        // Apply saved color vision type
        PingColors.setColorVisionType(
          ColorVisionType.values.firstWhere(
            (e) => e.name == _preferences.colorVisionType,
            orElse: () => ColorVisionType.none,
          ),
        );
      }
    } catch (e) {
      debugLog('[APP] Failed to load preferences: $e');
    }
    _preferencesLoaded = true;
    notifyListeners();
  }

  /// Save user preferences to Hive storage
  Future<void> _savePreferences() async {
    final box = await _openBoxSafely(_preferencesBoxName);
    if (box == null) return;

    try {
      await box.put('preferences', _preferences.toJson());
      await box.flush();
      debugLog('[APP] Saved preferences');
    } catch (e) {
      debugLog('[APP] Failed to save preferences: $e');
    }
  }

  // ============================================
  // Device Antenna Preferences Persistence
  // ============================================

  /// Load per-device antenna preferences from Hive storage
  Future<void> _loadDeviceAntennaPreferences() async {
    final box = await _openBoxSafely(_preferencesBoxName);
    if (box == null) return;

    try {
      final raw = box.get('device_antenna_preferences');
      if (raw != null) {
        _deviceAntennaPreferences = Map<String, bool>.from(raw as Map);
        debugLog(
            '[APP] Loaded antenna preferences for ${_deviceAntennaPreferences.length} device(s)');
      }
    } catch (e) {
      debugLog('[APP] Failed to load device antenna preferences: $e');
    }
  }

  /// Save per-device antenna preferences to Hive storage
  Future<void> _saveDeviceAntennaPreferences() async {
    final box = await _openBoxSafely(_preferencesBoxName);
    if (box == null) return;

    try {
      await box.put('device_antenna_preferences', _deviceAntennaPreferences);
      await box.flush();
    } catch (e) {
      debugLog('[APP] Failed to save device antenna preferences: $e');
    }
  }

  // ============================================
  // Device Power Override Persistence
  // ============================================

  /// Load per-device power overrides from Hive storage
  Future<void> _loadDevicePowerOverrides() async {
    final box = await _openBoxSafely(_preferencesBoxName);
    if (box == null) return;

    try {
      final raw = box.get('device_power_overrides');
      if (raw != null) {
        _devicePowerOverrides = (raw as Map).map(
          (key, value) =>
              MapEntry(key.toString(), Map<String, dynamic>.from(value as Map)),
        );
        debugLog(
            '[APP] Loaded power overrides for ${_devicePowerOverrides.length} device(s)');
      }
    } catch (e) {
      debugLog('[APP] Failed to load device power overrides: $e');
    }
  }

  /// Save per-device power overrides to Hive storage
  Future<void> _saveDevicePowerOverrides() async {
    final box = await _openBoxSafely(_preferencesBoxName);
    if (box == null) return;

    try {
      await box.put('device_power_overrides', _devicePowerOverrides);
      await box.flush();
    } catch (e) {
      debugLog('[APP] Failed to save device power overrides: $e');
    }
  }

  // ============================================
  // Device Real Name Persistence (Anonymous Mode Recovery)
  // ============================================

  Future<void> _loadDeviceRealNames() async {
    final box = await _openBoxSafely(_preferencesBoxName);
    if (box == null) return;

    try {
      final raw = box.get('device_real_names');
      if (raw != null) {
        _deviceRealNames = Map<String, String>.from(raw as Map);
        debugLog(
            '[APP] Loaded real names for ${_deviceRealNames.length} device(s)');
      }
    } catch (e) {
      debugLog('[APP] Failed to load device real names: $e');
    }
  }

  Future<void> _saveDeviceRealNames() async {
    final box = await _openBoxSafely(_preferencesBoxName);
    if (box == null) return;

    try {
      await box.put('device_real_names', _deviceRealNames);
      await box.flush();
    } catch (e) {
      debugLog('[APP] Failed to save device real names: $e');
    }
  }

  Future<void> _clearPersistedRealName(String publicKey) async {
    if (_deviceRealNames.remove(publicKey) != null) {
      await _saveDeviceRealNames();
      debugLog(
          '[APP] Cleared persisted real name for device ${publicKey.substring(0, 16)}...');
    }
  }

  // ============================================
  // Last Connected Device Persistence
  // ============================================

  /// Load last connected device info from Hive storage
  Future<void> _loadLastConnectedDevice() async {
    final box = await _openBoxSafely(_preferencesBoxName);
    if (box == null) return;

    try {
      _lastConnectedDeviceName =
          box.get('last_connected_device_name') as String?;
      _lastConnectedPublicKey = box.get('last_connected_public_key') as String?;
      if (_lastConnectedDeviceName != null) {
        debugLog(
            '[APP] Loaded last connected device: $_lastConnectedDeviceName');
      }
    } catch (e) {
      debugLog('[APP] Failed to load last connected device: $e');
    }
  }

  /// Save last connected device info to Hive storage
  Future<void> _saveLastConnectedDevice(
      String deviceName, String publicKey) async {
    final box = await _openBoxSafely(_preferencesBoxName);
    if (box == null) return;

    try {
      await box.put('last_connected_device_name', deviceName);
      await box.put('last_connected_public_key', publicKey);
      _lastConnectedDeviceName = deviceName;
      _lastConnectedPublicKey = publicKey;
      debugLog('[APP] Saved last connected device: $deviceName');
    } catch (e) {
      debugLog('[APP] Failed to save last connected device: $e');
    }
  }

  // ============================================
  // Last Known GPS Position Persistence
  // ============================================

  /// Load last known GPS position from Hive storage for map centering
  Future<void> _loadLastPosition() async {
    final box = await _openBoxSafely(_preferencesBoxName);
    if (box == null) return;

    try {
      final lat = box.get('last_position_lat') as double?;
      final lon = box.get('last_position_lon') as double?;
      if (lat != null && lon != null && isValidLatLng(lat, lon)) {
        _lastKnownPosition = (lat: lat, lon: lon);
        debugLog('[GPS] Loaded last position: $lat, $lon');
        notifyListeners(); // Trigger UI rebuild so map can center on last position
      } else if (lat != null && lon != null) {
        debugWarn('[GPS] Ignoring invalid stored last position: $lat, $lon');
      }
    } catch (e) {
      debugLog('[GPS] Failed to load last position: $e');
    }
  }

  /// Save last known GPS position to Hive storage (throttled to every 30 seconds)
  Future<void> _saveLastPosition(double lat, double lon) async {
    // Never persist invalid coords — a corrupted last-known position would be
    // loaded as the initial map center on next launch and abort the app.
    if (!isValidLatLng(lat, lon)) {
      debugWarn('[GPS] Skipping save of invalid last position: $lat, $lon');
      return;
    }

    // Throttle saves to every 30 seconds to avoid excessive Hive operations
    final now = DateTime.now();
    if (_lastPositionSaveTime != null &&
        now.difference(_lastPositionSaveTime!) < const Duration(seconds: 30)) {
      return; // Skip save, too soon since last save
    }

    final box = await _openBoxSafely(_preferencesBoxName);
    if (box == null) return;

    try {
      await box.put('last_position_lat', lat);
      await box.put('last_position_lon', lon);
      _lastPositionSaveTime = now;
    } catch (e) {
      debugLog('[GPS] Failed to save last position: $e');
    }
  }

  // ============================================
  // App Exit (Android only)
  // ============================================

  /// Exit the app completely (Android only)
  /// Uses SystemNavigator.pop() which is the recommended way to exit on Android
  Future<void> exitApp() async {
    debugLog('[APP] Exit app requested');

    // Disconnect first if connected
    if (isConnected) {
      await disconnect();
    }

    // Exit the app (Android only - iOS doesn't allow programmatic app exit)
    if (Platform.isAndroid) {
      SystemNavigator.pop();
    }
  }

  // ============================================
  // Noise Floor Session Tracking (Graph Feature)
  // ============================================

  static const String _noiseFloorSessionBoxName = 'noise_floor_sessions';

  /// Open noise floor session box with timeout and automatic recovery from corruption
  Future<Box<NoiseFloorSession>?> _openNoiseFloorBoxSafely() async {
    const timeout = Duration(seconds: 5);

    debugLog('[HIVE] Opening typed box "$_noiseFloorSessionBoxName"...');

    try {
      final box =
          await Hive.openBox<NoiseFloorSession>(_noiseFloorSessionBoxName)
              .timeout(timeout);
      debugLog(
          '[HIVE] Typed box "$_noiseFloorSessionBoxName" opened successfully');
      return box;
    } on TimeoutException {
      debugError(
          '[HIVE] Typed box "$_noiseFloorSessionBoxName" timed out - attempting recovery');
      return _attemptNoiseFloorBoxRecovery(timeout);
    } catch (e) {
      debugError(
          '[HIVE] Typed box "$_noiseFloorSessionBoxName" failed: $e - attempting recovery');
      return _attemptNoiseFloorBoxRecovery(timeout);
    }
  }

  /// Attempt to recover from Hive corruption for noise floor box
  Future<Box<NoiseFloorSession>?> _attemptNoiseFloorBoxRecovery(
      Duration timeout) async {
    try {
      debugLog('[HIVE] Deleting corrupted box "$_noiseFloorSessionBoxName"...');
      await Hive.deleteBoxFromDisk(_noiseFloorSessionBoxName);
      debugLog('[HIVE] Retrying open...');

      // Notify user that cleanup happened
      logError(
          'Storage for "$_noiseFloorSessionBoxName" was corrupted and has been reset');

      final box =
          await Hive.openBox<NoiseFloorSession>(_noiseFloorSessionBoxName)
              .timeout(timeout);
      debugLog(
          '[HIVE] Typed box "$_noiseFloorSessionBoxName" opened after recovery');
      return box;
    } catch (e) {
      debugError('[HIVE] Recovery failed for "$_noiseFloorSessionBoxName": $e');
      logError(
          'Storage for "$_noiseFloorSessionBoxName" unavailable - noise floor graphs will not persist');
      return null;
    }
  }

  /// Load stored noise floor sessions from Hive
  Future<void> _loadNoiseFloorSessions() async {
    _noiseFloorSessionBox = await _openNoiseFloorBoxSafely();
    if (_noiseFloorSessionBox == null) {
      _storedNoiseFloorSessions = [];
      return;
    }

    try {
      _storedNoiseFloorSessions = _noiseFloorSessionBox!.values.toList()
        ..sort((a, b) => b.startTime.compareTo(a.startTime)); // Newest first
      debugLog(
          '[GRAPH] Loaded ${_storedNoiseFloorSessions.length} stored noise floor sessions');
    } catch (e) {
      debugError('[GRAPH] Failed to load noise floor sessions: $e');
      _storedNoiseFloorSessions = [];
    }
  }

  /// Start a new noise floor session when mode is enabled
  void _startNoiseFloorSession(String mode) {
    // Continue existing session if same mode (e.g., after auto-reconnect)
    if (_currentNoiseFloorSession != null &&
        _currentNoiseFloorSession!.isActive &&
        _currentNoiseFloorSession!.mode == mode) {
      debugLog('[GRAPH] Continuing existing $mode noise floor session');
      return;
    }
    _currentNoiseFloorSession = NoiseFloorSession(
      id: const Uuid().v4(),
      startTime: DateTime.now(),
      mode: mode,
    );
    debugLog('[GRAPH] Started $mode noise floor session');
    notifyListeners();
  }

  /// Record a noise floor sample to the current session
  void _recordNoiseFloorSample(int noiseFloor) {
    if (_currentNoiseFloorSession != null) {
      _currentNoiseFloorSession!.samples.add(NoiseFloorSample(
        timestamp: DateTime.now(),
        noiseFloor: noiseFloor,
      ));
      // Don't notify on every sample - too frequent
    }
  }

  /// Record a ping event to the current session
  void recordPingEvent(
    PingEventType type, {
    double? latitude,
    double? longitude,
    List<MarkerRepeaterInfo>? repeaters,
  }) {
    if (_currentNoiseFloorSession != null && _currentNoiseFloor != null) {
      _currentNoiseFloorSession!.markers.add(PingEventMarker(
        timestamp: DateTime.now(),
        type: type,
        noiseFloor: _currentNoiseFloor!,
        latitude: latitude,
        longitude: longitude,
        repeaters: repeaters,
      ));
      debugLog('[GRAPH] Recorded ${type.name} event at ${_currentNoiseFloor}dBm'
          '${repeaters != null && repeaters.isNotEmpty ? " with ${repeaters.length} repeater(s)" : ""}');
      notifyListeners();
    }
  }

  /// End the current session and save to storage
  Future<void> _endNoiseFloorSession() async {
    if (_currentNoiseFloorSession == null) return;

    _currentNoiseFloorSession!.endTime = DateTime.now();
    debugLog(
        '[GRAPH] Ended session: ${_currentNoiseFloorSession!.durationDisplay}, '
        '${_currentNoiseFloorSession!.samples.length} samples, '
        '${_currentNoiseFloorSession!.markers.length} markers');

    // Save to Hive
    try {
      await _noiseFloorSessionBox?.put(
        _currentNoiseFloorSession!.id,
        _currentNoiseFloorSession!,
      );

      // Update stored list
      _storedNoiseFloorSessions.insert(0, _currentNoiseFloorSession!);

      // Keep only last 10 sessions
      while (_storedNoiseFloorSessions.length > 10) {
        final oldest = _storedNoiseFloorSessions.removeLast();
        await _noiseFloorSessionBox?.delete(oldest.id);
        debugLog('[GRAPH] Deleted oldest session: ${oldest.id}');
      }
    } catch (e) {
      debugError('[GRAPH] Failed to save noise floor session: $e');
    }

    _currentNoiseFloorSession = null;
    notifyListeners();
  }

  /// Clear all stored noise floor sessions
  Future<void> clearStoredNoiseFloorSessions() async {
    try {
      await _noiseFloorSessionBox?.clear();
      _storedNoiseFloorSessions = [];
      debugLog('[GRAPH] Cleared all stored noise floor sessions');
      notifyListeners();
    } catch (e) {
      debugError('[GRAPH] Failed to clear noise floor sessions: $e');
    }
  }

  /// Show a historical session's ping markers on the map
  void viewHistorySessionOnMap(NoiseFloorSession session) {
    final markers = session.markers
        .where((m) => m.latitude != null && m.longitude != null)
        .toList();
    if (markers.isEmpty) return;

    _historySessionMarkers = markers;
    _viewingHistorySession = true;
    _requestMapTabSwitch = true;
    debugLog('[GRAPH] Viewing session on map: ${markers.length} markers');
    notifyListeners();
  }

  /// Dismiss the history session map view
  void clearHistorySession() {
    if (!_viewingHistorySession) return;
    _historySessionMarkers = null;
    _viewingHistorySession = false;
    debugLog('[GRAPH] Cleared history session map view');
    notifyListeners();
  }

  // ============================================
  // Cleanup
  // ============================================

  void _cancelPendingAutoPingRestore() {
    _restoreAutoPingTimer?.cancel();
    _restoreAutoPingTimer = null;
    _reconnectRestoreGeneration++;
  }

  // ============================================
  // Map rebuild isolation (overheating fix)
  // ============================================
  //
  // The MapWidget (MapLibre GL) is by far the most expensive subtree. It used
  // to rebuild on EVERY notifyListeners() — including high-frequency UI-only
  // notifies (noise floor every 5s, battery, live stats) and the dense-mesh
  // RX-pin storm (10-20x/sec) — which kept the GPU/CPU pinned and overheated
  // the phone. Now the map is wrapped in a Selector keyed on [mapRevision]
  // (see home_screen.dart `_buildLayout`), so it only rebuilds when a
  // map-relevant change bumps the revision. UI-only notifies leave
  // [mapRevision] untouched, so the map stays cached.
  int _mapRevision = 0;

  /// Monotonic counter bumped whenever map-rendered data changes (markers,
  /// position, history view). The map's Selector watches this; UI-only
  /// notifies (noise floor, battery, stats) intentionally do not bump it.
  int get mapRevision => _mapRevision;

  Timer? _mapThrottleTimer;
  bool _mapThrottlePending = false;
  static const Duration _mapThrottleWindow = Duration(milliseconds: 250);

  /// Bump the map revision and notify immediately. Use for low-frequency
  /// map-relevant changes (TX ping added, ping window finalized, GPS position,
  /// history view, marker/log clears, marker-style preference changes).
  void _notifyMapNow() {
    _mapRevision++;
    notifyListeners();
  }

  /// Bump the map revision but coalesce notifications to ~4/sec. Use for
  /// high-frequency map-relevant changes (passive RX pins, echo bursts) so a
  /// dense mesh cannot force the map to rebuild 10-20x/sec. The pin data is
  /// updated immediately; only the rebuild signal is throttled.
  void _notifyMapThrottled() {
    _mapRevision++;
    if (_mapThrottleTimer != null) {
      _mapThrottlePending = true;
      return;
    }
    notifyListeners();
    _mapThrottleTimer = Timer(_mapThrottleWindow, () {
      _mapThrottleTimer = null;
      if (_mapThrottlePending) {
        _mapThrottlePending = false;
        notifyListeners();
      }
    });
  }

  @override
  @override
  void notifyListeners() {
    if (_isDisposed) return;
    super.notifyListeners();
    _scheduleLiveActivitySync();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _timerListenable.removeListener(_handleLiveActivityTimerChange);
    _liveActivityService.dispose();
    _watchBridge.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _adapterStateSubscription?.cancel();
    _connectionSubscription?.cancel();
    _gpsStatusSubscription?.cancel();
    _gpsPositionSubscription?.cancel();
    _logRxDataSubscription?.cancel();
    _noiseFloorSubscription?.cancel();
    _batterySubscription?.cancel();
    _maintenanceCheckTimer?.cancel();
    _zoneCheckRetryTimer?.cancel();
    _zoneCheckCountdownTimer?.cancel();
    _reconnectTimer?.cancel();
    _reconnectTimeoutTimer?.cancel();
    _restoreAutoPingTimer?.cancel();
    _idleDisconnectTimer?.cancel();
    _offlineAutoSaveTimer?.cancel();
    _zoneRefreshTimer?.cancel();
    _cancelZoneGraceTimers();
    _vectorFreshTimer?.cancel();
    _mapThrottleTimer?.cancel();
    _unifiedRxHandler?.dispose();
    _meshCoreConnection?.dispose();
    _pingService?.dispose();
    _gpsService.dispose();
    _apiQueueService.dispose();
    _customApiService.dispose();
    _offlineSessionService.dispose();
    _apiService.dispose();
    _bluetoothService.dispose();
    _audioService.dispose();
    _cooldownTimer.dispose();
    _manualPingCooldownTimer.dispose();
    _autoPingTimer.dispose();
    _rxWindowTimer.dispose();
    _discoveryWindowTimer.dispose();
    super.dispose();
  }
}
