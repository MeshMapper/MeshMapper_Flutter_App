import 'dart:math' as math;

/// Geometry behind "should a tap on a cluster zoom in, or spread it out?".
///
/// Kept pure and out of the map widget so the rule can be tested. It decides
/// how a tap feels, and a tap that does nothing visible is the worst outcome
/// the map can produce.

/// Web-Mercator metres per screen pixel at [latDeg] and [zoom].
double metersPerPixelAtZoom(double latDeg, num zoom) =>
    156543.03392 * math.cos(latDeg * math.pi / 180) / math.pow(2, zoom);

/// Great-circle distance between two points in metres.
double haversineMeters(
  double lat1Deg,
  double lon1Deg,
  double lat2Deg,
  double lon2Deg,
) {
  const earthRadiusM = 6378137.0;
  final lat1 = lat1Deg * math.pi / 180;
  final lat2 = lat2Deg * math.pi / 180;
  final dLat = (lat2Deg - lat1Deg) * math.pi / 180;
  final dLon = (lon2Deg - lon1Deg) * math.pi / 180;
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * earthRadiusM * math.asin(math.min(1.0, math.sqrt(h)));
}

/// Whether zooming all the way in to [maxZoom] could ever break a group of
/// points apart into separate markers.
///
/// MapLibre re-clusters by SCREEN distance: points stay merged for as long as
/// they sit within [clusterRadiusPx] of one another. So measure the group's
/// widest span as it would appear at max zoom. If it still fits inside that
/// radius there, no amount of zooming will ever separate the group, and a
/// zoom-in spends the user's tap on a camera move that changes nothing they
/// care about. That is the ordinary case on this map, where several repeaters
/// share a rooftop or a tower.
///
/// The span used is the diagonal of the group's bounding box: O(n) rather than
/// every pair, and it can only ever OVER-state the widest pair, so the answer
/// errs towards zooming. Erring that way keeps the older behaviour on genuinely
/// spread-out clusters and only changes the tight ones, which are the ones that
/// were frustrating.
///
/// Returns false for fewer than two points, for mismatched or empty inputs, and
/// for any non-finite coordinate, so a caller can treat false as "just spread
/// it".
bool clusterCanSeparateByZoom({
  required List<double> lats,
  required List<double> lons,
  required double maxZoom,
  required double clusterRadiusPx,
}) {
  if (lats.length != lons.length || lats.length < 2) return false;
  if (!clusterRadiusPx.isFinite || clusterRadiusPx < 0) return false;

  var minLat = double.infinity, maxLat = double.negativeInfinity;
  var minLon = double.infinity, maxLon = double.negativeInfinity;
  for (var i = 0; i < lats.length; i++) {
    final lat = lats[i];
    final lon = lons[i];
    if (!lat.isFinite || !lon.isFinite) return false;
    if (lat < minLat) minLat = lat;
    if (lat > maxLat) maxLat = lat;
    if (lon < minLon) minLon = lon;
    if (lon > maxLon) maxLon = lon;
  }

  final spreadMeters = haversineMeters(minLat, minLon, maxLat, maxLon);
  // Points this close are the same mast for any purpose, and zoom will never
  // tell them apart. The floor also keeps the division below honest: at a pole
  // both the span and the metres-per-pixel collapse to floating-point noise,
  // and the ratio of two near-zero numbers came out large enough to claim the
  // group would separate.
  if (spreadMeters < 0.5) return false;

  final metersPerPixel = metersPerPixelAtZoom((minLat + maxLat) / 2, maxZoom);
  if (!metersPerPixel.isFinite || metersPerPixel <= 0) return false;
  return spreadMeters / metersPerPixel > clusterRadiusPx;
}
