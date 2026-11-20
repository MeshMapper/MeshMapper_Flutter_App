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
  final lookup = RepeaterLookup.fromRepeaters([target]);

  group('RepeaterLookup.resolveByHex', () {
    final durham = _rep(
      'DF85',
      'DF85353AB65D4477D9A1C9075ADCF4358CCEFD33D913C711D9C9551C111A17F4',
      36.000378,
      -78.912449,
      name: 'df85353ab65d',
    );
    final georgia = _rep(
      'DF85',
      'DF85F67DCAC04FB8D567C77853DE6DF0DF72C2CE4575C94D03FB990A48A5E702',
      34.52335,
      -84.03748,
      name: 'Dahlonega Solar RAK 1W',
    );
    final colliding =
        RepeaterLookup.fromRepeaters([durham, georgia]);

    test('full keys resolve each real DF85 repeater independently', () {
      expect(colliding.resolveByHex(durham.hexId), same(durham));
      expect(
          colliding.resolveByHex(georgia.hexId.toLowerCase()), same(georgia));
    });

    test('an ambiguous prefix or legacy id is rejected', () {
      expect(colliding.resolveByHex('DF85'), isNull);
    });

    test('a unique longer prefix resolves its repeater', () {
      expect(colliding.resolveByHex('df8535'), same(durham));
      expect(colliding.resolveByHex('DF85F6'), same(georgia));
    });

    test('a repeater without a published location remains resolvable', () {
      final noLocation = _rep('A102', 'A102${'CD' * 30}', 0, 0);
      final lk = RepeaterLookup.fromRepeaters([noLocation]);

      expect(lk.resolveByHex(noLocation.hexId), same(noLocation));
      expect(lk.resolveByHex('A102'), same(noLocation));
    });
  });

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

    test('a colliding colocated repeater full token does not match target', () {
      final durham = _rep(
        'DF85',
        'DF85353AB65D4477D9A1C9075ADCF4358CCEFD33D913C711D9C9551C111A17F4',
        36.000378,
        -78.912449,
      );
      final sibling = _rep(
        'DF85',
        'DF85F67DCAC04FB8D567C77853DE6DF0DF72C2CE4575C94D03FB990A48A5E702',
        36.000378,
        -78.912449,
      );
      final lk = RepeaterLookup.fromRepeaters([durham, sibling]);
      final siblingPoint = <String, dynamic>{
        'status': 1,
        'lat': 36.001,
        'lon': -78.912449,
        'heard_repeats': '${sibling.hexId}(7)[36.000378,-78.912449]',
      };

      final result =
          RepeaterStats.fromCoverageWithPoints([siblingPoint], durham, lk);

      expect(result.stats.totalMatched, 0);
      expect(result.matched, isEmpty);
    });

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
          {
            'status': 1,
            'lat': 40.0,
            'lon': -70.0,
            'heard_repeats': 'ff99(9)[40,-70]'
          },
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

    test('taps anywhere in a cell resolve to the same cell; centre is inside',
        () {
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
        {
          'lat': '${cell.centerLat}',
          'lon': '${cell.centerLon}'
        }, // in cell (string)
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

    test(
        'blob fetch radius reaches the ±blob block corner, floored at gridSize',
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

  group('GridCell.blockCellPolygons', () {
    const latStep = 0.0009;
    const lonStep = 0.00128;
    const cell = GridCell(10, 20, latStep, lonStep);

    test('blob=0 yields the single tapped cell', () {
      final polys = cell.blockCellPolygons(0);
      expect(polys.length, 1);
      final ring = polys.first;
      expect(ring.length, 5);
      expect(ring.first, ring.last); // closed ring, [lon, lat] order
      expect(ring[0][0], closeTo(20 * lonStep, 1e-12)); // minLon
      expect(ring[0][1], closeTo(10 * latStep, 1e-12)); // minLat
      expect(ring[2][0], closeTo(21 * lonStep, 1e-12)); // maxLon
      expect(ring[2][1], closeTo(11 * latStep, 1e-12)); // maxLat
    });

    test('blob=1 yields nine unit cells covering the 3x3 block', () {
      final polys = cell.blockCellPolygons(1);
      expect(polys.length, 9);
      final iSet = <int>{};
      final jSet = <int>{};
      for (final ring in polys) {
        expect(ring.length, 5);
        expect(ring.first, ring.last);
        // Each polygon is exactly one grid cell (1 lonStep x 1 latStep).
        expect(ring[2][0] - ring[0][0], closeTo(lonStep, 1e-12));
        expect(ring[2][1] - ring[0][1], closeTo(latStep, 1e-12));
        jSet.add((ring[0][0] / lonStep).round());
        iSet.add((ring[0][1] / latStep).round());
      }
      // The 3x3 covers exactly i in 9..11 and j in 19..21, centred on (10, 20).
      expect(iSet, {9, 10, 11});
      expect(jSet, {19, 20, 21});
    });
  });

  group('dominantCoverageStatus', () {
    Map<String, dynamic> p(int status,
            {String? heardRepeats, String? directHeard}) =>
        {
          'lat': 45.0,
          'lon': -75.0,
          'status': status,
          if (heardRepeats != null) 'heard_repeats': heardRepeats,
          if (directHeard != null) 'direct_heard': directHeard,
        };

    test('returns null for no points', () {
      expect(dominantCoverageStatus(const []), isNull);
    });

    test('maps each status to its st category (web parity)', () {
      expect(dominantCoverageStatus([p(1, heardRepeats: 'ab(5)')]), 1); // green
      expect(dominantCoverageStatus([p(1)]), 1); // BIDIR is green either way
      expect(dominantCoverageStatus([p(2)]), 3); // TX -> orange
      expect(dominantCoverageStatus([p(5)]), 4); // RX -> purple
      expect(dominantCoverageStatus([p(6)]), 2); // DISC -> cyan
      expect(dominantCoverageStatus([p(7)]), 2); // TRACE -> cyan
      expect(dominantCoverageStatus([p(3)]), 5); // DEAD -> grey
      expect(dominantCoverageStatus([p(0)]), 6); // DROP -> red
      expect(dominantCoverageStatus([p(99)]), 6); // unknown -> red
    });

    test('green wins over red when both are in the blob', () {
      expect(dominantCoverageStatus([p(0), p(1)]), 1); // red + green -> green
      expect(dominantCoverageStatus([p(1), p(0)]), 1); // order independent
    });

    test('an all-red blob stays red (the intentional smear)', () {
      // The green a neighbour cell shows came from a ping OUTSIDE this blob, so
      // the in-blob pings are all red -> the whole block resolves to red.
      expect(dominantCoverageStatus([p(0), p(0)]), 6);
    });

    test('picks the highest-priority (lowest st) across a mix', () {
      expect(dominantCoverageStatus([p(2), p(6), p(3)]),
          2); // orange/cyan/grey -> cyan
    });
  });

  test('heard endpoints carry the full repeater identity', () {
    final rep = _rep(
        'DF85',
        'DF85353AB65D4477D9A1C9075ADCF4358CCEFD33D913C711D9C9551C111A17F4',
        36.0,
        -78.9);
    final lk = RepeaterLookup.fromRepeaters([rep]);

    final endpoints = heardEndpointsForCell(
      [
        {
          'status': 1,
          'heard_repeats': '${rep.hexId}(6)[36.0,-78.9]',
        }
      ],
      lk,
      startLat: 35.9,
      startLon: -78.9,
    );

    expect(endpoints, hasLength(1));
    expect(endpoints.single.repeaterId, rep.hexId.toLowerCase());
  });

  // A stored hop id matches a repeater only when the repeater's key starts
  // with the whole hop id, at the hop id's own width (the server's
  // rc_resolve_token rule). The region's path width from auth plays no part,
  // so these results are the same in a 1, 2 or 3 byte region.
  group('hop ids match at their own width', () {
    String key(String prefix) => prefix.padRight(64, '0');
    Repeater rep(String id, String prefix, double lat,
            {required int advertBytes, bool multibyteCapable = false}) =>
        Repeater(
          id: id,
          hexId: key(prefix),
          name: 'R$advertBytes',
          lat: lat,
          lon: -75.0,
          lastHeard: 0,
          enabled: 1,
          hopBytes: advertBytes,
          advertBytes: advertBytes,
          multibyteCapable: multibyteCapable,
        );

    // Three different keys sharing the first byte, advertised at 1, 2 and 3
    // bytes. The 1-byte one has been seen relaying wider ids.
    final one = rep('a3', 'a3b7', 45.0, advertBytes: 1, multibyteCapable: true);
    final two = rep('a3f2', 'a3f21c', 45.1, advertBytes: 2);
    final three = rep('a3f2e9', 'a3f2e9', 45.2, advertBytes: 3);
    final lk = RepeaterLookup.fromRepeaters([one, two, three]);

    // Hop ids at every width the history holds.
    final points = <Map<String, dynamic>>[
      // 1 byte, shared by all three, stamped at `one` (~1573 m away).
      {
        'status': 1,
        'lat': 45.0,
        'lon': -75.02,
        'heard_repeats': 'a3(9)[45.0,-75.0]',
      },
      // 2 bytes, shared by `two` and `three`, stamped at `two` (~2356 m).
      {
        'status': 2,
        'lat': 45.1,
        'lon': -75.03,
        'via': 'a3f2(3)[45.1,-75.0]',
      },
      // 3 bytes, only `three`.
      {
        'status': 5,
        'lat': 45.2,
        'lon': -75.01,
        'heard_repeats': 'a3f2e9(2)[45.2,-75.0]',
      },
      // 3 bytes that no key starts with, though `one` shares two of them.
      // Stamped at `one`, ~3931 m away: must not be credited to it.
      {
        'status': 1,
        'lat': 45.0,
        'lon': -75.05,
        'heard_repeats': 'a3b7ff(4)[45.0,-75.0]',
      },
      // 3 bytes that only share the first byte with anything (~6290 m).
      {
        'status': 1,
        'lat': 45.0,
        'lon': -75.08,
        'heard_repeats': 'a3d400(5)[45.0,-75.0]',
      },
      // DISC answered by `one`, named by its full key.
      {
        'status': 6,
        'public_key': one.hexId,
        'lat': 45.0,
        'lon': -75.01,
        'heard_repeats': '[45.0,-75.0]',
      },
      // Full key of `three`.
      {
        'status': 1,
        'lat': 45.2,
        'lon': -75.02,
        'heard_repeats': '${three.hexId}(6)[45.2,-75.0]',
      },
      // 2 bytes, only `one`.
      {
        'status': 3,
        'lat': 45.0,
        'lon': -75.0,
        'heard_repeats': 'a3b7(1)[45.0,-75.0]',
      },
    ];

    test('the cell summary ignores a hop id that no key starts with', () {
      final s = GridSummary.fromPoints(points, lk);

      expect(s.total, 8);
      // The farthest credited ping is the 2-byte one at ~2356 m. The
      // unmatched 3-byte hops at ~3931 m and ~6290 m do not count.
      expect(s.maxDistMeters, isNotNull);
      expect(s.maxDistMeters!, closeTo(2356, 60));
    });

    test('repeater stats credit each hop id to the right repeater', () {
      final a = RepeaterStats.fromCoverageWithPoints(points, one, lk);
      expect(a.matched, [points[0], points[5], points[7]]);
      expect(a.stats.bidir, 1);
      expect(a.stats.disc, 1);
      expect(a.stats.dead, 1);
      expect(a.stats.totalMatched, 3);
      expect(a.stats.maxRangeMeters!, closeTo(1573, 60));

      final b = RepeaterStats.fromCoverageWithPoints(points, two, lk);
      expect(b.matched, [points[1]]);
      expect(b.stats.tx, 1);
      expect(b.stats.totalMatched, 1);

      final c = RepeaterStats.fromCoverageWithPoints(points, three, lk);
      expect(c.matched, [points[2], points[6]]);
      expect(c.stats.rx, 1);
      expect(c.stats.bidir, 1);
      expect(c.stats.totalMatched, 2);
    });

    test('the tile lines reach only repeaters a hop id can mean', () {
      final ends = heardEndpointsForCell(
        [points[3], points[4]],
        lk,
        startLat: 45.0,
        startLon: -75.05,
      );
      expect(ends, isEmpty);
    });
  });
}
