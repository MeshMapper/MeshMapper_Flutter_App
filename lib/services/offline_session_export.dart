import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;

import 'offline_session_service.dart';

/// The JSON an exported offline session file holds: the session's data
/// payload, pretty-printed with two-space indent. Every export path (the
/// single-session share, the web download and Export all) writes this, so the
/// files are the same whichever button made them.
String offlineSessionJson(Map<String, dynamic> data) =>
    const JsonEncoder.withIndent('  ').convert(data);

/// Writes one export file per session into [dir] and returns them in the
/// order of [sessions].
///
/// Each file is named after its session (`2026-11-09.json`), the same name
/// the single-session export uses. A name already taken earlier in this export
/// gets ` (2)`, ` (3)` and so on before `.json`, so no session overwrites
/// another (the service can reuse a name after a delete).
///
/// Only reads the sessions: nothing is deleted, changed or marked uploaded.
/// Encoding runs off the UI isolate ([compute]) so a large drive does not
/// stall the screen.
Future<List<File>> writeOfflineSessionExports(
  List<OfflineSession> sessions,
  Directory dir,
) async {
  final files = <File>[];
  final used = <String>{};
  for (final session in sessions) {
    final name = _uniqueName(session.filename, used);
    used.add(name);
    final json = await compute(offlineSessionJson, session.data);
    final file = File('${dir.path}/$name');
    await file.writeAsString(json);
    files.add(file);
  }
  return files;
}

String _uniqueName(String filename, Set<String> used) {
  if (!used.contains(filename)) return filename;
  final dot = filename.lastIndexOf('.');
  final stem = dot > 0 ? filename.substring(0, dot) : filename;
  final ext = dot > 0 ? filename.substring(dot) : '';
  var n = 2;
  while (used.contains('$stem ($n)$ext')) {
    n++;
  }
  return '$stem ($n)$ext';
}
