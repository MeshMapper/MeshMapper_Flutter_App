import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/connection_state.dart';
import '../meshcore/protocol_constants.dart';
import 'bluetooth_service.dart';

/// Mobile Bluetooth implementation using flutter_blue_plus
/// For Android and iOS platforms
class MobileBluetoothService implements BluetoothService {
  StreamController<ConnectionStatus>? _connectionController;
  StreamController<Uint8List>? _dataController;
  bool _isDisposed = false;

  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;

  MobileBluetoothService() {
    _initControllers();
  }

  void _initControllers() {
    _connectionController = StreamController<ConnectionStatus>.broadcast();
    _dataController = StreamController<Uint8List>.broadcast();
    _isDisposed = false;
  }

  void _ensureControllers() {
    if (_isDisposed || _connectionController == null || _connectionController!.isClosed) {
      _initControllers();
    }
  }
  DiscoveredDevice? _connectedDevice;
  fbp.BluetoothDevice? _bleDevice;
  fbp.BluetoothCharacteristic? _rxCharacteristic;
  fbp.BluetoothCharacteristic? _txCharacteristic;
  StreamSubscription? _connectionStateSubscription;
  StreamSubscription? _notificationSubscription;
  StreamSubscription? _scanSubscription;

  @override
  Stream<ConnectionStatus> get connectionStream {
    _ensureControllers();
    return _connectionController!.stream;
  }

  @override
  Stream<Uint8List> get dataStream {
    _ensureControllers();
    return _dataController!.stream;
  }

  @override
  ConnectionStatus get connectionStatus => _connectionStatus;

  @override
  DiscoveredDevice? get connectedDevice => _connectedDevice;

  void _updateStatus(ConnectionStatus status) {
    _connectionStatus = status;
    _ensureControllers();
    if (!_connectionController!.isClosed) {
      _connectionController!.add(status);
    }
  }

