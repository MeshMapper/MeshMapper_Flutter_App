import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_mapper/services/gps_service.dart';

/// Issue 595: with Google Location Accuracy off, Android's location plugin
/// shows Google's "Location Accuracy" dialog. Declining it failed the GPS
/// stream as "location services disabled", the dialog closing resumed the
/// app, the resume restarted GPS, and the dialog came back, so the app could
/// not get past it. A decline with device location still on now moves GPS
/// to Android's own location service, which never shows that dialog.
void main() {
  bool decide({
    bool isAndroid = true,
    bool alreadyUsing = false,
    Object error = const LocationServiceDisabledException(),
    bool deviceLocationOn = true,
  }) =>
      shouldUseAndroidLocationManager(
        isAndroid: isAndroid,
        alreadyUsing: alreadyUsing,
        error: error,
        deviceLocationOn: deviceLocationOn,
      );

  test('a declined dialog with device location on switches', () {
    expect(decide(), isTrue);
  });

  test('device location really off stays disabled', () {
    expect(decide(deviceLocationOn: false), isFalse);
  });

  test('it switches once, never back and forth', () {
    expect(decide(alreadyUsing: true), isFalse);
  });

  test('other stream errors do not switch', () {
    expect(decide(error: const PermissionDeniedException('denied')), isFalse);
    expect(decide(error: StateError('anything')), isFalse);
  });

  test('only Android has a second location service', () {
    expect(decide(isAndroid: false), isFalse);
  });
}
