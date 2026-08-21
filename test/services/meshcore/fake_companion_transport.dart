import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_mapper/models/connection_state.dart';
import 'package:mesh_mapper/services/bluetooth/bluetooth_service.dart';
import 'package:mesh_mapper/services/transport/companion_transport.dart';

/// In-memory [CompanionTransport] for protocol tests.
///
/// `MeshCoreConnection` does all of its dispatching off `transport.dataStream`
/// and all of its sending through `transport.write`, so a fake at this seam
/// exercises the real framing code with no radio and no platform channels.
class FakeCompanionTransport implements CompanionTransport {
  final StreamController<Uint8List> _data =
      StreamController<Uint8List>.broadcast();
  final StreamController<ConnectionStatus> _status =
      StreamController<ConnectionStatus>.broadcast();

  /// Every frame the connection has written, oldest first.
  final List<Uint8List> writes = [];

  /// Set true to make [write] throw, simulating a dead link.
  bool failWrites = false;

  @override
  Stream<Uint8List> get dataStream => _data.stream;

  @override
  Stream<ConnectionStatus> get connectionStream => _status.stream;

  @override
  ConnectionStatus get connectionStatus => ConnectionStatus.connected;

  @override
  DiscoveredDevice? get connectedDevice =>
      const DiscoveredDevice(id: 'fake-transport', name: 'FakeRadio');

  @override
  Future<void> write(Uint8List data) async {
    if (failWrites) throw StateError('fake transport link is down');
    writes.add(Uint8List.fromList(data));
  }

  @override
  Future<void> disconnect() async {}

  @override
  void dispose() {
    _data.close();
    _status.close();
  }

  /// Push a frame from the "radio" into the connection's dispatcher.
  void emit(List<int> frame) => _data.add(Uint8List.fromList(frame));

  /// Let the broadcast stream deliver and any awaiting futures resume.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// The command byte of the nth write (or -1 when there is no nth write).
  int commandAt(int index) =>
      index < writes.length && writes[index].isNotEmpty ? writes[index][0] : -1;
}
