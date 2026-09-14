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
}
