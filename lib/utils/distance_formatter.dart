/// Utility functions for formatting distances in metric or imperial units
library;

/// Format a distance in meters for display
/// Returns string like "150m" (metric) or "492ft" (imperial)
String formatMeters(double meters, {bool isImperial = false}) {
  if (isImperial) {
    final feet = meters * 3.28084;
    return '${feet.toStringAsFixed(0)}ft';
  }
  return '${meters.toStringAsFixed(0)}m';
}

/// Web-parity distance string for coverage popups (GRID SUMMARY "MAX DIST" and
/// the repeater "Max Range"): "123.26 km" / "150 m" (metric) or "76.55 mi" /
/// "492 ft" (imperial). Mirrors `formatDistance` (dev/index.php:6205) — note the
/// space and 2-decimal km/mi, which differ from [formatMeters]/[formatKilometers].
String formatCoverageDistance(double meters, {bool isImperial = false}) {
  if (isImperial) {
    final feet = meters * 3.28084;
    if (feet >= 5280) return '${(feet / 5280).toStringAsFixed(2)} mi';
    return '${feet.round()} ft';
  }
  if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(2)} km';
  return '${meters.round()} m';
}

/// Format a distance in kilometers for display
/// Returns string like "2.5km" (metric) or "1.6mi" (imperial)
String formatKilometers(double kilometers, {bool isImperial = false}) {
  if (isImperial) {
    final miles = kilometers * 0.621371;
    return '${miles.toStringAsFixed(1)}mi';
  }
  return '${kilometers.toStringAsFixed(1)}km';
}

/// Format speed in km/h for display
/// Returns string like "50 km/h" (metric) or "31 mph" (imperial)
String formatSpeed(double kmh, {bool isImperial = false}) {
  if (isImperial) {
    final mph = kmh * 0.621371;
    return '${mph.round()} mph';
  }
  return '${kmh.round()} km/h';
}
