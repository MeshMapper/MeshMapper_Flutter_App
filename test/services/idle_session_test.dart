import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/idle_session.dart';

void main() {
  bool idle({
    bool autoPingEnabled = false,
    bool autoPingStarting = false,
    bool pendingDisable = false,
    bool pingSending = false,
    bool pingInProgress = false,
    bool repeaterAdminOpen = false,
    int queuedItems = 0,
  }) =>
      sessionIsIdle(
        autoPingEnabled: autoPingEnabled,
        autoPingStarting: autoPingStarting,
        pendingDisable: pendingDisable,
        pingSending: pingSending,
        pingInProgress: pingInProgress,
        repeaterAdminOpen: repeaterAdminOpen,
        queuedItems: queuedItems,
      );

  test('nothing running and nothing queued is idle', () {
    expect(idle(), isTrue);
  });

  test('any activity or queued item is busy', () {
    expect(idle(autoPingEnabled: true), isFalse);
    expect(idle(autoPingStarting: true), isFalse);
    expect(idle(pendingDisable: true), isFalse);
    expect(idle(pingSending: true), isFalse);
    expect(idle(pingInProgress: true), isFalse);
    expect(idle(repeaterAdminOpen: true), isFalse);
    expect(idle(queuedItems: 1), isFalse);
  });
}
