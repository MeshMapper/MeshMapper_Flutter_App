import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// A wardrive batch that lands on a closed keep-alive socket is replayed
/// once. If a live auth withdrew scope discovery while that first attempt
/// was failing, the replay must not carry the SCOPES answers the queue only
/// selected because the gate was open when the batch was built.
void main() {
  Map<String, dynamic> authBody({required bool offered}) => {
        'success': true,
        'session_id': 'YOW-20260927-0001',
        'tx_allowed': true,
        'rx_allowed': true,
        'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
        if (offered) 'scope_discovery': false,
      };

  Future<void> auth(ApiService api) => api.requestAuth(
        reason: 'connect',
        publicKey: 'AB' * 32,
        lat: 45.42,
        lon: -75.70,
      );

  final disc = {'type': 'DISC', 'lat': 45.42, 'lon': -75.70};
  final scopes = {'type': 'SCOPES', 'repeater_id': 'AB'};

  ({ApiService api, List<List<dynamic>> bodies}) build({
    required bool withdrawDuringFirstAttempt,
  }) {
    final bodies = <List<dynamic>>[];
    var offered = true;
    var wardriveAttempts = 0;
    late ApiService api;
    api = ApiService(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth')) {
          return http.Response(json.encode(authBody(offered: offered)), 200);
        }
        final body = json.decode(request.body) as Map<String, dynamic>;
        bodies.add(body['data'] as List<dynamic>);
        wardriveAttempts++;
        if (wardriveAttempts == 1) {
          if (withdrawDuringFirstAttempt) {
            offered = false;
            await auth(api);
          }
          throw http.ClientException(
            'Connection closed before full header was received',
            request.url,
          );
        }
        return http.Response(
            json.encode({'success': true, 'expires_at': 1789185716}), 200);
      }),
    );
    return (api: api, bodies: bodies);
  }

  test('a replay after the gate closed carries no SCOPES', () async {
    final t = build(withdrawDuringFirstAttempt: true);
    await auth(t.api);
    expect(t.api.scopeDiscoveryOffered, isTrue);

    final result = await t.api.uploadBatch([disc, scopes]);

    expect(t.api.scopeDiscoveryOffered, isFalse);
    expect(t.bodies.length, 2);
    expect(t.bodies.first.map((e) => e['type']), ['DISC', 'SCOPES']);
    expect(t.bodies.last.map((e) => e['type']), ['DISC']);
    expect(result, UploadResult.success);
    t.api.dispose();
  });

  test('a replay with the gate still open is sent unchanged', () async {
    final t = build(withdrawDuringFirstAttempt: false);
    await auth(t.api);

    final result = await t.api.uploadBatch([disc, scopes]);

    expect(t.bodies.length, 2);
    expect(t.bodies.last.map((e) => e['type']), ['DISC', 'SCOPES']);
    expect(result, UploadResult.success);
    t.api.dispose();
  });

  test('a replay left with nothing but SCOPES is not sent at all', () async {
    final t = build(withdrawDuringFirstAttempt: true);
    await auth(t.api);

    final result = await t.api.uploadBatch([scopes]);

    expect(t.bodies.length, 1);
    expect(result, UploadResult.unreachable);
    t.api.dispose();
  });
}
