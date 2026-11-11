import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/models/user_preferences.dart';
import 'package:mesh_mapper/services/api_queue_service.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/services/custom_api_service.dart';

/// The queue builds a batch with SCOPES while scope discovery is offered.
/// If a live auth withdraws it while the first POST is failing on a dead
/// keep-alive socket, the replay leaves the answers out, and so must the
/// forward to the third-party endpoint that follows a successful upload.
void main() {
  const key = 'A3B2C1D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2';

  test('a replay that dropped SCOPES does not forward them either', () async {
    var offered = true;
    var attempts = 0;
    final posted = <List<dynamic>>[];
    late ApiService api;
    Future<void> auth() => api.requestAuth(
        reason: 'connect', publicKey: 'AB' * 32, lat: 45.0, lon: -75.0);
    api = ApiService(client: MockClient((request) async {
      if (request.url.path.endsWith('/auth')) {
        return http.Response(
            json.encode({
              'success': true,
              'session_id': 'YOW-20260927-0001',
              'tx_allowed': true,
              'rx_allowed': true,
              if (offered) 'scope_discovery': false,
            }),
            200);
      }
      posted.add((json.decode(request.body) as Map)['data'] as List);
      attempts++;
      if (attempts == 1) {
        offered = false;
        await auth();
        throw http.ClientException(
            'Connection closed before full header was received', request.url);
      }
      return http.Response(json.encode({'success': true}), 200);
    }));
    await auth();

    final forwarded = <List<dynamic>>[];
    final custom = CustomApiService(
      prefsGetter: () => const UserPreferences(
          customApiEnabled: true,
          customApiUrl: 'https://example.invalid/ingest',
          customApiKey: 'k'),
      client: MockClient((request) async {
        forwarded.add((json.decode(request.body) as Map)['data'] as List);
        return http.Response('{}', 200);
      }),
    );
    final queue = ApiQueueService(apiService: api)
      ..customApiService = custom;
    queue.scopesAllowedGetter = () => api.scopeDiscoveryOffered;
    final uploaded = <(int, List<String>)>[];
    queue.onUploadSuccess =
        (count, items) => uploaded.add((count, [for (final i in items) i.type]));

    await queue.enqueueDisc(
      latitude: 45.0,
      longitude: -75.0,
      repeaterId: 'A3',
      nodeType: 'REPEATER',
      localSnr: 10.5,
      localRssi: -88,
      remoteSnr: 8.25,
      pubkeyFull: key,
      timestamp: 1757400000,
      externalAntenna: false,
    );
    await queue.enqueueScopes(
      publicKeyHex: key,
      scopes: ['*'],
      lat: 45.0,
      lon: -75.0,
      timestamp: 1757400001,
      expectedGeneration: queue.generation,
    );

    await queue.flushQueue();
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(posted.first.map((e) => e['type']).toSet(), {'DISC', 'SCOPES'});
    expect(posted.last.map((e) => e['type']), ['DISC']);
    expect(forwarded, hasLength(1));
    expect(forwarded.single.map((e) => e['type']), ['DISC']);
    expect(queue.queueSize, 0);
    // Only what the replay actually sent counts as uploaded.
    expect(uploaded, hasLength(1));
    expect(uploaded.single.$1, 1);
    expect(uploaded.single.$2, ['DISC']);
    api.dispose();
  });
}
