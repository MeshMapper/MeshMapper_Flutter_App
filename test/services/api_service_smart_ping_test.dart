import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// Smart Pinging rides two `/auth` fields. `smart_ping: true` forces the
/// feature on with the server's window; anything else leaves the user's own
/// settings in force, and a missing or invalid window falls back to 14 days.
void main() {
  Map<String, dynamic> authBody(Map<String, dynamic> extra) => {
        'success': true,
        'session_id': 'YOW-20260905-0001',
        'tx_allowed': true,
        'rx_allowed': true,
        'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
        ...extra,
      };

  Future<ApiService> authed(Map<String, dynamic> extra) async {
    final api = ApiService(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth')) {
          return http.Response(json.encode(authBody(extra)), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    // requestAuth throws without coordinates on a connect, so a fix is
    // part of the request shape here (as in api_service_rate_limit_test).
    await api.requestAuth(
      reason: 'connect',
      publicKey: 'AB' * 32,
      lat: 45.42,
      lon: -75.70,
    );
    return api;
  }

  group('auth parsing', () {
    test('defaults to not enforced, 14 days', () async {
      final api = await authed({});
      expect(api.enforceSmartPing, isFalse);
      expect(api.apiSmartPingDays, 14);
    });

    test('reads an enforced window', () async {
      final api = await authed({'smart_ping': true, 'smart_ping_days': 7});
      expect(api.enforceSmartPing, isTrue);
      expect(api.apiSmartPingDays, 7);
    });

    test('a false flag keeps the window it was sent with', () async {
      final api = await authed({'smart_ping': false, 'smart_ping_days': 30});
      expect(api.enforceSmartPing, isFalse);
      expect(api.apiSmartPingDays, 30);
    });

    test('an invalid window falls back to 14', () async {
      expect((await authed({'smart_ping_days': 0})).apiSmartPingDays, 14);
      expect((await authed({'smart_ping_days': -3})).apiSmartPingDays, 14);
      expect((await authed({'smart_ping_days': 'x'})).apiSmartPingDays, 14);
      expect((await authed({'smart_ping_days': 400})).apiSmartPingDays, 14);
    });

    test('a truthy string is not enforcement', () async {
      expect((await authed({'smart_ping': 'true'})).enforceSmartPing, isFalse);
    });
  });

  group('fetchRecentCoverageTile', () {
    http.Request? seen;
    ApiService answering(http.Response Function() responder) => ApiService(
          client: MockClient((request) async {
            seen = request;
            return responder();
          }),
        );

    test('builds the filtered z13 url and returns the body', () async {
      final api = answering(
          () => http.Response.bytes(Uint8List.fromList([1, 2, 3]), 200));
      final body = await api.fetchRecentCoverageTile(
          zone: 'YOW', x: 2385, y: 2926, gsize: 300, days: 14);
      expect(body, [1, 2, 3]);
      expect(seen!.url.host, 'yow.meshmapper.net');
      expect(seen!.url.path, '/vector_tile.php');
      expect(seen!.url.queryParameters, {
        'z': '13',
        'x': '2385',
        'y': '2926',
        'gsize': '300',
        'f_days': '14',
        'f_types': 'green,cyan',
      });
    });

    test('204 means nothing covered here: an empty body, not a failure',
        () async {
      final api = answering(() => http.Response('', 204));
      final body = await api.fetchRecentCoverageTile(
          zone: 'yow', x: 1, y: 1, gsize: 100, days: 7);
      expect(body, isNotNull);
      expect(body, isEmpty);
    });

    test('an HTTP error is a failure', () async {
      final api = answering(() => http.Response('nope', 500));
      expect(
          await api.fetchRecentCoverageTile(
              zone: 'yow', x: 1, y: 1, gsize: 300, days: 7),
          isNull);
    });

    test('a transport failure is a failure', () async {
      final api = ApiService(
          client: MockClient((_) async => throw http.ClientException('down')));
      expect(
          await api.fetchRecentCoverageTile(
              zone: 'yow', x: 1, y: 1, gsize: 300, days: 7),
          isNull);
    });
  });
}
