import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/airborne_release.dart';
import 'package:mesh_mapper/services/gps_service.dart';

/// What an airborne session end sends on the release call. The server tells a
/// plane from a high-speed train by seeing BOTH readings of the fix that set
/// the latch, so both ride along whenever known, as metric ints regardless of
/// the user's unit setting. `airborne_gate` stays "the test that fired" and
/// `airborne_value` its reading (raw meters, or km/h).

void main() {
  test('altitude gate carries its reading plus the speed of the same fix', () {
    final info = airborneReleaseInfo(
      gate: AirborneGate.altitude,
      altitudeMeters: 7000,
      speedMetersPerSecond: 50 / 3.6,
      isImperial: false,
    );
    expect(info.extras, {
      'disconnect_cause': 'airborne',
      'airborne_gate': 'altitude',
      'airborne_value': 7000,
      'airborne_alt_m': 7000,
      'airborne_speed_kmh': 50,
    });
    expect(info.detail, startsWith('Altitude '));
    expect(info.detail, contains('speed'));
  });

  test('speed gate carries km/h plus the altitude of the same fix', () {
    final info = airborneReleaseInfo(
      gate: AirborneGate.speed,
      altitudeMeters: 100,
      speedMetersPerSecond: 300 / 3.6,
      isImperial: false,
    );
    expect(info.extras, {
      'disconnect_cause': 'airborne',
      'airborne_gate': 'speed',
      'airborne_value': 300,
      'airborne_alt_m': 100,
      'airborne_speed_kmh': 300,
    });
    expect(info.detail, startsWith('Speed '));
    expect(info.detail, contains('altitude'));
  });

  test('an unknown reading leaves its key out', () {
    final altitudeOnly = airborneReleaseInfo(
      gate: AirborneGate.altitude,
      altitudeMeters: 9000,
      speedMetersPerSecond: null,
      isImperial: false,
    );
    expect(altitudeOnly.extras.containsKey('airborne_speed_kmh'), isFalse);
    expect(altitudeOnly.extras['airborne_alt_m'], 9000);
    expect(altitudeOnly.detail, isNot(contains('speed')));

    final speedOnly = airborneReleaseInfo(
      gate: AirborneGate.speed,
      altitudeMeters: null,
      speedMetersPerSecond: 80,
      isImperial: false,
    );
    expect(speedOnly.extras.containsKey('airborne_alt_m'), isFalse);
    expect(speedOnly.extras['airborne_speed_kmh'], 288);
    expect(speedOnly.detail, isNot(contains('altitude')));
  });

  test('imperial units change the text, never the telemetry', () {
    final metric = airborneReleaseInfo(
      gate: AirborneGate.speed,
      altitudeMeters: 100,
      speedMetersPerSecond: 300 / 3.6,
      isImperial: false,
    );
    final imperial = airborneReleaseInfo(
      gate: AirborneGate.speed,
      altitudeMeters: 100,
      speedMetersPerSecond: 300 / 3.6,
      isImperial: true,
    );
    expect(imperial.extras, metric.extras);
    expect(imperial.detail, isNot(metric.detail));
  });

  group('airborneCauseText', () {
    test('altitude gate names the altitude', () {
      expect(
          airborneCauseText(
            gate: AirborneGate.altitude,
            altitudeMeters: 10000,
            speedMetersPerSecond: 50 / 3.6,
            isImperial: false,
          ),
          'Your altitude is 10000m.');
    });

    test('speed gate names the speed', () {
      expect(
          airborneCauseText(
            gate: AirborneGate.speed,
            altitudeMeters: 100,
            speedMetersPerSecond: 300 / 3.6,
            isImperial: false,
          ),
          'You are moving at 300 km/h.');
    });

    test('imperial units are honoured', () {
      expect(
          airborneCauseText(
            gate: AirborneGate.altitude,
            altitudeMeters: 10000,
            speedMetersPerSecond: null,
            isImperial: true,
          ),
          'Your altitude is 32808ft.');
      expect(
          airborneCauseText(
            gate: AirborneGate.speed,
            altitudeMeters: null,
            speedMetersPerSecond: 300 / 3.6,
            isImperial: true,
          ),
          'You are moving at 186 mph.');
    });
  });
}
