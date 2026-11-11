import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';

/// Below companion firmware v1.16.0 (code 13) the switch still saves, but
/// nothing is asked and nothing extra is sent, so the Settings tile grows an
/// extra line while connected to that radio.
void main() {
  test('firmware below the floor while connected needs the note', () {
    expect(
        scopeDiscoveryFirmwareTooOld(connected: true, firmwareCode: 11),
        isTrue);
  });

  test('firmware at the floor while connected needs no note', () {
    expect(
        scopeDiscoveryFirmwareTooOld(connected: true, firmwareCode: 13),
        isFalse);
  });

  test('disconnected never needs the note, whatever the last firmware code',
      () {
    expect(
        scopeDiscoveryFirmwareTooOld(connected: false, firmwareCode: 11),
        isFalse);
  });

  test('unknown firmware code while connected reads as too old', () {
    expect(
        scopeDiscoveryFirmwareTooOld(connected: true, firmwareCode: null),
        isTrue);
  });
}
