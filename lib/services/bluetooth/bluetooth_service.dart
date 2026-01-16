import 'dart:async';
import 'dart:typed_data';

import '../../models/connection_state.dart';

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

/// Abstract Bluetooth service interface
/// Platform implementations provided by MobileBluetoothService and WebBluetoothService
abstract class BluetoothService {
  /// Stream of connection status changes
  Stream<ConnectionStatus> get connectionStream;

  /// Stream of received data from device
  Stream<Uint8List> get dataStream;

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

  /// Dispose of resources
  void dispose();
}
