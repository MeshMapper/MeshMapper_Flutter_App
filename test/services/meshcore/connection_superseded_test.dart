import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';

import 'catalog_protocol_transport.dart';
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

class _CountingProtocolTransport extends CatalogProtocolTransport {
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

  // An abandoned reconnect disposes its connection while the workflow sits
  // in the auth step (the provider's callback awaits a GPS fix first). The
  // callback then answers superseded, and the failure that follows must not
  // close the link a connect the user started meanwhile is using.
  group('disposed while the auth step is pending', () {
    Future<({Object? error, int disconnects})> run(
        {required bool disposeFirst}) async {
      final transport = _CountingProtocolTransport();
      final conn = MeshCoreConnection(transport: transport);
      final authStarted = Completer<void>();
      final authAnswer = Completer<Map<String, dynamic>?>();
      conn.onRequestAuth = () {
        authStarted.complete();
        return authAnswer.future;
      };
      Object? error;
      final done = conn.connect((_) async => null).then<void>((_) {},
          onError: (Object e) => error = e);
      await authStarted.future;
      if (disposeFirst) conn.dispose();
      authAnswer.complete({
        'success': false,
        'reason': disposeFirst ? 'superseded' : 'outside_zone',
      });
      await done;
      if (!disposeFirst) conn.dispose();
      return (error: error, disconnects: transport.disconnects);
    }

    test('the superseded attempt leaves the transport alone', () async {
      final result = await run(disposeFirst: true);
      expect(result.error.toString(), contains('AUTH_FAILED:superseded'));
      expect(result.disconnects, 0);
    });

    test('a live attempt refused by auth still disconnects', () async {
      final result = await run(disposeFirst: false);
      expect(result.error.toString(), contains('AUTH_FAILED:outside_zone'));
      expect(result.disconnects, 1);
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
