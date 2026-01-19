import 'dart:async';
import 'dart:math';

import 'package:geolocator/geolocator.dart';
import 'package:xml/xml.dart';

import '../utils/debug_logger_io.dart';

/// Movement pattern for GPS simulation
enum SimulatorPattern {
  /// Move in a straight line in the configured direction
  straight,
  /// Move in a circle around the start point
  circle,
  /// Random walk with smooth direction changes
  randomWalk,
  /// Follow a loaded route (KML/GPX)
  route,
}

/// A single point in a route
class RoutePoint {
  final double latitude;
  final double longitude;
  final double? altitude;

  const RoutePoint({
    required this.latitude,
    required this.longitude,
    this.altitude,
  });
}

/// GPS Simulator for testing without real GPS
/// Generates smooth, realistic position updates for development/testing
class GpsSimulatorService {
  /// Default start position (Ottawa downtown area)
  static const double defaultLatitude = 45.4215;
  static const double defaultLongitude = -75.6972;

  /// Simulation parameters
  double _latitude;
  double _longitude;
  double _speed; // km/h
  double _heading; // degrees (0 = North, 90 = East)
  SimulatorPattern _pattern;
  int _updateIntervalMs;

  /// For circle pattern
  double _circleRadius = 0.002; // ~200m in lat/lon degrees
  double _circleAngle = 0;
  double _circleCenterLat;
  double _circleCenterLon;

  /// For random walk
  final Random _random = Random();
  double _targetHeading = 0;

  /// For route playback
  List<RoutePoint> _routePoints = [];
  int _routeIndex = 0;
  double _routeProgress = 0; // 0-1 progress between current and next point
  String? _routeName;
  bool _routeLoop = true; // Loop back to start when done

  /// State
  bool _isRunning = false;
  Timer? _timer;
  final _positionController = StreamController<Position>.broadcast();

  /// Position stream for consumers
  Stream<Position> get positionStream => _positionController.stream;

  /// Current simulated position
  Position? _currentPosition;
  Position? get currentPosition => _currentPosition;

  /// Check if simulator is running
  bool get isRunning => _isRunning;

  /// Current speed in km/h
  double get speed => _speed;

  /// Current pattern
  SimulatorPattern get pattern => _pattern;

  /// Check if a route is loaded
  bool get hasRoute => _routePoints.isNotEmpty;

  /// Get loaded route name
  String? get routeName => _routeName;

  /// Get number of points in loaded route
  int get routePointCount => _routePoints.length;

  /// Get current route progress (0-100%)
  double get routeProgressPercent {
    if (_routePoints.isEmpty) return 0;
    return ((_routeIndex + _routeProgress) / _routePoints.length) * 100;
  }

  GpsSimulatorService({
    double? startLatitude,
    double? startLongitude,
    double speed = 50.0, // 50 km/h default
    double heading = 45.0, // Northeast default
    SimulatorPattern pattern = SimulatorPattern.straight,
    int updateIntervalMs = 500, // 500ms = 2 updates per second
  })  : _latitude = startLatitude ?? defaultLatitude,
        _longitude = startLongitude ?? defaultLongitude,
        _speed = speed,
        _heading = heading,
        _pattern = pattern,
        _updateIntervalMs = updateIntervalMs,
        _circleCenterLat = startLatitude ?? defaultLatitude,
        _circleCenterLon = startLongitude ?? defaultLongitude {
    _targetHeading = heading;
  }

  /// Update simulation parameters
  void configure({
    double? latitude,
    double? longitude,
    double? speed,
    double? heading,
    SimulatorPattern? pattern,
    int? updateIntervalMs,
  }) {
    if (latitude != null) _latitude = latitude;
    if (longitude != null) _longitude = longitude;
    if (speed != null) _speed = speed;
    if (heading != null) {
      _heading = heading;
      _targetHeading = heading;
    }
    if (pattern != null) _pattern = pattern;
    if (updateIntervalMs != null) _updateIntervalMs = updateIntervalMs;

    // Update circle center if position changed
    if (latitude != null || longitude != null) {
      _circleCenterLat = _latitude;
      _circleCenterLon = _longitude;
      _circleAngle = 0;
    }

    debugLog('[GPS SIM] Configured: speed=${_speed}km/h, pattern=$_pattern, heading=$_heading');
  }

  /// Start the simulator
  void start() {
    if (_isRunning) return;

    _isRunning = true;
    debugLog('[GPS SIM] Starting simulator: ${_latitude.toStringAsFixed(5)}, ${_longitude.toStringAsFixed(5)} @ ${_speed}km/h');

    // Emit initial position immediately
    _emitPosition();

    // Start update timer
    _timer = Timer.periodic(Duration(milliseconds: _updateIntervalMs), (_) {
      _updatePosition();
      _emitPosition();
    });
  }

