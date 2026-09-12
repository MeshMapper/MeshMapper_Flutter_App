import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_models.dart';

void main() {
  for (final iata in ['TLL', 'RIX']) {
    test('group label takes precedence over $iata without changing it', () {
      final claim = RepeaterClaim.fromJson({
        'repeater': 'AB' * 32,
        'iata': iata,
        'group_code': 'BALTIC',
      });
      expect(claim.groupCode, 'BALTIC');
      expect(claim.regionLabel, 'BALTIC');
      expect(claim.iata, iata);
    });
  }

  for (final group in [null, '', '   ']) {
    test('group value "$group" falls back to IATA', () {
      final claim = RepeaterClaim.fromJson({
        'repeater': 'AB' * 32,
        'iata': 'RIX',
        'group_code': group,
      });
      expect(claim.regionLabel, 'RIX');
      final restored = RepeaterClaim.fromJson(claim.toJson());
      expect(restored.groupCode, group);
      expect(restored.regionLabel, 'RIX');
    });
  }

  test('older server and cached rows without a group retain IATA', () {
    final claim = RepeaterClaim.fromJson({
      'repeater': 'AB' * 32,
      'iata': 'RIX',
    });
    expect(claim.groupCode, isNull);
    expect(claim.regionLabel, 'RIX');
    expect(RepeaterClaim.fromJson(claim.toJson()).regionLabel, 'RIX');
  });

  test('missing group and IATA leave the label absent', () {
    final claim = RepeaterClaim.fromJson({'repeater': 'AB' * 32});
    expect(claim.regionLabel, isNull);
  });

  test('group code survives the claim JSON cache round-trip', () {
    final row = {
      'repeater': 'AB' * 32,
      'name': 'ABAVA',
      'iata': 'TLL',
      'group_code': 'BALTIC',
      'claimed_at': 1,
      'updated_at': 2,
    };
    final claim = RepeaterClaim.fromJson(row);
    final cached = jsonDecode(jsonEncode(claim.toJson())) as Map<String, dynamic>;
    expect(cached['group_code'], 'BALTIC');
    final restored = RepeaterClaim.fromJson(cached);
    expect(restored.toJson(), row);
    expect(restored.regionLabel, 'BALTIC');
  });
}
