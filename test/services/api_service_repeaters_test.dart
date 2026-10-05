import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/services/scope_discovery/scope_lifecycle.dart';

void main() {
  const filter = {'f_freq': '910.525', 'f_bw': '62.5', 'f_sf': '7'};
  final body = jsonEncode([
    {
      'id': 'ab',
      'hex_id': 'ab1234',
      'name': 'Enabled',
      'enabled': 1,
      'lat': 45,
      'lon': -75,
      'last_heard': 1
    },
    {
      'id': 'cd',
      'hex_id': 'cd1234',
      'name': 'Disabled',
      'enabled': 0,
      'lat': 45,
      'lon': -75,
      'last_heard': 1
    },
  ]);

  for (final host in ['YOW', 'GROUP']) {
    for (final preset in [null, filter]) {
      test('$host sends the App key without a session, preset=$preset',
          () async {
        http.Request? seen;
        final api = ApiService(client: MockClient((request) async {
          seen = request;
          return http.Response(body, 200);
        }))
          ..radioFilterGetter = () => preset;
        addTearDown(api.dispose);
        expect(api.sessionId, isNull);
        final result = await api.fetchRepeaters(host);
        expect(seen!.method, 'GET');
        expect(seen!.headers['X-API-Key'], ApiService.apiKey);
        expect(seen!.url.host, '${host.toLowerCase()}.meshmapper.net');
        expect(seen!.url.path, '/get_repeaters.php');
        expect(seen!.url.queryParameters, preset ?? <String, String>{});
        expect(result.map((r) => r.name), ['Enabled']);
        expect(api.sessionId, isNull);
      });
    }
  }

  for (final status in [401, 403, 429, 500]) {
    test('$status is a failure, never an empty success or anonymous retry',
        () async {
      var calls = 0;
      final api = ApiService(client: MockClient((request) async {
        calls++;
        expect(request.headers['X-API-Key'], ApiService.apiKey);
        return http.Response('{"error":"rejected"}', status);
      }));
      addTearDown(api.dispose);
      await expectLater(
          api.fetchRepeaters('YOW'),
          throwsA(
            isA<RepeaterFetchException>()
                .having((e) => e.statusCode, 'HTTP status', status)
                .having((e) => e.isAuthenticationFailure, 'auth failure',
                    status == 401 || status == 403),
          ));
      await expectLater(api.fetchRepeaters('YOW'), throwsException);
      expect(calls, 1);
    });
  }

  for (final retryAfter in ['120', 'bad', null]) {
    test('429 honors backoff ($retryAfter) without blocking another host',
        () async {
      var now = DateTime.utc(2026, 10, 4);
      final calls = <String>[];
      final api = ApiService(
          now: () => now,
          client: MockClient((request) async {
            calls.add(request.url.host);
            if (calls.length == 1) {
              return http.Response('', 429,
                  headers: {if (retryAfter != null) 'retry-after': retryAfter});
            }
            return http.Response('[]', 200);
          }));
      addTearDown(api.dispose);
      await expectLater(api.fetchRepeaters('YOW'), throwsException);
      await expectLater(api.fetchRepeaters('yow'), throwsException);
      expect(await api.fetchRepeaters('GROUP'), isEmpty);
      final wait = retryAfter == '120' ? 120 : 75;
      now = now.add(Duration(seconds: wait - 1));
      await expectLater(api.fetchRepeaters('YOW'), throwsException);
      expect(calls.length, 2);
      now = now.add(const Duration(seconds: 1));
      expect(await api.fetchRepeaters('YOW'), isEmpty);
      expect(calls.length, 3);
    });
  }

  test('overlapping failures never shorten a server backoff', () async {
    var now = DateTime.utc(2026, 10, 4);
    final responses = [Completer<http.Response>(), Completer<http.Response>()];
    var calls = 0;
    final api = ApiService(
        now: () => now,
        client: MockClient((_) {
          final call = calls++;
          return call < 2
              ? responses[call].future
              : Future.value(http.Response('[]', 200));
        }));
    addTearDown(api.dispose);
    final first = expectLater(api.fetchRepeaters('YOW'), throwsException);
    final second = expectLater(api.fetchRepeaters('YOW'), throwsException);
    responses[0]
        .complete(http.Response('', 429, headers: {'retry-after': '600'}));
    await first;
    responses[1].complete(http.Response('', 500));
    await second;
    now = now.add(const Duration(seconds: 60));
    await expectLater(api.fetchRepeaters('YOW'), throwsException);
    expect(calls, 2);
    now = now.add(const Duration(seconds: 540));
    expect(await api.fetchRepeaters('YOW'), isEmpty);
    expect(calls, 3);
  });

  test('the same App key is sent after session acquisition and on refresh',
      () async {
    final headers = <Map<String, String>>[];
    final api = ApiService(client: MockClient((request) async {
      if (request.url.path.endsWith('/auth')) {
        return http.Response(
            jsonEncode({
              'success': true,
              'session_id': 'test-session',
              'tx_allowed': true,
              'rx_allowed': true,
              'expires_at':
                  DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
            }),
            200);
      }
      headers.add(request.headers);
      return http.Response(body, 200);
    }));
    addTearDown(api.dispose);
    await api.fetchRepeaters('YOW');
    await api.requestAuth(
        reason: 'connect', publicKey: 'AB', lat: 45, lon: -75);
    expect(api.sessionId, 'test-session');
    await api.fetchRepeaters('YOW');
    await api.fetchRepeaters('GROUP');
    expect(headers.length, 3);
    for (final h in headers) {
      expect(h['X-API-Key'], ApiService.apiKey);
      expect(h.containsKey('session_id'), isFalse);
    }
  });

  test('the 15 second repeater timeout is preserved', () {
    fakeAsync((time) {
      final response = Completer<http.Response>();
      final api = ApiService(client: MockClient((_) => response.future));
      Object? failure;
      api.fetchRepeaters('YOW').then<void>((_) => fail('must time out'),
          onError: (Object e) {
        failure = e;
      });
      time.elapse(const Duration(seconds: 14));
      expect(failure, isNull);
      time.elapse(const Duration(seconds: 1));
      expect(failure, isA<RepeaterFetchException>());
      response.complete(http.Response('[]', 200));
      time.flushMicrotasks();
      api.dispose();
    });
  });

  for (final changePreset in [false, true]) {
    test(
        'a delayed list is discarded after ${changePreset ? 'preset' : 'region/group'} changes',
        () async {
      final response = Completer<http.Response>();
      final api = ApiService(client: MockClient((_) => response.future));
      addTearDown(api.dispose);
      var zone = 'YOW';
      String? preset;
      final lifecycle =
          ScopeLifecycle(cancelHostRunner: (_) {}, onBadgeChanged: () {});
      final pending = lifecycle.resultIfStillCurrent(
        fetch: api.fetchRepeaters(zone),
        zone: zone,
        preset: preset,
        currentZone: () => zone,
        currentPreset: () => preset,
      );
      if (changePreset) {
        preset = '910.525,62.5,7';
      } else {
        zone = 'GROUP';
      }
      response.complete(http.Response(body, 200));
      expect(await pending, isNull);
    });
  }

  for (final error in [
    TimeoutException('timeout'),
    http.ClientException('offline'),
    const FormatException('invalid')
  ]) {
    test('$error is a failure instead of an empty list', () async {
      final api = ApiService(client: MockClient((_) async => throw error));
      addTearDown(api.dispose);
      await expectLater(api.fetchRepeaters('YOW'), throwsException);
    });
  }

  test('malformed response is a failure', () async {
    final api =
        ApiService(client: MockClient((_) async => http.Response('{}', 200)));
    addTearDown(api.dispose);
    await expectLater(api.fetchRepeaters('YOW'), throwsException);
  });

  for (final status in [401, 403, 429, 500]) {
    test('scope refresh rejects $status instead of replacing a loaded list',
        () async {
      var statusCode = 200;
      final api = ApiService(
          client: MockClient((_) async => http.Response(body, statusCode)));
      addTearDown(api.dispose);
      await api.fetchRepeaters('YOW');
      final lifecycle =
          ScopeLifecycle(cancelHostRunner: (_) {}, onBadgeChanged: () {});
      statusCode = status;
      final result = await lifecycle.resultIfStillCurrent(
        fetch: api.fetchRepeaters('YOW'),
        zone: 'YOW',
        preset: null,
        currentZone: () => 'YOW',
        currentPreset: () => null,
      );
      expect(result, isNull);
    });
  }
}
