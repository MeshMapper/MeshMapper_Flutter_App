import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// Scope discovery rides two `/auth` fields, same shape as Smart Pinging.
/// The key's PRESENCE is the gate: a server that predates the feature never
/// sends it, and the app must never ask a repeater for its scopes without it.
void main() {
  Map<String, dynamic> authBody(Map<String, dynamic> extra) => {
        'success': true,
        'session_id': 'YOW-20260905-0001',
        'tx_allowed': true,
        'rx_allowed': true,
        'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
        ...extra,
      };

  Future<ApiService> authed(Map<String, dynamic> extra,
      {bool skipSessionStore = false}) async {
    final api = ApiService(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth')) {
          return http.Response(json.encode(authBody(extra)), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    // requestAuth throws without coordinates on a connect, so a fix is
    // part of the request shape here (as in api_service_smart_ping_test).
    await api.requestAuth(
      reason: 'connect',
      publicKey: 'AB' * 32,
      lat: 45.42,
      lon: -75.70,
      skipSessionStore: skipSessionStore,
    );
    return api;
  }

  group('auth parsing', () {
    test('key absent: not offered, not enforced, 14 days', () async {
      final api = await authed({});
      expect(api.scopeDiscoveryOffered, isFalse);
      expect(api.enforceScopeDiscovery, isFalse);
      expect(api.apiScopeRefreshDays, 14);
    });

    test('false: offered, not enforced', () async {
      final api = await authed({'scope_discovery': false});
      expect(api.scopeDiscoveryOffered, isTrue);
      expect(api.enforceScopeDiscovery, isFalse);
    });

    test('true and 1 both enforce', () async {
      expect((await authed({'scope_discovery': true})).enforceScopeDiscovery,
          isTrue);
      expect(
          (await authed({'scope_discovery': 1})).enforceScopeDiscovery,
          isTrue);
    });

    test('days: 3 reads as 7, "x" as 14, 30 as 30', () async {
      expect(
          (await authed({'scope_discovery': true, 'scope_refresh_days': 3}))
              .apiScopeRefreshDays,
          7);
      expect(
          (await authed(
                  {'scope_discovery': true, 'scope_refresh_days': 'x'}))
              .apiScopeRefreshDays,
          14);
      expect(
          (await authed({'scope_discovery': true, 'scope_refresh_days': 30}))
              .apiScopeRefreshDays,
          30);
    });

    test('a later auth without the key withdraws the offer', () async {
      var body = authBody({'scope_discovery': true});
      final api = ApiService(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth')) {
            return http.Response(json.encode(body), 200);
          }
          return http.Response('{}', 404);
        }),
      );
      await api.requestAuth(
          reason: 'connect', publicKey: 'AB' * 32, lat: 45.42, lon: -75.70);
      expect(api.scopeDiscoveryOffered, isTrue);

      body = authBody({});
      await api.requestAuth(
          reason: 'connect', publicKey: 'AB' * 32, lat: 45.42, lon: -75.70);
      expect(api.scopeDiscoveryOffered, isFalse);
    });

    test('skipSessionStore auth leaves the fields alone', () async {
      final api = await authed(
        {'scope_discovery': true, 'scope_refresh_days': 30},
        skipSessionStore: true,
      );
      expect(api.scopeDiscoveryOffered, isFalse);
      expect(api.enforceScopeDiscovery, isFalse);
      expect(api.apiScopeRefreshDays, 14);
    });
  });
}
