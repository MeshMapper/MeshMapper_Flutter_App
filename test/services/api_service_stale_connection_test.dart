import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// Apache closes an idle keep-alive connection after 5 seconds; Dart's
/// HttpClient keeps it in the pool for 15. A request written into that gap is
/// put on a socket the server has already hung up on, and comes back as
/// `ClientException: Connection closed before full header was received`.
///
/// The server never sees such a request (it leaves no access-log entry), so
/// replaying it once is safe. Before this, one dead socket on `/auth` failed
/// the whole connect and the user had to press Connect again: on 2026-09-12 at
/// 04:02:02 UTC the request that failed on the phone never reached Apache, and
/// the retry the user made by hand succeeded eight seconds later. Across the
/// submitted debug logs the same failure appears 117 times, two thirds of them
/// at exactly five seconds of idle.
void main() {
  /// A mock server that throws [failures] times before answering. [thrown] is
  /// the error each failing attempt raises.
  ({ApiService api, List<String> attempts}) build({
    required int failures,
    Object? thrown,
  }) {
    final attempts = <String>[];
    final api = ApiService(
      client: MockClient((request) async {
        attempts.add(request.url.path);
        if (attempts.length <= failures) {
          throw thrown ??
              http.ClientException(
                'Connection closed before full header was received',
                request.url,
              );
        }
        return http.Response(
          json.encode({
            'success': true,
            'session_id': 'YOW-20260912-0001',
            'tx_allowed': true,
            'rx_allowed': true,
            'expires_at': 1789185716,
            'in_zone': true,
          }),
          200,
        );
      }),
    );
    return (api: api, attempts: attempts);
  }

  Future<Map<String, dynamic>?> connect(ApiService api) => api.requestAuth(
        reason: 'connect',
        publicKey: '8482E61880C65C13',
        appVersion: 'APP-TEST',
        lat: 45.26979,
        lon: -75.77749,
        accuracyMeters: 9.4,
      );

  test('a connect that lands on a closed keep-alive socket still gets a session',
      () async {
    final t = build(failures: 1);

    final data = await connect(t.api);

    expect(data?['session_id'], 'YOW-20260912-0001');
    expect(t.attempts.length, 2);
  });

  test('a zone check that lands on a closed keep-alive socket still answers',
      () async {
    final t = build(failures: 1);

    final data = await t.api.checkZoneStatus(
      lat: 45.26979,
      lon: -75.77749,
      accuracyMeters: 9.4,
      appVersion: 'APP-TEST',
    );

    expect(data?['in_zone'], true);
    expect(t.attempts.length, 2);
  });

  test('the replay is tried once, not in a loop', () async {
    final t = build(failures: 99);

    final data = await connect(t.api);

    expect(data, isNull);
    expect(t.attempts.length, 2);
  });

  test('a request that failed for any other reason is not replayed', () async {
    final t = build(
      failures: 99,
      thrown: http.ClientException('Software caused connection abort'),
    );

    final data = await connect(t.api);

    expect(data, isNull);
    expect(t.attempts.length, 1);
  });
}
