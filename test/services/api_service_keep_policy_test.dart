import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// A group handoff releases the old session and mints a new one at once.
/// For those two round trips the app is still connected, and the UI reads
/// txAllowed, the channels and the enforce flags on every notify: a plain
/// release zeroed them, so the Active button vanished, the status bar went
/// red with "at capacity" and Smart Pinging dropped its tiles. A keepPolicy
/// release clears only the session itself.
void main() {
  ApiService build() => ApiService(
        client: MockClient((request) async {
          final body = json.decode(request.body) as Map<String, dynamic>;
          if (body['reason'] == 'connect') {
            return http.Response(
              json.encode({
                'success': true,
                'session_id': 'YOW-20261012-0001',
                'tx_allowed': true,
                'rx_allowed': true,
                'expires_at': 1800000000,
                'channels': ['#ottawa'],
                'enforce_hybrid': true,
                'hop_bytes': 2,
                'smart_ping': true,
                'smart_ping_days': 7,
                'scope_discovery': true,
              }),
              200,
            );
          }
          return http.Response(json.encode({'success': true}), 200);
        }),
      );

  Future<void> connect(ApiService api) => api.requestAuth(
        reason: 'connect',
        publicKey: 'AB',
        lat: 45.27,
        lon: -75.78,
      );

  test('a keepPolicy release clears the session but keeps the zone policy',
      () async {
    final api = build();
    await connect(api);
    expect(api.hasSession, isTrue);
    expect(api.txAllowed, isTrue);

    await api.requestAuth(
        reason: 'disconnect', publicKey: 'AB', keepPolicy: true);

    expect(api.hasSession, isFalse);
    expect(api.sessionId, isNull);
    expect(api.txAllowed, isTrue, reason: 'the Active button stays');
    expect(api.rxAllowed, isTrue);
    expect(api.channels, ['#ottawa']);
    expect(api.enforceHybrid, isTrue);
    expect(api.apiHopBytes, 2);
    expect(api.enforceSmartPing, isTrue);
    expect(api.scopeDiscoveryOffered, isTrue);

    // The mint that follows overwrites every kept field.
    await connect(api);
    expect(api.hasSession, isTrue);
    expect(api.txAllowed, isTrue);
    api.dispose();
  });

  test('a plain release still clears the policy with the session', () async {
    final api = build();
    await connect(api);

    await api.requestAuth(reason: 'disconnect', publicKey: 'AB');

    expect(api.hasSession, isFalse);
    expect(api.txAllowed, isFalse);
    expect(api.rxAllowed, isFalse);
    expect(api.channels, isEmpty);
    expect(api.enforceHybrid, isFalse);
    expect(api.apiHopBytes, 1);
    expect(api.scopeDiscoveryOffered, isFalse);
    api.dispose();
  });

  test('clearSession forgets a kept policy when no mint follows', () async {
    final api = build();
    await connect(api);
    await api.requestAuth(
        reason: 'disconnect', publicKey: 'AB', keepPolicy: true);
    expect(api.txAllowed, isTrue);

    api.clearSession();

    expect(api.hasSession, isFalse);
    expect(api.txAllowed, isFalse);
    expect(api.channels, isEmpty);
    api.dispose();
  });
}
