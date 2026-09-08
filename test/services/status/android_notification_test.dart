import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart' show AutoMode;
import 'package:mesh_mapper/services/status/android_notification.dart';

/// The Android foreground notification's title and body, one row per mode.
///
/// This is the single source the provider's four hand-written mode strings
/// collapsed into, and the background isolate now only displays what it
/// produces. The strings are pinned byte for byte so the refactor cannot move
/// them.
void main() {
  ({String title, String body}) content(AutoMode mode) =>
      androidNotificationContent(
          mode: mode, txCount: 3, rxCount: 7, queueSize: 2);

  test('active shows the TX line', () {
    final n = content(AutoMode.active);
    expect(n.title, 'MeshMapper - Active Mode');
    expect(n.body, 'TX: 3 | RX: 7 | Queue: 2');
  });

  test('passive drops TX, which it never sends', () {
    final n = content(AutoMode.passive);
    expect(n.title, 'MeshMapper - Passive Mode');
    expect(n.body, 'RX: 7 | Queue: 2');
  });

  test('hybrid shows the TX line, like active', () {
    final n = content(AutoMode.hybrid);
    expect(n.title, 'MeshMapper - Hybrid Mode');
    expect(n.body, 'TX: 3 | RX: 7 | Queue: 2');
  });

  test('targeted reads Trace, in the title and the body', () {
    final n = content(AutoMode.targeted);
    expect(n.title, 'MeshMapper - Trace Mode');
    expect(n.body, 'Trace: 3 | RX: 7 | Queue: 2');
  });
}
