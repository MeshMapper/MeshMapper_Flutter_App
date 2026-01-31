import 'dart:async';
import 'dart:typed_data';

import '../../models/connection_state.dart';

/// Exception thrown when BLE permissions are permanently denied
/// User must enable permissions in device Settings
class BlePermissionDeniedException implements Exception {
  final String message;
  BlePermissionDeniedException(this.message);

  @override
  String toString() => message;
}

/// Discovered Bluetooth device
class DiscoveredDevice {
  final String id;
  final String name;
  final int? rssi;

  const DiscoveredDevice({
    required this.id,
    required this.name,
    this.rssi,
  });

  @override
  String toString() => 'DiscoveredDevice($name, $id, rssi=$rssi)';
}

/// Bluetooth adapter state
enum BluetoothAdapterState {
  unknown,
  on,
  off,
  turningOn,
  turningOff,
  unavailable,
}

/// Abstract Bluetooth service interface
/// Platform implementations provided by MobileBluetoothService and WebBluetoothService
abstract class BluetoothService {
  /// Stream of connection status changes
  Stream<ConnectionStatus> get connectionStream;

  /// Stream of received data from device
  Stream<Uint8List> get dataStream;

  /// Stream of Bluetooth adapter state changes (on/off)
  Stream<BluetoothAdapterState> get adapterStateStream;

  /// Current connection status
  ConnectionStatus get connectionStatus;

  /// Currently connected device (null if not connected)
  DiscoveredDevice? get connectedDevice;

  /// Check if Bluetooth is available on this platform
  Future<bool> isAvailable();

  /// Check if Bluetooth is enabled
  Future<bool> isEnabled();

  /// Request Bluetooth permissions
  Future<bool> requestPermissions();

  /// Scan for MeshCore devices
  /// Returns stream of discovered devices
  Stream<DiscoveredDevice> scanForDevices({Duration? timeout});

  /// Stop scanning for devices
  Future<void> stopScan();

  /// Connect to a device by ID
  Future<void> connect(String deviceId);

  /// Disconnect from current device
  Future<void> disconnect();

  /// Write data to device
  Future<void> write(Uint8List data);

  /// Pre-populate device cache with known device info
  /// Used for remembered devices to ensure name is available during connect
  void cacheDeviceInfo(DiscoveredDevice device);

  /// Dispose of resources
  void dispose();
}
