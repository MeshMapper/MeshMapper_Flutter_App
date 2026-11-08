import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';

import 'fake_companion_transport.dart';

/// A connect workflow whose connection was disposed under it (an abandoned
/// reconnect, or a newer connect that took over) must leave the shared
/// transport alone. In one log the stale workflow failed seconds after the
/// user had connected again by hand, and its cleanup disconnected the new
/// link; its retried frames also went out on that new link.

class _CountingTransport extends FakeCompanionTransport {
  int disconnects = 0;

  @override
  Future<void> disconnect() async => disconnects++;
}

void main() {
  Future<Never> noModel(String _) async => throw UnimplementedError();

  test('a disposed workflow failing does not disconnect the transport', () {
    fakeAsync((async) {
      final transport = _CountingTransport();
      final conn = MeshCoreConnection(transport: transport);
      Object? error;
      conn.connect(noModel).catchError((Object e) {
        error = e;
        return (deviceModel: null, deviceModelMatched: false);
      });
      // Past the handshake delay: the device query is waiting for a reply.
      async.elapse(const Duration(milliseconds: 600));
      expect(transport.writes, isNotEmpty);

      conn.dispose();
      async.elapse(const Duration(seconds: 6));

      expect(error, isNotNull, reason: 'the stale workflow still fails');
      expect(transport.disconnects, 0,
          reason: 'the transport belongs to whoever superseded this attempt');
    });
  });

  test('a live workflow failing still disconnects the transport', () {
    fakeAsync((async) {
      final transport = _CountingTransport();
      final conn = MeshCoreConnection(transport: transport);
      Object? error;
      conn.connect(noModel).catchError((Object e) {
        error = e;
        return (deviceModel: null, deviceModelMatched: false);
      });
      async.elapse(const Duration(seconds: 7));

      expect(error, isNotNull);
      expect(transport.disconnects, 1);
      conn.dispose();
    });
  });

  test('a disposed connection puts no frame on the transport', () {
    fakeAsync((async) {
      final transport = _CountingTransport();
      final conn = MeshCoreConnection(transport: transport);
      conn.connect(noModel).catchError(
          (Object e) => (deviceModel: null, deviceModelMatched: false));
      // Still inside the 500 ms handshake delay: nothing written yet.
      async.elapse(const Duration(milliseconds: 100));
      expect(transport.writes, isEmpty);

      conn.dispose();
      async.elapse(const Duration(seconds: 7));

      expect(transport.writes, isEmpty,
          reason: 'a stale workflow must not write over a newer link');
      expect(transport.disconnects, 0);
    });
  });

  test('debug writes on a disposed connection are refused', () async {
    final transport = _CountingTransport();
    final conn = MeshCoreConnection(transport: transport);
    conn.dispose();
    await expectLater(conn.debugWriteRaw(Uint8List.fromList([0x16])),
        throwsA(isA<RadioAbortedException>()));
    expect(transport.writes, isEmpty);
  });
}
