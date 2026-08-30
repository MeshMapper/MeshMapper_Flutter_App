import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// Regression tests for the 2026-08-29 heartbeat POST storm (361k requests in
/// 64 minutes from one device).
///
/// The trigger: expires_at comes from the SERVER clock while the scheduling
/// math runs on the DEVICE clock. A device clock running further ahead of the
/// server than TTL minus the 1-minute buffer (4+ minutes at the server's 300s
/// TTL) makes every freshly-extended expiry look already due, and the old
/// "expired, send immediately" path re-fired the next heartbeat straight from
/// the success response with no minimum interval. scheduleHeartbeat() also
/// cancels only timers, never an in-flight send, so every upload success and
/// per-ping session check stacked another self-sustaining chain.
void main() {
  /// Builds an ApiService whose mock server always answers success with the
  /// given expires_at, counting heartbeat POSTs. After [maxHeartbeats] the
  /// server kills the session so a hot-looping client cannot hang the test.
  ({ApiService api, List<DateTime> heartbeats}) build({
    required int Function() expiresAt,
    int maxHeartbeats = 100,
  }) {
    final heartbeats = <DateTime>[];
    final api = ApiService(
      client: MockClient((request) async {
        final body = json.decode(request.body) as Map<String, dynamic>;
        if (request.url.path.endsWith('/auth')) {
          return http.Response(
            json.encode({
              'success': true,
              'session_id': 'YOW-20260830-0001',
              'tx_allowed': true,
              'rx_allowed': true,
              'expires_at': expiresAt(),
            }),
            200,
          );
        }
        if (body['heartbeat'] == true) {
          heartbeats.add(DateTime.now());
          if (heartbeats.length >= maxHeartbeats) {
            return http.Response(
              json.encode({
                'success': false,
                'reason': 'session_expired',
                'message': 'killed by test backstop',
              }),
              401,
            );
          }
          return http.Response(
            json.encode({'success': true, 'expires_at': expiresAt()}),
            200,
          );
        }
        return http.Response(
          json.encode({'success': true, 'expires_at': expiresAt()}),
          200,
        );
      }),
    );
    return (api: api, heartbeats: heartbeats);
  }

  void connect(FakeAsync async, ApiService api) {
    api.requestAuth(
      reason: 'connect',
      publicKey: 'AB',
      lat: 45.0,
      lon: -75.0,
    );
    async.flushMicrotasks();
  }

  test('a stale expires_at never hot-loops heartbeats on success', () {
    fakeAsync((async) {
      // Device clock "ahead": the server's answer always looks expired.
      final built = build(
          expiresAt: () =>
              DateTime.now().millisecondsSinceEpoch ~/ 1000 - 100);
      connect(async, built.api);

      built.api.enableHeartbeat();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 5));

      // One immediate catch-up send, then paced at the spacing floor: at a
      // 30s floor that is at most 11 in 5 minutes. The unfixed loop reaches
      // the 100-send backstop within the first flush.
      expect(built.heartbeats.length, inInclusiveRange(1, 12),
          reason: 'heartbeats must be paced by a minimum interval even when '
              'expires_at always reads as already expired');
    });
  });

  test('repeated scheduleHeartbeat calls do not stack concurrent chains', () {
    fakeAsync((async) {
      final built = build(
          expiresAt: () =>
              DateTime.now().millisecondsSinceEpoch ~/ 1000 - 100);
      connect(async, built.api);

      built.api.enableHeartbeat();
      async.flushMicrotasks();
      // Simulate what the storm did: every upload success and per-ping
      // session check re-enters scheduleHeartbeat while state reads expired.
      for (var i = 0; i < 5; i++) {
        built.api.scheduleHeartbeat(
            DateTime.now().millisecondsSinceEpoch ~/ 1000 - 100);
        async.flushMicrotasks();
      }
      async.elapse(const Duration(minutes: 2));

      expect(built.heartbeats.length, inInclusiveRange(1, 6),
          reason: 're-entrant scheduling must coalesce into one paced chain, '
              'not one chain per caller');
    });
  });

  test('a healthy expiry still schedules the normal keepalive', () {
    fakeAsync((async) {
      final built = build(
          expiresAt: () =>
              DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300);
      connect(async, built.api);

      built.api.enableHeartbeat();
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 230));
      expect(built.heartbeats, isEmpty,
          reason: 'keepalive fires 1 minute before expiry, not earlier');

      async.elapse(const Duration(seconds: 20));
      expect(built.heartbeats.length, 1,
          reason: 'the ordinary pre-expiry keepalive must still go out');
    });
  });
}
