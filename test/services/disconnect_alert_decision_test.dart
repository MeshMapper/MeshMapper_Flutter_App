import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/disconnect_alert_decision.dart';

/// The disconnect alert must never describe a problem the user has already
/// walked back to. One user's reconnect timeout was armed for 30 seconds and
/// fired 21 minutes later, after Android froze the process, so the triple beep
/// played as they reached the car rather than as they left it. The freeze
/// itself is fixed by keeping the foreground service alive through the
/// reconnect window; this is the backstop for the phones that freeze anyway.

void main() {
  group('shouldPlayDisconnectAlert', () {
    test('a fresh alert beeps', () {
      expect(shouldPlayDisconnectAlert(Duration.zero), isTrue);
      expect(shouldPlayDisconnectAlert(const Duration(seconds: 30)), isTrue);
    });

    test('a slow but healthy give-up still beeps', () {
      // Three attempts plus a bond-error delay can outrun the 30 second
      // budget by a few seconds. That is not a freeze.
      expect(shouldPlayDisconnectAlert(const Duration(seconds: 45)), isTrue);
    });

    test('the boundary is inclusive', () {
      expect(shouldPlayDisconnectAlert(maxDisconnectAlertAge), isTrue);
      expect(
        shouldPlayDisconnectAlert(
            maxDisconnectAlertAge + const Duration(seconds: 1)),
        isFalse,
      );
    });

    test('the reported freezes are suppressed', () {
      // The two measured episodes: 18m42s and 21m30s.
      expect(
          shouldPlayDisconnectAlert(const Duration(minutes: 18, seconds: 42)),
          isFalse);
      expect(
          shouldPlayDisconnectAlert(const Duration(minutes: 21, seconds: 30)),
          isFalse);
    });

    test('a negative age does not beep', () {
      // A clock that jumped backwards should not be read as "very fresh".
      expect(shouldPlayDisconnectAlert(const Duration(seconds: -5)), isFalse);
    });
  });

  group('staleDisconnectAlertMessage', () {
    test('names the delay in minutes', () {
      expect(
        staleDisconnectAlertMessage(const Duration(minutes: 18, seconds: 42)),
        startsWith('Pinging stopped 18 minutes ago'),
      );
    });

    test('is singular at one minute', () {
      expect(
        staleDisconnectAlertMessage(const Duration(minutes: 1)),
        startsWith('Pinging stopped 1 minute ago'),
      );
    });

    test('falls back to seconds under a minute', () {
      expect(
        staleDisconnectAlertMessage(const Duration(seconds: 45)),
        startsWith('Pinging stopped 45 seconds ago'),
      );
    });

    test('says why the sound was skipped', () {
      expect(
        staleDisconnectAlertMessage(const Duration(minutes: 20)),
        contains('the app was suspended'),
      );
    });
  });
}
