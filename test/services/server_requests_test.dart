import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/models/user_preferences.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/services/custom_api_service.dart';
import 'package:mesh_mapper/services/debug_submit_service.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_api.dart';
import 'package:mesh_mapper/services/server_config.dart';

const _liveKey = 'live-key-for-tests';
const _customKey = 'custom-key-for-tests';

/// Sends one of every request that carries the app key, and records each.
Future<List<http.BaseRequest>> _sendEverything() async {
  final requests = <http.BaseRequest>[];
  final client = MockClient((request) async {
    requests.add(request);
    return http.Response('{"success":false,"reason":"test"}', 200);
  });
  final api = ApiService(client: client);
  await api.checkZoneStatus(
      lat: 45.4, lon: -75.7, accuracyMeters: 5, appVersion: '1.0.0');
  await api.requestAuth(
      reason: 'connect', publicKey: 'AB' * 32, lat: 45.4, lon: -75.7);
  await api.fetchBorderPolygons(lat: 45.4, lon: -75.7, appVersion: '1.0.0');
  await api.fetchDeviceCatalog();
  await api.reportUnknownDevice(manufacturer: 'Test', appVersion: '1.0.0');
  await api.uploadBatchWithSessionId([
    {'type': 'TX', 'lat': 45.4, 'lon': -75.7}
  ], 'session-1');
  try {
    await api.fetchRepeaters('YOW');
  } catch (_) {}
  await api.fetchRepeaterCoverage(zone: 'YOW', prefix: 'AB');
  await RepeaterAdminApi(
    client: client,
    sessionId: () => 'session-1',
    appVersion: () => '1.0.0',
    radioConfig: () => null,
  ).mine();
  await DebugSubmitService(client: client, retryDelayUnit: Duration.zero)
      .createTicket(
          title: 't', body: 'b', platform: 'app', ticketType: 'bug');
  return requests;
}

/// Every place a request can carry a key: body, header, query.
String _everythingSent(http.BaseRequest request) => [
      request.url.toString(),
      request.headers.toString(),
      if (request is http.Request) request.body,
    ].join('\n');

