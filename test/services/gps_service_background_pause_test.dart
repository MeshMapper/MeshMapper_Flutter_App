import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/gps_service.dart';

/// Location is read in the background only while a mode needs it, which is
/// what the location disclosure tells people.

void main() {
  group('shouldPauseInBackground', () {
    test('pauses in the background with no mode active', () {
      expect(
        GpsService.shouldPauseInBackground(
            lifecycle: AppLifecycleState.paused, modeActive: false),
        isTrue,
      );
    });

    test('keeps running in the background while a mode is active', () {
      expect(
        GpsService.shouldPauseInBackground(
            lifecycle: AppLifecycleState.paused, modeActive: true),
        isFalse,
      );
    });

    for (final state in [
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      null,
    ]) {
      test('keeps running when the app is $state', () {
        expect(
          GpsService.shouldPauseInBackground(
              lifecycle: state, modeActive: false),
          isFalse,
        );
      });
    }
  });
}
