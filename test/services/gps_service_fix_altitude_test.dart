import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_mapper/services/fix_altitude.dart';
import 'package:mesh_mapper/services/fix_altitude_resolver.dart';
import 'package:mesh_mapper/services/gps_service.dart';

/// GpsService hands every accepted fix to the resolver and exposes the
/// stored answer. The simulator's fixes are tracked as simulated (unknown)
/// and switching it on or off bumps the generation.

Position _pos({
  int timeMs = 1760000000000,
  double altitude = 84.0,
  double altitudeAccuracy = 6.0,
}) =>
    Position(
      latitude: 45.0,
      longitude: -75.0,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timeMs, isUtc: true),
      accuracy: 5.0,
      altitude: altitude,
      altitudeAccuracy: altitudeAccuracy,
      heading: 0.0,
      headingAccuracy: 1.0,
      speed: 0.0,
      speedAccuracy: 0.0,
    );

void main() {
  test('altitudeOrNull keeps the 0/0 rule', () {
    expect(GpsService.altitudeOrNull(_pos(altitude: 0.0, altitudeAccuracy: 0.0)),
        isNull, reason: 'the 0/0 pair is geolocator\'s "unknown"');
    expect(GpsService.altitudeOrNull(_pos(altitude: 0.0, altitudeAccuracy: 6.0)),
        0.0, reason: 'a real reading at sea level is kept');
    expect(GpsService.altitudeOrNull(_pos(altitude: 12.0)), 12.0);
  });

  test('a fix never handed to the service is unknown', () {
    final gps = GpsService(
        altitudeResolver: FixAltitudeResolver(platform: AltitudePlatform.ios));
    expect(gps.fixAltitudeOf(_pos()).isKnown, isFalse);
  });

  test('simulator fixes resolve unknown and enabling the simulator resets',
      () async {
    final resolver = FixAltitudeResolver(platform: AltitudePlatform.ios);
    final gps = GpsService(altitudeResolver: resolver);
    final before = resolver.generation;
    gps.enableSimulator(startLatitude: 45.0, startLongitude: -75.0);
    expect(resolver.generation, before + 1);
    final seed = gps.lastPosition;
    expect(seed, isNotNull);
    expect(resolver.size, 1,
        reason: 'the seed WAS handed to the resolver (not merely never stored)');
    expect(gps.fixAltitudeOf(seed!).isKnown, isFalse,
        reason: 'a simulated fix never carries a reference');
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(resolver.size, greaterThan(1),
        reason: 'the simulator\'s later ticks are tracked too, not only the seed');
    final after = resolver.generation;
    gps.dispose();
    expect(resolver.generation, after + 1, reason: 'dispose resets');
  });

  // disableSimulator() resets through startWatching(), whose first statements
  // run synchronously before its first await. That path touches the platform
  // location plugin and cannot run under flutter_test; the resolver test
  // "a completion for an older generation is dropped" covers the reset itself.
}
