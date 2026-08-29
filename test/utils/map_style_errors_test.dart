import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/map_style_errors.dart';

/// #482: a duplicate-install race left the native gps-puck layer alive while
/// the Dart-side "installed" flag stayed false, so every retry re-threw
/// "already exists" and the puck was never repositioned again. The classifier
/// lets install paths adopt the existing native object instead of failing.
void main() {
  test('recognises the Android CannotAddLayerException shape', () {
    final e = PlatformException(
      code: 'error',
      message: 'Layer gps-puck-layer already exists',
      details: 'org.maplibre.android.style.layers.CannotAddLayerException',
    );
    expect(mapStyleObjectAlreadyExists(e), isTrue);
  });

  test('recognises the Android CannotAddSourceException shape', () {
    final e = PlatformException(
      code: 'error',
      message: 'Source meshmapper-coverage-patch already exists',
      details: 'org.maplibre.android.style.sources.CannotAddSourceException',
    );
    expect(mapStyleObjectAlreadyExists(e), isTrue);
  });

  test('does not match unrelated platform errors', () {
    final e = PlatformException(
      code: 'error',
      message: 'Style is not fully loaded',
    );
    expect(mapStyleObjectAlreadyExists(e), isFalse);
    expect(mapStyleObjectAlreadyExists(StateError('boom')), isFalse);
  });
}
