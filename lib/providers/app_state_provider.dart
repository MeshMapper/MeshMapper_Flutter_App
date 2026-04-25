import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter/widgets.dart'
    show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
import 'package:geolocator/geolocator.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
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
import '../services/api_service.dart';
import '../services/audio_service.dart';
import '../services/background_service.dart';
import '../services/debug_file_logger.dart';
import '../services/offline_session_service.dart';
import '../services/bluetooth/bluetooth_service.dart';
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
import '../services/custom_api_service.dart';
import '../utils/constants.dart';
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

/// Result of uploading an offline session
enum OfflineUploadResult {
  /// Upload completed successfully
  success,

  /// Session file not found
  notFound,

  /// Session data is invalid or empty
  invalidSession,

  /// API authentication failed
  authFailed,

  /// Some pings failed to upload
  partialFailure,

  /// Another upload is already in progress
  uploadInProgress,

  /// GPS position required but not available
  gpsRequired,
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
  MeshCoreConnection? _meshCoreConnection;
  PingService? _pingService;
  UnifiedRxHandler? _unifiedRxHandler;
  TxTracker? _txTracker;
  RxLogger? _rxLogger;
  StreamSubscription? _logRxDataSubscription;
  StreamSubscription? _noiseFloorSubscription;
  StreamSubscription? _batterySubscription;

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

  /// BLE device name (e.g., "MeshCore-MrAlders0n_Elecrow")
  String? get connectedDeviceName => _bluetoothService.connectedDevice?.name;

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
  ({String repeaterId, double snr})? _rxOverlaySlot;
  Timer? _rxOverlayWindowTimer;

  // Targeted mode state
  String? _targetRepeaterId;

  // User error log entries
  final List<UserErrorEntry> _errorLogEntries = [];

  // User preferences
  UserPreferences _preferences = const UserPreferences();

  // Anonymous mode state
  String? _originalDeviceName; // Real name stored before rename
  bool _isAnonymousRenamed = false; // Device currently renamed to "Anonymous"

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

  // Tile refresh after upload
  int _overlayCacheBust = 0;
  Timer? _tileRefreshTimer;

  // Auth type from API response (API, Mesh, Manual)
  String? _authType;

