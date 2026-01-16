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
  dynamic _rxCharacteristic;  // Using dynamic to handle WebBluetoothRemoteGATTCharacteristic
  dynamic _txCharacteristic;  // Using dynamic to handle WebBluetoothRemoteGATTCharacteristic
  StreamSubscription? _notificationSubscription;

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
        yield DiscoveredDevice(
          id: device.id,
          name: device.name ?? 'MeshCore Device',
        );
      }
    } catch (e) {
      // User cancelled or error
    } finally {
      _updateStatus(ConnectionStatus.disconnected);
    }
  }

  @override
  Future<void> stopScan() async {
    // Web Bluetooth doesn't have explicit scan stop
    if (_connectionStatus == ConnectionStatus.scanning) {
      _updateStatus(ConnectionStatus.disconnected);
    }
  }

  @override
  Future<void> connect(String deviceId) async {
    try {
      _updateStatus(ConnectionStatus.connecting);
      debugLog('[BLE] Connecting to device: $deviceId');

      // Request device filtered by MeshCore service UUID (matches JS implementation)
      _device = await _webBluetooth.requestDevice(
        fwb.RequestOptionsBuilder([
          fwb.RequestFilterBuilder(services: [BleUuids.serviceUuid.toLowerCase()]),
        ]),
      );

      if (_device == null) {
        throw Exception('No device selected');
      }

      // Connect to GATT server
      final server = await _device!.gatt?.connect();
      if (server == null) {
        throw Exception('Could not connect to GATT server');
      }

      // Get primary service
      final service = await server.getPrimaryService(
        BleUuids.serviceUuid.toLowerCase(),
      );

      // Get characteristics
      final characteristics = await service.getCharacteristics();

      for (final char in characteristics) {
        final uuid = char.uuid.toUpperCase();
        if (uuid == BleUuids.characteristicRxUuid.toUpperCase()) {
          _rxCharacteristic = char;
        } else if (uuid == BleUuids.characteristicTxUuid.toUpperCase()) {
          _txCharacteristic = char;
        }
      }

      if (_rxCharacteristic == null || _txCharacteristic == null) {
        throw Exception('Required characteristics not found');
      }

      // Start notifications on TX characteristic
      await _txCharacteristic!.startNotifications();
      _notificationSubscription = _txCharacteristic!.value.listen((value) {
        try {
          Uint8List buffer;
          // Handle different data types from Web Bluetooth API
          if (value is ByteData) {
            buffer = value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes);
          } else if (value is Uint8List) {
            buffer = value;
          } else {
            // Unexpected type, skip
            return;
          }
          
          if (buffer.isNotEmpty) {
            _dataController.add(buffer);
          }
        } catch (e) {
          // Silently ignore conversion errors
        }
      });

      _connectedDevice = DiscoveredDevice(
        id: _device!.id,
        name: _device!.name ?? 'MeshCore Device',
      );

      _updateStatus(ConnectionStatus.connected);
    } catch (e) {
      _updateStatus(ConnectionStatus.error);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      _device?.gatt?.disconnect();
    } finally {
      _connectedDevice = null;
      _device = null;
      _rxCharacteristic = null;
      _txCharacteristic = null;
      _notificationSubscription?.cancel();
      _notificationSubscription = null;
      _updateStatus(ConnectionStatus.disconnected);
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
    _device?.gatt?.disconnect();
  }
}
