import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/cluster_spread.dart';

/// The rule that decides whether a tap on a cluster zooms or spreads.
///
/// It used to be "zoom until max zoom, spread only there", which cost three or
/// four presses on a stack that no zoom level could ever separate, and the last
/// presses did nothing at all. These pin the replacement.
void main() {
  // What the map actually runs with.
  const maxZoom = 17.0 - 0.01;
  const clusterRadiusPx = 50.0;

  bool canSeparate(List<(double, double)> points, {double zoom = maxZoom}) =>
      clusterCanSeparateByZoom(
        lats: [for (final p in points) p.$1],
        lons: [for (final p in points) p.$2],
        maxZoom: zoom,
        clusterRadiusPx: clusterRadiusPx,
      );

  /// Metres per pixel at max zoom in Ottawa, where the screenshot was taken.
  final mPerPx = metersPerPixelAtZoom(45.27, maxZoom);

  /// Two points [meters] apart on the same latitude line.
  List<(double, double)> pair(double meters) {
    const lat = 45.27;
    const lonDegPerM = 1 / (111320 * 0.7046); // cos(45.27)
    return [(lat, -75.77), (lat, -75.77 + meters * lonDegPerM)];
  }

  group('a stack no zoom can separate spreads immediately', () {
    test('repeaters sharing a rooftop never come apart', () {
      // A few metres apart: at max zoom that is a couple of pixels, far inside
      // the merge radius, so zooming is pure friction.
      expect(canSeparate(pair(3)), isFalse);
      expect(canSeparate(pair(10)), isFalse);
    });

    test('identical coordinates never come apart', () {
      expect(canSeparate([(45.27, -75.77), (45.27, -75.77)]), isFalse);
    });

    test('the boundary is the merge radius at a WHOLE zoom level', () {
      // Clustering is recomputed at integer zooms and the camera stops just
      // short of 17, so the deepest clustering level a user can actually reach
      // is 16. A group has to clear the radius THERE. Judging it at the
      // fractional maximum instead promises a separation that never arrives,
      // and the tap then zooms to the end and sits there.
      final mPerPxAtReachableZoom = metersPerPixelAtZoom(45.27, 16);
      expect(canSeparate(pair(mPerPxAtReachableZoom * (clusterRadiusPx - 2))),
          isFalse);
      expect(canSeparate(pair(mPerPxAtReachableZoom * (clusterRadiusPx + 10))),
          isTrue);
      expect(mPerPx, lessThan(mPerPxAtReachableZoom),
          reason: 'sanity: the fractional max is deeper than z16');
    });
  });

  group('a genuinely spread cluster still zooms', () {
    test('repeaters hundreds of metres apart come apart on zoom', () {
      expect(canSeparate(pair(500)), isTrue);
      expect(canSeparate(pair(5000)), isTrue);
    });

    test('a cluster tight at low zoom is judged at MAX zoom, not the current',
        () {
      // 300 m is one cluster at z11 and clearly separate at max zoom. The rule
      // must look ahead to max zoom, or it would spread things that zooming
      // would have resolved nicely.
      expect(canSeparate(pair(300), zoom: 11), isFalse,
          reason: 'at z11 those points are within the merge radius');
      expect(canSeparate(pair(300)), isTrue,
          reason: 'but at max zoom they are far apart, so zooming is useful');
    });
  });

  group('degenerate inputs answer "just spread it" rather than throwing', () {
    test('fewer than two points', () {
      expect(canSeparate([]), isFalse);
      expect(canSeparate([(45.27, -75.77)]), isFalse);
    });

    test('mismatched lists', () {
      expect(
        clusterCanSeparateByZoom(
          lats: [45.0, 46.0],
          lons: [-75.0],
          maxZoom: maxZoom,
          clusterRadiusPx: clusterRadiusPx,
        ),
        isFalse,
      );
    });

    test('non-finite coordinates', () {
      expect(canSeparate([(double.nan, -75.77), (45.27, -75.77)]), isFalse);
      expect(canSeparate([(45.27, double.infinity), (45.27, -75.77)]), isFalse);
    });

    test('a nonsense radius', () {
      expect(
        clusterCanSeparateByZoom(
          lats: [45.0, 46.0],
          lons: [-75.0, -75.0],
          maxZoom: maxZoom,
          clusterRadiusPx: double.nan,
        ),
        isFalse,
      );
    });

    test('at a pole, where the span and the scale are both numerical noise',
        () {
      // Two longitudes at latitude 90 are the same physical point. Without the
      // half-metre floor, dividing one near-zero by another claimed a spread
      // of ~900,000 px and the tap would have zoomed forever.
      expect(canSeparate([(90.0, 0.0), (90.0, 10.0)]), isFalse);
    });

    test('points under half a metre apart are treated as one mast', () {
      expect(canSeparate(pair(0.2)), isFalse);
    });
  });

  group('the span used is the bounding box, so it never under-states', () {
    test('a third point inside the box does not change the answer', () {
      final two = pair(500);
      final withMiddle = [...two, (45.27, -75.77 + 0.001)];
      expect(canSeparate(withMiddle), canSeparate(two));
    });

    test('a point outside the box widens it', () {
      expect(canSeparate(pair(3)), isFalse);
      expect(canSeparate([...pair(3), (45.28, -75.77)]), isTrue);
    });
  });

  group('the zoom a tap should jump to', () {
    double? expansion(List<(double, double)> points) => clusterExpansionZoom(
          lats: [for (final p in points) p.$1],
          lons: [for (final p in points) p.$2],
          maxZoom: maxZoom,
          clusterRadiusPx: clusterRadiusPx,
        );

    test('it is a whole zoom level, because clustering is', () {
      final z = expansion(pair(300));
      expect(z, isNotNull);
      expect(z, z!.roundToDouble());
    });

    test('it actually separates the group, and one level less does not', () {
      // All above the physical floor: at z16, the deepest clustering level a
      // user can reach here, 50 px is about 84 m, so anything tighter than
      // that never separates at all and belongs in the null case below.
      for (final meters in [100.0, 150.0, 300.0, 900.0, 4000.0]) {
        final z = expansion(pair(meters));
        expect(z, isNotNull, reason: '$meters m should separate somewhere');
        final atZoom = meters / metersPerPixelAtZoom(45.27, z!);
        expect(atZoom, greaterThan(clusterRadiusPx),
            reason: '$meters m is only $atZoom px at the zoom it picked');
        if (z >= 1) {
          final oneLess = meters / metersPerPixelAtZoom(45.27, z - 1);
          expect(oneLess, lessThanOrEqualTo(clusterRadiusPx),
              reason: '$meters m already separated a level earlier, so the '
                  'jump overshoots');
        }
      }
    });

    test('a wider group needs less zoom than a tighter one', () {
      expect(expansion(pair(2000))!, lessThan(expansion(pair(200))!));
    });

    test('null when no reachable zoom separates it, which means spread it', () {
      expect(expansion(pair(3)), isNull);
      expect(expansion(pair(0.2)), isNull);
      expect(expansion([(45.27, -75.77)]), isNull);
      expect(canSeparate(pair(3)), isFalse);
    });

    test('the boolean and the zoom always agree', () {
      for (final meters in [0.1, 1.0, 5.0, 40.0, 80.0, 500.0, 20000.0]) {
        expect(canSeparate(pair(meters)), expansion(pair(meters)) != null,
            reason: '$meters m');
      }
    });
  });

  group('the geometry helpers themselves', () {
    test('metres per pixel halves with each zoom level', () {
      final z10 = metersPerPixelAtZoom(45.0, 10);
      final z11 = metersPerPixelAtZoom(45.0, 11);
      expect(z11, closeTo(z10 / 2, z10 / 2 * 1e-9));
    });

    test('metres per pixel shrinks towards the poles', () {
      expect(metersPerPixelAtZoom(60.0, 12),
          lessThan(metersPerPixelAtZoom(0.0, 12)));
    });

    test('haversine matches a known short distance', () {
      // One ten-thousandth of a degree of latitude is about 11.1 m anywhere.
      expect(haversineMeters(45.0, -75.0, 45.0001, -75.0), closeTo(11.1, 0.2));
    });

    test('haversine is zero for a point against itself', () {
      expect(haversineMeters(45.27, -75.77, 45.27, -75.77), 0);
    });
  });
}
