import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';
import 'package:mesh_mapper/utils/coverage_summary.dart';

Repeater _rep(String id, String hexId, double lat, double lon,
        {int enabled = 1, String name = 'R'}) =>
    Repeater(
      id: id,
      hexId: hexId,
      name: name,
      lat: lat,
      lon: lon,
      lastHeard: 0,
      enabled: enabled,
      hopBytes: 2,
    );

void main() {
  // Target repeater at (45, -75); id 'ab12' (2 bytes), full hex 'ab12cd34'.
  final target = _rep('ab12', 'ab12cd34', 45.0, -75.0);
  final lookup = RepeaterLookup.fromRepeaters([target], hopBytes: 2);

  group('GridSummary.fromPoints', () {
    final points = <Map<String, dynamic>>[
      // BIDIR, snr 10, noise -100, 0.02° west of the repeater (~1573 m).
      {
        'status': 1,
        'local_snr': 10,
        'noisefloor': -100,
        'lat': 45.0,
        'lon': -75.02,
        'heard_repeats': 'ab12(10)[45.0,-75.0]',
      },
      // BIDIR, snr 4, noise -110, at the repeater (0 m).
      {
        'status': 1,
        'local_snr': 4,
        'noisefloor': -110,
        'lat': 45.0,
        'lon': -75.0,
        'heard_repeats': 'ab12(4)[45.0,-75.0]',
      },
      // TX — no local_snr, snr 6 parsed from the heard_repeats token.
      {
        'status': 2,
        'lat': 45.0,
        'lon': -75.0,
        'heard_repeats': 'ab12(6)[45.0,-75.0]',
      },
      {'status': 5, 'lat': 45.0, 'lon': -75.0}, // RX
      {'status': 3, 'lat': 45.0, 'lon': -75.0}, // DEAD
      {'status': 3, 'lat': 45.0, 'lon': -75.0}, // DEAD
      {'status': 0, 'lat': 45.0, 'lon': -75.0}, // DROP
      // DISC matched by full public_key + baked coord in heard_repeats.
      {
        'status': 6,
        'public_key': 'ab12cd34',
        'lat': 45.0,
        'lon': -75.0,
        'heard_repeats': '[45.0,-75.0]',
      },
    ];

    final s = GridSummary.fromPoints(points, lookup);

    test('per-status counts + total', () {
      expect(s.total, 8);
      expect(s.bidir, 2);
      expect(s.tx, 1);
      expect(s.rx, 1);
      expect(s.dead, 2);
      expect(s.drop, 1);
      expect(s.disc, 1);
    });

    test('AVG SNR averages local_snr + parsed token SNR (10,4,6)', () {
      expect(s.avgSnr, isNotNull);
      expect(s.avgSnr!, closeTo(20 / 3, 0.001));
      expect(s.snrBucket, 'good'); // > 5
    });

    test('AVG NOISE averages noisefloor (-100,-110)', () {
      expect(s.avgNoise, -105);
    });

    test('MAX DIST is the farthest matched ping→repeater (~1573 m)', () {
      expect(s.maxDistMeters, isNotNull);
      expect(s.maxDistMeters!, closeTo(1573, 60));
    });

    test('(0,0) no-location repeater is excluded from MAX DIST', () {
      // A repeater at the (0,0) "location not published" sentinel, referenced by
      // a baked [0,0] token, must NOT produce a ~8900 km distance to (0,0).
      final lk = RepeaterLookup.fromRepeaters(
        [target, _rep('00ff', '00ff0000', 0.0, 0.0)],
        hopBytes: 2,
      );
      final pts = <Map<String, dynamic>>[
        {
          'status': 1,
          'lat': 45.27,
          'lon': -75.78,
          'heard_repeats': '00ff(5)[0,0]',
        },
      ];
      final summary = GridSummary.fromPoints(pts, lk);
      expect(summary.bidir, 1);
      expect(summary.maxDistMeters, isNull);
    });

    test('MAX DIST resolves a WIDE (full-hex) token + ignores the marker', () {
      // The new bake stores tokens WIDER than repeater.id (4-byte cap) + a {U/R} marker.
      // 'ab12cd34' (full hex, wider than id 'ab12') must still resolve for MAX DIST — the
      // old _byId[token] lookup would have missed it (and shown N/A).
      final pts = <Map<String, dynamic>>[
        {
          'status': 1,
          'lat': 45.0,
          'lon': -75.02, // ~1573 m west of the repeater
          'heard_repeats': 'ab12cd34(8)[45.0,-75.0]{U2}',
        },
      ];
      final summary = GridSummary.fromPoints(pts, lookup);
      expect(summary.bidir, 1);
      expect(summary.maxDistMeters, isNotNull);
      expect(summary.maxDistMeters!, closeTo(1573, 60));
    });

    test('empty input yields a zeroed summary', () {
      final e = GridSummary.fromPoints(const [], lookup);
      expect(e.total, 0);
      expect(e.bidir, 0);
      expect(e.avgSnr, isNull);
      expect(e.avgNoise, isNull);
      expect(e.maxDistMeters, isNull);
      expect(e.snrBucket, isNull);
    });
  });

  group('RepeaterStats.fromCoverage', () {
    final points = <Map<String, dynamic>>[
      // BIDIR via heard_repeats token (coords ~repeater); ping ~786 m away.
      {
        'status': 1,
        'lat': 45.0,
        'lon': -75.01,
        'heard_repeats': 'ab12(7.5)[45.0,-75.0]',
      },
      // TX via the `via` path token.
      {
        'status': 2,
        'lat': 45.0,
        'lon': -75.0,
        'via': 'ab12(3.1)[45.0,-75.0]',
      },
      {
        'status': 5,
        'lat': 45.0,
        'lon': -75.0,
        'heard_repeats': 'ab12(2.0)[45.0,-75.0]',
      },
      {
        'status': 3,
        'lat': 45.0,
        'lon': -75.0,
        'heard_repeats': 'ab12(1.0)[45.0,-75.0]',
      },
      // DISC by full public_key; ping ~3931 m away (the max).
      {
        'status': 6,
        'public_key': 'ab12cd34',
        'lat': 45.0,
        'lon': -75.05,
        'heard_repeats': '[45.0,-75.0]',
      },
      // Token without coords -> must NOT match (dup-logic enabled by default).
      {
        'status': 1,
        'lat': 45.5,
        'lon': -75.0,
        'heard_repeats': 'ab12(9)',
      },
      // References a different repeater -> must NOT match.
      {
        'status': 1,
        'lat': 40.0,
        'lon': -70.0,
        'heard_repeats': 'ff99(9)[40.0,-70.0]',
      },
      // DROP -> skipped.
      {'status': 0, 'lat': 45.0, 'lon': -75.0},
    ];

    final stats = RepeaterStats.fromCoverage(points, target, lookup);

    test('per-status counts attributed to the target', () {
      expect(stats.bidir, 1);
      expect(stats.tx, 1);
      expect(stats.rx, 1);
      expect(stats.disc, 1);
      expect(stats.dead, 1);
      expect(stats.totalMatched, 5);
    });

    test('max range is the farthest matched ping (~3931 m)', () {
      expect(stats.maxRangeMeters, isNotNull);
      expect(stats.maxRangeMeters!, closeTo(3931, 80));
    });

    test('no matches yields zeros + null range', () {
      final none = RepeaterStats.fromCoverage(
        const [
          {'status': 1, 'lat': 40.0, 'lon': -70.0, 'heard_repeats': 'ff99(9)[40,-70]'},
        ],
        target,
        lookup,
      );
      expect(none.totalMatched, 0);
      expect(none.maxRangeMeters, isNull);
    });
  });

  group('GridCell', () {
    // 100 m Detailed grid steps (kCoverageGridSteps[100]).
    const latStep = 0.0009, lonStep = 0.00128;

    test('taps anywhere in a cell resolve to the same cell; centre is inside', () {
      final cell = GridCell.containing(45.26970, -75.77795, latStep, lonStep);
      final a =
          GridCell.containing(cell.centerLat, cell.centerLon, latStep, lonStep);
      final b = GridCell.containing(cell.centerLat + latStep * 0.3,
          cell.centerLon - lonStep * 0.3, latStep, lonStep);
      expect(a.i, cell.i);
      expect(a.j, cell.j);
      expect(b.i, cell.i);
      expect(b.j, cell.j);
      expect(cell.contains(cell.centerLat, cell.centerLon), isTrue);
    });

    test('filter keeps only in-cell points (parses string coords)', () {
      final cell = GridCell.containing(45.0, -75.0, latStep, lonStep);
      final pts = <Map<String, dynamic>>[
        {'lat': cell.centerLat, 'lon': cell.centerLon}, // in cell (num)
        {'lat': '${cell.centerLat}', 'lon': '${cell.centerLon}'}, // in cell (string)
        {
          'lat': (cell.i + 3) * latStep + latStep * 0.5,
          'lon': cell.centerLon
        }, // a different cell
        {'lat': null, 'lon': cell.centerLon}, // unparseable
      ];
      expect(cell.filter(pts).length, 2);
    });

    test('Detailed (blob=1) keeps a ping one cell away; own-cell-only drops it',
        () {
      // The Detailed (100 m) coverage tile paints a 3×3 block per ping, so a
      // green cell can be coloured by a ping up to 1 cell away. Mirrors the web's
      // lazyShowPingsAt: own-cell-only would falsely show "no coverage data here".
      final cell = GridCell.containing(45.0, -75.0, latStep, lonStep);
      final pts = <Map<String, dynamic>>[
        {
          'lat': (cell.i + 1) * latStep + latStep * 0.5,
          'lon': (cell.j - 1) * lonStep + lonStep * 0.5,
        }, // diagonal neighbour — own cell is (i+1, j-1)
        {
          'lat': (cell.i + 2) * latStep + latStep * 0.5,
          'lon': cell.centerLon,
        }, // two cells away — outside the ±1 blob
        {'lat': null, 'lon': cell.centerLon}, // unparseable
      ];
      // blob=1: the diagonal neighbour is within ±1; the two-away ping is not.
      expect(cell.filterWithinBlob(pts, 1).length, 1);
      // own-cell-only (the pre-fix behaviour) drops both → empty summary.
      expect(cell.filter(pts).length, 0);
    });

    test('Simplified (blob=0) reduces to own-cell-only filtering', () {
      const sLat = 0.0027, sLon = 0.00384; // kCoverageGridSteps[300]
      final cell = GridCell.containing(45.0, -75.0, sLat, sLon);
      final pts = <Map<String, dynamic>>[
        {'lat': cell.centerLat, 'lon': cell.centerLon}, // in cell
        {
          'lat': (cell.i + 1) * sLat + sLat * 0.5,
          'lon': cell.centerLon
        }, // a neighbour cell
      ];
      expect(cell.filterWithinBlob(pts, 0).length, cell.filter(pts).length);
      expect(cell.filterWithinBlob(pts, 0).length, 1);
    });

    test('blob fetch radius reaches the ±blob block corner, floored at gridSize',
        () {
      // Detailed: blob=1, 100 m floor → must exceed 100 m and reach the block's
      // far corner (~212 m here) so blob-neighbour pings get fetched.
      final detailed = GridCell.containing(45.0, -75.0, latStep, lonStep);
      final rDetailed = detailed.blobFetchRadiusMeters(1, 100);
      expect(rDetailed, greaterThan(100));
      expect(rDetailed, greaterThanOrEqualTo(212));

      // Simplified: blob=0, the own-cell corner (~212 m) is below the 300 m floor
      // → returns exactly 300, byte-unchanged from the old gridSize radius.
      const sLat = 0.0027, sLon = 0.00384;
      final simplified = GridCell.containing(45.0, -75.0, sLat, sLon);
      expect(simplified.blobFetchRadiusMeters(0, 300), 300);
    });
  });

  group('GridCell.blockRing', () {
    const latStep = 0.0009;
    const lonStep = 0.00128;
    const cell = GridCell(10, 20, latStep, lonStep);

    test('blob=1 makes a 3x3 block centred on the tapped cell', () {
      final ring = cell.blockRing(1);
      expect(ring.length, 5);
      expect(ring.first, ring.last); // closed ring
      final sw = ring[0]; // [minLon, minLat]
      final ne = ring[2]; // [maxLon, maxLat]
      // 3 cells wide/tall: i-1..i+2 and j-1..j+2
      expect(sw[1], closeTo(9 * latStep, 1e-12));
      expect(ne[1], closeTo(12 * latStep, 1e-12));
      expect(sw[0], closeTo(19 * lonStep, 1e-12));
      expect(ne[0], closeTo(22 * lonStep, 1e-12));
      // The block's centre is the tapped cell's centre — the clicked tile is
      // always the middle.
      expect((sw[1] + ne[1]) / 2, closeTo(cell.centerLat, 1e-12));
      expect((sw[0] + ne[0]) / 2, closeTo(cell.centerLon, 1e-12));
    });

    test('blob=0 is just the tapped cell', () {
      final ring = cell.blockRing(0);
      final sw = ring[0];
      final ne = ring[2];
      expect(sw[1], closeTo(10 * latStep, 1e-12));
      expect(ne[1], closeTo(11 * latStep, 1e-12));
      expect(sw[0], closeTo(20 * lonStep, 1e-12));
      expect(ne[0], closeTo(21 * lonStep, 1e-12));
    });
  });
}