  @override
  Future<bool> isAvailable() async {
    try {
      return await fbp.FlutterBluePlus.isSupported;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> isEnabled() async {
    try {
      final state = await fbp.FlutterBluePlus.adapterState.first;
      return state == fbp.BluetoothAdapterState.on;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> requestPermissions() async {
    if (Platform.isIOS) {
      // iOS: Core Bluetooth handles Bluetooth authorization automatically.
      // It will prompt the user when we first try to scan/connect.
      //
      // For location, we use Geolocator's API instead of permission_handler
      // because permission_handler can incorrectly report status on iOS.
      LocationPermission locationPermission = await Geolocator.checkPermission();
      print('[BLE] iOS location permission check: $locationPermission');

      if (locationPermission == LocationPermission.denied) {
        // Request permission
        locationPermission = await Geolocator.requestPermission();
        print('[BLE] iOS location permission after request: $locationPermission');
      }

      if (locationPermission == LocationPermission.deniedForever) {
        print('[BLE] iOS location permission permanently denied - user must enable in Settings');
        throw BlePermissionDeniedException(
          'Location permission required for Bluetooth scanning. '
          'Please enable in Settings > Privacy & Security > Location Services > MeshMapper'
        );
      }

      if (locationPermission == LocationPermission.denied) {
        print('[BLE] iOS location permission denied');
        return false;
      }

      print('[BLE] iOS permissions OK - Core Bluetooth will prompt for Bluetooth access when scanning');
      return true;
    } else {
      // Android: Use bluetoothScan and bluetoothConnect (Android 12+)
      final bluetoothScan = await Permission.bluetoothScan.request();
      final bluetoothConnect = await Permission.bluetoothConnect.request();
      final location = await Permission.locationWhenInUse.request();

      print('[BLE] Android permission check - scan: $bluetoothScan, connect: $bluetoothConnect, location: $location');

      // Check for permanently denied permissions
      if (bluetoothScan.isPermanentlyDenied || bluetoothConnect.isPermanentlyDenied || location.isPermanentlyDenied) {
        final denied = <String>[];
        if (bluetoothScan.isPermanentlyDenied) denied.add('Bluetooth Scan');
        if (bluetoothConnect.isPermanentlyDenied) denied.add('Bluetooth Connect');
        if (location.isPermanentlyDenied) denied.add('Location');
        print('[BLE] Android permissions permanently denied: ${denied.join(", ")}');
        throw BlePermissionDeniedException('${denied.join(", ")} permission(s) denied. Please enable in Settings');
      }

      final granted = bluetoothScan.isGranted &&
          bluetoothConnect.isGranted &&
          location.isGranted;

      if (!granted) {
        print('[BLE] Android permissions not fully granted');
      }

      return granted;
    }
  }

  @override
  Stream<DiscoveredDevice> scanForDevices({Duration? timeout}) async* {
    final controller = StreamController<DiscoveredDevice>();
    
    _updateStatus(ConnectionStatus.scanning);

    try {
      // Start scanning with filter for MeshCore service UUID
      await fbp.FlutterBluePlus.startScan(
        withServices: [fbp.Guid(BleUuids.serviceUuid)],
        timeout: timeout ?? const Duration(seconds: 10),
      );

      // Listen for scan results
      _scanSubscription = fbp.FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          final device = DiscoveredDevice(
            id: result.device.remoteId.str,
            name: result.device.platformName.isNotEmpty 
                ? result.device.platformName 
                : 'MeshCore Device',
            rssi: result.rssi,
          );
          controller.add(device);
        }
      });

      yield* controller.stream;
    } finally {
      await _scanSubscription?.cancel();
      _scanSubscription = null;
    }
  }

  @override
  Future<void> stopScan() async {
    await fbp.FlutterBluePlus.stopScan();
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    // NOTE: Do NOT fire 'disconnected' here. Stopping a scan is not a disconnection.
    // The status will be updated by connect() when a connection starts.
    // Firing 'disconnected' here causes a race condition where the queued event
    // arrives after a new MeshCoreConnection is created and disposes it incorrectly.
  }

  @override
  Future<void> connect(String deviceId) async {
    try {
      print('[BLE] Starting connection to $deviceId');
      _updateStatus(ConnectionStatus.connecting);

      // Cancel any existing subscriptions from a previous connection
      // This prevents old listeners from interfering with the new connection
      await _connectionStateSubscription?.cancel();
      _connectionStateSubscription = null;
      await _notificationSubscription?.cancel();
      _notificationSubscription = null;

      // Ensure controllers are initialized
      _ensureControllers();

      // Disconnect any previously connected device
      if (_bleDevice != null) {
        print('[BLE] Disconnecting previous device');
        try {
          await _bleDevice!.disconnect();
        } catch (e) {
          print('[BLE] Previous disconnect error (ignoring): $e');
        }
        _bleDevice = null;
      }

      // Get the device
      _bleDevice = fbp.BluetoothDevice.fromId(deviceId);
      print('[BLE] Device reference created');

      // Connect to GATT server FIRST (before subscribing to state changes)
      print('[BLE] Connecting to GATT...');
      await _bleDevice!.connect(timeout: const Duration(seconds: 15));
      print('[BLE] GATT connected');

      // NOW subscribe to connection state changes (after we're connected)
      // Use skip(1) to ignore the initial state emission from the stream.
      // Flutter Blue Plus emits the current state immediately when you subscribe,
      // but we only want to react to CHANGES, not the initial state.
      // This prevents false disconnection triggers during connection setup.
      _connectionStateSubscription = _bleDevice!.connectionState.skip(1).listen((state) {
        print('[BLE] Connection state changed: $state');
        if (state == fbp.BluetoothConnectionState.disconnected) {
          _handleDisconnection();
        }
      });

      // Discover services
      print('[BLE] Discovering services...');
      final services = await _bleDevice!.discoverServices();
      print('[BLE] Found ${services.length} services');

      // Find our service
      final service = services.firstWhere(
        (s) => s.uuid.toString().toUpperCase() == BleUuids.serviceUuid,
        orElse: () => throw Exception('MeshCore service not found'),
      );
      print('[BLE] Found MeshCore service');

      // Find characteristics
      for (final char in service.characteristics) {
        final uuid = char.uuid.toString().toUpperCase();
        if (uuid == BleUuids.characteristicRxUuid) {
          _rxCharacteristic = char;
          print('[BLE] Found RX characteristic');
        } else if (uuid == BleUuids.characteristicTxUuid) {
          _txCharacteristic = char;
          print('[BLE] Found TX characteristic');
        }
      }

      if (_rxCharacteristic == null || _txCharacteristic == null) {
        throw Exception('Required characteristics not found');
      }

      // Enable notifications on TX characteristic
      print('[BLE] Enabling notifications...');
      await _txCharacteristic!.setNotifyValue(true);
      _notificationSubscription = _txCharacteristic!.lastValueStream.listen((value) {
        if (value.isNotEmpty && _dataController != null && !_dataController!.isClosed) {
          _dataController!.add(Uint8List.fromList(value));
        }
      });
      print('[BLE] Notifications enabled');

      _connectedDevice = DiscoveredDevice(
        id: deviceId,
        name: _bleDevice!.platformName.isNotEmpty
            ? _bleDevice!.platformName
            : 'MeshCore Device',
      );

      print('[BLE] Connection complete');
      _updateStatus(ConnectionStatus.connected);
    } catch (e, stackTrace) {
      print('[BLE] Connection error: $e');
      print('[BLE] Stack trace: $stackTrace');
      _updateStatus(ConnectionStatus.error);
      rethrow;
    }
  }

  void _handleDisconnection() {
    // Guard against double-disconnect: when disconnect() is called, the BLE
    // connectionState listener fires first, then the finally block also calls
    // this method. Only process the first call.
    if (_connectionStatus == ConnectionStatus.disconnected) {
      return;
    }

    _connectedDevice = null;
    _bleDevice = null;
    _rxCharacteristic = null;
    _txCharacteristic = null;
    _notificationSubscription?.cancel();
    _notificationSubscription = null;
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    _updateStatus(ConnectionStatus.disconnected);
  }

  @override
  Future<void> disconnect() async {
    try {
      await _bleDevice?.disconnect();
    } finally {
      _handleDisconnection();
    }
  }

  @override
  Future<void> write(Uint8List data) async {
    if (_rxCharacteristic == null) {
      throw Exception('Not connected');
    }

    // Write to RX characteristic (device reads from this)
    await _rxCharacteristic!.write(data, withoutResponse: false);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _scanSubscription?.cancel();
    _notificationSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _connectionController?.close();
    _dataController?.close();
    _bleDevice?.disconnect();
  }
}
