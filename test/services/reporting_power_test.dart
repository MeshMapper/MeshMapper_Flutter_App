import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/device_model.dart';
import 'package:mesh_mapper/services/reporting_power.dart';

final modelB = DeviceModel(
  id: 2,
  manufacturer: 'Radio B',
  shortName: 'B',
  aliases: const [],
  power: 0.3,
  platform: 'nrf52',
  txPower: 22,
  notes: '',
);

void main() {
  test('a recognized offline radio replaces the prior radio override', () {
    final power = resolveReportingPower(model: modelB);
    expect(power.power, 0.3);
    expect(power.txPower, 22);
    expect(power.autoSet, isTrue);
    expect(power.configured, isFalse);
  });

  test('a saved override wins over catalog defaults in every connection mode',
      () {
    final power = resolveReportingPower(
      model: modelB,
      savedOverride: {'powerLevel': 2.0, 'txPower': 9},
    );
    expect(power.power, 2.0);
    expect(power.txPower, 9);
    expect(power.autoSet, isFalse);
    expect(power.configured, isTrue);
  });
}
