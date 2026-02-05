/// Utility functions for formatting distances in metric or imperial units

/// Format a distance in meters for display
/// Returns string like "150m" (metric) or "492ft" (imperial)
String formatMeters(double meters, {bool isImperial = false}) {
  if (isImperial) {
    final feet = meters * 3.28084;
    return '${feet.toStringAsFixed(0)}ft';
  }
  return '${meters.toStringAsFixed(0)}m';
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