  /// Stop the simulator
  void stop() {
    if (!_isRunning) return;

    _isRunning = false;
    _timer?.cancel();
    _timer = null;
    debugLog('[GPS SIM] Stopped simulator');
  }

  /// Reset to start position
  void reset({double? latitude, double? longitude}) {
    _latitude = latitude ?? defaultLatitude;
    _longitude = longitude ?? defaultLongitude;
    _circleCenterLat = _latitude;
    _circleCenterLon = _longitude;
    _circleAngle = 0;
    _heading = 45;
    _targetHeading = 45;
    _routeIndex = 0;
    _routeProgress = 0;
    debugLog('[GPS SIM] Reset to: ${_latitude.toStringAsFixed(5)}, ${_longitude.toStringAsFixed(5)}');
  }

  /// Load route from KML file content
  /// Returns true if route was loaded successfully
  bool loadKml(String kmlContent, {String? name}) {
    try {
      final document = XmlDocument.parse(kmlContent);
      final coordinates = <RoutePoint>[];

      // Find all coordinate elements (handles both LineString and Point)
      final coordElements = document.findAllElements('coordinates');

      for (final coordElement in coordElements) {
        final coordText = coordElement.innerText.trim();
        // KML format: lon,lat,alt lon,lat,alt ...
        final pointStrings = coordText.split(RegExp(r'\s+'));

        for (final pointStr in pointStrings) {
          if (pointStr.isEmpty) continue;
          final parts = pointStr.split(',');
          if (parts.length >= 2) {
            final lon = double.tryParse(parts[0]);
            final lat = double.tryParse(parts[1]);
            final alt = parts.length > 2 ? double.tryParse(parts[2]) : null;

            if (lon != null && lat != null) {
              coordinates.add(RoutePoint(
                latitude: lat,
                longitude: lon,
                altitude: alt,
              ));
            }
          }
        }
      }

      if (coordinates.isEmpty) {
        debugLog('[GPS SIM] No coordinates found in KML');
        return false;
      }

      _routePoints = coordinates;
      _routeIndex = 0;
      _routeProgress = 0;
      _routeName = name ?? _extractKmlName(document);
      _pattern = SimulatorPattern.route;

      // Set initial position to first point
      _latitude = _routePoints[0].latitude;
      _longitude = _routePoints[0].longitude;

      debugLog('[GPS SIM] Loaded KML route "$_routeName" with ${_routePoints.length} points');
      return true;
    } catch (e) {
      debugLog('[GPS SIM] Error parsing KML: $e');
      return false;
    }
  }

  /// Extract route name from KML document
  String _extractKmlName(XmlDocument document) {
    final nameElement = document.findAllElements('name').firstOrNull;
    return nameElement?.innerText ?? 'Unnamed Route';
  }

  /// Load route from GPX file content
  /// Returns true if route was loaded successfully
  bool loadGpx(String gpxContent, {String? name}) {
    try {
      final document = XmlDocument.parse(gpxContent);
      final coordinates = <RoutePoint>[];

      // GPX track points (<trkpt lat="..." lon="...">)
      final trkpts = document.findAllElements('trkpt');
      for (final pt in trkpts) {
        final lat = double.tryParse(pt.getAttribute('lat') ?? '');
        final lon = double.tryParse(pt.getAttribute('lon') ?? '');
        final eleElement = pt.findElements('ele').firstOrNull;
        final alt = eleElement != null ? double.tryParse(eleElement.innerText) : null;

        if (lat != null && lon != null) {
          coordinates.add(RoutePoint(latitude: lat, longitude: lon, altitude: alt));
        }
      }

      // Also check route points (<rtept>)
      if (coordinates.isEmpty) {
        final rtepts = document.findAllElements('rtept');
        for (final pt in rtepts) {
          final lat = double.tryParse(pt.getAttribute('lat') ?? '');
          final lon = double.tryParse(pt.getAttribute('lon') ?? '');
          if (lat != null && lon != null) {
            coordinates.add(RoutePoint(latitude: lat, longitude: lon));
          }
        }
      }

      // Also check waypoints (<wpt>)
      if (coordinates.isEmpty) {
        final wpts = document.findAllElements('wpt');
        for (final pt in wpts) {
          final lat = double.tryParse(pt.getAttribute('lat') ?? '');
          final lon = double.tryParse(pt.getAttribute('lon') ?? '');
          if (lat != null && lon != null) {
            coordinates.add(RoutePoint(latitude: lat, longitude: lon));
          }
        }
      }

      if (coordinates.isEmpty) {
        debugLog('[GPS SIM] No coordinates found in GPX');
        return false;
      }

      _routePoints = coordinates;
      _routeIndex = 0;
      _routeProgress = 0;
      _routeName = name ?? _extractGpxName(document);
      _pattern = SimulatorPattern.route;

      // Set initial position to first point
      _latitude = _routePoints[0].latitude;
      _longitude = _routePoints[0].longitude;

      debugLog('[GPS SIM] Loaded GPX route "$_routeName" with ${_routePoints.length} points');
      return true;
    } catch (e) {
      debugLog('[GPS SIM] Error parsing GPX: $e');
      return false;
    }
  }

