import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/models/user_preferences.dart';
import 'package:mesh_mapper/services/custom_api_service.dart';

/// The custom third-party endpoint gets the same items MeshMapper accepted,
/// enriched with contact and iata, minus the auto_mode stamp, which is
/// MeshMapper analytics. The radio configuration tag is a fact about the ping
/// and is kept. DEFER items pass through unchanged.

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

  test('radio_freq is kept on every forwarded item', () async {
    final t = build();
    t.svc.forwardPings([
      {'type': 'TX', 'lat': 45.0, 'lon': -75.0, 'radio_freq': '910.525,62.5,7,5', 'auto_mode': 'active'},
      {'type': 'DEFER', 'lat': 45.0, 'lon': -75.0, 'held': 'tx', 'radio_freq': '910.525,62.5,7,5'},
    ]);
    final sent = await t.sent.timeout(const Duration(seconds: 5));
    expect(sent.length, 2);
    for (final item in sent) {
      expect(item['radio_freq'], '910.525,62.5,7,5');
      expect(item.containsKey('auto_mode'), isFalse);
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

  test('a SCOPES item forwards with the rest of the batch, contact and iata '
      'added, auto_mode absent, fields otherwise unchanged', () async {
    final t = build();
    t.svc.forwardPings([
      {
        'type': 'SCOPES',
        'public_key':
            'A3B2C1D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2',
        'scopes': ['ROOM1', '*'],
        'timestamp': 1757400000,
        'lat': 45.26974,
        'lon': -75.77746,
      },
      {'type': 'DISC', 'lat': 45.0, 'lon': -75.0, 'auto_mode': 'passive'},
    ]);
    final sent = await t.sent.timeout(const Duration(seconds: 5));
    expect(sent, hasLength(2));
    final scopesItem = sent.firstWhere((p) => p['type'] == 'SCOPES');
    expect(scopesItem, {
      'type': 'SCOPES',
      'public_key':
          'A3B2C1D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2',
      'scopes': ['ROOM1', '*'],
      'timestamp': 1757400000,
      'lat': 45.26974,
      'lon': -75.77746,
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

  test('a bare altitude is stripped from a forwarded item, nothing else is',
      () async {
    final t = build();
    t.svc.forwardPings([
      {
        'type': 'TX',
        'lat': 45.0,
        'lon': -75.0,
        'altitude': 84,
        'altitude_acc': 5,
        'noisefloor': -103,
      },
    ]);
    final sent = await t.sent.timeout(const Duration(seconds: 5));
    expect(sent.single.containsKey('altitude'), isFalse);
    expect(sent.single.containsKey('altitude_acc'), isFalse);
    expect(sent.single['noisefloor'], -103);
  });

  test('the altitude trio is kept on every forwarded item', () async {
    final t = build();
    t.svc.forwardPings([
      {
        'type': 'TX',
        'lat': 45.0,
        'lon': -75.0,
        'altitude': 84,
        'altitude_ref': 'msl',
        'altitude_acc': 6,
        'auto_mode': 'active',
      },
    ]);
    final sent = await t.sent.timeout(const Duration(seconds: 5));
    expect(sent.single['altitude'], 84);
    expect(sent.single['altitude_ref'], 'msl');
    expect(sent.single['altitude_acc'], 6);
  });
}
