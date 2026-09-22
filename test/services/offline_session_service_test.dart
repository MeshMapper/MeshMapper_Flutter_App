import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mesh_mapper/services/offline_session_service.dart';

/// Regression tests for the offline-session lifecycle duplicate bug.
///
/// Repro: during offline wardriving the 60s auto-save (and app-pause) call
/// `updateCurrentSession()`, which on first fire creates and *tracks* a session.
/// The final save (`_saveOfflineSession` in AppStateProvider) must finalize that
/// SAME tracked session — if it instead calls `saveSession()` it creates a second
/// session holding the same pings, surfacing as two identical sessions at the
/// same time under Settings → Data → Offline Sessions.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<Map<String, dynamic>> pings(int n) =>
      List.generate(n, (i) => {'type': 'TX', 'seq': i});

  group('OfflineSessionService lifecycle', () {
    test(
        'auto-save then final save through updateCurrentSession yields ONE session (the fix)',
        () async {
      SharedPreferences.setMockInitialValues({});
      final service = OfflineSessionService();
      await service.init();

      // Auto-save fires (60s timer / app pause) — creates + tracks session A.
      await service.updateCurrentSession(pings(3), deviceName: 'Test');
      expect(service.sessionCount, 1);

      // Final save (stop/disconnect) routes through updateCurrentSession with the
      // full ping set, then finalizes the tracker.
      await service.updateCurrentSession(pings(5), deviceName: 'Test');
      service.finalizeCurrentSession();

      expect(service.sessionCount, 1,
          reason: 'final save must update the tracked session in place');
      expect(service.sessions.first.pingCount, 5,
          reason: 'session holds the complete final ping set');
    });

    test(
        'auto-save then final save through saveSession DUPLICATES (the bug being fixed)',
        () async {
      SharedPreferences.setMockInitialValues({});
      final service = OfflineSessionService();
      await service.init();

      // Auto-save creates + tracks session A.
      await service.updateCurrentSession(pings(5), deviceName: 'Test');
      // Old buggy final-save path: saveSession() ignores the tracked session.
      await service.saveSession(pings(5), deviceName: 'Test');

      expect(service.sessionCount, 2,
          reason:
              'documents the duplicate: saveSession creates a second session '
              'alongside the tracked auto-save session');
    });

    test('finalize then save creates a fresh session (clean break preserved)',
        () async {
      SharedPreferences.setMockInitialValues({});
      final service = OfflineSessionService();
      await service.init();

      await service.updateCurrentSession(pings(3), deviceName: 'Test');
      service.finalizeCurrentSession();
      // New offline session after a finalize should be a distinct file.
      await service.updateCurrentSession(pings(2), deviceName: 'Test');

      expect(service.sessionCount, 2,
          reason: 'finalize breaks tracking so the next save is a new session');
    });

    test(
        'final save with empty queue still finalizes, so next session does not append to the old one',
        () async {
      SharedPreferences.setMockInitialValues({});
      final service = OfflineSessionService();
      await service.init();

      // Offline session 1: auto-save tracks a 3-ping session.
      await service.updateCurrentSession(pings(3), deviceName: 'Test');

      // Final save runs with no new pings — the provider's empty-queue path now
      // finalizes the tracker instead of leaving it set.
      service.finalizeCurrentSession();

      // Offline session 2 starts and auto-saves 2 pings.
      await service.updateCurrentSession(pings(2), deviceName: 'Test');

      // sessions are sorted newest-first: .last is session 1, .first is session 2.
      expect(service.sessionCount, 2,
          reason:
              'second session must be its own file, not appended to the first');
      expect(service.sessions.last.pingCount, 3,
          reason: 'first session keeps its original 3 pings (no append)');
      expect(service.sessions.first.pingCount, 2,
          reason: 'second session holds only its own 2 pings');
    });
  });
}
