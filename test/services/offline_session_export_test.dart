import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mesh_mapper/services/offline_session_export.dart';
import 'package:mesh_mapper/services/offline_session_service.dart';

/// Export all offline sessions (#560): one JSON file per stored session, the
/// same name and pretty JSON the single-session export writes, and nothing
/// about the stored sessions changes afterwards.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('offline_export_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  OfflineSession session(String filename, {int pings = 2}) => OfflineSession(
        filename: filename,
        createdAt: DateTime(2026, 11, 9, 12),
        pingCount: pings,
        data: {
          'offline': true,
          'ping_count': pings,
          'pings': List.generate(pings, (i) => {'type': 'TX', 'seq': i}),
        },
      );

  test('the JSON is the pretty JSON the single-session export writes', () {
    final data = session('2026-11-09.json').data;
    expect(offlineSessionJson(data),
        const JsonEncoder.withIndent('  ').convert(data));
  });

  test('no sessions gives no files', () async {
    final files = await writeOfflineSessionExports(const [], dir);
    expect(files, isEmpty);
  });

  test('one session gives one file named after it', () async {
    final s = session('2026-11-09.json');
    final files = await writeOfflineSessionExports([s], dir);

    expect(files, hasLength(1));
    expect(files.single.path, '${dir.path}/2026-11-09.json');
    expect(await files.single.readAsString(), offlineSessionJson(s.data));
  });

  test('every session gets its own file, in list order', () async {
    final sessions = [
      session('2026-11-09-2.json', pings: 3),
      session('2026-11-09.json', pings: 1),
      session('2026-11-08.json', pings: 500),
    ];
    final files = await writeOfflineSessionExports(sessions, dir);

    expect(files.map((f) => f.uri.pathSegments.last).toList(),
        ['2026-11-09-2.json', '2026-11-09.json', '2026-11-08.json']);
    for (var i = 0; i < sessions.length; i++) {
      expect(await files[i].readAsString(), offlineSessionJson(sessions[i].data));
    }
  });

  test('a repeated filename is not overwritten', () async {
    // A delete can make the service hand out a name that is still in use.
    final a = session('2026-11-09-3.json', pings: 1);
    final b = session('2026-11-09-3.json', pings: 4);
    final files = await writeOfflineSessionExports([a, b], dir);

    expect(files.map((f) => f.uri.pathSegments.last).toList(),
        ['2026-11-09-3.json', '2026-11-09-3 (2).json']);
    expect(await files[0].readAsString(), offlineSessionJson(a.data));
    expect(await files[1].readAsString(), offlineSessionJson(b.data));
  });

  test('exporting keeps every session, none marked uploaded', () async {
    SharedPreferences.setMockInitialValues({});
    final service = OfflineSessionService();
    await service.init();
    await service.saveSession([
      {'type': 'TX', 'seq': 0}
    ], deviceName: 'A');
    await service.saveSession([
      {'type': 'TX', 'seq': 1},
      {'type': 'RX', 'seq': 2},
    ], deviceName: 'B');
    final before = service.sessions.map((s) => jsonEncode(s.toJson())).toList();

    final files = await writeOfflineSessionExports(service.sessions, dir);

    expect(files, hasLength(2));
    expect(service.sessionCount, 2);
    expect(service.sessions.every((s) => !s.uploaded), isTrue);
    expect(service.sessions.map((s) => jsonEncode(s.toJson())).toList(), before);

    // And the stored copy is untouched too.
    final reloaded = OfflineSessionService();
    await reloaded.init();
    expect(reloaded.sessions.map((s) => jsonEncode(s.toJson())).toList(),
        before);
  });
}
