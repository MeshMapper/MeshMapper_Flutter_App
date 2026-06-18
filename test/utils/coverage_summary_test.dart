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
  });
}
