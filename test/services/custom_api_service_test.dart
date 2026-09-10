import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/models/user_preferences.dart';
import 'package:mesh_mapper/services/custom_api_service.dart';

/// The custom third-party endpoint gets the same items MeshMapper accepted,
/// enriched with contact and iata, minus the auto_mode stamp, which is
/// MeshMapper analytics. DEFER items pass through unchanged.

void main() {
  ({CustomApiService svc, Future<List<Map<String, dynamic>>> sent}) build() {
    final sent = Completer<List<Map<String, dynamic>>>();
    final svc = CustomApiService(
      prefsGetter: () => const UserPreferences(
        customApiEnabled: true,
        customApiUrl: 'https://example.test/wardrive',
        customApiKey: 'k',
        customApiIncludeContact: true,
      ),
      client: MockClient((request) async {
        final body = json.decode(request.body) as Map<String, dynamic>;
        sent.complete(
            (body['data'] as List).cast<Map<String, dynamic>>());
        return http.Response('{}', 200);
      }),
    )
      ..contactGetter = (() => 'D873B1F2')
      ..iataGetter = (() => 'YOW');
    return (svc: svc, sent: sent.future);
  }

  test('auto_mode is stripped from every forwarded item', () async {
    final t = build();
    t.svc.forwardPings([
      {'type': 'TX', 'lat': 45.0, 'lon': -75.0, 'auto_mode': 'active'},
      {'type': 'RX', 'lat': 45.0, 'lon': -75.0, 'auto_mode': 'passive'},
    ]);
    final sent = await t.sent.timeout(const Duration(seconds: 5));
    expect(sent.length, 2);
    for (final item in sent) {
      expect(item.containsKey('auto_mode'), isFalse);
      expect(item['contact'], 'D873B1F2');
      expect(item['iata'], 'YOW');
    }
  });

  test('a DEFER passes through with only contact and iata added', () async {
    final t = build();
    t.svc.forwardPings([
      {
        'type': 'DEFER',
        'lat': 45.26974,
        'lon': -75.77746,
        'timestamp': 1757400000,
        'held': 'tx',
        'auto_mode': 'hybrid',
      },
    ]);
    final sent = await t.sent.timeout(const Duration(seconds: 5));
    expect(sent.single, {
      'type': 'DEFER',
      'lat': 45.26974,
      'lon': -75.77746,
      'timestamp': 1757400000,
      'held': 'tx',
      'contact': 'D873B1F2',
      'iata': 'YOW',
    });
  });

  test('the caller\'s list is not mutated', () async {
    final t = build();
    final original = [
      {'type': 'TX', 'lat': 45.0, 'lon': -75.0, 'auto_mode': 'active'},
    ];
    t.svc.forwardPings(original);
    await t.sent.timeout(const Duration(seconds: 5));
    expect(original.single['auto_mode'], 'active');
  });
}
