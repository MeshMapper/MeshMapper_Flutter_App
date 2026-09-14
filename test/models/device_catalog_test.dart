import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/device_catalog.dart';

Map<String, dynamic> validCatalog() => {
      'success': true,
      'revision': 0,
      'devices': [
        {
          'id': 1,
          'manufacturer': 'Seeed Tracker T1000',
          'shortName': 'T1000',
          'aliases': ['T1000e', 'T1000E_OTA'],
          'power': 0.3,
          'platform': 'nrf52',
          'txPower': 22,
          'notes': 'tracker',
        }
      ],
    };

void main() {
  test('rejects non-strict scalar types and invalid power values', () {
    final wrongType = validCatalog()..['revision'] = '0';
    expect(() => DeviceCatalog.fromJson(wrongType), throwsFormatException);

    final nonFinite = validCatalog();
    (nonFinite['devices'] as List).single['power'] = double.infinity;
    expect(() => DeviceCatalog.fromJson(nonFinite), throwsFormatException);
  });

  test('requires a bounded non-empty catalog with valid revision', () {
    final negativeRevision = validCatalog()..['revision'] = -1;
    expect(() => DeviceCatalog.fromJson(negativeRevision), throwsFormatException);

    final empty = validCatalog()..['devices'] = [];
    expect(() => DeviceCatalog.fromJson(empty), throwsFormatException);
  });

  test('rejects excessive aliases and colliding manufacturer identities', () {
    final aliases = validCatalog();
    (aliases['devices'] as List).single['aliases'] =
        List<String>.filled(51, 'alias');
    expect(() => DeviceCatalog.fromJson(aliases), throwsFormatException);

    final collision = validCatalog();
    (collision['devices'] as List).add({
      'id': 2,
      'manufacturer': 'T1000-E',
      'shortName': 'other',
      'aliases': <String>[],
      'power': 1.0,
      'platform': 'nrf52',
      'txPower': 22,
      'notes': '',
    });
    expect(() => DeviceCatalog.fromJson(collision), throwsFormatException);
  });
}
