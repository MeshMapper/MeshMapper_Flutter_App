// Coordinate-validity helpers shared across the GPS, state, and map layers.

/// Whether [lat]/[lon] are safe to hand to MapLibre's camera.
///
/// MapLibre's native `LatLng` constructor throws `std::domain_error` on NaN,
/// infinite, or out-of-range (|lat| > 90) coordinates. That C++ exception is
/// uncaught across the C++→Obj-C boundary, so it calls `std::terminate` and
/// aborts the whole app (`SIGABRT`). iOS can briefly report an invalid
/// `CLLocation` (e.g. right after the app resumes from background, or with a
/// negative accuracy), which `geolocator` passes straight through — so every
/// coordinate that can reach the map camera or be persisted/uploaded must be
/// validated against the WGS84 domain first.
bool isValidLatLng(double lat, double lon) =>
    lat.isFinite && lon.isFinite && lat.abs() <= 90 && lon.abs() <= 180;

/// Whether a lat/lon bounding box is zero/near-zero area (a single point, or a
/// cluster of coincident points).
///
/// Fitting the camera to a degenerate box makes MapLibre divide by a ~0 span,
/// producing a non-finite zoom that propagates into its `unproject` math and
/// aborts the app via the same `LatLng` throw as invalid coordinates. Callers
/// must detect this and fall back to a plain center+zoom move instead.
/// [epsilonDeg] defaults to 1e-6° (≈0.1 m) — below this a fit is meaningless.
bool isDegenerateBounds(
  double minLat,
  double maxLat,
  double minLon,
  double maxLon, {
  double epsilonDeg = 1e-6,
}) =>
    (maxLat - minLat).abs() < epsilonDeg && (maxLon - minLon).abs() < epsilonDeg;

/// Clamp fit-bounds edge padding so it can never meet or exceed the map's
/// rendered size.
///
/// MapLibre fits a bounds into `size - padding`; if the horizontal or vertical
/// padding sums to ≥ the map dimension the available area goes to zero/negative,
/// yielding a non-finite zoom that aborts the app inside `unproject`. This keeps
/// at least [minVisible] logical pixels visible on each axis, shrinking each
/// side proportionally when the requested padding is too large. When [width] or
/// [height] is unknown (≤ 0, e.g. before first layout) it returns small safe
/// defaults rather than trusting the caller's values.
({double left, double top, double right, double bottom}) clampFitPadding(
  double left,
  double top,
  double right,
  double bottom,
  double width,
  double height, {
  double minVisible = 40,
}) {
  // Unknown/zero viewport: don't trust the requested padding at all.
  if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
    return (left: 8, top: 8, right: 8, bottom: 8);
  }

  ({double a, double b}) clampPair(double a, double b, double extent) {
    a = a.isFinite && a > 0 ? a : 0;
    b = b.isFinite && b > 0 ? b : 0;
    final budget = extent - minVisible;
    if (budget <= 0) return (a: 0, b: 0);
    final sum = a + b;
    if (sum <= budget) return (a: a, b: b);
    // Shrink proportionally to fit the budget (sum > 0 here since sum > budget ≥ 0).
    final scale = budget / sum;
    return (a: a * scale, b: b * scale);
  }

  final h = clampPair(left, right, width);
  final v = clampPair(top, bottom, height);
  return (left: h.a, top: v.a, right: h.b, bottom: v.b);
}