  // Mode switching state (for hot-switching offline/online while connected)
  bool _isSwitchingMode = false;
  String? _modeSwitchError; // Error message if mode switch fails

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
  bool _requestConnectionTabSwitch = false; // Request switch to connection tab

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
    } else if (state == AppLifecycleState.paused) {
      debugLog('[APP] App paused (backgrounded)');
      // Save offline pings immediately on pause to prevent data loss if OS kills app
      if (_preferences.offlineMode && _apiQueueService.offlinePingCount > 0) {
        _autoSaveOfflinePings();
      }
    }
  }

  // ============================================
  // Getters
  // ============================================

  String get deviceId => _deviceId;
  bool get preferencesLoaded => _preferencesLoaded;
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
  String? get devicePublicKey => _devicePublicKey;
  PingStats get pingStats => _pingStats;
  bool get autoPingEnabled => _autoPingEnabled;
  AutoMode get autoMode => _autoMode;
  bool get isPingSending => _isPingSending;
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
  }

  /// Update the RX overlay slot — window matches auto-ping interval (best SNR wins).
  void _updateRxOverlaySlot(String repeaterId, double snr) {
    final entry = (repeaterId: repeaterId.toUpperCase(), snr: snr);
    if (_rxOverlayWindowTimer?.isActive ?? false) {
      if (_rxOverlaySlot == null || snr > _rxOverlaySlot!.snr) {
        _rxOverlaySlot = entry;
      }
    } else {
      _rxOverlaySlot = entry;
      _rxOverlayWindowTimer =
          Timer(Duration(seconds: _preferences.autoPingInterval), () {
        // Window closed — slot stays until next RX or cleared
      });
    }
  }

  /// Clear all overlay state (top 3 + RX slot).
  void _clearOverlayState() {
    _topRepeatersOverlay = [];
    _rxOverlaySlot = null;
    _rxOverlayWindowTimer?.cancel();
    _rxOverlayWindowTimer = null;
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
  bool get requestConnectionTabSwitch => _requestConnectionTabSwitch;
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
  int get overlayCacheBust => _overlayCacheBust;
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

  // Repeater markers getters
  List<Repeater> get repeaters => List.unmodifiable(_repeaters);

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

    // Initialize countdown timers with notifyListeners callback for smooth UI updates
    _cooldownTimer = CooldownTimer(onUpdate: notifyListeners);
    _manualPingCooldownTimer =
        ManualPingCooldownTimer(onUpdate: notifyListeners);
    _autoPingTimer = AutoPingTimer(onUpdate: notifyListeners);
    _rxWindowTimer = RxWindowTimer(onUpdate: notifyListeners);
    _discoveryWindowTimer = DiscoveryWindowTimer(onUpdate: notifyListeners);

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

    _apiQueueService.onUploadSuccess = (uploadedCount) {
      _pingStats = _pingStats.copyWith(
        successfulUploads: _pingStats.successfulUploads + uploadedCount,
      );
      debugLog(
          '[APP] Upload success: +$uploadedCount items (total: ${_pingStats.successfulUploads})');
      notifyListeners();

      // Schedule overlay tile refresh after server has time to regenerate tiles.
      // The MapWidget watches _overlayCacheBust and calls _refreshCoverageOverlay()
      // (remove + re-add raster source with new URL) when it changes.
      _tileRefreshTimer?.cancel();
      _tileRefreshTimer = Timer(const Duration(seconds: 5), () {
        _overlayCacheBust = DateTime.now().millisecondsSinceEpoch;
        debugLog('[MAP] Refreshing overlay tiles');
        notifyListeners();
      });
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
      notifyListeners();

      // Save last position for next app launch
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

  /// Connect to a discovered device
  Future<void> connectToDevice(DiscoveredDevice device) async {
    try {
      _connectionError = null;
      _isAuthError = false;
      _isNetworkError = false;

      // Clean up any previous connection first
      if (_meshCoreConnection != null) {
        debugLog('[APP] Disposing previous MeshCoreConnection');
        _meshCoreConnection!.dispose();
        _meshCoreConnection = null;
      }

      // ALWAYS START FRESH - clear any stale pings before connecting
      await _apiQueueService.clearBeforeConnect();

      // Create MeshCore connection
      debugLog('[APP] Creating new MeshCoreConnection');
      _meshCoreConnection = MeshCoreConnection(bluetooth: _bluetoothService);

      // Set auth callback for Step 6 (called during connect, after public key is acquired)
      // Implements two-stage auth flow with registration fallback
      // Skip auth when offline mode is enabled
      if (!_preferences.offlineMode) {
        _meshCoreConnection!.onRequestAuth = () async {
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
              _originalDeviceName = realName;
              try {
                await _meshCoreConnection!.setAdvertName('Anonymous');
                _isAnonymousRenamed = true;
                _displayDeviceName = 'Anonymous';
                debugLog(
                    '[CONN] Anonymous mode: renamed from "$realName" to "Anonymous"');
                // Short delay for firmware to process
                await Future.delayed(const Duration(milliseconds: 300));
              } catch (e) {
                debugError('[CONN] Anonymous mode: rename failed: $e');
                // Continue with real name if rename fails
              }
            }
          }

          // Resolve device name: use "Anonymous" if renamed, otherwise SelfInfo name
          final deviceName = _isAnonymousRenamed
              ? 'Anonymous'
              : (_meshCoreConnection!.selfInfo?.name ??
                  connectedDeviceName?.replaceFirst('MeshCore-', ''));
          if (deviceName == null || deviceName.isEmpty) {
            debugError(
                '[APP] Cannot request auth: could not retrieve device name');
            return {
              'success': false,
              'reason': 'no_device_name',
              'message': 'Could not retrieve device name'
            };
          }

          // ============================================================
          // STAGE 1: Try existing public_key authentication
          // ============================================================
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
            lat: _currentPosition?.latitude,
            lon: _currentPosition?.longitude,
            accuracyMeters: _currentPosition?.accuracy,
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
            return {
              'success': false,
              'reason': 'maintenance',
              'message': _maintenanceMessage ?? 'Service is under maintenance',
            };
          }

          // Check if Stage 1 succeeded
          if (result != null && result['success'] == true) {
            debugLog('[APP] Stage 1 succeeded: authenticated via public_key');

            // Store the auth type from response
            if (result['type'] != null) {
              _authType = result['type'] as String;
              debugLog('[APP] Auth type: $_authType');
              notifyListeners();
            }

            // Sync zone capacity display with auth result
            _syncZoneCapacityFromAuth(result);

            return result;
          }

          // API unreachable (null = network/timeout error, not an auth rejection)
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

          // If Stage 1 failed due to GPS issues, Stage 2 will also fail with same bad data
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
            return {
              'success': false,
              'reason': 'registration_failed',
              'message':
                  'Companion not found in backend and failed to register via API'
            };
          }

          // Call API with contact_uri for registration
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
            return {
              'success': false,
              'reason': serverReason,
              'message': serverMessage ?? 'Registration rejected by server',
            };
          }

          // Registration successful - response contains full auth data directly
          debugLog('[APP] Stage 2 succeeded: registered and authenticated');

          // Store the auth type from response
          if (registerResult['type'] != null) {
            _authType = registerResult['type'] as String;
            debugLog('[APP] Auth type: $_authType');
            notifyListeners();
          }

          // Sync zone capacity display with auth result
          _syncZoneCapacityFromAuth(registerResult);

          return registerResult;
        };
      } else {
        // Offline mode: skip API auth
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
          var deviceName = _isAnonymousRenamed
              ? _originalDeviceName
              : (_meshCoreConnection!.selfInfo?.name ?? connectedDeviceName);
          if (deviceName != null) {
            // Always strip MeshCore- prefix if present
            deviceName = deviceName.replaceFirst('MeshCore-', '');
          }
          if (deviceName != null &&
              deviceName.isNotEmpty &&
              _devicePublicKey != null) {
            _saveLastConnectedDevice(deviceName, _devicePublicKey!);
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

      // Listen for noise floor updates
      _noiseFloorSubscription =
          _meshCoreConnection!.noiseFloorStream.listen((noiseFloor) {
        _currentNoiseFloor = noiseFloor;
        // Record sample to current noise floor session (if active)
        _recordNoiseFloorSample(noiseFloor);
        notifyListeners();
      });

      // Listen for battery updates
      _batterySubscription =
          _meshCoreConnection!.batteryStream.listen((batteryPercent) {
        _currentBatteryPercent = batteryPercent;
        notifyListeners();
      });

      // Execute connection workflow
      final connectionResult = await _meshCoreConnection!.connect(
        device.id,
        _deviceModelService.models,
      );

      // Update preferences if device model was recognized (for display/API reporting)
      // Note: This does NOT change the radio's TX power - it only sets what power level to REPORT
      if (connectionResult.deviceModelMatched &&
          connectionResult.deviceModel != null) {
        final device = connectionResult.deviceModel!;
        _preferences = _preferences.copyWith(
          powerLevel: device.power,
          txPower: device.txPower,
          autoPowerSet:
              true, // Indicates power was auto-detected from device model
          powerLevelSet: false, // Clear stale manual flag from previous session
        );
        notifyListeners();
        debugLog(
            '[MODEL] Device recognized: ${device.shortName} - reporting ${device.power}W in API calls');
      }

      // Note: API session acquisition is now handled by the auth callback
      // during connection workflow Step 6 (onRequestAuth)

      // Create unified RX handler
      await _createUnifiedRxHandler();

      // Set regional channels from API response and update validator
      final apiChannels = _apiService.channels;
      await ChannelService.setRegionalChannels(apiChannels);
      _regionalChannels = ChannelService.getRegionalChannelNames();
      debugLog('[APP] Regional channels configured: $_regionalChannels');

      // Update unified RX handler's validator with new channel configuration
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

      // Set flood scope from API response (regional TX filtering)
      // "*" or "#*" = wildcard/global → no scope (unscoped flood, same as before)
      // Any other value (e.g., "ottawa") → derive TransportKey and set scope
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

      // Enforce hybrid mode if required by regional admin
      if (_apiService.enforceHybrid && !_preferences.hybridModeEnabled) {
        _preferences = _preferences.copyWith(hybridModeEnabled: true);
        debugLog('[CONN] Hybrid mode force-enabled by regional admin');
      }

      // Enforce discovery drop if required by regional admin
      if (_apiService.enforceDiscDrop && !_preferences.discDropEnabled) {
        _preferences = _preferences.copyWith(discDropEnabled: true);
        debugLog('[CONN] Discovery drop force-enabled by regional admin');
      }

      // Sync Flood Traffic preference with regional policy:
      //  - flood_disabled=true  → force OFF (region forbids)
      //  - flood_disabled=false → force ON  (region permits, user lands ready)
      // Fire a one-shot alert only on user-on → region-off transition.
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

      // Enforce minimum auto-ping interval if required by regional admin
      if (_preferences.autoPingInterval < _apiService.minModeInterval) {
        _preferences = _preferences.copyWith(
            autoPingInterval: _apiService.minModeInterval);
        debugLog(
            '[CONN] Auto-ping interval bumped to ${_apiService.minModeInterval}s by regional admin');
      }

      // Configure multi-byte path hash mode on radio
      await _configurePathHashMode();

      // Create ping service with wakelock (create new instance per connection)
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

      // Wire UnifiedRxHandler so trace payloads route to TraceTracker
      _pingService!.unifiedRxHandler = _unifiedRxHandler;

      // Set validation callbacks
      _pingService!.checkExternalAntennaConfigured = () {
        // External antenna must be explicitly set (yes or no) before pinging
        return _preferences.externalAntennaSet;
      };

      _pingService!.checkPowerLevelConfigured = () {
        // Power is configured if:
        // - Auto-detected from device model, OR
        // - Manually selected by user, OR
        // - Device model is known (has default power)
        return _preferences.autoPowerSet ||
            _preferences.powerLevelSet ||
            _deviceModel != null;
      };

      // Get external antenna value for API payloads
      _pingService!.getExternalAntenna = () => _preferences.externalAntenna;

      // Get power level from preferences (includes per-device overrides and manual selection)
      _pingService!.getPowerLevel = () => _preferences.powerLevel;

      // Check if TX is allowed by API (zone capacity)
      _pingService!.checkTxAllowed = () => txAllowed;

      // Check if discovery drop is enabled
      _pingService!.getDiscDropEnabled = () => discDropEnabled;

      _pingService!.onTxPing = (ping) {
        _txPings.add(ping);
        if (_txPings.length > _maxMapPins) _txPings.removeAt(0);

        // Add TX log entry (power in watts from preferences)
        _txLogEntries.add(TxLogEntry(
          timestamp: ping.timestamp,
          latitude: ping.latitude,
          longitude: ping.longitude,
          power: _preferences.powerLevel, // Watts (0.3, 0.6, 1.0, 2.0)
          events: [], // Will be updated when RX responses come in
        ));
        if (_txLogEntries.length > _maxLogEntries) _txLogEntries.removeAt(0);

        notifyListeners();
      };

      _pingService!.onRxPing = (ping) {
        _rxPings.add(ping);
        if (_rxPings.length > _maxMapPins) _rxPings.removeAt(0);

        // Add RX log entry
        _rxLogEntries.add(RxLogEntry(
          timestamp: ping.timestamp,
          repeaterId: ping.repeaterId,
          snr: ping.snr,
          rssi: ping.rssi,
          pathLength: 0, // TODO: Extract from packet metadata
          header: 0, // TODO: Extract from packet metadata
          latitude: ping.latitude,
          longitude: ping.longitude,
        ));
        if (_rxLogEntries.length > _maxLogEntries) _rxLogEntries.removeAt(0);

        // Update RX overlay slot with this RX observation
        _updateRxOverlaySlot(ping.repeaterId, ping.snr);

        notifyListeners();
      };

      _pingService!.onStatsUpdated = (stats) {
        // Preserve rxCount and successfulUploads while updating TX-related stats from PingService
        // PingService sends stats with rxCount=0 and successfulUploads=0 (it doesn't track these),
        // so we must preserve the values that other handlers increment
        _pingStats = stats.copyWith(
          rxCount: _pingStats.rxCount,
          successfulUploads: _pingStats.successfulUploads,
        );
        notifyListeners();

        // Update background service notification with current stats
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

      // Handle real-time echo updates - update TxLogEntry as echoes are received
      _pingService!.onEchoReceived = (txPing, repeater, isNew) {
        debugLog('[APP] ========== ECHO CALLBACK RECEIVED ==========');
        debugLog(
            '[APP] Real-time echo: ${repeater.repeaterId} (SNR: ${repeater.snr ?? 'null'}, isNew: $isNew)');
        debugLog('[APP] TxLogEntries count: ${_txLogEntries.length}');

        // Find the matching TxLogEntry and update its events
        if (_txLogEntries.isNotEmpty) {
          final lastEntry = _txLogEntries.last;
          // Verify it's the right entry by timestamp (should be within a few seconds)
          final timeDiff =
              lastEntry.timestamp.difference(txPing.timestamp).inSeconds.abs();
          if (timeDiff <= 10) {
            // Build updated events list
            final existingEvents = List<RxEvent>.from(lastEntry.events);
            final newEvent = RxEvent(
              repeaterId: repeater.repeaterId,
              snr: repeater.snr,
              rssi: repeater.rssi,
            );

            if (isNew) {
              // Add new event
              existingEvents.add(newEvent);
              // Play receive sound for new repeater echo
              _audioService.playReceiveSound();
            } else {
              // Update existing event's SNR
              final idx = existingEvents
                  .indexWhere((e) => e.repeaterId == repeater.repeaterId);
              if (idx >= 0) {
                existingEvents[idx] = newEvent;
              }
            }

            // Replace the entry with updated events
            final updatedEntry = TxLogEntry(
              timestamp: lastEntry.timestamp,
              latitude: lastEntry.latitude,
              longitude: lastEntry.longitude,
              power: lastEntry.power,
              events: existingEvents,
            );
            _txLogEntries[_txLogEntries.length - 1] = updatedEntry;
            debugLog(
                '[APP] Updated TxLogEntry with ${existingEvents.length} events (real-time)');

            // Update top repeaters overlay with current TX echoes
            _updateTopRepeaters(
                existingEvents
                    .where((e) => e.snr != null)
                    .map((e) =>
                        (repeaterId: e.repeaterId.toUpperCase(), snr: e.snr!))
                    .toList(),
                OverlayPingType.tx);

            debugLog('[APP] Calling notifyListeners() to update UI');
            notifyListeners();
            debugLog('[APP] notifyListeners() completed');
          } else {
            debugLog(
                '[APP] Timestamp mismatch: lastEntry=${lastEntry.timestamp}, txPing=${txPing.timestamp}, diff=${timeDiff}s');
          }
        } else {
          debugLog('[APP] WARNING: _txLogEntries is empty, cannot update');
        }
      };

      // Wire up ping progress callback for immediate UI refresh (e.g. "Sending..." on disc)
      _pingService!.onPingProgressChanged = notifyListeners;

      // Wire up auto ping scheduled callback for countdown display
      _pingService!.onAutoPingScheduled = (intervalMs, skipReason) {
        _autoPingTimer.startWithSkipReason(intervalMs, skipReason);

        // Track idle time for auto-stop
        if (skipReason != null) {
          // Ping was skipped — check if idle too long
          if (_preferences.autoStopAfterIdle &&
              _idleAutoStopReference != null) {
            final elapsed = DateTime.now().difference(_idleAutoStopReference!);
            if (elapsed >= _autoStopIdleTimeout) {
              _triggerIdleAutoStop();
            }
          }
        } else {
          // Successful ping — reset idle reference
          _idleAutoStopReference = DateTime.now();
        }
      };

      // Wire up discovery ping callback - fires immediately (like onTxPing)
      _pingService!.onDiscPing = (entry) {
        _addDiscLogEntry(entry);
      };

      // Wire up real-time disc node discovery callback (like onEchoReceived)
      _pingService!.onDiscNodeDiscovered = (discPing, nodeEntry, isNew) {
        debugLog(
            '[APP] Real-time disc node: ${nodeEntry.repeaterId}, isNew=$isNew');
        if (isNew) {
          _audioService.playReceiveSound();
        }

        // Update top repeaters overlay with all discovered nodes from this ping
        _updateTopRepeaters(
            discPing.discoveredNodes
                .map((n) =>
                    (repeaterId: n.repeaterId.toUpperCase(), snr: n.localSnr))
                .toList(),
            OverlayPingType.disc);

        notifyListeners();
      };

      // Wire up TX window complete callback for noise floor graph
      _pingService!.onTxWindowComplete = (success) {
        // Get location and repeater info from the last TX log entry
        double? lat;
        double? lon;
        List<MarkerRepeaterInfo>? repeaters;

        if (_txLogEntries.isNotEmpty) {
          final lastTx = _txLogEntries.last;
          lat = lastTx.latitude;
          lon = lastTx.longitude;
          if (lastTx.events.isNotEmpty) {
            repeaters = lastTx.events
                .map((e) => MarkerRepeaterInfo(
                      repeaterId: e.repeaterId,
                      snr: e.snr ?? 0.0,
                      rssi: e.rssi ?? 0,
                    ))
                .toList();
          }
        }

        recordPingEvent(
          success ? PingEventType.txSuccess : PingEventType.txFail,
          latitude: lat,
          longitude: lon,
          repeaters: repeaters,
        );
      };

      // Wire up discovery window complete callback for noise floor graph
      _pingService!.onDiscoveryWindowComplete = (success) {
        // Get location and node info from the most recent discovery log entry
        // Note: _discLogEntries uses insert(0,...) so .first is newest
        double? lat;
        double? lon;
        List<MarkerRepeaterInfo>? repeaters;

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
        }

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

      // Wire up trace ping callback (for log entry creation)
      _pingService!.onTracePing = (entry) {
        _addTraceLogEntry(entry);
      };

      // Wire up trace window complete callback for noise floor graph
      _pingService!.onTraceWindowComplete = (result) {
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
            // Update the log entry with success data
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
            notifyListeners();
          }
        }

        recordPingEvent(
          result != null && result.success
              ? PingEventType.traceSuccess
              : PingEventType.traceFail,
          latitude: lat,
          longitude: lon,
          repeaters: repeaters,
        );
      };

      // Wire up discovery carpeater drop callback (for DiscTracker RSSI failsafe)
      _pingService!.onDiscCarpeaterDrop = (String repeaterId, String reason) {
        debugLog(
            '[APP] Discovery carpeater drop: repeater=$repeaterId, reason=$reason');
        logError('Discovery Dropped\nPossible carpeater: $repeaterId\n$reason',
            severity: ErrorSeverity.warning, autoSwitch: false);
      };

      // Wire up pending disable complete callback
      // Called when user disables Active Mode during sending/listening and the RX window ends
      _pingService!.onPendingDisableComplete = () async {
        debugLog('[APP] Pending disable completed, cleaning up');

        // Stop TX echo tracking
        _pingService!.stopEchoTracking();
        // Stop RX wardriving (flushes batches)
        _rxLogger?.stopWardriving(trigger: 'pending_disable');

        // Stop background service
        await BackgroundServiceManager.stopService();

        // Stop countdown timers
        _autoPingTimer.stop();
        _rxWindowTimer.stop();

        // Save offline session if offline mode is enabled
        if (_preferences.offlineMode) {
          await _saveOfflineSession();
        }

        // End noise floor session
        await _endNoiseFloorSession();

        // Disable heartbeat
        _apiService.disableHeartbeat();

        // Update local state
        _autoPingEnabled = false;
        _idleAutoStopReference = null;

        debugLog('[APP] Pending disable cleanup complete, cooldown running');
        notifyListeners();
      };

      // Save this device for quick reconnection (mobile only)
      await _saveRememberedDevice(device);

      // Update display name from SelfInfo (reflects user's chosen name)
      // BLE advertisement name may be cached/stale after device rename
      final selfInfoName = _meshCoreConnection?.selfInfo?.name;
      if (selfInfoName != null && selfInfoName.isNotEmpty) {
        // Keep "Anonymous" display name if anonymous mode is active
        _displayDeviceName = _isAnonymousRenamed ? 'Anonymous' : selfInfoName;
        debugLog('[APP] Display name set: "$_displayDeviceName"');

        // Update remembered device with real name (not "Anonymous")
        // BLE advertisement name may be stale after device rename
        final realName = _isAnonymousRenamed
            ? (_originalDeviceName ?? selfInfoName)
            : selfInfoName;
        if (_rememberedDevice != null && _rememberedDevice!.id == device.id) {
          final updatedName = 'MeshCore-$realName';
          if (_rememberedDevice!.name != updatedName) {
            await _saveRememberedDevice(
                DiscoveredDevice(id: device.id, name: updatedName));
            debugLog(
                '[APP] Updated remembered device name from SelfInfo: $updatedName');
          }
        }
      }

      // Restore per-device antenna preference if previously saved
      // Use original name for keying, not "Anonymous"
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

      // Restore per-device power override if previously saved
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

      // Log connection status based on TX/RX permissions
      if (hasApiSession) {
        if (txAllowed && rxAllowed) {
          debugLog('[CONN] Connected with full access (TX + RX allowed)');
        } else if (rxAllowed) {
          debugLog(
              '[CONN] Connected with RX-only access (TX not allowed, zone at TX capacity)');
        } else {
          debugLog('[CONN] Connected with limited access');
        }

        // Track session zone for zone-to-zone transfer detection
        _sessionZoneCode = zoneCode;

        // Start periodic zone refresh to keep slot counts current
        if (!_preferences.offlineMode) {
          _startZoneRefreshTimer();
        }

        // Enable heartbeat immediately on connection to keep server session alive
        // Previously only enabled on auto-ping start, causing silent session expiry
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

        // Start 15-minute idle disconnect timer (cancelled by manual ping or auto-ping start)
        _startIdleDisconnectTimer();
      } else {
        // No API session - offline mode or auth skipped
        debugLog('[CONN] Connected without API session (offline mode)');
      }

      // Log ping validation status after connection
      final validation = pingValidation;
      if (validation != PingValidation.valid) {
        debugLog('[CONN] Ping validation after connect: $validation');
      }
    } catch (e) {
      debugError('[APP] Connection failed: $e');

      // Ensure channel is cleaned up if it was created during connection
      // Must happen BEFORE BLE disconnect while connection is still alive
      try {
        await _meshCoreConnection?.deleteWardrivingChannelEarly();
      } catch (channelError) {
        debugError('[APP] Cleanup channel delete failed: $channelError');
      }

      // Ensure BLE is disconnected on any connection failure
      // (connection.dart should have done this, but be defensive)
      try {
        if (_meshCoreConnection != null) {
          await _meshCoreConnection!.disconnect();
        }
      } catch (disconnectError) {
        debugError('[APP] Cleanup disconnect failed: $disconnectError');
      }

      // Parse auth failure errors for clean display
      final errorStr = e.toString();
      if (errorStr.contains('AUTH_FAILED:')) {
        // Format: "Exception: AUTH_FAILED:reason:message"
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
        // Provide clean user-facing messages for common BLE errors
        if (errorStr.contains('timeout') ||
            errorStr.contains('Timeout') ||
            errorStr.contains('timed out')) {
          _connectionError = 'Bluetooth connection scan timed out';
        } else {
          _connectionError = errorStr.replaceFirst('Exception: ', '');
        }
      }
      _connectionStep = ConnectionStep.error;
      notifyListeners();
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
            notifyListeners();
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

          // Update UI
          notifyListeners();
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

    // Store the device's current mode (from DeviceInfo response)
    _originalPathHashMode = deviceInfo.pathHashMode;

    // Sync runtime hopBytes from device's current mode
    if (_originalPathHashMode != null) {
      final deviceHopBytes = _originalPathHashMode! + 1;
      _hopBytes = deviceHopBytes;
      // Map TX bytes to trace bytes (3-byte traces not possible, use 4)
      _traceHopBytes = deviceHopBytes == 3 ? 4 : deviceHopBytes;
      _pingService?.traceHopBytes = _traceHopBytes;
      debugLog(
          '[PATH] Read device path mode: $deviceHopBytes-byte (trace: $_traceHopBytes-byte)');
    } else {
      _hopBytes = 1;
      _traceHopBytes = 1;
    }

    final effective = effectiveHopBytes;
    final deviceMode =
        _originalPathHashMode ?? 0; // null = old firmware, treat as 0 (1-byte)
    final deviceHopBytes = deviceMode + 1;

    if (effective != deviceHopBytes && _originalPathHashMode != null) {
      // Need to change the radio's path hash mode
      try {
        await _meshCoreConnection!.setPathHashMode(effective - 1);
        _hopBytes = effective; // Update runtime state to reflect new mode
        _traceHopBytes = effective == 3 ? 4 : effective;
        _pingService?.traceHopBytes = _traceHopBytes;
        debugLog(
            '[PATH] Set path hash mode: device was $deviceHopBytes-byte, now $effective-byte (trace: $_traceHopBytes-byte)');

        // Show warning popup if changing from 1-byte to multi-byte
        if (deviceMode == 0 && effective > 1) {
          final reason = enforceHopBytes
              ? 'set by your regional admin'
              : 'set in your app preferences';
          _pendingPathHashWarning = (hopBytes: effective, reason: reason);
          notifyListeners(); // Trigger UI to show warning
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
          '[PATH] Path hash mode OK: device=$deviceHopBytes-byte, effective=$effective-byte');
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
    // Guard against double cleanup (e.g., reconnect timeout + BLE disconnect event)
    if (_connectionStep == ConnectionStep.disconnected) {
      debugLog('[CONN] Already disconnected, skipping duplicate cleanup');
      return;
    }
    _cancelPendingAutoPingRestore();
    _connectionStep = ConnectionStep.disconnected;

    // Cancel any active zone grace period
    _cancelZoneGraceTimers();
    _isInZoneGracePeriod = false;
    _zoneGraceSecondsRemaining = 0;
    _autoPingWasEnabledBeforeGrace = false;

    // Stop heartbeat immediately on BLE disconnect
    _apiService.disableHeartbeat();
    debugLog('[CONN] Heartbeat disabled due to BLE disconnect');

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
      debugLog('[AUTO] Auto-ping disabled due to BLE disconnect');
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
      debugLog('[CONN] Releasing API session due to BLE disconnect');
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

    // Reset anonymous mode state (BLE already gone, can't restore name)
    _isAnonymousRenamed = false;
    _originalDeviceName = null;

    // Clear top-heard overlay
    _clearOverlayState();

    // Existing cleanup
    _meshCoreConnection?.dispose();
    _meshCoreConnection = null;
    _pingService?.dispose();
    _pingService = null;
  }

  /// Start auto-reconnect after unexpected BLE disconnect
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

  /// Detect iOS apple-code 14/15 bond errors and clear the stale bond before retry
  Future<void> _handleBondErrorIfNeeded(Object error) async {
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
    // Mark as user-requested so BLE disconnect listener doesn't trigger auto-reconnect
    _userRequestedDisconnect = true;

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

    // Disconnect BLE (don't call disconnect() twice - meshCoreConnection.disconnect() already does it)
    await _meshCoreConnection?.disconnect();

    // Cancel stream subscriptions
    await _noiseFloorSubscription?.cancel();
    _noiseFloorSubscription = null;
    await _batterySubscription?.cancel();
    _batterySubscription = null;

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

    // Check session validity before starting (skip in offline mode)
    if (!_preferences.offlineMode) {
      final sessionCheck = await _checkSessionBeforeAction();
      if (!sessionCheck) return false;
    }

    // Reset idle disconnect timer (user is actively pinging)
    _startIdleDisconnectTimer();

    // Set sending state immediately for instant UI feedback
    _isPingSending = true;
    notifyListeners();

    debugLog('[PING] Sending manual TX ping');
    try {
      return await _pingService!.sendTxPing(manual: true);
    } finally {
      // Clear sending state when done (RX window timer will show listening state)
      _isPingSending = false;
      notifyListeners();
    }
  }

  /// Check session validity before starting a wardrive action
  /// Returns true if session is valid, false if expired (triggers disconnect)
  Future<bool> _checkSessionBeforeAction() async {
    final pos = _gpsService.lastPosition;
    final result = await _apiService.checkSessionValid(
      lat: pos?.latitude,
      lon: pos?.longitude,
    );

    if (!result.isValid) {
      debugWarn(
          '[API] Session check failed: ${result.reason} - ${result.message ?? "Session expired"}');
      // Note: onSessionError callback will trigger disconnect for critical errors
      return false;
    }
    return true;
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
    }

    notifyListeners();
    return true;
  }

  /// Clear ping markers from map
  void clearPings() {
    _txPings.clear();
    _rxPings.clear();
    _clearOverlayState();
    _pingService?.resetStats();
    notifyListeners();
  }

  /// Clear log entries
  void clearLogs() {
    _txLogEntries.clear();
    _rxLogEntries.clear();
    _discLogEntries.clear();
    _traceLogEntries.clear();
    _errorLogEntries.clear();
    _clearOverlayState();
    notifyListeners();
  }

  /// Add a discovery log entry (from Passive Mode)
  void _addDiscLogEntry(DiscLogEntry entry) {
    _discLogEntries.insert(0, entry);
    if (_discLogEntries.length > _maxLogEntries) {
      _discLogEntries.removeLast();
    }
    debugLog(
        '[APP] Discovery log entry added: ${entry.nodeCount} nodes discovered');
    notifyListeners();
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

    notifyListeners();
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

      // Re-check zone status BEFORE auth (zone data was cleared when entering offline mode)
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
      _preferences = _preferences.copyWith(offlineMode: false);
      _apiQueueService.offlineMode = false;

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
      return;
    }

    // Include device info for auth during upload (use real name, not "Anonymous" — sessions upload later)
    // Note: Connection already validates device name exists, so this should never be null
    final offlineDeviceName = _isAnonymousRenamed
        ? _originalDeviceName
        : (_meshCoreConnection?.selfInfo?.name ??
            connectedDeviceName?.replaceFirst('MeshCore-', ''));
    await _offlineSessionService.saveSession(
      pings,
      devicePublicKey: _devicePublicKey,
      deviceName: offlineDeviceName,
      contactUri: _offlineContactUri,
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

    // 2. Get device credentials from session
    final publicKey = session.devicePublicKey;
    if (publicKey == null) {
      debugLog('[OFFLINE] Session missing device public key: $filename');
      return OfflineUploadResult.invalidSession;
    }

    final deviceName = session.deviceName;
    if (deviceName == null || deviceName.isEmpty) {
      debugLog('[OFFLINE] Session missing device name: $filename');
      return OfflineUploadResult.invalidSession;
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
    debugLog(
        '[OFFLINE] Authenticating for offline upload with device: $deviceName');
    final authResult = await _apiService.requestAuth(
      reason: 'connect',
      publicKey: publicKey,
      who: deviceName,
      appVersion: _appVersion,
      power: _preferences.powerLevel,
      iataCode: zoneCode ?? _preferences.iataCode,
      model: 'Offline Upload',
      lat: _currentPosition?.latitude,
      lon: _currentPosition?.longitude,
      accuracyMeters: _currentPosition?.accuracy,
      offlineMode: true,
      skipSessionStore: true,
    );

    Map<String, dynamic>? effectiveAuth = authResult;

    if (authResult == null) {
      debugError('[OFFLINE] Auth failed: network error');
      return OfflineUploadResult.authFailed;
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
          appVersion: _appVersion,
          power: _preferences.powerLevel,
          iataCode: zoneCode ?? _preferences.iataCode,
          model: 'Offline Upload',
          lat: _currentPosition?.latitude,
          lon: _currentPosition?.longitude,
          accuracyMeters: _currentPosition?.accuracy,
          offlineMode: true,
          skipSessionStore: true,
        );

        if (registerResult == null || registerResult['success'] != true) {
          final regReason = registerResult?['reason'] as String? ?? 'unknown';
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

    // Delay after auth before posting
    await Future.delayed(const Duration(seconds: 1));

    // 4. Upload pings in batches of 50 using isolated session
    const batchSize = 50;
    var uploadedCount = 0;
    var failedBatches = 0;
    final totalBatches = (pings.length + batchSize - 1) ~/ batchSize;

    for (var i = 0; i < pings.length; i += batchSize) {
      final batchNum = (i ~/ batchSize) + 1;
      onProgress?.call('Batch $batchNum/$totalBatches');

      final batch = pings.skip(i).take(batchSize).toList();
      final result =
          await _apiService.uploadBatchWithSessionId(batch, offlineSessionId);
      if (result == UploadResult.success) {
        uploadedCount += batch.length;
        debugLog('[OFFLINE] Uploaded batch $batchNum: ${batch.length} pings');
      } else {
        failedBatches++;
        debugError('[OFFLINE] Failed to upload batch $batchNum');
      }
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

    // 6. Mark session as uploaded (don't delete) if all batches succeeded
    if (failedBatches == 0) {
      await _offlineSessionService.markAsUploaded(filename);
      debugLog('[OFFLINE] Uploaded ${pings.length} pings from $filename');
      notifyListeners();
      return OfflineUploadResult.success;
    } else {
      debugWarn(
          '[OFFLINE] Partial upload: $uploadedCount/${pings.length} pings from $filename');
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

    notifyListeners();
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
        _requestConnectionTabSwitch = true;
        notifyListeners();
        await disconnect(); // Full cleanup (restores name if previously anonymous)
        // Short delay for BLE cleanup
        await Future.delayed(const Duration(milliseconds: 500));
        await connectToDevice(deviceToReconnect);
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

  /// Set map style (dark, light, satellite) and persist
  void setMapStyle(String style) {
    _preferences = _preferences.copyWith(mapStyle: style);
    debugLog('[MAP] Map style set to $style');
    notifyListeners();
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
    notifyListeners();
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
    notifyListeners();
  }

  /// Clear the map tab switch request (called by main scaffold after switching)
  void clearMapTabSwitchRequest() {
    _requestMapTabSwitch = false;
  }

  /// Clear the error log switch request (called by log screen after switching)
  void clearErrorLogSwitchRequest() {
    _requestErrorLogSwitch = false;
  }

  /// Clear the connection tab switch request (called by main scaffold after switching)
  void clearConnectionTabSwitchRequest() {
    _requestConnectionTabSwitch = false;
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
      default:
        return serverMessage ?? 'Unknown error occurred.';
    }
  }

  /// Handle session error from wardrive/heartbeat API calls
  /// This may trigger auto-disconnect
  Future<void> handleSessionError(String? reason, String? message) async {
    final userMessage = _getErrorMessage(reason, message);

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

    // Start 5-minute countdown
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
        _autoPingWasEnabledBeforeGrace = false;
        await _handleZoneTransfer(
            reEnteredZoneCode, _currentZone?['name'] ?? 'Unknown');
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
          toggleAutoPing(previousMode);
          debugLog('[ZONE GRACE] Auto-ping restored (mode=$previousMode)');
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

  // ============================================
  // Zone-to-Zone Transfer
  // ============================================

  /// Handle zone-to-zone transfer during active wardriving session.
  /// Releases old zone session and acquires new session for target zone.
  /// Preserves BLE connection and radio configuration.
  Future<void> _handleZoneTransfer(
      String newZoneCode, String newZoneName) async {
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
      final wasAutoPing = _autoPingEnabled;
      final previousMode = _autoMode;

      // 2. Pause auto-ping and wardriving activity
      _autoPingTimer.stop();
      _rxWindowTimer.stop();
      _cooldownTimer.stop();
      if (_autoPingEnabled) {
        _autoPingEnabled = false;
        _idleAutoStopReference = null;
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
      final result = await _apiService.requestAuth(
        reason: 'connect',
        publicKey: _devicePublicKey!,
        who: deviceName,
        appVersion: _appVersion,
        power: _preferences.powerLevel,
        iataCode: newZoneCode,
        model: _meshCoreConnection?.deviceModel?.manufacturer ??
            _meshCoreConnection?.deviceInfo?.manufacturer ??
            'Unknown',
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
        logError('Zone transfer failed: $message',
            severity: ErrorSeverity.error);
        await disconnect();
        return;
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

      // 15. Enforce regional admin policies from new zone
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
            toggleAutoPing(previousMode);
            debugLog('[ZONE] Auto-ping restored (mode=$previousMode)');
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
        notifyListeners();
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
        debugLog('[APP] Loaded remembered device: ${_rememberedDevice!.name}');
        notifyListeners();
      }
    } catch (e) {
      debugLog('[APP] Failed to load remembered device: $e');
    }
  }

  /// Save device for quick reconnection
  Future<void> _saveRememberedDevice(DiscoveredDevice device) async {
    // Skip on web - Web Bluetooth requires user interaction for each connection
    if (kIsWeb) return;

    final box = await _openBoxSafely(_rememberedDeviceBoxName);
    if (box == null) return;

    try {
      final remembered = RememberedDevice(
        id: device.id,
        name: device.name,
        lastConnected: DateTime.now(),
      );

      await box.put('device', remembered.toJson());

      _rememberedDevice = remembered;
      debugLog('[APP] Saved remembered device: ${device.name}');
      notifyListeners();
    } catch (e) {
      debugLog('[APP] Failed to save remembered device: $e');
    }
  }

  /// Reconnect to remembered device without scanning
  Future<void> reconnectToRememberedDevice() async {
    if (_rememberedDevice == null) return;
    if (kIsWeb) return; // Not supported on web

    final device = DiscoveredDevice(
      id: _rememberedDevice!.id,
      name: _rememberedDevice!.name,
    );

    // Pre-populate the BLE scan cache with remembered device info
    // This ensures the device name is available during connect()
    // (normally populated by scanning, but we're skipping the scan)
    _bluetoothService.cacheDeviceInfo(device);

    await connectToDevice(device);
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
      if (lat != null && lon != null) {
        _lastKnownPosition = (lat: lat, lon: lon);
        debugLog('[GPS] Loaded last position: $lat, $lon');
        notifyListeners(); // Trigger UI rebuild so map can center on last position
      }
    } catch (e) {
      debugLog('[GPS] Failed to load last position: $e');
    }
  }

  /// Save last known GPS position to Hive storage (throttled to every 30 seconds)
  Future<void> _saveLastPosition(double lat, double lon) async {
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

  // ============================================
  // Cleanup
  // ============================================

  void _cancelPendingAutoPingRestore() {
    _restoreAutoPingTimer?.cancel();
    _restoreAutoPingTimer = null;
    _reconnectRestoreGeneration++;
  }

  @override
  @override
  void notifyListeners() {
    if (!_isDisposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
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
    _tileRefreshTimer?.cancel();
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
    _autoPingTimer.dispose();
    _rxWindowTimer.dispose();
    _discoveryWindowTimer.dispose();
    super.dispose();
  }
}
