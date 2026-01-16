import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';

import '../models/connection_state.dart';
import '../models/device_model.dart';
import '../models/ping_data.dart';
import '../services/api_queue_service.dart';
import '../services/api_service.dart';
import '../services/bluetooth/bluetooth_service.dart';
import '../services/device_model_service.dart';
import '../services/gps_service.dart';
import '../services/meshcore/connection.dart';
import '../services/ping_service.dart';
import '../utils/debug_logger_io.dart';

/// Auto-ping mode (matches MeshMapper_WebClient behavior)
enum AutoMode {
  /// TX/RX Auto: Sends pings on movement, listens for RX responses
  txRx,
  /// RX Auto: Passive listening only (no transmit)
  rxOnly,
}

/// Main application state provider
class AppStateProvider extends ChangeNotifier {
  final BluetoothService _bluetoothService;
  late final GpsService _gpsService;
  late final ApiService _apiService;
  late final ApiQueueService _apiQueueService;
  late final DeviceModelService _deviceModelService;
  MeshCoreConnection? _meshCoreConnection;
  PingService? _pingService;

  // Device identity
  String _deviceId = '';

  // Connection state
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  ConnectionStep _connectionStep = ConnectionStep.disconnected;
  String? _connectionError;

  // GPS state
  GpsStatus _gpsStatus = GpsStatus.permissionDenied;
  Position? _currentPosition;

  // Device info
  DeviceModel? _deviceModel;
  String? _manufacturerString;

  // Ping state
  PingStats _pingStats = const PingStats();
  bool _autoPingEnabled = false;
  AutoMode _autoMode = AutoMode.txRx;
  int _queueSize = 0;

  // Discovered devices
  List<DiscoveredDevice> _discoveredDevices = [];
  bool _isScanning = false;

  // TX/RX markers for map
  final List<TxPing> _txPings = [];
  final List<RxPing> _rxPings = [];

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
  GpsStatus get gpsStatus => _gpsStatus;
  Position? get currentPosition => _currentPosition;
  DeviceModel? get deviceModel => _deviceModel;
  String? get manufacturerString => _manufacturerString;
  PingStats get pingStats => _pingStats;
  bool get autoPingEnabled => _autoPingEnabled;
  AutoMode get autoMode => _autoMode;
  int get queueSize => _queueSize;
  List<DiscoveredDevice> get discoveredDevices => _discoveredDevices;
  bool get isScanning => _isScanning;
  List<TxPing> get txPings => List.unmodifiable(_txPings);
  List<RxPing> get rxPings => List.unmodifiable(_rxPings);
  
  bool get isConnected => _connectionStep == ConnectionStep.connected;
  bool get hasGpsLock => _gpsStatus == GpsStatus.locked;
  bool get canPing => isConnected && hasGpsLock;

  // ============================================
  // Initialization
  // ============================================

