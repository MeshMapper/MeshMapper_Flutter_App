import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:share_plus/share_plus.dart';

import '../models/connection_state.dart';
import '../models/device_model.dart';
import '../models/ping_data.dart';
import '../models/log_entry.dart';
import '../models/remembered_device.dart';
import '../models/repeater.dart';
import '../models/user_preferences.dart';
import '../services/api_queue_service.dart';
import '../services/api_service.dart';
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
import '../services/meshcore/packet_validator.dart' show PacketValidator, ChannelInfo;
import '../services/meshcore/rx_logger.dart';
import '../services/meshcore/tx_tracker.dart';
import '../services/meshcore/unified_rx_handler.dart';
import '../services/ping_service.dart';
import '../services/status_message_service.dart';
import '../services/countdown_timer_service.dart';
import '../utils/constants.dart';
import '../services/wakelock_service.dart';
import '../utils/debug_logger_io.dart';

/// Auto-ping mode (matches MeshMapper_WebClient behavior)
enum AutoMode {
  /// TX/RX Auto: Sends pings on movement, listens for RX responses
  txRx,
  /// RX Auto: Passive listening only (no transmit)
  rxOnly,
}

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
}

/// Main application state provider
class AppStateProvider extends ChangeNotifier {
  final BluetoothService _bluetoothService;
  final GpsService _gpsService = GpsService(); // Initialize immediately
  late final ApiService _apiService;
  late final ApiQueueService _apiQueueService;
  late final OfflineSessionService _offlineSessionService;
  late final DeviceModelService _deviceModelService;
  late final StatusMessageService _statusMessageService;
  late final CooldownTimer _cooldownTimer; // Shared cooldown for TX Ping and TX/RX Auto
  late final AutoPingTimer _autoPingTimer;
  late final RxWindowTimer _rxWindowTimer;
  late final DiscoveryWindowTimer _discoveryWindowTimer; // Discovery listening window (Passive Mode)
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
  bool _isAuthError = false;  // Track if connection failed due to auth

  // GPS state
  GpsStatus _gpsStatus = GpsStatus.permissionDenied;
  Position? _currentPosition;

  // Device info
  DeviceModel? _deviceModel;
  String? _manufacturerString;
  String? _devicePublicKey;

  /// BLE device name (e.g., "MeshCore-MrAlders0n_Elecrow")
  String? get connectedDeviceName => _bluetoothService.connectedDevice?.name;

  // Ping state
  PingStats _pingStats = const PingStats();
  bool _autoPingEnabled = false;
  AutoMode _autoMode = AutoMode.txRx;
  bool _isPingSending = false; // True immediately when ping button clicked
  int _queueSize = 0;
  int? _currentNoiseFloor;
  int? _currentBatteryPercent;

  // Discovered devices
  List<DiscoveredDevice> _discoveredDevices = [];
  bool _isScanning = false;

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

  // User error log entries
  final List<UserErrorEntry> _errorLogEntries = [];

  // User preferences
  UserPreferences _preferences = const UserPreferences();

  // Remembered device for quick reconnection (mobile only)
  RememberedDevice? _rememberedDevice;

  // Debug logs state (non-persistent, always starts false)
  bool _debugLogsEnabled = false;
  List<File> _debugLogFiles = [];
  String? _viewingLogContent;

  // Zone state for geo-auth
  bool? _inZone; // null = not checked yet, true/false = checked
  Map<String, dynamic>? _currentZone; // Zone info when inZone == true
  Map<String, dynamic>? _nearestZone; // Nearest zone info when inZone == false
  DateTime? _lastZoneCheck;
  Position? _lastZoneCheckPosition;
  bool _isCheckingZone = false;

  // Map navigation trigger (for navigating to log entry coordinates)
  ({double lat, double lon})? _mapNavigationTarget;
  int _mapNavigationTrigger = 0; // Increment to trigger navigation
  bool _requestMapTabSwitch = false; // Request switch to map tab
  bool _requestErrorLogSwitch = false; // Request switch to error log tab

  // Repeater markers state
  List<Repeater> _repeaters = [];
  bool _repeatersLoaded = false;
  String? _repeatersLoadedForIata;

  // Regional channels from API (for UI display)
  List<String> _regionalChannels = [];

  AppStateProvider({required BluetoothService bluetoothService})
      : _bluetoothService = bluetoothService {
    _initialize();
  }

  // ============================================
  // Getters
  // ============================================

  String get deviceId => _deviceId;
  ConnectionStatus get connectionStatus => _connectionStatus;
  ConnectionStep get connectionStep => _connectionStep;
  String? get connectionError => _connectionError;
  bool get isAuthError => _isAuthError;
  GpsStatus get gpsStatus => _gpsStatus;
  Position? get currentPosition => _currentPosition;
  DeviceModel? get deviceModel => _deviceModel;
  String? get manufacturerString => _manufacturerString;
  String? get devicePublicKey => _devicePublicKey;
  PingStats get pingStats => _pingStats;
  bool get autoPingEnabled => _autoPingEnabled;
  AutoMode get autoMode => _autoMode;
  bool get isPingSending => _isPingSending;
  bool get isPingInProgress => _pingService?.pingInProgress ?? false;  // True during entire ping + RX window (for auto pings)
  bool get isDiscoveryListening => _pingService?.isDiscoveryListening ?? false;  // True during discovery listening window (for Passive Mode)
  /// Check if auto-ping disable is pending (waiting for RX window)
  bool get isPendingDisable => _pingService?.pendingDisable ?? false;
  int get queueSize => _queueSize;
  int? get currentNoiseFloor => _currentNoiseFloor;
  int? get currentBatteryPercent => _currentBatteryPercent;
  List<DiscoveredDevice> get discoveredDevices => _discoveredDevices;
  bool get isScanning => _isScanning;
  List<TxPing> get txPings => List.unmodifiable(_txPings);
  List<RxPing> get rxPings => List.unmodifiable(_rxPings);
  List<TxLogEntry> get txLogEntries => List.unmodifiable(_txLogEntries);
  List<RxLogEntry> get rxLogEntries => List.unmodifiable(_rxLogEntries);
  List<DiscLogEntry> get discLogEntries => List.unmodifiable(_discLogEntries);
  List<UserErrorEntry> get errorLogEntries => List.unmodifiable(_errorLogEntries);
  ({double lat, double lon})? get mapNavigationTarget => _mapNavigationTarget;
  int get mapNavigationTrigger => _mapNavigationTrigger;
  bool get requestMapTabSwitch => _requestMapTabSwitch;
  bool get requestErrorLogSwitch => _requestErrorLogSwitch;
  UserPreferences get preferences => _preferences;
  RememberedDevice? get rememberedDevice => _rememberedDevice;

