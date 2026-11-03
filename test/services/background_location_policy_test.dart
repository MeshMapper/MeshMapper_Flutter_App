import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/connection_state.dart';
import 'package:mesh_mapper/services/background_location_policy.dart';

/// When GPS and Android's session service may run in the background.
///
/// One test per row of the policy table, so a change to the rule shows up as a
/// named failure instead of a drive that goes quiet.
void main() {
  group('radioSessionActive', () {
    bool active(
      ConnectionStep step, {
      bool autoReconnecting = false,
      bool connectRerunPending = false,
    }) =>
        radioSessionActive(
          step: step,
          autoReconnecting: autoReconnecting,
          connectRerunPending: connectRerunPending,
        );

    for (final step in ConnectionStep.values) {
      final quiet =
          step == ConnectionStep.disconnected || step == ConnectionStep.error;
      test('$step with no flags is ${quiet ? 'inactive' : 'active'}', () {
        expect(active(step), !quiet);
      });
    }

    test('disconnected with autoReconnecting is active', () {
      expect(
          active(ConnectionStep.disconnected, autoReconnecting: true), isTrue);
    });

    test('disconnected with a connect re-run pending is active', () {
      expect(active(ConnectionStep.disconnected, connectRerunPending: true),
          isTrue);
    });

    test('error with either flag is active', () {
      expect(active(ConnectionStep.error, autoReconnecting: true), isTrue);
      expect(active(ConnectionStep.error, connectRerunPending: true), isTrue);
    });
  });

  group('gpsRunDecision', () {
    GpsRunDecision decide(
      AppLifecycleState? lifecycle, {
      required bool radioActive,
      required bool isIos,
    }) =>
        gpsRunDecision(
          lifecycle: lifecycle,
          radioActive: radioActive,
          isIos: isIos,
        );

    for (final isIos in [false, true]) {
      final os = isIos ? 'iOS' : 'Android';

      test('resumed with no radio session runs on $os', () {
        expect(
            decide(AppLifecycleState.resumed, radioActive: false, isIos: isIos),
            GpsRunDecision.run);
      });

      for (final state in [
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.detached,
      ]) {
        test('$state with no radio session stops on $os', () {
          expect(decide(state, radioActive: false, isIos: isIos),
              GpsRunDecision.stop);
        });
      }

      test('inactive with no radio session keeps on $os', () {
        expect(
            decide(AppLifecycleState.inactive,
                radioActive: false, isIos: isIos),
            GpsRunDecision.keep);
      });

      test('unknown lifecycle with no radio session keeps on $os', () {
        expect(decide(null, radioActive: false, isIos: isIos),
            GpsRunDecision.keep);
      });
    }

    test('paused with a radio session runs on Android', () {
      expect(decide(AppLifecycleState.paused, radioActive: true, isIos: false),
          GpsRunDecision.run);
    });

    test('paused with a radio session keeps on iOS', () {
      expect(decide(AppLifecycleState.paused, radioActive: true, isIos: true),
          GpsRunDecision.keep);
    });

    test('unknown lifecycle with a radio session runs on Android', () {
      expect(decide(null, radioActive: true, isIos: false), GpsRunDecision.run);
    });

    test('resumed with a radio session runs on iOS', () {
      expect(decide(AppLifecycleState.resumed, radioActive: true, isIos: true),
          GpsRunDecision.run);
    });
  });

  group('shouldStartConnectionService', () {
    bool start({
      bool followsConnection = true,
      bool running = false,
      bool starting = false,
      bool sessionActive = true,
      ConnectionStep step = ConnectionStep.transportConnecting,
      AppLifecycleState? lifecycle = AppLifecycleState.resumed,
      bool locationGranted = true,
    }) =>
        shouldStartConnectionService(
          followsConnection: followsConnection,
          running: running,
          starting: starting,
          sessionActive: sessionActive,
          step: step,
          lifecycle: lifecycle,
          locationGranted: locationGranted,
        );

    test('baseline starts', () {
      expect(start(), isTrue);
    });

    test('does not start when the service does not follow the connection', () {
      expect(start(followsConnection: false), isFalse);
    });

    test('does not start when it is already running', () {
      expect(start(running: true), isFalse);
    });

    test('does not start while a start is in flight', () {
      expect(start(starting: true), isFalse);
    });

    test('does not start without a radio session', () {
      expect(start(sessionActive: false), isFalse);
    });

    test('does not start while disconnecting', () {
      expect(start(step: ConnectionStep.disconnecting), isFalse);
    });

    test('does not start when paused', () {
      expect(start(lifecycle: AppLifecycleState.paused), isFalse);
    });

    test('does not start when inactive', () {
      expect(start(lifecycle: AppLifecycleState.inactive), isFalse);
    });

    test('does not start with an unknown lifecycle', () {
      expect(start(lifecycle: null), isFalse);
    });

    test('does not start without location permission', () {
      expect(start(locationGranted: false), isFalse);
    });
  });

  group('shouldStopServiceAtCleanupEnd', () {
    test('stops when following and no session is left', () {
      expect(
          shouldStopServiceAtCleanupEnd(
              followsConnection: true, sessionActive: false),
          isTrue);
    });

    test('keeps going when following and a session is still live', () {
      expect(
          shouldStopServiceAtCleanupEnd(
              followsConnection: true, sessionActive: true),
          isFalse);
    });

    test('stops when not following, even with a live session', () {
      expect(
          shouldStopServiceAtCleanupEnd(
              followsConnection: false, sessionActive: true),
          isTrue);
    });

    test('stops when not following and no session', () {
      expect(
          shouldStopServiceAtCleanupEnd(
              followsConnection: false, sessionActive: false),
          isTrue);
    });
  });
}
