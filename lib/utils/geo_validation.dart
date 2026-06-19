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
