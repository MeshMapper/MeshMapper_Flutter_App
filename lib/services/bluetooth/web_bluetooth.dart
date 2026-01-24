import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_web_bluetooth/flutter_web_bluetooth.dart' as fwb;

import '../../models/connection_state.dart';
import '../../utils/debug_logger_io.dart';
import '../meshcore/protocol_constants.dart';
import 'bluetooth_service.dart';

/// Web Bluetooth implementation using flutter_web_bluetooth
/// For web platform (Chrome, Edge - Safari not supported)
class WebBluetoothService implements BluetoothService {
  final _connectionController = StreamController<ConnectionStatus>.broadcast();
  final _dataController = StreamController<Uint8List>.broadcast();
  final fwb.FlutterWebBluetoothInterface _webBluetooth = fwb.FlutterWebBluetooth.instance;

  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  DiscoveredDevice? _connectedDevice;
  fwb.BluetoothDevice? _device;
  fwb.BluetoothDevice? _pendingDevice; // Store device from scan for connect()
  fwb.BluetoothCharacteristic? _rxCharacteristic;  // For writing (device RX)
  fwb.BluetoothCharacteristic? _txCharacteristic;  // For notifications (device TX)
  StreamSubscription<ByteData>? _notificationSubscription;

  @override
  Stream<ConnectionStatus> get connectionStream => _connectionController.stream;

  @override
  Stream<Uint8List> get dataStream => _dataController.stream;

  @override
  ConnectionStatus get connectionStatus => _connectionStatus;

  @override
  DiscoveredDevice? get connectedDevice => _connectedDevice;

  void _updateStatus(ConnectionStatus status) {
    _connectionStatus = status;
    _connectionController.add(status);
  }

  @override
  Future<bool> isAvailable() async {
    return _webBluetooth.isBluetoothApiSupported;
  }

