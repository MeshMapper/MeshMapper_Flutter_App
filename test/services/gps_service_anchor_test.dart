import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_mapper/services/gps_service.dart';

/// #501: the map's distance-to-previous-ping readout read the TX skip anchor,
/// which only TX pings update. In Trace and Passive modes it stayed anchored
/// to the last TX (typically the session start) and showed kilometers while
/// the real previous trace was 100 m away. The display now follows a separate
/// any-ping anchor; the TX skip anchor is untouched so feeding discovery and
/// trace positions into the readout cannot skip Hybrid TX pings.
Position _pos(double lat, double lon) => Position(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime.now(),
      accuracy: 5.0,
      altitude: 0.0,
      altitudeAccuracy: 1.0,
      heading: 0.0,
      headingAccuracy: 1.0,
      speed: 0.0,
      speedAccuracy: 1.0,
    );

void main() {
  test('no ping of any type yet reports infinity', () {
    final gps = GpsService();
    expect(gps.distanceFromLastActivity(_pos(45.0, -75.0)), double.infinity);
  });

  test('a TX ping moves both the display and the skip anchor', () {
    final gps = GpsService();
    final p0 = _pos(45.0, -75.0);
    gps.markPingPosition(p0);
    expect(gps.distanceFromLastActivity(p0), 0.0);
    expect(gps.distanceFromLastPing(p0), 0.0);
  });

  test('a discovery or trace moves the display anchor only', () {
    final gps = GpsService();
    final txPos = _pos(45.0, -75.0);
    final tracePos = _pos(45.01, -75.0); // ~1.1 km north
    gps.markPingPosition(txPos);
    gps.markActivityPosition(tracePos);

    // Readout follows the trace.
    expect(gps.distanceFromLastActivity(tracePos), 0.0);

    // TX skip logic still measures from the last TX ping.
    expect(gps.distanceFromLastPing(tracePos), greaterThan(1000));
    expect(gps.canPingAtPosition(tracePos), isTrue);
    expect(gps.canPingAtPosition(txPos), isFalse);
  });
}