  // Debug logs getters
  bool get debugLogsEnabled => _debugLogsEnabled;
  List<File> get debugLogFiles => List.unmodifiable(_debugLogFiles);
  String? get viewingLogContent => _viewingLogContent;

  // Zone state getters
  bool? get inZone => _inZone;
  Map<String, dynamic>? get currentZone => _currentZone;
  Map<String, dynamic>? get nearestZone => _nearestZone;
  bool get isCheckingZone => _isCheckingZone;
  String? get zoneName => _currentZone?['name'] as String?;
  String? get zoneCode => _currentZone?['code'] as String?;
  int? get zoneSlotsAvailable => _currentZone?['slots_available'] as int?;
  int? get zoneSlotsMax => _currentZone?['slots_max'] as int?;
  String? get nearestZoneName => _nearestZone?['name'] as String?;
  double? get nearestZoneDistanceKm => (_nearestZone?['distance_km'] as num?)?.toDouble();

  // Repeater markers getters
  List<Repeater> get repeaters => List.unmodifiable(_repeaters);

  // Regional channels getter (for UI)
  List<String> get regionalChannels => List.unmodifiable(_regionalChannels);

  bool get isConnected => _connectionStep == ConnectionStep.connected;
  bool get hasGpsLock => _gpsStatus == GpsStatus.locked;
  bool get canPing => isConnected && hasGpsLock;

  // API session permissions (from geo-auth)
  bool get txAllowed => _apiService.txAllowed;
  bool get rxAllowed => _apiService.rxAllowed;
  bool get hasApiSession => _apiService.hasSession;
  bool get isRxOnlyMode => hasApiSession && !txAllowed && rxAllowed;

  // Offline mode
  bool get offlineMode => _preferences.offlineMode;
  List<OfflineSession> get offlineSessions => _offlineSessionService.sessions;

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

  // Status message and countdown timers
  StatusMessageService get statusMessageService => _statusMessageService;
  CooldownTimer get cooldownTimer => _cooldownTimer; // Shared cooldown for TX Ping and TX/RX Auto
  AutoPingTimer get autoPingTimer => _autoPingTimer;
  RxWindowTimer get rxWindowTimer => _rxWindowTimer;
  DiscoveryWindowTimer get discoveryWindowTimer => _discoveryWindowTimer; // Discovery listening window (Passive Mode)

  // ============================================
  // Initialization
  // ============================================

