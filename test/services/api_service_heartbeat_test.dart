import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/services/idle_session.dart';

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

  test('an expired scheduled heartbeat lets its replacement auth own the lane',
      () {
    fakeAsync((async) {
      final origin = DateTime.utc(2026, 9, 14, 12);
      withClock(Clock(() => origin.add(async.elapsed)), () {
        var auths = 0;
        var heartbeats = 0;
        final api = ApiService(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/auth')) {
              auths++;
              return http.Response(
                json.encode({
                  'success': true,
                  'session_id': 'session-$auths',
                  'tx_allowed': true,
                  'rx_allowed': true,
                  'expires_at':
                      clock.now().millisecondsSinceEpoch ~/ 1000 + 300,
                }),
                200,
              );
            }
            heartbeats++;
            if (heartbeats == 1) {
              return http.Response(
                json.encode({
                  'success': false,
                  'reason': 'session_expired',
                  'message': 'expired for test',
                }),
                401,
              );
            }
            return http.Response(
              json.encode({
                'success': true,
                'expires_at':
                    clock.now().millisecondsSinceEpoch ~/ 1000 + 300,
              }),
              200,
            );
          }),
        );
        api.onSessionExpiredRecovery = () async {
          await api.requestAuth(
            reason: 'connect',
            publicKey: 'AB',
            lat: 45.0,
            lon: -75.0,
          );
          return SessionRecoveryResult.recovered;
        };

        api.requestAuth(
          reason: 'connect',
          publicKey: 'AB',
          lat: 45.0,
          lon: -75.0,
        );
        async.flushMicrotasks();
        api.enableHeartbeat();
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 241));
        async.flushMicrotasks();
        expect(heartbeats, 1);
        expect(auths, 2, reason: 'the expired heartbeat triggers one re-auth');

        async.elapse(const Duration(seconds: 230));
        expect(heartbeats, 1,
            reason: 'the old heartbeat chain must not leave a second timer');
        async.elapse(const Duration(seconds: 10));
        expect(heartbeats, 2,
            reason: 'the recovered session schedules its own next heartbeat');
      });
    });
  });

  group('an expired keepalive while idle (#563)', () {
    /// A server whose session has lapsed: every heartbeat answers
    /// session_expired until a new /auth mints a fresh session.
    ({
      ApiService api,
      int Function() auths,
      int Function() heartbeats,
      int Function() recoveries,
    }) buildLapsed(bool Function() idle) {
      var auths = 0;
      var heartbeats = 0;
      var recoveries = 0;
      var lapsed = false;
      late final ApiService api;
      api = ApiService(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth')) {
            auths++;
            // The first auth is the connect; the test then lets it lapse.
            lapsed = auths == 1;
            return http.Response(
              json.encode({
                'success': true,
                'session_id': 'session-$auths',
                'tx_allowed': true,
                'rx_allowed': true,
                'expires_at': clock.now().millisecondsSinceEpoch ~/ 1000 + 300,
              }),
              200,
            );
          }
          heartbeats++;
          if (lapsed) {
            return http.Response(
              json.encode({
                'success': false,
                'reason': 'session_expired',
                'message': 'expired for test',
              }),
              401,
            );
          }
          return http.Response(
            json.encode({
              'success': true,
              'expires_at': clock.now().millisecondsSinceEpoch ~/ 1000 + 300,
            }),
            200,
          );
        }),
      );
      api.onSessionExpiredRecovery = () async {
        recoveries++;
        await api.requestAuth(
          reason: 'connect',
          publicKey: 'AB',
          lat: 45.0,
          lon: -75.0,
        );
        return SessionRecoveryResult.recovered;
      };
      api.isSessionIdle = idle;
      return (
        api: api,
        auths: () => auths,
        heartbeats: () => heartbeats,
        recoveries: () => recoveries,
      );
    }

    void connectAndRunToFirstKeepalive(FakeAsync async, ApiService api) {
      api.requestAuth(
        reason: 'connect',
        publicKey: 'AB',
        lat: 45.0,
        lon: -75.0,
      );
      async.flushMicrotasks();
      api.enableHeartbeat();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 241));
      async.flushMicrotasks();
    }

    bool idleWith({bool autoPingEnabled = false, int queuedItems = 0}) =>
        sessionIsIdle(
          autoPingEnabled: autoPingEnabled,
          autoPingStarting: false,
          pendingDisable: false,
          pingSending: false,
          pingInProgress: false,
          repeaterAdminOpen: false,
          queuedItems: queuedItems,
        );

    test('idle: no recovery, the keepalive stops, the next action recovers',
        () {
      fakeAsync((async) {
        final origin = DateTime.utc(2026, 9, 28, 22);
        withClock(Clock(() => origin.add(async.elapsed)), () {
          final built = buildLapsed(() => idleWith());
          connectAndRunToFirstKeepalive(async, built.api);

          expect(built.heartbeats(), 1);
          expect(built.recoveries(), 0,
              reason: 'an idle app must not mint a session nobody will use');
          expect(built.auths(), 1);
          expect(built.api.sessionId, 'session-1',
              reason: 'the lapsed session is left in place, not cleared');

          async.elapse(const Duration(minutes: 30));
          expect(built.heartbeats(), 1,
              reason: 'the keepalive stops instead of retrying');
          expect(built.recoveries(), 0);

          // The next Start or manual ping runs the session check, which
          // posts its own heartbeat and recovers on the expired answer.
          ({bool isValid, String? reason, String? message})? check;
          built.api.checkSessionValid(lat: 45.0, lon: -75.0).then((r) {
            check = r;
          });
          async.flushMicrotasks();
          expect(check?.isValid, isTrue);
          expect(built.recoveries(), 1);
          expect(built.api.sessionId, 'session-2');

          // The recovered session owns a keepalive again.
          final before = built.heartbeats();
          async.elapse(const Duration(seconds: 241));
          expect(built.heartbeats(), before + 1,
              reason: 'the recovered session schedules its own keepalive');
        });
      });
    });

    test('a running mode still recovers as before', () {
      fakeAsync((async) {
        final origin = DateTime.utc(2026, 9, 28, 22);
        withClock(Clock(() => origin.add(async.elapsed)), () {
          final built = buildLapsed(() => idleWith(autoPingEnabled: true));
          connectAndRunToFirstKeepalive(async, built.api);

          expect(built.recoveries(), 1);
          expect(built.auths(), 2);
          expect(built.api.sessionId, 'session-2');
        });
      });
    });

    test('queued items still recover as before', () {
      fakeAsync((async) {
        final origin = DateTime.utc(2026, 9, 28, 22);
        withClock(Clock(() => origin.add(async.elapsed)), () {
          final built = buildLapsed(() => idleWith(queuedItems: 3));
          connectAndRunToFirstKeepalive(async, built.api);

          expect(built.recoveries(), 1);
          expect(built.auths(), 2);
          expect(built.api.sessionId, 'session-2');
        });
      });
    });
    test('a late expired answer for a replaced session leaves its keepalive',
        () {
      fakeAsync((async) {
        final origin = DateTime.utc(2026, 9, 28, 22);
        withClock(Clock(() => origin.add(async.elapsed)), () {
          var auths = 0;
          var recoveries = 0;
          final heartbeatSessions = <String>[];
          final held = Completer<http.Response>();
          http.Response expired() => http.Response(
                json.encode({
                  'success': false,
                  'reason': 'session_expired',
                  'message': 'expired for test',
                }),
                401,
              );
          late final ApiService api;
          api = ApiService(
            client: MockClient((request) async {
              if (request.url.path.endsWith('/auth')) {
                auths++;
                return http.Response(
                  json.encode({
                    'success': true,
                    'session_id': 'session-$auths',
                    'tx_allowed': true,
                    'rx_allowed': true,
                    'expires_at':
                        clock.now().millisecondsSinceEpoch ~/ 1000 + 300,
                  }),
                  200,
                );
              }
              final body = json.decode(request.body) as Map<String, dynamic>;
              final sid = body['session_id'] as String;
              heartbeatSessions.add(sid);
              if (sid == 'session-1') {
                // The scheduled keepalive is held in flight; the manual
                // check that follows is answered at once.
                if (heartbeatSessions.length == 1) return held.future;
                return expired();
              }
              return http.Response(
                json.encode({
                  'success': true,
                  'expires_at':
                      clock.now().millisecondsSinceEpoch ~/ 1000 + 300,
                }),
                200,
              );
            }),
          );
          api.onSessionExpiredRecovery = () async {
            recoveries++;
            await api.requestAuth(
              reason: 'connect',
              publicKey: 'AB',
              lat: 45.0,
              lon: -75.0,
            );
            return SessionRecoveryResult.recovered;
          };
          api.isSessionIdle = () => idleWith();
          connectAndRunToFirstKeepalive(async, api);
          expect(heartbeatSessions, ['session-1']);

          // A manual action recovers to session-2 while the keepalive for
          // session-1 is still waiting on its answer.
          ({bool isValid, String? reason, String? message})? check;
          api.checkSessionValid(lat: 45.0, lon: -75.0).then((r) {
            check = r;
          });
          async.flushMicrotasks();
          expect(check?.isValid, isTrue);
          expect(api.sessionId, 'session-2');
          expect(recoveries, 1);

          // The stale answer lands with the app idle.
          held.complete(expired());
          async.flushMicrotasks();
          expect(api.sessionId, 'session-2');
          expect(recoveries, 1, reason: 'a stale answer must not re-mint');

          async.elapse(const Duration(seconds: 241));
          expect(heartbeatSessions.last, 'session-2',
              reason: "the replacement session's keepalive survives");
        });
      });
    });
  });
}