  Future<void> _initialize() async {
    // Generate or load device ID
    _deviceId = const Uuid().v4();

    // Initialize services
    _gpsService = GpsService();
    _apiService = ApiService();
    _apiQueueService = ApiQueueService(apiService: _apiService);
    _deviceModelService = DeviceModelService();

    // Initialize API queue
    await _apiQueueService.init();
    _apiQueueService.onQueueUpdated = (size) {
      _queueSize = size;
      notifyListeners();
    };

    // Load device models
    await _deviceModelService.loadModels();

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

    _gpsService.positionStream.listen((position) {
      _currentPosition = position;
      notifyListeners();
    });

    // Start GPS
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
    final hasPermission = await _bluetoothService.requestPermissions();
    if (!hasPermission) {
      _connectionError = 'Bluetooth permissions not granted';
      notifyListeners();
      return;
    }

    // Check if Bluetooth is available
    if (!await _bluetoothService.isAvailable()) {
      _connectionError = 'Bluetooth not available';
      notifyListeners();
      return;
    }

    // Check if Bluetooth is enabled
    if (!await _bluetoothService.isEnabled()) {
      _connectionError = 'Bluetooth is disabled';
      notifyListeners();
      return;
    }

    _isScanning = true;
    _discoveredDevices = [];
    _connectionError = null;
    notifyListeners();

    // Listen for discovered devices
    await for (final device in _bluetoothService.scanForDevices(
      timeout: const Duration(seconds: 15),
    )) {
      if (!_discoveredDevices.any((d) => d.id == device.id)) {
        _discoveredDevices.add(device);
        notifyListeners();
      }
    }

    _isScanning = false;
    notifyListeners();
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

      // Create MeshCore connection
      _meshCoreConnection = MeshCoreConnection(bluetooth: _bluetoothService);

      // Listen for step changes
      _meshCoreConnection!.stepStream.listen((step) {
        _connectionStep = step;
        if (step == ConnectionStep.connected) {
          // Update device info
          _manufacturerString = _meshCoreConnection!.deviceInfo?.manufacturer;
          _deviceModel = _meshCoreConnection!.deviceModel;
        }
        notifyListeners();
      });

      // Execute connection workflow
      await _meshCoreConnection!.connect(
        device.id,
        _deviceModelService.models,
      );

      // Acquire API slot
      await _apiService.acquireSlot();

      // Create ping service
      _pingService = PingService(
        gpsService: _gpsService,
        connection: _meshCoreConnection!,
        apiQueue: _apiQueueService,
        deviceId: _deviceId,
      );

      _pingService!.onTxPing = (ping) {
        _txPings.add(ping);
        notifyListeners();
      };

      _pingService!.onRxPing = (ping) {
        _rxPings.add(ping);
        notifyListeners();
      };

      _pingService!.onStatsUpdated = (stats) {
        _pingStats = stats;
        notifyListeners();
      };

    } catch (e) {
      _connectionError = e.toString();
      _connectionStep = ConnectionStep.error;
      notifyListeners();
    }
  }

  /// Disconnect from current device
  Future<void> disconnect() async {
    await _meshCoreConnection?.disconnect();
    await _bluetoothService.disconnect();
    
    _meshCoreConnection?.dispose();
    _meshCoreConnection = null;
    _pingService?.dispose();
    _pingService = null;
    
    _connectionStep = ConnectionStep.disconnected;
    _deviceModel = null;
    _manufacturerString = null;
    
    notifyListeners();
  }

  // ============================================
  // Ping Controls
  // ============================================

  /// Get current ping validation status
  PingValidation get pingValidation {
    return _pingService?.canPing() ?? PingValidation.notConnected;
  }

  /// Send a manual TX ping
  Future<bool> sendPing() async {
    if (_pingService == null) return false;
    debugLog('[PING] Sending manual TX ping');
    return await _pingService!.sendTxPing();
  }

  /// Toggle auto-ping mode (TX/RX or RX-only)
  void toggleAutoPing(AutoMode mode) {
    if (_pingService == null) return;
    
    // If currently running the same mode, stop it
    if (_autoPingEnabled && _autoMode == mode) {
      debugLog('[PING] Stopping auto mode: ${mode.name}');
      _pingService!.disableAutoPing();
      _autoPingEnabled = false;
    } else {
      // Stop any existing mode first
      if (_autoPingEnabled) {
        _pingService!.disableAutoPing();
      }
      
      // Start new mode
      debugLog('[PING] Starting auto mode: ${mode.name}');
      _autoMode = mode;
      _pingService!.enableAutoPing(rxOnly: mode == AutoMode.rxOnly);
      _autoPingEnabled = true;
    }
    
    notifyListeners();
  }

  /// Clear ping markers from map
  void clearPings() {
    _txPings.clear();
    _rxPings.clear();
    _pingService?.resetStats();
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
  // Cleanup
  // ============================================

  @override
  void dispose() {
    _meshCoreConnection?.dispose();
    _pingService?.dispose();
    _gpsService.dispose();
    _apiQueueService.dispose();
    _apiService.dispose();
    _bluetoothService.dispose();
    super.dispose();
  }
}
