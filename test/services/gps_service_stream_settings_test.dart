import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_mapper/services/gps_service.dart';

/// Android's location plugin asks for a fix every 5 s unless told otherwise,
/// so Android pings reused the previous fix far more often than iOS (median
/// gap 5 s against 1 s). Both Android providers now ask for one a second;
/// the 10 m distance filter still decides how often a fix is delivered.
void main() {
  test('Android with Google\'s provider asks for a fix every second', () {
    final settings = gpsStreamSettings(
        isAndroid: true, useAndroidLocationManager: false);
    expect(settings, isA<AndroidSettings>());
    final android = settings as AndroidSettings;
    expect(android.intervalDuration, const Duration(seconds: 1));
    expect(android.forceLocationManager, isFalse);
    expect(android.distanceFilter, 10);
    expect(android.accuracy, LocationAccuracy.high);
    expect(android.useMSLAltitude, isFalse);
  });

  test('Android\'s own location service asks for a fix every second', () {
    final settings =
        gpsStreamSettings(isAndroid: true, useAndroidLocationManager: true);
    expect(settings, isA<AndroidSettings>());
    final android = settings as AndroidSettings;
    expect(android.intervalDuration, const Duration(seconds: 1));
    expect(android.forceLocationManager, isTrue);
    expect(android.distanceFilter, 10);
    expect(android.accuracy, LocationAccuracy.high);
    expect(android.useMSLAltitude, isFalse);
  });

  test('other platforms keep the plain settings', () {
    final settings = gpsStreamSettings(
        isAndroid: false, useAndroidLocationManager: false);
    expect(settings, isNot(isA<AndroidSettings>()));
    expect(settings.distanceFilter, 10);
    expect(settings.accuracy, LocationAccuracy.high);
  });
}