  @override
  Future<bool> isEnabled() async {
    try {
      return await _webBluetooth.isAvailable.first;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> requestPermissions() async {
    // Web Bluetooth permissions are handled at connection time
    return await isAvailable();
  }

  @override
  Stream<DiscoveredDevice> scanForDevices({Duration? timeout}) async* {
    // Web Bluetooth doesn't support scanning - uses requestDevice dialog
    // This is a stub that will yield devices from the request dialog
    _updateStatus(ConnectionStatus.scanning);
    debugLog('[BLE] Opening device picker with service filter: ${BleUuids.serviceUuid}');
    
    try {
      // Request device filtered by MeshCore service UUID (matches JS implementation)
      final device = await _webBluetooth.requestDevice(
        fwb.RequestOptionsBuilder([
          fwb.RequestFilterBuilder(services: [BleUuids.serviceUuid.toLowerCase()]),
        ]),
      );

      if (device != null) {
        // Store the device for later connection (avoid requesting twice)
        _pendingDevice = device;
        debugLog('[BLE] Device selected: ${device.name ?? device.id}');

        final deviceName = device.name ?? 'MeshCore Device';
        if (device.name == null) {
          debugWarn('[BLE] WARNING: Device ${device.id} has no name during scan, using fallback "MeshCore Device"');
        }
        yield DiscoveredDevice(
          id: device.id,
          name: deviceName,
        );
      }
    } catch (e) {
      debugError('[BLE] Device picker error: $e');
      // Only set disconnected on error - successful scan will proceed to connect()
      _updateStatus(ConnectionStatus.disconnected);
    }
    // NOTE: Do NOT set disconnected in finally block. On web, connect() is called
    // immediately after scan yields a device. Setting disconnected here would race
    // with the connect() call and potentially dispose the new MeshCoreConnection.
  }

  @override
  Future<void> stopScan() async {
    // Web Bluetooth doesn't have explicit scan stop
    // NOTE: Do NOT fire 'disconnected' here. Stopping a scan is not a disconnection.
    // The status will be updated by connect() when a connection starts.
  }

  @override
  Future<void> connect(String deviceId) async {
    try {
      _updateStatus(ConnectionStatus.connecting);
      debugLog('[BLE] Connecting to device: $deviceId');

      // Use the pending device from scanForDevices() - don't request again!
      if (_pendingDevice == null) {
        debugError('[BLE] No pending device - must call scanForDevices first');
        throw Exception('No device selected. Please scan for devices first.');
      }
      
      _device = _pendingDevice;
      _pendingDevice = null; // Clear pending
      debugLog('[BLE] Using stored device: ${_device!.name ?? _device!.id}');

      // Connect to GATT server using HIGH-LEVEL API
      debugLog('[BLE] Connecting to GATT server...');
      await _device!.connect(timeout: const Duration(seconds: 10));
      debugLog('[BLE] GATT connected');

      // Discover services using HIGH-LEVEL API
      debugLog('[BLE] Discovering services...');
      final services = await _device!.discoverServices();
      debugLog('[BLE] Found ${services.length} services');
      
      // Find our MeshCore service
      fwb.BluetoothService? meshCoreService;
      for (final service in services) {
        debugLog('[BLE] Service: ${service.uuid}');
        if (service.uuid.toLowerCase() == BleUuids.serviceUuid.toLowerCase()) {
          meshCoreService = service;
          debugLog('[BLE] Found MeshCore service');
          break;
        }
      }
      
      if (meshCoreService == null) {
        throw Exception('MeshCore service not found');
      }

      // Get characteristics using HIGH-LEVEL API
      debugLog('[BLE] Getting characteristics...');
      final characteristics = await meshCoreService.getCharacteristics();
      debugLog('[BLE] Found ${characteristics.length} characteristics');

      for (final char in characteristics) {
        final uuid = char.uuid.toUpperCase();
        debugLog('[BLE] Characteristic: $uuid');
        if (uuid == BleUuids.characteristicRxUuid.toUpperCase()) {
          _rxCharacteristic = char;
          debugLog('[BLE] Found RX characteristic (for writing)');
        } else if (uuid == BleUuids.characteristicTxUuid.toUpperCase()) {
          _txCharacteristic = char;
          debugLog('[BLE] Found TX characteristic (for notifications)');
        }
      }

      if (_rxCharacteristic == null || _txCharacteristic == null) {
        throw Exception('Required characteristics not found');
      }

      // Start notifications on TX characteristic (device sends data to us via TX)
      debugLog('[BLE] Starting notifications on TX characteristic...');
      try {
        await _txCharacteristic!.startNotifications();
        debugLog('[BLE] Notifications started, setting up listener...');
        
        // HIGH-LEVEL API: BluetoothCharacteristic.value is a Stream<ByteData>
        _notificationSubscription = _txCharacteristic!.value.listen(
          (ByteData data) {
            try {
              // Convert ByteData to Uint8List
              final buffer = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
              
              if (buffer.isNotEmpty) {
                debugLog('[BLE] Received ${buffer.length} bytes');
                _dataController.add(buffer);
              }
            } catch (e) {
              debugError('[BLE] Error processing notification data: $e');
            }
          },
          onError: (error) {
            debugError('[BLE] Notification stream error: $error');
          },
          cancelOnError: false,
        );
        debugLog('[BLE] Notification listener active');
      } catch (e) {
        debugError('[BLE] Failed to start notifications: $e');
        // This is critical - without notifications we can't receive data
        throw Exception('Failed to enable BLE notifications: $e');
      }

      final deviceName = _device!.name ?? 'MeshCore Device';
      if (_device!.name == null) {
        debugWarn('[BLE] WARNING: Device ${_device!.id} has no name during connect, using fallback "MeshCore Device"');
      }
      _connectedDevice = DiscoveredDevice(
        id: _device!.id,
        name: deviceName,
      );

      _updateStatus(ConnectionStatus.connected);
      if (deviceName == 'MeshCore Device') {
        debugWarn('[BLE] WARNING: Connected device name is "MeshCore Device"');
      } else {
        debugLog('[BLE] Connected successfully as: $deviceName');
      }
    } catch (e) {
      debugError('[BLE] Connection failed: $e');
      _updateStatus(ConnectionStatus.error);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    debugLog('[BLE] Disconnecting...');
    try {
      await _notificationSubscription?.cancel();
      _device?.disconnect();
    } finally {
      _connectedDevice = null;
      _device = null;
      _pendingDevice = null;
      _rxCharacteristic = null;
      _txCharacteristic = null;
      _notificationSubscription = null;
      _updateStatus(ConnectionStatus.disconnected);
      debugLog('[BLE] Disconnected');
    }
  }

  @override
  Future<void> write(Uint8List data) async {
    if (_rxCharacteristic == null) {
      throw Exception('Not connected');
    }

    await _rxCharacteristic!.writeValueWithoutResponse(data);
  }

  @override
  void dispose() {
    _notificationSubscription?.cancel();
    _connectionController.close();
    _dataController.close();
    _device?.disconnect();
  }
}
