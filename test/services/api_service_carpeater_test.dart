import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/utils/debug_logger_io.dart';

/// The CARpeater lane on `/auth`: the user's own key goes out as `carpeater`
/// on connect and register (never on an offline-mode auth), and every LIVE
/// answer hands back the region's `carpeaters` list plus an optional
/// `carpeater_error`, replacing the last list in full. An offline-mode or
/// skipSessionStore auth is not a live auth and leaves the cache alone.
///
/// The list is also a pile of public keys, so it may never reach a log line:
/// a debug log file ships with bug reports.
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

    test('an offline-mode auth leaves the cached list alone', () async {
      // The offline upload authenticates only to close out its own isolated
      // session (offlineMode + skipSessionStore). It never sends the user's
      // own `carpeater`, and a server answering it without the field would
      // otherwise empty the very cache Offline Mode exists to keep.
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

      var listenerFired = false;
      api.onRegionalCarpeaters = (_, __) => listenerFired = true;
      await api.requestAuth(
          reason: 'connect',
          publicKey: 'AA' * 32,
          lat: 45.42,
          lon: -75.70,
          offlineMode: true,
          skipSessionStore: true);
      expect(api.regionalCarpeaters, [a],
          reason: 'an offline-mode auth is not a live auth and must not '
              'replace the region list');
      expect(listenerFired, isFalse);
    });

    test('an offline-mode auth does not adopt a list either', () async {
      // The other direction: whatever such an answer carries is ignored, so
      // the cache only ever changes on a live connect or register.
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
      expect(t.api.regionalCarpeaters, isEmpty);
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

  group('logging', () {
    /// Captures every debug line the call writes.
    List<String> captureLogs() {
      final logs = <String>[];
      final originalPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      DebugLogger.setEnabled(true);
      addTearDown(() {
        debugPrint = originalPrint;
        DebugLogger.setEnabled(false);
      });
      return logs;
    }

    test('a failed auth never logs the region key list', () async {
      // A 500 that still carries `carpeaters` used to be logged verbatim, and
      // a debug log file ships with bug reports.
      final logs = captureLogs();
      final body = json.encode({
        'success': false,
        'reason': 'server_error',
        'carpeaters': [a, b],
      });
      final api = ApiService(
        client: MockClient((request) async => http.Response(body, 500)),
      );
      await api.requestAuth(
          reason: 'connect', publicKey: 'AA' * 32, lat: 45.42, lon: -75.70);

      final joined = logs.join('\n');
      expect(joined, isNot(contains(a)), reason: 'a region key leaked');
      expect(joined, isNot(contains(b)), reason: 'a region key leaked');
      expect(joined, contains('server_error'),
          reason: 'the useful half of the body should survive redaction');
    });

    test('a parse error never quotes the body tail back into the log',
        () async {
      // FormatException.toString() quotes a window of the source around the
      // parse offset, so logging the exception itself hands back the tail of
      // the very body this lane just redacted. Here the tail is a full key.
      final logs = captureLogs();
      final body = '{"padding":"${'z' * 300}","carpeaters":["$a"';
      final api = ApiService(
        client: MockClient((request) async => http.Response(body, 200)),
      );
      await api.requestAuth(
          reason: 'connect', publicKey: 'AA' * 32, lat: 45.42, lon: -75.70);

      final joined = logs.join('\n');
      expect(joined, isNot(contains(a)),
          reason: 'the parse error quoted the body tail back into the log');
      expect(joined, contains('FormatException'),
          reason: 'the failure should still be identifiable');
    });

    test('a non-JSON body is truncated instead of logged whole', () async {
      final logs = captureLogs();
      final body = '<html>${'x' * 4000}</html>';
      final api = ApiService(
        client: MockClient((request) async => http.Response(body, 502)),
      );
      await api.requestAuth(
          reason: 'connect', publicKey: 'AA' * 32, lat: 45.42, lon: -75.70);

      final joined = logs.join('\n');
      expect(joined, isNot(contains('x' * 250)));
      expect(joined, contains('truncated'));
    });
  });
}
