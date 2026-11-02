import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/debug/store_capture.dart';
import 'package:mesh_mapper/debug/store_capture_route.dart';

final newest = DateTime(2026, 11, 1, 9, 40);

final repeaters = [
  (id: 'CBC003', lat: 45.4210, lon: -75.6960),
  (id: '85FFDD', lat: 45.4150, lon: -75.7000),
  (id: 'BB0003', lat: 45.4300, lon: -75.6900),
  (id: '60', lat: 45.4000, lon: -75.7200),
];

StoreCaptureSample _build(
        {List<({String id, double lat, double lon})>? reps}) =>
    buildStoreCaptureSample(newest: newest, repeaters: reps ?? repeaters);

void main() {
  group('buildStoreCaptureSample', () {
    test('one TX per route point, newest at the arrow at 9:40', () {
      final s = _build();
      expect(storeCaptureRoute.length, 45);
      expect(s.txPings.length, 45);
      expect(s.txPings.last.timestamp, newest);
      expect(s.txPings.last.latitude, storeCaptureRoute.last.$1);
      expect(s.txPings.last.longitude, storeCaptureRoute.last.$2);
      for (var i = 1; i < s.txPings.length; i++) {
        expect(
          s.txPings[i].timestamp.difference(s.txPings[i - 1].timestamp),
          const Duration(seconds: 22),
        );
      }
      expect(s.txLog.length, 45);
    });

    test('mostly heard, at least one miss', () {
      final misses =
          _build().txPings.where((p) => p.heardRepeaters.isEmpty).length;
      expect(misses, greaterThanOrEqualTo(1));
      expect(misses, lessThanOrEqualTo(9));
    });

    test('heard ids come from the loaded repeaters', () {
      final allowed = {'CBC003', '85FFDD', 'BB0003', '60'};
      for (final p in _build().txPings) {
        for (final h in p.heardRepeaters) {
          expect(allowed, contains(h.repeaterId));
        }
      }
    });

    test('falls back to fixed ids when no repeaters loaded', () {
      final s = _build(reps: []);
      expect(s.txPings, isNotEmpty);
      for (final p in s.txPings) {
        for (final h in p.heardRepeaters) {
          expect(storeCaptureFallbackIds, contains(h.repeaterId));
        }
      }
    });

    test('RX on every third point', () {
      final s = _build();
      expect(s.rxPings.length, 15);
      expect(s.rxLog.length, 15);
      for (final r in s.rxPings) {
        expect(r.timestamp.isBefore(newest), isTrue);
      }
      for (final r in s.rxLog) {
        expect(r.timestamp.isBefore(newest), isTrue);
      }
    });

    test('one discovery and one trace', () {
      final s = _build();
      expect(s.disc.length, 1);
      expect(s.trace.length, 1);
      expect(s.trace.single.success, isTrue);
    });

    test('four finished sessions, newest first', () {
      final s = _build();
      expect(s.sessions.map((e) => e.mode).toList(),
          ['active', 'hybrid', 'passive', 'active']);
      for (final session in s.sessions) {
        expect(session.endTime, isNotNull);
        for (final m in session.markers) {
          expect(m.latitude, isNotNull);
          expect(m.longitude, isNotNull);
        }
      }
      for (var i = 1; i < s.sessions.length; i++) {
        expect(s.sessions[i].startTime.isBefore(s.sessions[i - 1].startTime),
            isTrue);
      }
    });

    test('stats match the lists', () {
      final s = _build();
      expect(s.stats.txCount, 45);
      expect(s.stats.rxCount, 15);
      expect(s.stats.discCount, 1);
      expect(s.stats.traceCount, 1);
      expect(s.stats.successfulUploads, 60);
    });

    test('header numbers', () {
      final s = _build();
      expect(s.noiseFloor, -109);
      expect(s.batteryPercent, 86);
    });

    test('deterministic', () {
      // Lists inside records compare by identity, so flatten each ping to text.
      List<String> shape(StoreCaptureSample s) => [
            for (final p in s.txPings)
              '${p.timestamp.toIso8601String()} '
                  '${[
                for (final h in p.heardRepeaters) h.repeaterId
              ].join(',')}',
          ];
      expect(shape(_build()), isNotEmpty);
      expect(shape(_build()), shape(_build()));
    });
  });

  group('StoreCaptureConfig', () {
    test('config parse', () {
      expect(StoreCaptureConfig.parse('{"screen":"log"}')?.screen,
          StoreCaptureScreen.log);
      expect(StoreCaptureConfig.parse('{"screen":"log"}')?.screen.tabIndex, 1);
      expect(
          StoreCaptureConfig.parse('{"screen":"history"}')?.screen.tabIndex, 2);
      expect(StoreCaptureConfig.parse('{"screen":"map"}')?.screen.tabIndex, 0);
      expect(StoreCaptureConfig.parse('not json'), isNull);
      expect(StoreCaptureConfig.parse('{"screen":"settings"}'), isNull);
      expect(StoreCaptureConfig.parse('{}'), isNull);
    });

    test('config load', () async {
      final dir = Directory.systemTemp.createTempSync('store_capture_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(await StoreCaptureConfig.load(dir), isNull);
      File('${dir.path}/$storeCaptureFileName')
          .writeAsStringSync('{"screen":"history"}');
      final loaded = await StoreCaptureConfig.load(dir);
      expect(loaded?.screen, StoreCaptureScreen.history);
    });
  });
}
