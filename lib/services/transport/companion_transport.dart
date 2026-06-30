import 'dart:async';
import 'dart:typed_data';

import '../../models/connection_state.dart';
import '../bluetooth/bluetooth_service.dart';

/// Transport-agnostic interface for MeshCore companion connections.
///
/// Implemented by BLE (BluetoothService), TCP (TcpService),
/// and USB Serial (AndroidSerialService, WebSerialService).
/// MeshCoreConnection depends only on this interface.
abstract class CompanionTransport {
  Stream<Uint8List> get dataStream;

  Stream<ConnectionStatus> get connectionStream;

  ConnectionStatus get connectionStatus;

  DiscoveredDevice? get connectedDevice;

  Future<void> write(Uint8List data);

  Future<void> disconnect();

  void dispose();
}
