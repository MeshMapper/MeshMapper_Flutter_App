import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/recent_coverage_service.dart';
import 'package:mesh_mapper/utils/mvt_cells.dart';

/// Smart Pinging's lookup. The service keeps the covered cells of every z13
/// tile within 500 m of the phone, refreshed every 5 minutes, and answers
/// "is the cell under this fix covered" without touching the network. When
/// it does not know, it says so, and the caller lets the ping go out.

/// Builds a minimal single-layer MVT whose only properties are i, j and st,
/// one feature per (i, j) pair, matching what decodeCoverageCells reads.
Uint8List tileWithCells(List<(int, int)> cells) {
  final out = <int>[];
  void varint(List<int> b, int v) {
    while (v >= 128) {
      b.add((v % 128) + 128);
      v = v ~/ 128;
    }
    b.add(v);
  }

  int zigzag(int n) => n >= 0 ? n * 2 : -n * 2 - 1;
  void bytesField(List<int> b, int field, List<int> payload) {
    varint(b, field * 8 + 2);
    varint(b, payload.length);
    b.addAll(payload);
  }

  final layer = <int>[];
  // name (field 1)
  bytesField(layer, 1, 'coverage'.codeUnits);
  // keys (field 3): i, j, st
  bytesField(layer, 3, 'i'.codeUnits);
  bytesField(layer, 3, 'j'.codeUnits);
  bytesField(layer, 3, 'st'.codeUnits);
  // values (field 4): one sint value per distinct number used
  final numbers = <int>{};
  for (final c in cells) {
    numbers.add(c.$1);
    numbers.add(c.$2);
  }
  numbers.add(1);
  final valueIndex = <int, int>{};
  for (final n in numbers) {
    final v = <int>[];
    varint(v, 6 * 8 + 0); // field 6 sint_value, varint wire type
    varint(v, zigzag(n));
    valueIndex[n] = valueIndex.length;
    bytesField(layer, 4, v);
  }
  // features (field 2)
  var id = 1;
  for (final c in cells) {
    final f = <int>[];
    varint(f, 1 * 8 + 0); // id
    varint(f, id++);
    final tags = <int>[];
    varint(tags, 0);
    varint(tags, valueIndex[c.$1]!);
    varint(tags, 1);
    varint(tags, valueIndex[c.$2]!);
    varint(tags, 2);
    varint(tags, valueIndex[1]!);
    bytesField(f, 2, tags);
    varint(f, 3 * 8 + 0); // type polygon
    varint(f, 3);
    bytesField(layer, 2, f);
  }
  // extent (field 5)
  varint(layer, 5 * 8 + 0);
  varint(layer, 4096);
  bytesField(out, 3, layer);
  return Uint8List.fromList(out);
}

class _Fetches {
  final calls = <({String zone, int x, int y, int gsize, int days})>[];
  final answers = <String, Uint8List?>{}; // 'x/y' -> body (null = failure)
  Completer<void>? gate; // when set, fetches wait on it
  Object? throwNext; // when set, the next call throws it instead of answering

  Future<Uint8List?> call({
    required String zone,
    required int x,
    required int y,
    required int gsize,
    required int days,
  }) async {
    calls.add((zone: zone, x: x, y: y, gsize: gsize, days: days));
    if (gate != null) await gate!.future;
    final boom = throwNext;
    if (boom != null) {
      throwNext = null;
      throw boom;
    }
    return answers['$x/$y'];
  }
}

// Ottawa-ish fix in the middle of a z13 tile.
const lat = 45.4215;
const lon = -75.6972;