  /// Extract route name from GPX document
  String _extractGpxName(XmlDocument document) {
    // Try track name first
    final trkName = document.findAllElements('trk').firstOrNull
        ?.findElements('name').firstOrNull?.innerText;
    if (trkName != null) return trkName;

    // Try route name
    final rteName = document.findAllElements('rte').firstOrNull
        ?.findElements('name').firstOrNull?.innerText;
    if (rteName != null) return rteName;

    // Try metadata name
    final metaName = document.findAllElements('metadata').firstOrNull
        ?.findElements('name').firstOrNull?.innerText;
    if (metaName != null) return metaName;

    return 'Unnamed Route';
  }

  /// Load route from file content (auto-detect format)
  bool loadRoute(String content, {String? name, String? filename}) {
    // Try to detect format from content or filename
    final isGpx = content.contains('<gpx') ||
        (filename?.toLowerCase().endsWith('.gpx') ?? false);
    final isKml = content.contains('<kml') ||
        (filename?.toLowerCase().endsWith('.kml') ?? false);

    if (isGpx) {
      return loadGpx(content, name: name);
    } else if (isKml) {
      return loadKml(content, name: name);
    } else {
      // Try GPX first, then KML
      if (loadGpx(content, name: name)) return true;
      return loadKml(content, name: name);
    }
  }

  /// Clear loaded route
  void clearRoute() {
    _routePoints = [];
    _routeIndex = 0;
    _routeProgress = 0;
    _routeName = null;
    if (_pattern == SimulatorPattern.route) {
      _pattern = SimulatorPattern.randomWalk;
    }
    debugLog('[GPS SIM] Route cleared');
  }

  /// Update position based on current pattern
  void _updatePosition() {
    switch (_pattern) {
      case SimulatorPattern.straight:
        _updateStraight();
        break;
      case SimulatorPattern.circle:
        _updateCircle();
        break;
      case SimulatorPattern.randomWalk:
        _updateRandomWalk();
        break;
      case SimulatorPattern.route:
        _updateRoute();
        break;
    }
  }

  /// Move along loaded route
  void _updateRoute() {
    if (_routePoints.isEmpty) {
      // Fall back to random walk if no route
      _updateRandomWalk();
      return;
    }

    // Calculate distance traveled in this interval based on speed
    final distanceKm = (_speed / 3600000) * _updateIntervalMs;
    var remainingDistanceM = distanceKm * 1000;

    // May need to traverse multiple segments if speed is high
    var iterations = 0;
    const maxIterations = 100; // Safety limit

    while (remainingDistanceM > 0 && iterations < maxIterations) {
      iterations++;

      // Get current and next point
      final currentPoint = _routePoints[_routeIndex];
      final nextIndex = (_routeIndex + 1) % _routePoints.length;
      final nextPoint = _routePoints[nextIndex];

      // Calculate distance between current and next point
      final segmentDistanceM = _haversineDistance(
        currentPoint.latitude, currentPoint.longitude,
        nextPoint.latitude, nextPoint.longitude,
      );

      if (segmentDistanceM < 1) {
        // Points are essentially the same, move to next
        _routeIndex = nextIndex;
        _routeProgress = 0;
        if (_routeIndex == 0 && !_routeLoop) {
          // End of route, stop
          stop();
          return;
        }
        continue;
      }

      // Calculate remaining distance in current segment
      final currentPositionM = _routeProgress * segmentDistanceM;
      final remainingInSegmentM = segmentDistanceM - currentPositionM;

      if (remainingDistanceM >= remainingInSegmentM) {
        // We'll reach or pass the next point
        remainingDistanceM -= remainingInSegmentM;
        _routeIndex = nextIndex;
        _routeProgress = 0;

        if (_routeIndex == 0) {
          if (!_routeLoop) {
            // End of route, stop at last point
            _latitude = _routePoints[_routePoints.length - 1].latitude;
            _longitude = _routePoints[_routePoints.length - 1].longitude;
            stop();
            return;
          }
          debugLog('[GPS SIM] Route looped back to start');
        }
      } else {
        // We'll stop somewhere along this segment
        _routeProgress += remainingDistanceM / segmentDistanceM;
        remainingDistanceM = 0;
      }
    }

    // Interpolate position along current segment
    final currentPoint = _routePoints[_routeIndex];
    final nextIndex = (_routeIndex + 1) % _routePoints.length;
    final nextPoint = _routePoints[nextIndex];

    final t = _routeProgress.clamp(0.0, 1.0);
    _latitude = currentPoint.latitude + (nextPoint.latitude - currentPoint.latitude) * t;
    _longitude = currentPoint.longitude + (nextPoint.longitude - currentPoint.longitude) * t;

    // Calculate heading towards next point
    _heading = _calculateBearing(
      currentPoint.latitude, currentPoint.longitude,
      nextPoint.latitude, nextPoint.longitude,
    );
  }

