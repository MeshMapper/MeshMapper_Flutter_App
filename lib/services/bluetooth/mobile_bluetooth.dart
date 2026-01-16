import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/connection_state.dart';
import '../meshcore/protocol_constants.dart';
import 'bluetooth_service.dart';

/// Mobile Bluetooth implementation using flutter_blue_plus
/// For Android and iOS platforms
class MobileBluetoothService implements BluetoothService {
  final _connectionController = StreamController<ConnectionStatus>.broadcast();
  final _dataController = StreamController<Uint8List>.broadcast();

  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  DiscoveredDevice? _connectedDevice;
  BluetoothDevice? _bleDevice;
  BluetoothCharacteristic? _rxCharacteristic;
  BluetoothCharacteristic? _txCharacteristic;
  StreamSubscription? _connectionStateSubscription;
  StreamSubscription? _notificationSubscription;
  StreamSubscription? _scanSubscription;

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
    try {
      return await FlutterBluePlus.isSupported;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> isEnabled() async {
    try {
      final state = await FlutterBluePlus.adapterState.first;
      return state == BluetoothAdapterState.on;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> requestPermissions() async {
    // Request Bluetooth permissions
    final bluetoothScan = await Permission.bluetoothScan.request();
    final bluetoothConnect = await Permission.bluetoothConnect.request();
    final location = await Permission.locationWhenInUse.request();

    return bluetoothScan.isGranted &&
        bluetoothConnect.isGranted &&
        location.isGranted;
  }

  @override
  Stream<DiscoveredDevice> scanForDevices({Duration? timeout}) async* {
    final controller = StreamController<DiscoveredDevice>();
    
    _updateStatus(ConnectionStatus.scanning);

    try {
      // Start scanning with filter for MeshCore service UUID
      await FlutterBluePlus.startScan(
        withServices: [Guid(BleUuids.serviceUuid)],
        timeout: timeout ?? const Duration(seconds: 10),
      );

      // Listen for scan results
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
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
    await FlutterBluePlus.stopScan();
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    if (_connectionStatus == ConnectionStatus.scanning) {
      _updateStatus(ConnectionStatus.disconnected);
    }
  }

  @override
  Future<void> connect(String deviceId) async {
    try {
      _updateStatus(ConnectionStatus.connecting);

      // Get the device
      _bleDevice = BluetoothDevice.fromId(deviceId);

      // Listen for connection state changes
      _connectionStateSubscription = _bleDevice!.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _handleDisconnection();
        }
      });

      // Connect to GATT server
      await _bleDevice!.connect(timeout: const Duration(seconds: 15));

      // Discover services
      final services = await _bleDevice!.discoverServices();

      // Find our service
      final service = services.firstWhere(
        (s) => s.uuid.toString().toUpperCase() == BleUuids.serviceUuid,
        orElse: () => throw Exception('MeshCore service not found'),
      );

      // Find characteristics
      for (final char in service.characteristics) {
        final uuid = char.uuid.toString().toUpperCase();
        if (uuid == BleUuids.characteristicRxUuid) {
          _rxCharacteristic = char;
        } else if (uuid == BleUuids.characteristicTxUuid) {
          _txCharacteristic = char;
        }
      }

      if (_rxCharacteristic == null || _txCharacteristic == null) {
        throw Exception('Required characteristics not found');
      }

      // Enable notifications on TX characteristic
      await _txCharacteristic!.setNotifyValue(true);
      _notificationSubscription = _txCharacteristic!.lastValueStream.listen((value) {
        if (value.isNotEmpty) {
          _dataController.add(Uint8List.fromList(value));
        }
      });

      _connectedDevice = DiscoveredDevice(
        id: deviceId,
        name: _bleDevice!.platformName.isNotEmpty 
            ? _bleDevice!.platformName 
            : 'MeshCore Device',
      );

      _updateStatus(ConnectionStatus.connected);
    } catch (e) {
      _updateStatus(ConnectionStatus.error);
      rethrow;
    }
  }

  void _handleDisconnection() {
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
    _scanSubscription?.cancel();
    _notificationSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _connectionController.close();
    _dataController.close();
    _bleDevice?.disconnect();
  }
}
