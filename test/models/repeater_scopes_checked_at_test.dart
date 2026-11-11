import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';

/// `scopes_checked_at` is when the server last asked this repeater for its
/// scopes, across every phone. It is additive and lazy like the backbone
/// fields: absent on any server that predates it, and read by the due
/// rule's server-side check (Rule 1 in scope_discovery_rules.dart).
void main() {
  final base = {
    'id': '4E',
    'hex_id': 'ab' * 32,
    'name': 'Hill',
    'lat': 1.0,
    'lon': 2.0,
    'last_heard': 0,
    'enabled': 1,
  };

  group('parsing', () {
    test('an int timestamp parses as-is', () {
      final r = Repeater.fromJson({...base, 'scopes_checked_at': 1790000000});
      expect(r.scopesCheckedAt, 1790000000);
    });

    test('missing reads null', () {
      final r = Repeater.fromJson(base);
      expect(r.scopesCheckedAt, isNull);
    });

    test('a non-numeric value reads null, never logged', () {
      final r = Repeater.fromJson({...base, 'scopes_checked_at': 'x'});
      expect(r.scopesCheckedAt, isNull);
    });

    test('a num (e.g. 1.79e9) parses as an int', () {
      final r = Repeater.fromJson({...base, 'scopes_checked_at': 1.79e9});
      expect(r.scopesCheckedAt, 1790000000);
    });
  });

  group('round trip', () {
    test('absent stays absent, not an explicit null', () {
      final json = Repeater.fromJson(base).toJson();
      expect(json.containsKey('scopes_checked_at'), isFalse);
    });

    test('a set value round-trips', () {
      final json =
          Repeater.fromJson({...base, 'scopes_checked_at': 1790000000})
              .toJson();
      expect(json['scopes_checked_at'], 1790000000);
      final again = Repeater.fromJson({...base, ...json});
      expect(again.scopesCheckedAt, 1790000000);
    });
  });

  test('copyWith updates the field', () {
    final r = Repeater.fromJson(base).copyWith(scopesCheckedAt: 1790000000);
    expect(r.scopesCheckedAt, 1790000000);
  });
}