  /// Haversine distance between two points in meters
  double _haversineDistance(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0; // Earth radius in meters
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) *
        sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  /// Calculate bearing from point 1 to point 2 in degrees
  double _calculateBearing(double lat1, double lon1, double lat2, double lon2) {
    final dLon = (lon2 - lon1) * pi / 180;
    final lat1Rad = lat1 * pi / 180;
    final lat2Rad = lat2 * pi / 180;

    final y = sin(dLon) * cos(lat2Rad);
    final x = cos(lat1Rad) * sin(lat2Rad) -
        sin(lat1Rad) * cos(lat2Rad) * cos(dLon);
    var bearing = atan2(y, x) * 180 / pi;
    return (bearing + 360) % 360; // Normalize to 0-360
  }

  /// Move in a straight line
  void _updateStraight() {
    // Calculate distance traveled in this interval
    // speed is km/h, interval is in ms
    final distanceKm = (_speed / 3600000) * _updateIntervalMs;

    // Convert heading to radians
    final headingRad = _heading * pi / 180;

    // Calculate new position
    // 1 degree latitude ≈ 111 km
    // 1 degree longitude ≈ 111 km * cos(latitude)
    final latChange = (distanceKm / 111) * cos(headingRad);
    final lonChange = (distanceKm / (111 * cos(_latitude * pi / 180))) * sin(headingRad);

    _latitude += latChange;
    _longitude += lonChange;
  }

  /// Move in a circle around the start point
  void _updateCircle() {
    // Calculate angular velocity based on speed and radius
    // Circumference = 2 * pi * radius (in km)
    final radiusKm = _circleRadius * 111; // Approximate conversion
    final circumferenceKm = 2 * pi * radiusKm;
    final degreesPerMs = (_speed / circumferenceKm) * 360 / 3600000;

    // Update angle
    _circleAngle += degreesPerMs * _updateIntervalMs;
    if (_circleAngle >= 360) _circleAngle -= 360;

    // Calculate position on circle
    final angleRad = _circleAngle * pi / 180;
    _latitude = _circleCenterLat + _circleRadius * cos(angleRad);
    _longitude = _circleCenterLon + _circleRadius * sin(angleRad) / cos(_circleCenterLat * pi / 180);

    // Update heading to be tangent to circle
    _heading = (_circleAngle + 90) % 360;
  }

  /// Random walk with smooth direction changes
  void _updateRandomWalk() {
    // Occasionally change target heading
    if (_random.nextDouble() < 0.05) {
      // 5% chance each update
      _targetHeading = _random.nextDouble() * 360;
    }

    // Smoothly interpolate heading towards target
    var headingDiff = _targetHeading - _heading;
    if (headingDiff > 180) headingDiff -= 360;
    if (headingDiff < -180) headingDiff += 360;
    _heading += headingDiff * 0.1; // Smooth turn

    // Normalize heading
    if (_heading < 0) _heading += 360;
    if (_heading >= 360) _heading -= 360;

    // Move in current direction (same as straight)
    _updateStraight();
  }

  /// Emit current position to stream
  void _emitPosition() {
    _currentPosition = Position(
      latitude: _latitude,
      longitude: _longitude,
      timestamp: DateTime.now(),
      accuracy: 5.0, // Simulated accuracy: 5 meters
      altitude: 100.0, // Simulated altitude
      altitudeAccuracy: 1.0,
      heading: _heading,
      headingAccuracy: 1.0,
      speed: _speed / 3.6, // Convert km/h to m/s
      speedAccuracy: 0.5,
    );

    _positionController.add(_currentPosition!);
  }

  /// Dispose resources
  void dispose() {
    stop();
    _positionController.close();
  }
}