  Future<void> _initialize() async {
    // Generate or load device ID
    _deviceId = const Uuid().v4();

    // Initialize services
    _apiService = ApiService();
    _apiQueueService = ApiQueueService(apiService: _apiService);

    // Set up session error callback for auto-disconnect
    _apiService.onSessionError = (reason, message) async {
      debugError('[APP] Session error from API: $reason - $message');
      await handleSessionError(reason, message);
    };
    _offlineSessionService = OfflineSessionService();
    _deviceModelService = DeviceModelService();

    // Initialize status message and countdown timers
    _statusMessageService = StatusMessageService();
    // Pass notifyListeners callback to timers for smooth UI updates
    _cooldownTimer = CooldownTimer(_statusMessageService, onUpdate: notifyListeners);
    _autoPingTimer = AutoPingTimer(_statusMessageService, onUpdate: notifyListeners);
    _rxWindowTimer = RxWindowTimer(_statusMessageService, onUpdate: notifyListeners);
    _discoveryWindowTimer = DiscoveryWindowTimer(_statusMessageService, onUpdate: notifyListeners);

    // Auto-enable debug logging for development builds
    await _autoEnableDebugLogsIfDevelopmentBuild();

    // Initialize channel service with Public channel only (regional channels added after auth)
    await ChannelService.initializePublicChannel();
    debugLog('[APP] Channel service initialized (Public channel only)');

    // Initialize API queue
    await _apiQueueService.init();
    _apiQueueService.onQueueUpdated = (size) {
      _queueSize = size;
      notifyListeners();

      // Update background service notification with queue size
      if (_autoPingEnabled) {
        final modeName = _autoMode == AutoMode.rxOnly ? 'RX Auto' : 'TX/RX Auto';
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
      debugLog('[APP] Upload success: +$uploadedCount items (total: ${_pingStats.successfulUploads})');
      notifyListeners();
    };

    // Initialize offline session service
    await _offlineSessionService.init();
    _offlineSessionService.onSessionsUpdated = (sessions) {
      notifyListeners();
    };

    // Load device models
    await _deviceModelService.loadModels();

    // Load remembered device (mobile only)
    await _loadRememberedDevice();

    // Load user preferences
    await _loadPreferences();

    // Set device ID for API
    _apiService.setDeviceId(_deviceId);

    // Listen to Bluetooth connection changes
    _bluetoothService.connectionStream.listen((status) {
      _connectionStatus = status;
      if (status == ConnectionStatus.disconnected) {
        _connectionStep = ConnectionStep.disconnected;
        _meshCoreConnection?.dispose();
        _meshCoreConnection = null;
        _pingService?.dispose();
        _pingService = null;
      }
      notifyListeners();
    });

    // Listen to GPS changes
    _gpsService.statusStream.listen((status) {
      _gpsStatus = status;
      notifyListeners();
    });

    _gpsService.positionStream.listen((position) async {
      _currentPosition = position;
      notifyListeners();

      // Check zone on first GPS lock (when _inZone is null)
      // Skip zone checks when offline mode is enabled
      if (_inZone == null && !_preferences.offlineMode) {
        debugLog('[GEOFENCE] First GPS lock, checking zone status');
        await checkZoneStatus();
      }

      // Check zone every 100m movement (while disconnected)
      // This allows users to know if they've entered/exited a zone while moving
      // Skip zone checks when offline mode is enabled
      if (!isConnected && !_preferences.offlineMode && _shouldRecheckZone(position)) {
        debugLog('[GEOFENCE] Moved 100m+ while disconnected, rechecking zone');
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

    // Start GPS (may skip if permissions not yet granted - disclosure flow handles that)
    await _gpsService.startWatching();

    notifyListeners();
  }

  /// Restart GPS service after permission disclosure is accepted
  /// Called from MainScaffold after user grants location permission
  Future<void> restartGpsAfterPermission() async {
    debugLog('[APP] Restarting GPS after permission granted');
    await _gpsService.startWatching();
    notifyListeners();
  }

  // ============================================
  // Bluetooth Scanning
  // ============================================

  /// Start scanning for MeshCore devices
  Future<void> startScan() async {
    if (_isScanning) return;

    // Check permissions
    try {
      final hasPermission = await _bluetoothService.requestPermissions();
      if (!hasPermission) {
        _connectionError = 'Bluetooth permissions not granted';
        notifyListeners();
        return;
      }
    } on BlePermissionDeniedException catch (e) {
      // Permissions are permanently denied - user must enable in Settings
      _connectionError = e.message;
      notifyListeners();
      return;
    }

    // Check if Bluetooth is available
    if (!await _bluetoothService.isAvailable()) {
      _connectionError = 'Bluetooth not available';
      notifyListeners();
      return;
    }

    // Check if Bluetooth is enabled (with retry for iOS permission race condition)
    // After granting Bluetooth permission on iOS, there's a brief delay before
    // the adapter state updates. Retry a few times to handle this.
    bool isEnabled = await _bluetoothService.isEnabled();
    if (!isEnabled) {
      debugLog('[BLE] Bluetooth not enabled, retrying...');
      for (int i = 0; i < 3 && !isEnabled; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        isEnabled = await _bluetoothService.isEnabled();
        debugLog('[BLE] Retry ${i + 1}: isEnabled=$isEnabled');
      }
    }
    if (!isEnabled) {
      _connectionError = 'Bluetooth is disabled. Please enable Bluetooth and try again.';
      notifyListeners();
      return;
    }

    _isScanning = true;
    _discoveredDevices = [];
    _connectionError = null;
    _isAuthError = false;
    notifyListeners();

    // Listen for discovered devices
    DiscoveredDevice? selectedDevice;
    await for (final device in _bluetoothService.scanForDevices(
      timeout: const Duration(seconds: 15),
    )) {
      if (!_discoveredDevices.any((d) => d.id == device.id)) {
        _discoveredDevices.add(device);
        selectedDevice = device;
        notifyListeners();
      }
    }

    _isScanning = false;
    notifyListeners();

    // On web platform, the Chrome BLE picker already handles device selection,
    // so auto-connect immediately after the picker returns (no second click needed)
    if (kIsWeb && selectedDevice != null) {
      debugLog('[APP] Web platform: auto-connecting to selected device');
      await connectToDevice(selectedDevice);
    }
  }

  /// Stop scanning for devices
  Future<void> stopScan() async {
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
      // Skip auth when offline mode is enabled
      if (!_preferences.offlineMode) {
        _meshCoreConnection!.onRequestAuth = () async {
          final publicKey = _meshCoreConnection!.devicePublicKey;
          if (publicKey == null) {
            debugError('[APP] Cannot request auth: no public key');
            return {'success': false, 'reason': 'no_public_key', 'message': 'Device public key not available'};
          }

          debugLog('[APP] Requesting API auth with public key: ${publicKey.substring(0, 16)}...');
          // Strip "MeshCore-" prefix from device name for API
          final deviceName = connectedDeviceName?.replaceFirst('MeshCore-', '') ?? 'GOME-WarDriver';
          return await _apiService.requestAuth(
            reason: 'connect',
            publicKey: publicKey,
            who: deviceName,
            appVersion: _appVersion,
            power: _preferences.powerLevel,  // Send wattage (0.3, 1.0, 2.0) to match WebClient
            iataCode: _preferences.iataCode,
            model: _meshCoreConnection!.deviceModel?.manufacturer ?? _meshCoreConnection!.deviceInfo?.manufacturer ?? 'Unknown',
            lat: _currentPosition?.latitude,
            lon: _currentPosition?.longitude,
            accuracyMeters: _currentPosition?.accuracy,
          );
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
          _deviceModel = _meshCoreConnection!.deviceModel;
          _devicePublicKey = _meshCoreConnection!.devicePublicKey;
          debugLog('[APP] Device public key stored: ${_devicePublicKey?.substring(0, 16) ?? 'null'}...');
        }
        notifyListeners();
      });

      // Listen for noise floor updates
      _noiseFloorSubscription = _meshCoreConnection!.noiseFloorStream.listen((noiseFloor) {
        _currentNoiseFloor = noiseFloor;
        notifyListeners();
      });

      // Listen for battery updates
      _batterySubscription = _meshCoreConnection!.batteryStream.listen((batteryPercent) {
        _currentBatteryPercent = batteryPercent;
        notifyListeners();
      });

      // Execute connection workflow
      final connectionResult = await _meshCoreConnection!.connect(
        device.id,
        _deviceModelService.models,
      );

      // Update preferences if auto-power was configured
      if (connectionResult.autoPowerConfigured && connectionResult.deviceModel != null) {
        final device = connectionResult.deviceModel!;
        _preferences = _preferences.copyWith(
          powerLevel: device.power,
          txPower: device.txPower,
          autoPowerSet: true,
        );
        // TODO: Persist to SharedPreferences when implemented
        notifyListeners();
        _statusMessageService.setDynamicStatus(
          'Power auto-configured: ${device.power}W (${device.shortName})',
          StatusColor.info,
        );
        debugLog('[APP] Auto-power preferences updated: ${device.power}W/${device.txPower}dBm');
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
        final allowedChannelsData = ChannelService.getAllowedChannelsForValidator();
        final allowedChannels = <int, ChannelInfo>{};
        for (final entry in allowedChannelsData.entries) {
          allowedChannels[entry.key] = ChannelInfo(
            channelName: entry.value.channelName,
            key: entry.value.key,
            hash: entry.value.hash,
          );
        }
        final newValidator = PacketValidator(allowedChannels: allowedChannels);
        _unifiedRxHandler!.updateValidator(newValidator);
        debugLog('[APP] PacketValidator updated with ${allowedChannels.length} channels: '
            '${allowedChannelsData.values.map((c) => c.channelName).join(', ')}');
      }

      // Create ping service with wakelock (create new instance per connection)
      _pingService = PingService(
        gpsService: _gpsService,
        connection: _meshCoreConnection!,
        apiQueue: _apiQueueService,
        wakelockService: WakelockService(),
        cooldownTimer: _cooldownTimer,
        rxWindowTimer: _rxWindowTimer,
        discoveryWindowTimer: _discoveryWindowTimer,
        deviceId: _deviceId,
        txTracker: _txTracker,
      );

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
        return _preferences.autoPowerSet || _preferences.powerLevelSet || _deviceModel != null;
      };

      _pingService!.onTxPing = (ping) {
        _txPings.add(ping);

        // Add TX log entry (power in watts from preferences)
        _txLogEntries.add(TxLogEntry(
          timestamp: ping.timestamp,
          latitude: ping.latitude,
          longitude: ping.longitude,
          power: _preferences.powerLevel, // Watts (0.3, 0.6, 1.0, 2.0)
          events: [], // Will be updated when RX responses come in
        ));

        notifyListeners();
      };

      _pingService!.onRxPing = (ping) {
        _rxPings.add(ping);

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
          final modeName = _autoMode == AutoMode.rxOnly ? 'RX Auto' : 'TX/RX Auto';
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
        debugLog('[APP] Real-time echo: ${repeater.repeaterId} (SNR: ${repeater.snr}, isNew: $isNew)');
        debugLog('[APP] TxLogEntries count: ${_txLogEntries.length}');

        // Find the matching TxLogEntry and update its events
        if (_txLogEntries.isNotEmpty) {
          final lastEntry = _txLogEntries.last;
          // Verify it's the right entry by timestamp (should be within a few seconds)
          final timeDiff = lastEntry.timestamp.difference(txPing.timestamp).inSeconds.abs();
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
            } else {
              // Update existing event's SNR
              final idx = existingEvents.indexWhere((e) => e.repeaterId == repeater.repeaterId);
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
            debugLog('[APP] Updated TxLogEntry with ${existingEvents.length} events (real-time)');
            debugLog('[APP] Calling notifyListeners() to update UI');
            notifyListeners();
            debugLog('[APP] notifyListeners() completed');
          } else {
            debugLog('[APP] Timestamp mismatch: lastEntry=${lastEntry.timestamp}, txPing=${txPing.timestamp}, diff=${timeDiff}s');
          }
        } else {
          debugLog('[APP] WARNING: _txLogEntries is empty, cannot update');
        }
      };

      // Wire up auto ping scheduled callback for countdown display
      _pingService!.onAutoPingScheduled = (intervalMs, skipReason) {
        _autoPingTimer.startWithSkipReason(intervalMs, skipReason);
      };

      // Wire up discovery complete callback for RX Auto mode
      _pingService!.onDiscoveryComplete = (entry) {
        _addDiscLogEntry(entry);
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

        // Disable heartbeat
        _apiService.disableHeartbeat();

        // Update local state
        _autoPingEnabled = false;

        debugLog('[APP] Pending disable cleanup complete, cooldown running');
        notifyListeners();
      };

      // Save this device for quick reconnection (mobile only)
      await _saveRememberedDevice(device);

      // Show connection status based on TX/RX permissions
      if (hasApiSession) {
        if (txAllowed && rxAllowed) {
          _statusMessageService.setDynamicStatus(
            'Connected - Full Access',
            StatusColor.success,
          );
          debugLog('[APP] Connected with full access (TX + RX allowed)');
        } else if (rxAllowed) {
          _statusMessageService.setDynamicStatus(
            'Connected - RX Only (zone at TX capacity)',
            StatusColor.warning,
          );
          debugLog('[APP] Connected with RX-only access (TX not allowed)');
        } else {
          _statusMessageService.setDynamicStatus(
            'Connected - Limited Access',
            StatusColor.warning,
          );
          debugLog('[APP] Connected with limited access');
        }
      } else {
        // No API session - offline mode or auth skipped
        _statusMessageService.setDynamicStatus(
          'Connected - Offline Mode',
          StatusColor.info,
        );
        debugLog('[APP] Connected without API session');
      }

      // Check ping validation and warn about configuration issues
      // This helps users understand why buttons might be disabled after connection
      final validation = pingValidation;
      if (validation != PingValidation.valid) {
        debugLog('[APP] Ping validation after connect: $validation');
        // Show configuration warnings that require user action (delayed to not override connection status)
        Future.delayed(const Duration(seconds: 3), () {
          // Re-check validation in case user configured during the delay
          final currentValidation = pingValidation;
          if (_connectionStep == ConnectionStep.connected) {
            if (currentValidation == PingValidation.externalAntennaRequired) {
              _statusMessageService.setDynamicStatus(
                'Select antenna option before pinging',
                StatusColor.warning,
              );
            } else if (currentValidation == PingValidation.powerLevelRequired) {
              _statusMessageService.setDynamicStatus(
                'Set power level before pinging',
                StatusColor.warning,
              );
            }
          }
        });
      }

    } catch (e) {
      debugError('[APP] Connection failed: $e');

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
          _connectionError = _getErrorMessage(reason, null);
        } else {
          _connectionError = 'Authentication failed';
        }
      } else {
        _isAuthError = false;
        _connectionError = errorStr.replaceFirst('Exception: ', '');
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

    // Create RX logger (stored for use when enabling RX Auto mode)
    _rxLogger = RxLogger(
      // Function to check if repeater should be ignored (carpeater filter)
      shouldIgnoreRepeater: (String repeaterId) {
        // Check user preferences for ignored repeater ID
        final prefs = _preferences;
        if (prefs.ignoreCarpeater && prefs.ignoreRepeaterId != null) {
          // Case-insensitive comparison (both uppercase)
          final ignored = prefs.ignoreRepeaterId!.toUpperCase();
          final current = repeaterId.toUpperCase();
          return current == ignored;
        }
        return false;
      },
      // Immediate observation callback - fires when packet is first validated
      // Creates pin IMMEDIATELY for NEW repeaters (first time in current batch)
      onObservation: (observation) {
        try {
          debugLog('[APP] Immediate RX observation: repeater=${observation.repeaterId}, '
              'snr=${observation.snr}, location=${observation.lat.toStringAsFixed(5)},${observation.lon.toStringAsFixed(5)}');

          // Log current batch tracking state for debugging
          debugLog('[APP] Current batch tracking: ${_currentBatchRepeaters.length} repeaters: $_currentBatchRepeaters');

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
              snr: observation.snr,
              rssi: observation.rssi,
            );
            _rxPings.add(rxPing);
            _currentBatchRepeaters.add(repeaterKey);

            // Increment RX count immediately when pin is created (not on batch flush)
            _pingStats = _pingStats.copyWith(rxCount: _pingStats.rxCount + 1);

            debugLog('[APP] Created IMMEDIATE RX pin for repeater: ${observation.repeaterId} '
                'at ${observation.lat.toStringAsFixed(5)},${observation.lon.toStringAsFixed(5)} '
                '(batch tracking: ${_currentBatchRepeaters.length} repeaters, rxCount: ${_pingStats.rxCount})');
            notifyListeners();
          } else {
            debugLog('[APP] Repeater ${observation.repeaterId} already has pin in current batch, SNR will update on flush if better');
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
          debugLog('[APP] Finalized RX entry (best SNR): repeater=${entry.repeaterId}, '
              'snr=${entry.snr}, location=${entry.lat.toStringAsFixed(5)},${entry.lon.toStringAsFixed(5)}');

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
            if (entry.snr > existingPin.snr) {
              _rxPings[lastPinIndex] = RxPing(
                latitude: existingPin.latitude,   // KEEP batch start location
                longitude: existingPin.longitude, // KEEP batch start location
                repeaterId: entry.repeaterId,
                timestamp: entry.timestamp,
                snr: entry.snr,                   // UPDATE to best SNR from batch
                rssi: entry.rssi,
              );
              debugLog('[APP] Updated RX pin SNR for repeater=${entry.repeaterId}: '
                  '${existingPin.snr.toStringAsFixed(2)} -> ${entry.snr.toStringAsFixed(2)}');
            } else {
              debugLog('[APP] RX pin SNR unchanged for repeater=${entry.repeaterId}: '
                  'batch best ${entry.snr.toStringAsFixed(2)} <= pin ${existingPin.snr.toStringAsFixed(2)}');
            }
          } else {
            // Edge case: pin not found (should have been created in onObservation)
            final newRxPing = RxPing(
              latitude: entry.lat,
              longitude: entry.lon,
              repeaterId: entry.repeaterId,
              timestamp: entry.timestamp,
              snr: entry.snr,
              rssi: entry.rssi,
            );
            _rxPings.add(newRxPing);
            debugLog('[APP] Created FALLBACK RX pin for repeater=${entry.repeaterId} '
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
          debugLog('[APP] Added RX log entry: repeater=${entry.repeaterId}, '
              'snr=${entry.snr}, pathLen=${entry.pathLength}');

          // Note: RX count is incremented in onObservation when pin is created (immediate feedback)

          // Enqueue to API with formatted heard_repeats string
          // Format: "repeaterId(snr)" e.g. "4e(12.25)"
          final heardRepeats = '${entry.repeaterId}(${entry.snr.toStringAsFixed(2)})';
          await _apiQueueService.enqueueRx(
            latitude: entry.lat,
            longitude: entry.lon,
            heardRepeats: heardRepeats,
            timestamp: entry.timestamp.millisecondsSinceEpoch ~/ 1000,
            repeaterId: entry.repeaterId,
            noiseFloor: _meshCoreConnection?.lastNoiseFloor,
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
    debugLog('[APP] PacketValidator configured with ${allowedChannels.length} channels: '
        '${allowedChannelsData.values.map((c) => c.channelName).join(', ')}');
    final validator = PacketValidator(allowedChannels: allowedChannels);
    
    // Create unified handler
    _unifiedRxHandler = UnifiedRxHandler(
      txTracker: _txTracker!,
      rxLogger: _rxLogger!,
      validator: validator,
    );
    
    // Subscribe to LogRxData stream
    _logRxDataSubscription = _meshCoreConnection!.logRxDataStream.listen((data) {
      _unifiedRxHandler!.handlePacket(data.raw, data.snr, data.rssi);
    });
    
    // Start listening
    _unifiedRxHandler!.startListening();
    
    debugLog('[APP] Unified RX handler created and listening');
  }

  /// Disconnect from current device
  Future<void> disconnect() async {
    // Disable heartbeat immediately on disconnect
    _apiService.disableHeartbeat();

    // Stop auto-ping if running (before releasing session)
    if (_autoPingEnabled) {
      await _pingService?.forceDisableAutoPing();
      _autoPingEnabled = false;
    }

    // Stop background service
    await BackgroundServiceManager.stopService();

    // Stop all countdown timers
    _cooldownTimer.stop();
    _autoPingTimer.stop();
    _rxWindowTimer.stop();

    // Stop RX wardriving if active (flushes batches to queue)
    _rxLogger?.stopWardriving(trigger: 'disconnect');

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

    // Delete wardriving channel FIRST, while BLE connection is still active
    // This prevents "GATT Server is disconnected" errors
    await _meshCoreConnection?.deleteWardrivingChannelEarly();

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
    _devicePublicKey = null;
    _currentNoiseFloor = null;
    _currentBatteryPercent = null;

    // Clear regional channels (keeps only Public)
    ChannelService.clearRegionalChannels();
    _regionalChannels = [];

    // Clear discovered devices so user must scan fresh
    _discoveredDevices = [];

    notifyListeners();
  }

  // ============================================
  // Ping Controls
  // ============================================

  /// Get current ping validation status
  PingValidation get pingValidation {
    return _pingService?.canPing() ?? PingValidation.notConnected;
  }

  /// Get auto mode validation status (excludes distance check)
  /// Allows starting auto mode while stationary - pings will be skipped until user moves
  PingValidation get autoModeValidation {
    return _pingService?.canStartAutoMode() ?? PingValidation.notConnected;
  }

  /// Send a manual TX ping
  Future<bool> sendPing() async {
    if (_pingService == null) return false;

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

  /// Toggle auto-ping mode (TX/RX or RX-only)
  /// Returns false if blocked by cooldown (TX/RX Auto only - RX Auto ignores cooldown)
  Future<bool> toggleAutoPing(AutoMode mode) async {
    if (_pingService == null) return false;

    final isRxOnly = mode == AutoMode.rxOnly;

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

      // Disable heartbeat when stopping auto mode
      _apiService.disableHeartbeat();

      _autoPingEnabled = false;

      // Start 7-second shared cooldown ONLY for TX/RX Auto (not RX Auto)
      // RX Auto is passive listening, no cooldown needed
      if (!isRxOnly) {
        _cooldownTimer.start(7000);
        debugLog('[PING] Shared cooldown started (7s) - blocks TX Ping and TX/RX Auto');
      } else {
        debugLog('[RX AUTO] Stopped - no cooldown (passive mode)');
      }
    } else {
      // Block starting if shared cooldown is active (TX/RX Auto only)
      // RX Auto is passive listening and can start during cooldown
      if (!isRxOnly && _cooldownTimer.isRunning) {
        debugLog('[PING] TX/RX Auto start blocked by shared cooldown');
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
        // Save offline session if offline mode is enabled
        if (_preferences.offlineMode) {
          await _saveOfflineSession();
        }
      }

      // Start new mode
      debugLog('[PING] Starting auto mode: ${mode.name}');
      _autoMode = mode;

      // Set interval from user preferences before starting
      final intervalMs = _preferences.autoPingInterval * 1000;
      _pingService!.setAutoPingInterval(intervalMs);
      debugLog('[PING] Using interval from preferences: ${_preferences.autoPingInterval}s (${intervalMs}ms)');

      final started = await _pingService!.enableAutoPing(rxOnly: isRxOnly);
      if (!started) {
        // Blocked by cooldown or already enabled
        debugLog('[PING] Auto mode start blocked');
        if (_pingService!.isInCooldown()) {
          _statusMessageService.setDynamicStatus(
            'Wait ${_pingService!.getRemainingCooldownSeconds()}s before starting auto mode',
            StatusColor.warning,
          );
        }
        return false;
      }
      // Start RX wardriving for both TX/RX Auto and RX Auto modes
      // Reference: state.rxTracking.isWardriving = true in wardrive.js
      _rxLogger?.startWardriving();
      _autoPingEnabled = true;

      // Enable heartbeat if not in offline mode
      // Heartbeat fires after 3 minutes of API inactivity to keep session alive
      if (!_preferences.offlineMode) {
        _apiService.enableHeartbeat(
          gpsProvider: () {
            // Provide current GPS coordinates for heartbeat (matching wardrive.js)
            final pos = _gpsService?.lastPosition;
            if (pos == null) return null;
            return (lat: pos.latitude, lon: pos.longitude);
          },
        );
      }

      // Start background service for continuous operation
      final modeName = isRxOnly ? 'RX Auto' : 'TX/RX Auto';
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
    _pingService?.resetStats();
    notifyListeners();
  }

  /// Clear log entries
  void clearLogs() {
    _txLogEntries.clear();
    _rxLogEntries.clear();
    _discLogEntries.clear();
    _errorLogEntries.clear();
    notifyListeners();
  }

  /// Add a discovery log entry (from RX Auto mode)
  void _addDiscLogEntry(DiscLogEntry entry) {
    _discLogEntries.insert(0, entry);
    // Keep max 100 entries
    if (_discLogEntries.length > 100) {
      _discLogEntries.removeLast();
    }
    debugLog('[APP] Discovery log entry added: ${entry.nodeCount} nodes discovered');
    notifyListeners();
  }

  /// Log a user-facing error message
  void logError(String message, {ErrorSeverity severity = ErrorSeverity.error}) {
    _errorLogEntries.add(UserErrorEntry(
      timestamp: DateTime.now(),
      message: message,
      severity: severity,
    ));
    _requestErrorLogSwitch = true; // Auto-switch to error log
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
  /// Returns false if offline mode cannot be changed (e.g., while connected)
  bool setOfflineMode(bool enabled) {
    // Cannot change offline mode while connected
    if (isConnected) {
      debugLog('[APP] Cannot change offline mode while connected');
      return false;
    }

    _preferences = _preferences.copyWith(offlineMode: enabled);
    _apiQueueService.offlineMode = enabled;
    debugLog('[APP] Offline mode ${enabled ? 'enabled' : 'disabled'}');

    if (enabled) {
      // Clear zone data when entering offline mode
      _inZone = null;
      _currentZone = null;
      _nearestZone = null;
      _lastZoneCheck = null;
      _lastZoneCheckPosition = null;
      debugLog('[GEOFENCE] Cleared zone data for offline mode');
    } else {
      // Re-check zone status when exiting offline mode
      if (_currentPosition != null) {
        debugLog('[GEOFENCE] Re-checking zone status after offline mode disabled');
        checkZoneStatus();
      }
    }

    notifyListeners();
    return true;
  }

  /// Save accumulated offline pings to a session file
  Future<void> _saveOfflineSession() async {
    final pings = _apiQueueService.getAndClearOfflinePings();
    if (pings.isEmpty) {
      debugLog('[APP] No offline pings to save');
      return;
    }

    // Include device info for auth during upload
    await _offlineSessionService.saveSession(
      pings,
      devicePublicKey: _devicePublicKey,
      deviceName: connectedDeviceName?.replaceFirst('MeshCore-', ''),
    );
    debugLog('[APP] Saved offline session with ${pings.length} pings');
    notifyListeners();
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
      final success = await _apiService.uploadBatch(pings);
      if (success) {
        // Delete the session file on successful upload
        await _offlineSessionService.deleteSession(filename);
        debugLog('[APP] Uploaded and deleted offline session: $filename');
        _statusMessageService.setDynamicStatus(
          'Uploaded ${pings.length} pings from $filename',
          StatusColor.success,
        );
      } else {
        debugLog('[APP] Failed to upload offline session: $filename');
        _statusMessageService.setDynamicStatus(
          'Failed to upload $filename',
          StatusColor.error,
        );
      }
      notifyListeners();
      return success;
    } catch (e) {
      debugLog('[APP] Error uploading offline session: $e');
      _statusMessageService.setDynamicStatus(
        'Error uploading $filename',
        StatusColor.error,
      );
      return false;
    }
  }

  /// Upload an offline session with authenticated API session
  /// Uses stored device credentials to authenticate before uploading
  ///
  /// Returns the result of the upload operation
  Future<OfflineUploadResult> uploadOfflineSessionWithAuth(String filename) async {
    // 1. Get session with stored device credentials
    final session = _offlineSessionService.getSession(filename);
    if (session == null) {
      debugLog('[APP] Offline session not found: $filename');
      return OfflineUploadResult.notFound;
    }

    // Check if session has pings
    final sessionData = session.data;
    final pings = (sessionData['pings'] as List<dynamic>?)
        ?.map((p) => Map<String, dynamic>.from(p as Map))
        .toList();

    if (pings == null || pings.isEmpty) {
      debugLog('[APP] Offline session has no pings: $filename');
      return OfflineUploadResult.invalidSession;
    }

    // 2. Get device credentials from session
    final publicKey = session.devicePublicKey;
    if (publicKey == null) {
      debugLog('[APP] Offline session missing device public key: $filename');
      return OfflineUploadResult.invalidSession;
    }

    // 3. Authenticate with offline_mode: true
    debugLog('[APP] Authenticating for offline upload with device: ${session.deviceName ?? "unknown"}');
    final authResult = await _apiService.requestAuth(
      reason: 'connect',
      publicKey: publicKey,
      who: session.deviceName ?? 'GOME-WarDriver',
      appVersion: _appVersion,
      power: _preferences.powerLevel,
      iataCode: _preferences.iataCode,
      model: 'Offline Upload',
      lat: _currentPosition?.latitude,
      lon: _currentPosition?.longitude,
      accuracyMeters: _currentPosition?.accuracy,
      offlineMode: true,
    );

    if (authResult == null || authResult['success'] != true) {
      final reason = authResult?['reason'] as String? ?? 'unknown';
      debugLog('[APP] Offline upload auth failed: $reason');
      _statusMessageService.setDynamicStatus(
        'Auth failed: $reason',
        StatusColor.error,
      );
      return OfflineUploadResult.authFailed;
    }

    debugLog('[APP] Offline upload authenticated, session: ${authResult['session_id']}');

    // Delay after auth before posting
    await Future.delayed(const Duration(seconds: 1));

    // 4. Upload pings in batches of 50
    const batchSize = 50;
    var uploadedCount = 0;
    var failedBatches = 0;

    for (var i = 0; i < pings.length; i += batchSize) {
      final batch = pings.skip(i).take(batchSize).toList();
      final success = await _apiService.uploadBatch(batch);
      if (success) {
        uploadedCount += batch.length;
        debugLog('[APP] Uploaded batch ${(i ~/ batchSize) + 1}: ${batch.length} pings');
      } else {
        failedBatches++;
        debugError('[APP] Failed to upload batch ${(i ~/ batchSize) + 1}');
      }
    }

    // Delay after posting before disconnect
    await Future.delayed(const Duration(seconds: 1));

    // 5. Release API session
    await _apiService.requestAuth(
      reason: 'disconnect',
      publicKey: publicKey,
    );
    debugLog('[APP] Offline upload session released');

    // 6. Mark session as uploaded (don't delete) if all batches succeeded
    if (failedBatches == 0) {
      await _offlineSessionService.markAsUploaded(filename);
      _statusMessageService.setDynamicStatus(
        'Uploaded ${pings.length} pings from $filename',
        StatusColor.success,
      );
      notifyListeners();
      return OfflineUploadResult.success;
    } else {
      _statusMessageService.setDynamicStatus(
        'Partial upload: $uploadedCount/${pings.length} pings',
        StatusColor.warning,
      );
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
    debugLog('[APP] Preferences updated: externalAntennaSet=${preferences.externalAntennaSet}, '
        'externalAntenna=${preferences.externalAntenna}, autoPowerSet=${preferences.autoPowerSet}');
    _preferences = preferences;
    notifyListeners();
    _savePreferences();
  }

  /// Set developer mode (unlocked by tapping version 7 times)
  void setDeveloperMode(bool enabled) {
    _preferences = _preferences.copyWith(developerModeEnabled: enabled);
    debugLog('[APP] Developer mode ${enabled ? 'enabled' : 'disabled'}');
    notifyListeners();
    _savePreferences();
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
      default:
        return serverMessage ?? 'Unknown error occurred.';
    }
  }

  /// Handle auth error response and show appropriate status
  void _handleAuthError(Map<String, dynamic> result) {
    final reason = result['reason'] as String?;
    final message = result['message'] as String?;
    final userMessage = _getErrorMessage(reason, message);

    // Special handling for zone_full - this is actually a partial success
    if (reason == 'zone_full') {
      _statusMessageService.setDynamicStatus(userMessage, StatusColor.warning);
      debugLog('[API] Auth returned zone_full - RX-only mode allowed');
      return;
    }

    // Special case: outofdate is a critical error requiring app update
    if (reason == 'outofdate') {
      _statusMessageService.setPersistentError(userMessage, StatusColor.error);
      debugLog('[API] App version outdated - update required');
      return;
    }

    // Log error and add to error log
    debugError('[API] Auth error: $reason - $userMessage');
    logError(userMessage, severity: ErrorSeverity.error);

    // Show persistent error for zone-related issues
    if (reason == 'outside_zone' || reason == 'zone_disabled') {
      _statusMessageService.setPersistentError(userMessage, StatusColor.error);
    } else {
      _statusMessageService.setDynamicStatus(userMessage, StatusColor.error);
    }
  }

  /// Handle session error from wardrive/heartbeat API calls
  /// This may trigger auto-disconnect
  Future<void> handleSessionError(String? reason, String? message) async {
    final userMessage = _getErrorMessage(reason, message);
    debugError('[API] Session error: $reason - $userMessage');

    // Rate limiting should warn but not disconnect (per PORTED_APP behavior)
    if (reason == 'rate_limited') {
      _statusMessageService.setDynamicStatus(userMessage, StatusColor.warning);
      debugLog('[API] Rate limited - continuing without disconnect');
      return;
    }

    // Show error message
    _statusMessageService.setDynamicStatus(userMessage, StatusColor.error);
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
    };

    // Handle errors that require disconnect
    if (sessionErrors.contains(reason) ||
        authErrors.contains(reason) ||
        zoneErrors.contains(reason)) {
      debugLog('[API] Session error requires disconnect: $reason');
      // Don't call requestAuth disconnect - session is already invalid on server
      // Just cleanup locally and disconnect
      await disconnect();
    }
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
  ({bool isValid, String? errorMessage, String? errorCode}) _validateGps(Position? position) {
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
        errorMessage: 'GPS data is ${ageSeconds}s old (max ${_maxGpsAgeSeconds}s)',
        errorCode: 'gps_stale',
      );
    }

    // Check accuracy
    if (position.accuracy > _maxGpsAccuracyMeters) {
      return (
        isValid: false,
        errorMessage: 'GPS accuracy is ${position.accuracy.toStringAsFixed(0)}m (max ${_maxGpsAccuracyMeters.toStringAsFixed(0)}m)',
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

  /// Check zone status via API
  /// Should be called on app launch and every 100m of GPS movement while disconnected
  Future<void> checkZoneStatus() async {
    if (_currentPosition == null) {
      debugLog('[GEOFENCE] Cannot check zone status: no GPS position');
      return;
    }

    if (_isCheckingZone) {
      debugLog('[GEOFENCE] Zone check already in progress');
      return;
    }

    _isCheckingZone = true;
    notifyListeners();

    try {
      debugLog('[GEOFENCE] Checking zone status at ${_currentPosition!.latitude.toStringAsFixed(5)}, ${_currentPosition!.longitude.toStringAsFixed(5)}');

      final result = await _apiService.checkZoneStatus(
        lat: _currentPosition!.latitude,
        lon: _currentPosition!.longitude,
        accuracyMeters: _currentPosition!.accuracy,
        appVersion: _appVersion,
      );

      if (result == null) {
        debugError('[GEOFENCE] Zone status check failed: no response');
        _statusMessageService.setDynamicStatus('Zone check failed', StatusColor.error);
        return;
      }

      _lastZoneCheck = DateTime.now();
      _lastZoneCheckPosition = _currentPosition;

      final success = result['success'] == true;
      if (!success) {
        debugError('[GEOFENCE] Zone status check failed: ${result['message']}');
        _statusMessageService.setDynamicStatus('Zone check failed', StatusColor.error);
        return;
      }

      _inZone = result['in_zone'] == true;

      if (_inZone!) {
        _currentZone = result['zone'] as Map<String, dynamic>?;
        _nearestZone = null;
        final zoneName = _currentZone?['name'] ?? 'Unknown';
        final zoneCode = _currentZone?['code'] as String? ?? '';
        debugLog('[GEOFENCE] In zone: $zoneName ($zoneCode)');
        _statusMessageService.setDynamicStatus('Zone: $zoneName ($zoneCode)', StatusColor.success);

        // Fetch repeaters for this zone
        if (zoneCode.isNotEmpty) {
          await _fetchRepeatersForZone(zoneCode);
        }
      } else {
        _currentZone = null;
        _nearestZone = result['nearest_zone'] as Map<String, dynamic>?;
        final nearestName = _nearestZone?['name'] ?? 'Unknown';
        final distanceKm = (_nearestZone?['distance_km'] as num?)?.toStringAsFixed(1) ?? '?';
        debugLog('[GEOFENCE] Outside zone. Nearest: $nearestName (${distanceKm}km away)');
        _statusMessageService.setPersistentError(
          'Outside zone. Nearest: $nearestName (${distanceKm}km)',
          StatusColor.warning,
        );

        // Clear repeaters when exiting zone
        _repeaters = [];
        _repeatersLoaded = false;
        _repeatersLoadedForIata = null;
      }
    } catch (e) {
      debugError('[GEOFENCE] Zone status check error: $e');
      _statusMessageService.setDynamicStatus('Zone check error', StatusColor.error);
    } finally {
      _isCheckingZone = false;
      notifyListeners();
    }
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
      _repeaters = fetchedRepeaters;
      _repeatersLoaded = true;
      _repeatersLoadedForIata = iata;
      debugLog('[MAP] Loaded ${_repeaters.length} repeaters for zone $iata');
      notifyListeners();
    } catch (e) {
      debugError('[MAP] Failed to fetch repeaters: $e');
    }
  }

  // ============================================
  // Debug File Logging (Mobile Only)
  // ============================================

  /// Auto-enable debug file logging for development builds
  Future<void> _autoEnableDebugLogsIfDevelopmentBuild() async {
    if (kIsWeb) return; // File logging not available on web

    if (AppConstants.isDevelopmentBuild) {
      debugLog('[INIT] Development build detected (${AppConstants.appVersion}), auto-enabling debug logs');
      try {
        await DebugFileLogger.enable();
        _debugLogsEnabled = true;
        await _refreshDebugLogFiles();
      } catch (e) {
        debugError('[INIT] Failed to auto-enable debug logs: $e');
      }
    } else {
      debugLog('[INIT] Release build (${AppConstants.appVersion}), debug logs disabled by default');
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
      notifyListeners();
      debugLog('[DEBUG] Debug file logging enabled');
    } catch (e) {
      debugError('[DEBUG] Failed to enable debug file logging: $e');
      _statusMessageService.setDynamicStatus(
        'Failed to enable debug logging',
        StatusColor.error,
      );
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

  /// Delete all debug log files
  ///
  /// Disables logging if active, then deletes all log files.
  Future<void> deleteAllDebugLogs() async {
    debugLog('[DEBUG] Deleting all debug logs');
    try {
      await DebugFileLogger.deleteAll();
      await _refreshDebugLogFiles();
      _statusMessageService.setDynamicStatus(
        'All debug logs deleted',
        StatusColor.info,
      );
    } catch (e) {
      debugError('[DEBUG] Failed to delete all debug logs: $e');
      _statusMessageService.setDynamicStatus(
        'Failed to delete debug logs',
        StatusColor.error,
      );
    }
  }

  /// Share a debug log file
  ///
  /// Uses the native share sheet to allow users to share logs via email, messaging, etc.
  Future<void> shareDebugLog(File file) async {
    try {
      final result = await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'MeshMapper Debug Log',
      );
      debugLog('[DEBUG] Shared log: ${file.path}, status: ${result.status}');
    } catch (e) {
      debugError('[DEBUG] Failed to share log: $e');
      _statusMessageService.setDynamicStatus(
        'Failed to share log file',
        StatusColor.error,
      );
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
      debugError('[DEBUG] Failed to view log: $e');
      _statusMessageService.setDynamicStatus(
        'Failed to read log file',
        StatusColor.error,
      );
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
    final success = _gpsService.simulator.loadRoute(content, filename: filename);
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

  /// Load remembered device from Hive storage
  Future<void> _loadRememberedDevice() async {
    // Skip on web - Web Bluetooth requires user interaction for each connection
    if (kIsWeb) return;

    try {
      final box = await Hive.openBox(_rememberedDeviceBoxName);
      final json = box.get('device');
      if (json != null) {
        _rememberedDevice = RememberedDevice.fromJson(Map<String, dynamic>.from(json));
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

    try {
      final remembered = RememberedDevice(
        id: device.id,
        name: device.name,
        lastConnected: DateTime.now(),
      );

      final box = await Hive.openBox(_rememberedDeviceBoxName);
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

    await connectToDevice(device);
  }

  /// Clear remembered device
  Future<void> clearRememberedDevice() async {
    if (kIsWeb) return;

    try {
      final box = await Hive.openBox(_rememberedDeviceBoxName);
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
    try {
      final box = await Hive.openBox(_preferencesBoxName);
      final json = box.get('preferences');
      if (json != null) {
        _preferences = UserPreferences.fromJson(Map<String, dynamic>.from(json));
        debugLog('[APP] Loaded preferences: interval=${_preferences.autoPingInterval}s, '
            'ignoreCarpeater=${_preferences.ignoreCarpeater}, '
            'ignoreRepeaterId=${_preferences.ignoreRepeaterId}');
        notifyListeners();
      }
    } catch (e) {
      debugLog('[APP] Failed to load preferences: $e');
    }
  }

  /// Save user preferences to Hive storage
  Future<void> _savePreferences() async {
    try {
      final box = await Hive.openBox(_preferencesBoxName);
      await box.put('preferences', _preferences.toJson());
      debugLog('[APP] Saved preferences');
    } catch (e) {
      debugLog('[APP] Failed to save preferences: $e');
    }
  }

  // ============================================
  // Cleanup
  // ============================================

  @override
  void dispose() {
    _logRxDataSubscription?.cancel();
    _noiseFloorSubscription?.cancel();
    _batterySubscription?.cancel();
    _unifiedRxHandler?.dispose();
    _meshCoreConnection?.dispose();
    _pingService?.dispose();
    _gpsService.dispose();
    _apiQueueService.dispose();
    _offlineSessionService.dispose();
    _apiService.dispose();
    _bluetoothService.dispose();
    _statusMessageService.dispose();
    _cooldownTimer.dispose();
    _autoPingTimer.dispose();
    _rxWindowTimer.dispose();
    _discoveryWindowTimer.dispose();
    super.dispose();
  }
}
