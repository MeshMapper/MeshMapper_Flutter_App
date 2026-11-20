import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/utils/debug_logger_io.dart';

import 'fake_companion_transport.dart';

/// Frames the app deliberately ignores are recorded by the per-frame line
/// only. "Unhandled frame" is kept for codes the app does not know.
void main() {
  late FakeCompanionTransport transport;
  late MeshCoreConnection connection;
  late List<String> lines;

  setUp(() {
    transport = FakeCompanionTransport();
    connection = MeshCoreConnection(transport: transport);
    lines = <String>[];
    final originalDebugPrint = debugPrint;
    final originalEnabled = DebugLogger.isEnabled;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    DebugLogger.setEnabled(true);
    addTearDown(() {
      debugPrint = originalDebugPrint;
      DebugLogger.setEnabled(originalEnabled);
    });
  });

  tearDown(() {
    connection.dispose();
    transport.dispose();
  });

  for (final code in [0x80, 0x83, 0x0a, 0x11, 0x8a, 0x8f, 0x16]) {
    test('code 0x${code.toRadixString(16)} is not logged as unhandled',
        () async {
      transport.emit([code, 0x01, 0x02, 0x03]);
      await transport.settle();

      expect(lines.any((l) => l.contains('[CONN] Frame 0x')), isTrue);
      expect(lines.where((l) => l.contains('Unhandled frame')), isEmpty);
      expect(lines.where((l) => l.startsWith('ERROR:')), isEmpty);
    });
  }

  test('a genuinely unknown code is still logged as unhandled', () async {
    transport.emit([0x7E, 0x01]);
    await transport.settle();

    expect(lines.where((l) => l.contains('Unhandled frame: code=126')),
        hasLength(1));
  });
}
