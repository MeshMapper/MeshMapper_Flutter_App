import 'dart:async';
import 'dart:typed_data';

import '../../models/connection_state.dart';
import '../../utils/debug_logger_io.dart';
import '../bluetooth/bluetooth_service.dart';
import 'companion_transport.dart';
import 'stream_frame_codec.dart';

/// Shared base class for TCP and USB Serial transports.
///
/// Handles frame encoding/decoding via [StreamFrameCodec] and manages
/// connection state, data streams, and lifecycle. Subclasses implement
/// the raw byte I/O for their specific transport.
abstract class StreamTransportBase implements CompanionTransport {
  final StreamFrameCodec _codec = StreamFrameCodec();
  final _connectionController = StreamController<ConnectionStatus>.broadcast();
  final _dataController = StreamController<Uint8List>.broadcast();
  ConnectionStatus _status = ConnectionStatus.disconnected;
  DiscoveredDevice? _device;
  StreamSubscription<Uint8List>? _codecSubscription;

  StreamTransportBase() {
    _codecSubscription = _codec.frames.listen((payload) {
      if (!_dataController.isClosed) {
        _dataController.add(payload);
      }
    });
  }

  @override
  Stream<Uint8List> get dataStream => _dataController.stream;

  @override
  Stream<ConnectionStatus> get connectionStream =>
      _connectionController.stream;

  @override
  ConnectionStatus get connectionStatus => _status;

  @override
  DiscoveredDevice? get connectedDevice => _device;

  @override
  Future<void> write(Uint8List data) async {
    if (_status != ConnectionStatus.connected) {
      throw StateError('Cannot write: transport not connected');
    }
    final framed = StreamFrameCodec.encode(data);
    await writeRawBytes(framed);
  }

  @override
  Future<void> disconnect() async {
    if (_status == ConnectionStatus.disconnected) return;
    try {
      await closeConnection();
    } catch (e) {
      debugError('[CONN] Error closing connection: $e');
    }
    setDisconnected();
  }

  @override
  void dispose() {
    _codecSubscription?.cancel();
    _codec.dispose();
    _connectionController.close();
    _dataController.close();
  }

  /// Called when raw bytes arrive from the underlying transport.
  /// Feeds them into the frame codec for reassembly.
  void onRawBytesReceived(Uint8List data) {
    _codec.addBytes(data);
  }

  /// Update state to connecting and emit.
  void setConnecting() {
    _status = ConnectionStatus.connecting;
    if (!_connectionController.isClosed) {
      _connectionController.add(ConnectionStatus.connecting);
    }
  }

  /// Update state to error and emit.
  void setError() {
    _status = ConnectionStatus.error;
    if (!_connectionController.isClosed) {
      _connectionController.add(ConnectionStatus.error);
    }
  }

  /// Update state to connected and emit.
  void setConnected(DiscoveredDevice device) {
    _device = device;
    _status = ConnectionStatus.connected;
    if (!_connectionController.isClosed) {
      _connectionController.add(ConnectionStatus.connected);
    }
  }

  /// Update state to disconnected and emit.
  void setDisconnected() {
    _device = null;
    _codec.reset();
    _status = ConnectionStatus.disconnected;
    if (!_connectionController.isClosed) {
      _connectionController.add(ConnectionStatus.disconnected);
    }
  }

  /// Open the underlying byte stream (socket, serial port, etc).
  Future<void> openConnection();

  /// Write raw (already framed) bytes to the underlying stream.
  Future<void> writeRawBytes(Uint8List data);

  /// Close the underlying byte stream.
  Future<void> closeConnection();
}