void main() {
  test('sanity: the test tile round-trips through the app decoder', () {
    final cells = decodeCoverageCells(tileWithCells([(16822, -19713)]));
    expect(cells.length, 1);
    expect(cells.first.i, 16822);
    expect(cells.first.j, -19713);
    expect(cells.first.st, 1);
  });

  group('tile math', () {
    test('z13 tile for a fix', () {
      final t = recentCoverageTile(lat, lon);
      expect(t.x, 2373);
      expect(t.y, 2933);
    });

    test('one tile in the middle, more near an edge or corner', () {
      // Tile 2373/2933 spans lon -75.7178..-75.6738 and lat 45.3984..45.4293.
      expect(recentCoverageTilesWithin(45.4132, -75.6958, 500).length, 1);
      // 200 m from the west edge: two tiles.
      expect(recentCoverageTilesWithin(45.4132, -75.7152, 500).length, 2);
      // 200 m from the west edge and 200 m above the south edge: four tiles.
      expect(recentCoverageTilesWithin(45.3998, -75.7152, 500).length, 4);
    });
  });

  group('lookup', () {
    late _Fetches fetches;
    late DateTime now;
    late RecentCoverageService svc;

    setUp(() {
      fetches = _Fetches();
      now = DateTime(2026, 9, 5, 12);
      svc = RecentCoverageService(fetchTile: fetches.call, now: () => now);
      svc.configure(zone: 'YOW', gridSize: 300, days: 14, enabled: true);
    });

    (int, int) cellOf(double la, double lo) =>
        ((la / 0.0027).floor(), (lo / 0.00384).floor());

    test('unknown before any tile has loaded', () {
      expect(svc.isCovered(lat, lon), RecentCoverage.unknown);
    });

    test('covered when the tile lists the cell, clear otherwise', () async {
      fetches.answers['2373/2933'] = tileWithCells([cellOf(lat, lon)]);
      await svc.onPosition(lat, lon);
      expect(svc.loadedTileCount, 1);
      expect(svc.isCovered(lat, lon), RecentCoverage.covered);
      // A different cell in the same tile.
      expect(svc.isCovered(lat + 0.003, lon), RecentCoverage.clear);
      expect(fetches.calls.single.gsize, 300);
      expect(fetches.calls.single.days, 14);
      expect(fetches.calls.single.zone, 'YOW');
    });

    test('a 204 (empty body) is a loaded, empty tile', () async {
      fetches.answers['2373/2933'] = Uint8List(0);
      await svc.onPosition(lat, lon);
      expect(svc.isCovered(lat, lon), RecentCoverage.clear);
    });

    test('a failed fetch stays unknown and retries after 30 s, not before',
        () async {
      fetches.answers['2373/2933'] = null;
      await svc.onPosition(lat, lon);
      expect(svc.isCovered(lat, lon), RecentCoverage.unknown);
      expect(fetches.calls.length, 1);

      now = now.add(const Duration(seconds: 10));
      await svc.onPosition(lat + 0.002, lon); // moved > 100 m
      expect(fetches.calls.length, 1, reason: 'inside the retry hold');

      now = now.add(const Duration(seconds: 30));
      fetches.answers['2373/2933'] = tileWithCells([cellOf(lat, lon)]);
      await svc.onPosition(lat, lon);
      expect(fetches.calls.length, 2);
      expect(svc.isCovered(lat, lon), RecentCoverage.covered);
    });

    test('a throwing fetch is a failed fetch, not a rejected future', () async {
      fetches.throwNext = StateError('the fetch blew up');
      // An unhandled throw here fails the test: onPosition runs off the GPS
      // listener and must never reject.
      await svc.onPosition(lat, lon);
      expect(svc.isCovered(lat, lon), RecentCoverage.unknown);
      expect(fetches.calls.length, 1);

      now = now.add(const Duration(seconds: 10));
      await svc.onPosition(lat + 0.002, lon); // moved > 100 m
      expect(fetches.calls.length, 1, reason: 'inside the retry hold');

      now = now.add(const Duration(seconds: 30));
      fetches.answers['2373/2933'] = tileWithCells([cellOf(lat, lon)]);
      await svc.onPosition(lat, lon);
      expect(fetches.calls.length, 2);
      expect(svc.isCovered(lat, lon), RecentCoverage.covered);
    });

    test('a throwing refresh keeps the old set', () async {
      fetches.answers['2373/2933'] = tileWithCells([cellOf(lat, lon)]);
      await svc.onPosition(lat, lon);
      now = now.add(const Duration(minutes: 6));
      fetches.throwNext = StateError('the fetch blew up');
      await svc.onPosition(lat + 0.002, lon);
      expect(fetches.calls.length, 2);
      expect(svc.isCovered(lat, lon), RecentCoverage.covered);
    });

    test('a failed refresh keeps the old set', () async {
      fetches.answers['2373/2933'] = tileWithCells([cellOf(lat, lon)]);
      await svc.onPosition(lat, lon);
      now = now.add(const Duration(minutes: 6));
      fetches.answers['2373/2933'] = null;
      await svc.onPosition(lat + 0.002, lon);
      expect(fetches.calls.length, 2);
      expect(svc.isCovered(lat, lon), RecentCoverage.covered);
    });

    test('a fresh tile is reused; a 5 minute old one is refetched', () async {
      fetches.answers['2373/2933'] = tileWithCells([]);
      await svc.onPosition(lat, lon);
      await svc.onPosition(lat + 0.002, lon);
      expect(fetches.calls.length, 1);
      now = now.add(const Duration(minutes: 5, seconds: 1));
      await svc.onPosition(lat, lon);
      expect(fetches.calls.length, 2);
    });

    test('small moves do not re-evaluate', () async {
      fetches.answers['2373/2933'] = tileWithCells([]);
      await svc.onPosition(lat, lon);
      now = now.add(const Duration(minutes: 6));
      await svc.onPosition(lat + 0.0003, lon); // ~33 m
      expect(fetches.calls.length, 1);
    });

    test('tiles outside the 500 m box are evicted', () async {
      fetches.answers['2373/2933'] = tileWithCells([]);
      fetches.answers['2372/2933'] = tileWithCells([]);
      await svc.onPosition(45.4132, -75.7152); // near the west edge: 2 tiles
      expect(svc.loadedTileCount, 2);
      await svc.onPosition(45.4132, -75.6958); // middle: 1 tile
      expect(svc.loadedTileCount, 1);
    });

    test('fetches run one at a time', () async {
      fetches.gate = Completer<void>();
      fetches.answers['2373/2933'] = tileWithCells([]);
      fetches.answers['2372/2933'] = tileWithCells([]);
      final pending = svc.onPosition(45.4132, -75.7152);
      await Future<void>.delayed(Duration.zero);
      expect(fetches.calls.length, 1, reason: 'second waits for the first');
      fetches.gate!.complete();
      await pending;
      expect(fetches.calls.length, 2);
    });

    test('a session mark is covered at once, even with no tile', () {
      svc.markCovered(lat, lon);
      expect(svc.isCovered(lat, lon), RecentCoverage.covered);
      expect(svc.isCovered(lat + 0.01, lon), RecentCoverage.unknown);
    });

    test('follows the 100 m grid when configured for it', () async {
      svc.configure(zone: 'YOW', gridSize: 100, days: 14, enabled: true);
      final c = ((lat / 0.0009).floor(), (lon / 0.00128).floor());
      fetches.answers['2373/2933'] = tileWithCells([c]);
      await svc.onPosition(lat, lon);
      expect(fetches.calls.single.gsize, 100);
      expect(svc.isCovered(lat, lon), RecentCoverage.covered);
      expect(svc.isCovered(lat + 0.001, lon), RecentCoverage.clear);
    });

    test('reconfiguring the window or grid clears the cache', () async {
      fetches.answers['2373/2933'] = tileWithCells([cellOf(lat, lon)]);
      await svc.onPosition(lat, lon);
      svc.markCovered(lat + 0.01, lon);
      svc.configure(zone: 'YOW', gridSize: 300, days: 7, enabled: true);
      expect(svc.loadedTileCount, 0);
      expect(svc.isCovered(lat, lon), RecentCoverage.unknown);
      expect(svc.isCovered(lat + 0.01, lon), RecentCoverage.unknown,
          reason: 'session marks belong to the old configuration');
    });

    test('same configuration keeps the cache', () async {
      fetches.answers['2373/2933'] = tileWithCells([cellOf(lat, lon)]);
      await svc.onPosition(lat, lon);
      svc.configure(zone: 'YOW', gridSize: 300, days: 14, enabled: true);
      expect(svc.loadedTileCount, 1);
    });

    test('inactive when disabled or without a zone: clear, no fetches',
        () async {
      svc.configure(zone: 'YOW', gridSize: 300, days: 14, enabled: false);
      await svc.onPosition(lat, lon);
      expect(svc.isActive, isFalse);
      expect(svc.isCovered(lat, lon), RecentCoverage.clear);
      svc.configure(zone: null, gridSize: 300, days: 14, enabled: true);
      await svc.onPosition(lat, lon);
      expect(svc.isActive, isFalse);
      expect(fetches.calls, isEmpty);
    });

    test('clear drops everything', () async {
      fetches.answers['2373/2933'] = tileWithCells([cellOf(lat, lon)]);
      await svc.onPosition(lat, lon);
      svc.markCovered(lat, lon);
      svc.clear();
      expect(svc.loadedTileCount, 0);
      expect(svc.isCovered(lat, lon), RecentCoverage.unknown);
    });
  });
}
