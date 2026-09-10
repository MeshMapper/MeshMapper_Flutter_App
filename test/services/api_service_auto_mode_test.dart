import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// The running auto mode rides every batch post, every heartbeat and the
/// release, so the server can total mode time. It is read through a hook at
/// the moment of the call, never cached. Connect, register and the offline
/// upload never carry it.

void main() {
  /// An ApiService whose mock server records every request body and answers
  /// success with a far-off expiry.
  ({ApiService api, List<Map<String, dynamic>> bodies}) build() {
    final bodies = <Map<String, dynamic>>[];
    final api = ApiService(
      client: MockClient((request) async {
        final body = json.decode(request.body) as Map<String, dynamic>;
        bodies.add(body);
        if (request.url.path.endsWith('/auth')) {
          return http.Response(
            json.encode({
              'success': true,
              'session_id': 'YOW-20260909-0001',
              'tx_allowed': true,
              'rx_allowed': true,
              'expires_at':
                  DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
            }),
            200,
          );
        }
        return http.Response(
          json.encode({
            'success': true,
            'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
          }),
          200,
        );
      }),
    );
    return (api: api, bodies: bodies);
  }

  Future<void> connect(ApiService api) => api.requestAuth(
        reason: 'connect',
        publicKey: 'AB',
        lat: 45.0,
        lon: -75.0,
      );

  Map<String, dynamic> lastBody(List<Map<String, dynamic>> bodies) =>
      bodies.last;

  test('batch post carries the hook value', () async {
    final t = build();
    t.api.currentAutoMode = () => 'hybrid';
    await connect(t.api);
    await t.api.submitWardriveData([
      {'type': 'RX', 'lat': 45.0, 'lon': -75.0}
    ]);
    expect(lastBody(t.bodies)['auto_mode'], 'hybrid');
  });

  test('heartbeat carries the hook value, read at call time', () async {
    final t = build();
    var mode = 'active';
    t.api.currentAutoMode = () => mode;
    await connect(t.api);
    await t.api.sendHeartbeat();
    expect(lastBody(t.bodies)['auto_mode'], 'active');
    mode = 'none';
    await t.api.sendHeartbeat();
    expect(lastBody(t.bodies)['auto_mode'], 'none');
  });

  test('the release carries it, connect does not', () async {
    final t = build();
    t.api.currentAutoMode = () => 'passive';
    await connect(t.api);
    expect(t.bodies.single.containsKey('auto_mode'), isFalse,
        reason: 'connect has no session yet');
    await t.api.requestAuth(reason: 'disconnect', publicKey: 'AB');
    expect(lastBody(t.bodies)['reason'], 'disconnect');
    expect(lastBody(t.bodies)['auto_mode'], 'passive');
  });

  test('register does not carry it', () async {
    final t = build();
    t.api.currentAutoMode = () => 'active';
    await t.api.requestAuth(
      reason: 'register',
      contactUri: 'meshcore://contact/AB',
      lat: 45.0,
      lon: -75.0,
    );
    expect(lastBody(t.bodies).containsKey('auto_mode'), isFalse);
  });

  test('no hook means no field, on all three calls', () async {
    final t = build();
    await connect(t.api);
    await t.api.submitWardriveData([
      {'type': 'RX', 'lat': 45.0, 'lon': -75.0}
    ]);
    expect(lastBody(t.bodies).containsKey('auto_mode'), isFalse);
    await t.api.sendHeartbeat();
    expect(lastBody(t.bodies).containsKey('auto_mode'), isFalse);
    await t.api.requestAuth(reason: 'disconnect', publicKey: 'AB');
    expect(lastBody(t.bodies).containsKey('auto_mode'), isFalse);
  });

  test('the offline upload never carries it', () async {
    final t = build();
    t.api.currentAutoMode = () => 'active';
    await t.api.uploadBatchWithSessionId(
      [
        {'type': 'RX', 'lat': 45.0, 'lon': -75.0}
      ],
      'offline-20260909-0001',
    );
    expect(lastBody(t.bodies).containsKey('auto_mode'), isFalse);
  });
}
