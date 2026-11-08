/// Storage for the History tab's recording sessions ([NoiseFloorSession]).
///
/// A session used to reach Hive only when its mode ended, so an app killed
/// mid-drive lost the whole entry. The running session is now checkpointed
/// into the same box under its own id ([NoiseFloorCheckpoint]), and a launch
/// closes any checkpoint a kill left open ([loadStoredNoiseFloorSessions]).
/// The ended-session save puts the same id, so a checkpointed session is
/// stored once.
library;

import 'package:hive/hive.dart';

import '../models/noise_floor_session.dart';
import '../utils/debug_logger_io.dart';

/// How many ended sessions History keeps.
const int maxStoredNoiseFloorSessions = 10;

/// The end of a session that was never ended (the app was killed): its last
/// sample or marker, whichever is later, or its start when it recorded
/// nothing.
DateTime interruptedNoiseFloorSessionEnd(NoiseFloorSession session) {
  var end = session.startTime;
  if (session.samples.isNotEmpty &&
      session.samples.last.timestamp.isAfter(end)) {
    end = session.samples.last.timestamp;
  }
  for (final marker in session.markers) {
    if (marker.timestamp.isAfter(end)) end = marker.timestamp;
  }
  return end;
}

/// Reads the stored sessions at launch, newest first. A checkpoint left open
/// by a kill is closed at [interruptedNoiseFloorSessionEnd] and written back,
/// then the list is cut to [keep], deleting the oldest from [box].
Future<List<NoiseFloorSession>> loadStoredNoiseFloorSessions(
  Box<NoiseFloorSession> box, {
  int keep = maxStoredNoiseFloorSessions,
}) async {
  final sessions = box.values.toList();
  for (final session in sessions) {
    if (!session.isActive) continue;
    session.endTime = interruptedNoiseFloorSessionEnd(session);
    await box.put(session.id, session);
    debugLog('[GRAPH] Closed a session the app did not end: '
        '${session.durationDisplay}, ${session.samples.length} samples, '
        '${session.markers.length} markers');
  }
  sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
  while (sessions.length > keep) {
    final oldest = sessions.removeLast();
    await box.delete(oldest.id);
    debugLog('[GRAPH] Deleted oldest session: ${oldest.id}');
  }
  return sessions;
}

/// Saves an ended [session] and adds it to the front of [stored], keeping
/// [keep] sessions. A checkpoint of it already in [box] is overwritten (same
/// id), and an entry of it already in [stored] is replaced, never doubled.
Future<void> saveEndedNoiseFloorSession(
  Box<NoiseFloorSession>? box,
  List<NoiseFloorSession> stored,
  NoiseFloorSession session, {
  int keep = maxStoredNoiseFloorSessions,
}) async {
  await box?.put(session.id, session);
  stored.removeWhere((s) => s.id == session.id);
  stored.insert(0, session);
  while (stored.length > keep) {
    final oldest = stored.removeLast();
    await box?.delete(oldest.id);
    debugLog('[GRAPH] Deleted oldest session: ${oldest.id}');
  }
}

/// Writes the running session to Hive so a kill cannot lose it.
///
/// Each write rewrites the whole session (a 5 hour drive is about 3600
/// samples), so the caller writes on a timer of a few minutes and when the
/// app leaves the screen, never per sample, and a write with nothing new
/// since the last one is skipped.
class NoiseFloorCheckpoint {
  String? _id;
  int _samples = -1;
  int _markers = -1;

  /// Writes [session] when it is still running and has something new since
  /// the last write. True when it wrote.
  Future<bool> write(
      Box<NoiseFloorSession>? box, NoiseFloorSession session) async {
    if (box == null || !session.isActive) return false;
    if (_id == session.id &&
        _samples == session.samples.length &&
        _markers == session.markers.length) {
      return false;
    }
    _id = session.id;
    _samples = session.samples.length;
    _markers = session.markers.length;
    await box.put(session.id, session);
    return true;
  }
}
