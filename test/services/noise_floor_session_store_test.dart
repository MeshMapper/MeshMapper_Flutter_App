import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mesh_mapper/models/noise_floor_session.dart';
import 'package:mesh_mapper/services/noise_floor_session_store.dart';

/// The History tab's recording session lived only in memory until the mode
/// stopped, so an app killed mid-drive lost the whole entry (graph, ping
/// markers, view on map). It is now checkpointed while it runs, and a
/// checkpoint left open by a kill is closed at the next launch.
void main() {
  late Directory directory;
  const boxName = 'noise_floor_sessions';

  // Registered once: Hive.resetAdapters() also drops Hive's own DateTime
  // adapter, which these models need.
  setUpAll(() {
    Hive.registerAdapter(NoiseFloorSampleAdapter());
    Hive.registerAdapter(PingEventTypeAdapter());
    Hive.registerAdapter(MarkerRepeaterInfoAdapter());
    Hive.registerAdapter(PingEventMarkerAdapter());
    Hive.registerAdapter(NoiseFloorSessionAdapter());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nf-sessions-');
    Hive.init(directory.path);
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  final t0 = DateTime(2026, 11, 8, 9);

  NoiseFloorSession session(String id, DateTime start,
          {DateTime? end, int samples = 0}) =>
      NoiseFloorSession(
        id: id,
        startTime: start,
        endTime: end,
        mode: 'passive',
        samples: [
          for (var i = 0; i < samples; i++)
            NoiseFloorSample(
                timestamp: start.add(Duration(seconds: 5 * i)),
                noiseFloor: -110),
        ],
      );

  Future<Box<NoiseFloorSession>> open() =>
      Hive.openBox<NoiseFloorSession>(boxName);

  /// What a kill does: the process goes away without ending the session.
  Future<Box<NoiseFloorSession>> killAndRelaunch() async {
    await Hive.close();
    return open();
  }

  group('checkpoint, kill, relaunch', () {
    test('the session comes back closed at its last sample', () async {
      var box = await open();
      final live = session('live', t0, samples: 3);
      live.markers.add(PingEventMarker(
          timestamp: t0.add(const Duration(seconds: 7)),
          type: PingEventType.discSuccess,
          noiseFloor: -108,
          latitude: 45,
          longitude: -75));
      final checkpoint = NoiseFloorCheckpoint();
      expect(await checkpoint.write(box, live), isTrue);
      live.samples.add(NoiseFloorSample(
          timestamp: t0.add(const Duration(minutes: 4)), noiseFloor: -105));
      expect(await checkpoint.write(box, live), isTrue);

      box = await killAndRelaunch();
      final stored = await loadStoredNoiseFloorSessions(box);

      expect(stored, hasLength(1));
      expect(stored.single.id, 'live');
      expect(stored.single.isActive, isFalse);
      expect(stored.single.endTime, t0.add(const Duration(minutes: 4)));
      expect(stored.single.samples, hasLength(4));
      expect(stored.single.markers.single.latitude, 45);

      // The close is written back, so a later launch reads it closed too.
      box = await killAndRelaunch();
      expect(box.get('live')!.endTime, t0.add(const Duration(minutes: 4)));
    });

    test('a marker later than the last sample sets the end', () {
      final s = session('s', t0, samples: 2)
        ..markers.add(PingEventMarker(
            timestamp: t0.add(const Duration(minutes: 1)),
            type: PingEventType.txFail,
            noiseFloor: -100));
      expect(interruptedNoiseFloorSessionEnd(s),
          t0.add(const Duration(minutes: 1)));
    });

    test('a session with nothing recorded ends at its start', () {
      expect(interruptedNoiseFloorSessionEnd(session('s', t0)), t0);
    });

    test('closed sessions load unchanged, newest first', () async {
      final box = await open();
      await box.put('old', session('old', t0, end: t0, samples: 1));
      await box.put(
          'new',
          session('new', t0.add(const Duration(hours: 1)),
              end: t0.add(const Duration(hours: 2)), samples: 1));
      final stored = await loadStoredNoiseFloorSessions(box);
      expect(stored.map((s) => s.id), ['new', 'old']);
      expect(stored.first.endTime, t0.add(const Duration(hours: 2)));
    });

    test('a recovered session past the cap drops the oldest', () async {
      var box = await open();
      for (var i = 0; i < maxStoredNoiseFloorSessions; i++) {
        final start = t0.add(Duration(hours: i));
        await box.put('s$i', session('s$i', start, end: start, samples: 1));
      }
      await NoiseFloorCheckpoint().write(
          box, session('live', t0.add(const Duration(days: 1)), samples: 2));

      box = await killAndRelaunch();
      final stored = await loadStoredNoiseFloorSessions(box);

      expect(stored, hasLength(maxStoredNoiseFloorSessions));
      expect(stored.first.id, 'live');
      expect(stored.map((s) => s.id), isNot(contains('s0')));
      expect(box.length, maxStoredNoiseFloorSessions);
      expect(box.containsKey('s0'), isFalse);
    });
  });

  group('checkpoint writes', () {
    test('nothing new since the last write skips it', () async {
      final box = await open();
      final live = session('live', t0, samples: 2);
      final checkpoint = NoiseFloorCheckpoint();
      expect(await checkpoint.write(box, live), isTrue);
      expect(await checkpoint.write(box, live), isFalse);
      live.markers.add(PingEventMarker(
          timestamp: t0, type: PingEventType.rx, noiseFloor: -110));
      expect(await checkpoint.write(box, live), isTrue);
    });

    test('an ended session is never checkpointed', () async {
      final box = await open();
      final ended = session('done', t0, end: t0, samples: 2);
      expect(await NoiseFloorCheckpoint().write(box, ended), isFalse);
      expect(box.isEmpty, isTrue);
    });

    test('no box writes nothing', () async {
      expect(await NoiseFloorCheckpoint().write(null, session('s', t0)),
          isFalse);
    });
  });

  group('ending a session', () {
    test('a session never checkpointed is stored as before', () async {
      final box = await open();
      final stored = <NoiseFloorSession>[];
      final live = session('live', t0, samples: 2)
        ..endTime = t0.add(const Duration(minutes: 1));
      await saveEndedNoiseFloorSession(box, stored, live);
      expect(stored.map((s) => s.id), ['live']);
      expect(box.get('live')!.endTime, t0.add(const Duration(minutes: 1)));
    });

    test('a checkpointed session is stored once, not twice', () async {
      final box = await open();
      final stored = <NoiseFloorSession>[];
      final live = session('live', t0, samples: 2);
      await NoiseFloorCheckpoint().write(box, live);
      live.endTime = t0.add(const Duration(minutes: 1));
      await saveEndedNoiseFloorSession(box, stored, live);
      expect(stored, hasLength(1));
      expect(box.length, 1);
      expect(box.get('live')!.endTime, t0.add(const Duration(minutes: 1)));
    });

    test('the cap of 10 holds with a checkpoint in the box', () async {
      final box = await open();
      final stored = <NoiseFloorSession>[];
      for (var i = maxStoredNoiseFloorSessions - 1; i >= 0; i--) {
        final start = t0.add(Duration(hours: i));
        final s = session('s$i', start, end: start, samples: 1);
        await box.put(s.id, s);
        stored.add(s);
      }
      final live = session('live', t0.add(const Duration(days: 1)));
      await NoiseFloorCheckpoint().write(box, live);
      expect(box.length, maxStoredNoiseFloorSessions + 1);

      live.endTime = live.startTime.add(const Duration(minutes: 5));
      await saveEndedNoiseFloorSession(box, stored, live);

      expect(stored, hasLength(maxStoredNoiseFloorSessions));
      expect(stored.first.id, 'live');
      expect(stored.map((s) => s.id), isNot(contains('s0')));
      expect(box.length, maxStoredNoiseFloorSessions);
      expect(box.containsKey('s0'), isFalse);
    });

    test('with no box the list still updates', () async {
      final stored = <NoiseFloorSession>[];
      final live = session('live', t0)..endTime = t0;
      await saveEndedNoiseFloorSession(null, stored, live);
      expect(stored.single.id, 'live');
    });
  });
}
