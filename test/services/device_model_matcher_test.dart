import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/device_model.dart';
import 'package:mesh_mapper/services/device_model_matcher.dart';

final tracker = DeviceModel(
  id: 12,
  manufacturer: 'Seeed Tracker T1000',
  shortName: 'Seeed Tracker T1000',
  aliases: ['T1000e', 'T1000E_OTA'],
  power: 0.3,
  platform: 'nrf52',
  txPower: 22,
  notes: 'tracker',
);

void main() {
  test('matches exact aliases after approved normalization', () {
    for (final input in ['T1000e', 'T1000-E', 'T1000E_OTA']) {
      expect(matchDeviceModel(input, [tracker]), same(tracker));
    }
    expect(matchDeviceModel(' SEEED TRACKER T1000 nightly-a1b2 ', [tracker]),
        same(tracker));
  });

  test('does not use substring or fuzzy matching', () {
    for (final input in [
      'Heltec V30',
      'Seeed Tracker T1000X',
      'LilyGo T-Beam Supreme',
    ]) {
      expect(matchDeviceModel(input, [tracker]), isNull);
    }
  });

  test('returns unknown when a duplicate short name is ambiguous', () {
    final duplicate = DeviceModel(
      id: 13,
      manufacturer: 'Other device',
      shortName: 'Seeed Tracker T1000',
      aliases: [],
      power: 1,
      platform: 'esp32',
      txPower: 20,
      notes: '',
    );
    expect(
        matchDeviceModel('Seeed Tracker T1000', [tracker, duplicate]), isNull);
  });

  test('executes the shared catalog contract fixture', () {
    final fixture = jsonDecode(
      File('test/fixtures/device_catalog_contract.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    for (final entry in fixture['normalization'] as List) {
      final row = entry as Map<String, dynamic>;
      expect(
          normalizeDeviceIdentity(row['input'] as String), row['normalized']);
    }
    expect(
      matchDeviceModel('T1000e', [tracker]),
      same(tracker),
    );
  });

  test('matches every canonical manufacturer from the retired catalog', () {
    final fixture = jsonDecode(
      File('test/fixtures/device_catalog_manufacturers.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final rows = fixture['devices'] as List;
    final models = <DeviceModel>[
      for (var index = 0; index < rows.length; index++)
        DeviceModel.fromJson(
          <String, dynamic>{
            'id': index + 1,
            'aliases': const <String>[],
            ...rows[index] as Map,
          },
        ),
    ];

    expect(models, hasLength(39));
    for (final model in models) {
      expect(matchDeviceModel(model.manufacturer, models), same(model));
    }
  });
}