void main() {
  setUp(() {
    ServerConfig.resetForTest();
    ServerConfig.buildKeyForTest = _liveKey;
  });
  tearDown(ServerConfig.resetForTest);

  test('Live: /status is exactly the request the app has always sent',
      () async {
    late http.Request sent;
    final api = ApiService(
      client: MockClient((request) async {
        sent = request;
        return http.Response('{"success":true,"in_zone":false}', 200);
      }),
    );
    await api.checkZoneStatus(
      lat: 45.4215,
      lon: -75.6972,
      accuracyMeters: 4.5,
      appVersion: '1.2.3',
      radioFreq: '910.525,62.5,7,5',
    );

    expect(sent.method, 'POST');
    expect(sent.url.toString(),
        'https://meshmapper.net/wardrive-api.php/status');
    final body = json.decode(sent.body) as Map<String, dynamic>;
    final timestamp = body.remove('timestamp');
    expect(timestamp, isA<int>());
    // Same keys, same order, same values: the encoded body is unchanged.
    expect(
      json.encode(body),
      json.encode({
        'lat': 45.4215,
        'lng': -75.6972,
        'accuracy_m': 4.5,
        'ver': '1.2.3',
        'key': _liveKey,
        'radio_freq': '910.525,62.5,7,5',
      }),
    );
  });

  test('Live: the repeater read and the coverage post go to the region host',
      () async {
    final requests = <http.Request>[];
    final api = ApiService(
      client: MockClient((request) async {
        requests.add(request);
        return http.Response('[]', 200);
      }),
    );
    await api.fetchRepeaters('YOW');
    await api.fetchRepeaterCoverage(zone: 'YOW', prefix: 'AB');

    expect(requests[0].url.toString(),
        'https://yow.meshmapper.net/get_repeaters.php');
    expect(requests[0].headers['X-API-Key'], _liveKey);
    expect(requests[1].url.toString(),
        'https://yow.meshmapper.net/app_coverage.php');
    expect((json.decode(requests[1].body) as Map)['key'], _liveKey);
  });

  test('Live: every request goes to live with the live key only', () async {
    final requests = await _sendEverything();
    expect(requests.length, greaterThanOrEqualTo(10));
    for (final request in requests) {
      final sent = _everythingSent(request);
      expect(request.url.host, endsWith('meshmapper.net'), reason: sent);
      expect(request.url.host, isNot(contains('example.org')), reason: sent);
      expect(sent, contains(_liveKey));
      expect(sent, isNot(contains(_customKey)));
    }
  });

  test('Custom: every request goes to the custom server with its key only',
      () async {
    ServerConfig.useCustom(domain: 'dev.example.org', key: _customKey);
    final requests = await _sendEverything();
    expect(requests.length, greaterThanOrEqualTo(10));
    for (final request in requests) {
      final sent = _everythingSent(request);
      expect(request.url.scheme, 'https', reason: sent);
      expect(
          request.url.host == 'dev.example.org' ||
              request.url.host.endsWith('.dev.example.org'),
          isTrue,
          reason: sent);
      expect(sent, contains(_customKey));
      expect(sent, isNot(contains(_liveKey)),
          reason: 'the live key must never reach a custom server');
    }
    expect(
        requests.map((r) => r.url.toString()),
        containsAll([
          'https://dev.example.org/wardrive-api.php/status',
          'https://dev.example.org/wardrive-api.php/auth',
          'https://dev.example.org/wardrive-api.php/border',
          'https://dev.example.org/wardrive-api.php/devices',
          'https://dev.example.org/wardrive-api.php/wardrive',
          'https://dev.example.org/wardrive-api.php/repeater',
          'https://yow.dev.example.org/get_repeaters.php',
          'https://yow.dev.example.org/app_coverage.php',
          'https://dev.example.org/debug/submitdebug.php/create-ticket',
        ]));
  });

  test('the same service follows the server without being rebuilt', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response('{"success":false}', 200);
    });
    // Built on Live, as the app builds them at launch.
    final api = ApiService(client: client);
    final debug = DebugSubmitService(client: client, retryDelayUnit: Duration.zero);

    ServerConfig.useCustom(domain: 'dev.example.org', key: _customKey);
    await api.checkZoneStatus(
        lat: 1, lon: 2, accuracyMeters: 3, appVersion: '1.0.0');
    await debug.createTicket(
        title: 't', body: 'b', platform: 'app', ticketType: 'bug');
    ServerConfig.useLive();
    await api.checkZoneStatus(
        lat: 1, lon: 2, accuracyMeters: 3, appVersion: '1.0.0');
    await debug.createTicket(
        title: 't', body: 'b', platform: 'app', ticketType: 'bug');

    expect(requests.map((r) => r.url.host).toList(), [
      'dev.example.org',
      'dev.example.org',
      'meshmapper.net',
      'meshmapper.net',
    ]);
    expect(
        requests.map((r) => (json.decode(r.body) as Map)['key']).toList(),
        [_customKey, _customKey, _liveKey, _liveKey]);
  });

  test('the vector tile fetch uses the region host of the active server',
      () async {
    final urls = <Uri>[];
    final api = ApiService(
      client: MockClient((request) async {
        urls.add(request.url);
        return http.Response('', 204);
      }),
    );
    await api.fetchRecentCoverageTile(zone: 'YOW', x: 1, y: 2, gsize: 300, days: 7);
    ServerConfig.useCustom(domain: 'dev.example.org', key: _customKey);
    await api.fetchRecentCoverageTile(zone: 'YOW', x: 1, y: 2, gsize: 300, days: 7);
    expect(urls[0].host, 'yow.meshmapper.net');
    expect(urls[1].host, 'yow.dev.example.org');
    expect(urls[1].path, urls[0].path);
    expect(urls[1].query, urls[0].query);
  });

  group('custom API forwarding', () {
    CustomApiService build(List<http.Request> sent) => CustomApiService(
          prefsGetter: () => const UserPreferences(
            customApiEnabled: true,
            customApiUrl: 'https://third-party.test/wardrive',
            customApiKey: 'k',
          ),
          client: MockClient((request) async {
            sent.add(request);
            return http.Response('{}', 200);
          }),
        );

    final pings = [
      {'type': 'TX', 'lat': 45.4, 'lon': -75.7, 'timestamp': 1}
    ];

    test('forwards on Live', () async {
      final sent = <http.Request>[];
      build(sent).forwardPings(pings);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sent, hasLength(1));
    });

    test('is suspended on a custom server: nothing is sent', () async {
      ServerConfig.useCustom(domain: 'dev.example.org', key: _customKey);
      final sent = <http.Request>[];
      build(sent).forwardPings(pings);
      build(sent).forwardPings(pings, source: 'offline');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sent, isEmpty);
    });
  });

  test('no test or source file holds something that looks like a real key',
      () {
    // The dev server key and the live key are never written down. This
    // catches the obvious slip: a long hex or base64 secret assigned to a
    // key-named constant in this feature's files.
    final secret = RegExp(r'''['"][A-Za-z0-9+/=_-]{32,}['"]''');
    for (final path in [
      'lib/services/server_config.dart',
      'lib/services/server_settings_store.dart',
      'lib/services/server_probe.dart',
      'lib/screens/settings/server_settings_card.dart',
    ]) {
      expect(secret.hasMatch(File(path).readAsStringSync()), isFalse,
          reason: path);
    }
  });
}
