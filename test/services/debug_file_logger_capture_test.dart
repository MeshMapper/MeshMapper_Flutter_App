import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/debug_file_logger.dart';

/// Startup lines are held in memory until the stored preference says whether
/// a log file should exist at all. Before this the app opened a file on every
/// launch and closed it again when the preference read off, leaving one stub
/// file per launch that all surfaced the moment the user turned logging on.
void main() {
  tearDown(DebugFileLogger.discardCapture);

  test('a write before capture starts is dropped', () {
    DebugFileLogger.write('LOG', '[APP] too early');
    expect(DebugFileLogger.pendingLogCount, 0);
  });

  test('capture buffers lines with their level and scrubs them', () {
    DebugFileLogger.beginCapture();
    DebugFileLogger.write('LOG', '[APP] MeshMapper starting...');
    DebugFileLogger.write('WARN', 'Authorization: Bearer ${'a' * 64}');
    expect(DebugFileLogger.pendingLogCount, 2);
    final lines = DebugFileLogger.pendingLogsForTest;
    expect(lines[0], contains('LOG: [APP] MeshMapper starting...'));
    expect(lines[1], contains('WARN: Authorization: Bearer <redacted>'));
    expect(lines[1], isNot(contains('a' * 64)));
  });

  test('discarding the capture empties it and later writes are dropped', () {
    DebugFileLogger.beginCapture();
    DebugFileLogger.write('LOG', '[APP] one');
    DebugFileLogger.discardCapture();
    expect(DebugFileLogger.pendingLogCount, 0);
    DebugFileLogger.write('LOG', '[APP] two');
    expect(DebugFileLogger.pendingLogCount, 0);
  });

  test('the capture is capped', () {
    DebugFileLogger.beginCapture();
    for (var i = 0; i < 600; i++) {
      DebugFileLogger.write('LOG', '[APP] line $i');
    }
    expect(DebugFileLogger.pendingLogCount, DebugFileLogger.maxPendingLogs);
    expect(DebugFileLogger.pendingLogsForTest.first, contains('line 0'));
  });

  test('only a stored false turns file logging off', () {
    expect(DebugFileLogger.wantsFileLogging(null), isTrue);
    expect(DebugFileLogger.wantsFileLogging(true), isTrue);
    expect(DebugFileLogger.wantsFileLogging('stray'), isTrue);
    expect(DebugFileLogger.wantsFileLogging(false), isFalse);
  });

  test('a legacy startup stub is recognised by its exact line', () {
    const stub = '=== MeshMapper Debug Log Started: 2026-10-08T06:22:00 ===\n'
        '=== App APP-1.4.0 | iOS 18.5 ===\n\n'
        '[2026-10-08T06:22:00] LOG: [APP] MeshMapper starting...\n'
        '[2026-10-08T06:22:01] LOG: [INIT] Debug logs disabled by user preference, turning off\n'
        '\n=== MeshMapper Debug Log Stopped: 2026-10-08T06:22:01 ===\n';
    expect(DebugFileLogger.isStartupStubContent(stub), isTrue);
  });

  test('a real log and the new wording are not stubs', () {
    const real = '=== MeshMapper Debug Log Started ===\n'
        '[t] LOG: [APP] MeshMapper starting...\n'
        '[t] LOG: [INIT] Debug logging enabled (APP-1.4.0)\n'
        '[t] LOG: [BLE] Connected\n';
    expect(DebugFileLogger.isStartupStubContent(real), isFalse);
    const reworded = '[t] LOG: [INIT] File logging stopped: preference is off\n';
    expect(DebugFileLogger.isStartupStubContent(reworded), isFalse);
  });
}
