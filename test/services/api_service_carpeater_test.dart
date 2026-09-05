import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// The CARpeater lane on `/auth`: the user's own key goes out as `carpeater`
/// on connect and register (never on an offline-mode auth), and every answer
/// hands back the region's `carpeaters` list plus an optional
/// `carpeater_error`, replacing the last list in full.
void main() {
  final own = 'AB' * 32;
  final a = 'CD' * 32;
  final b = 'EF' * 32;

  Map<String, dynamic> authBody(Map<String, dynamic> extra) => {
        'success': true,
        'session_id': 'YOW-20260905-0001',
        'tx_allowed': true,
        'rx_allowed': true,
        'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
        ...extra,
      };

  /// Builds a service whose /auth answers [reply] and records request bodies.
  ({ApiService api, List<Map<String, dynamic>> sent}) build(
      Map<String, dynamic> reply) {
    final sent = <Map<String, dynamic>>[];
    final api = ApiService(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth')) {
          sent.add(json.decode(request.body) as Map<String, dynamic>);
          return http.Response(json.encode(authBody(reply)), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    return (api: api, sent: sent);
  }

  group('request', () {
    test('sends carpeater on connect and register when a key is set', () async {
      final t = build({});
      t.api.carpeaterKey = own;
      await t.api.requestAuth(
          reason: 'connect', publicKey: 'AA' * 32, lat: 45.42, lon: -75.70);
      await t.api.requestAuth(
          reason: 'register', publicKey: 'AA' * 32, lat: 45.42, lon: -75.70);
      expect(t.sent[0]['carpeater'], own);
      expect(t.sent[1]['carpeater'], own);
    });

    test('omits carpeater when no key is set', () async {
      final t = build({});
      await t.api.requestAuth(
          reason: 'connect', publicKey: 'AA' * 32, lat: 45.42, lon: -75.70);
      expect(t.sent.single.containsKey('carpeater'), isFalse);
    });

    test('never sends carpeater on an offline-mode auth', () async {
      final t = build({});
      t.api.carpeaterKey = own;
      await t.api.requestAuth(
          reason: 'connect',
          publicKey: 'AA' * 32,
          lat: 45.42,
          lon: -75.70,
          offlineMode: true,
          skipSessionStore: true);
      expect(t.sent.single.containsKey('carpeater'), isFalse);
    });
  });

  group('response', () {
    test('parses carpeaters into sorted upper keys and drops junk', () async {
      final t = build({
        'carpeaters': [b.toLowerCase(), 'junk', a, a, 7]
      });
      await t.api.requestAuth(
          reason: 'connect', publicKey: 'AA' * 32, lat: 45.42, lon: -75.70);
      expect(t.api.regionalCarpeaters, [a, b]);
      expect(t.api.lastCarpeaterError, isNull);
    });

    test('a missing field is an empty list and replaces the last one', () async {
      // One service, two answers: the second has no `carpeaters` field at all,
      // so the list the first one loaded must be gone.
      var calls = 0;
      final api = ApiService(
        client: MockClient((request) async {
          calls++;
          return http.Response(
              json.encode(authBody(calls == 1
                  ? {
                      'carpeaters': [a]
                    }
                  : {})),
              200);
        }),
      );
      await api.requestAuth(
          reason: 'connect', publicKey: 'AA' * 32, lat: 45.42, lon: -75.70);
      expect(api.regionalCarpeaters, [a]);

      await api.requestAuth(
          reason: 'connect', publicKey: 'AA' * 32, lat: 45.42, lon: -75.70);
      expect(api.regionalCarpeaters, isEmpty);
    });

    test('an offline-mode auth still replaces the list', () async {
      final t = build({
        'carpeaters': [a]
      });
      await t.api.requestAuth(
          reason: 'connect',
          publicKey: 'AA' * 32,
          lat: 45.42,
          lon: -75.70,
          offlineMode: true,
          skipSessionStore: true);
      expect(t.api.regionalCarpeaters, [a]);
    });

    test('carpeater_error is exposed and handed to the callback', () async {
      final t = build({'carpeaters': [], 'carpeater_error': 'max_reached'});
      List<String>? gotKeys;
      String? gotError;
      t.api.onRegionalCarpeaters = (keys, error) {
        gotKeys = keys;
        gotError = error;
      };
      await t.api.requestAuth(
          reason: 'connect', publicKey: 'AA' * 32, lat: 45.42, lon: -75.70);
      expect(t.api.lastCarpeaterError, 'max_reached');
      expect(gotKeys, isEmpty);
      expect(gotError, 'max_reached');
    });

    test('the callback fires with the list on a clean answer', () async {
      final t = build({
        'carpeaters': [a]
      });
      List<String>? gotKeys;
      String? gotError = 'unset';
      t.api.onRegionalCarpeaters = (keys, error) {
        gotKeys = keys;
        gotError = error;
      };
      await t.api.requestAuth(
          reason: 'connect', publicKey: 'AA' * 32, lat: 45.42, lon: -75.70);
      expect(gotKeys, [a]);
      expect(gotError, isNull);
    });
  });
}
