import 'dart:async';
import 'dart:math';

import 'package:geolocator/geolocator.dart';

import '../models/connection_state.dart';

/// GPS service for location tracking and geofencing
/// Ported from wardrive.js geolocation logic
class GpsService {
  /// Ottawa coordinates (geofence center)
  static const double _ottawaLat = 45.4215;
  static const double _ottawaLon = -75.6972;
  
  /// Geofence radius in kilometers
  static const double _geofenceRadiusKm = 150.0;
  
  /// Minimum distance (meters) from last ping before allowing new ping
  static const double minDistanceMeters = 25.0;

  final _statusController = StreamController<GpsStatus>.broadcast();
  final _positionController = StreamController<Position>.broadcast();

  GpsStatus _status = GpsStatus.permissionDenied;
  Position? _lastPosition;
  Position? _lastPingPosition;
  StreamSubscription<Position>? _positionSubscription;

  /// Stream of GPS status changes
  Stream<GpsStatus> get statusStream => _statusController.stream;

  /// Stream of position updates
  Stream<Position> get positionStream => _positionController.stream;

  /// Current GPS status
  GpsStatus get status => _status;

  /// Last known position
  Position? get lastPosition => _lastPosition;

  /// Last ping position
  Position? get lastPingPosition => _lastPingPosition;

  void _updateStatus(GpsStatus status) {
    _status = status;
    _statusController.add(status);
  }

  /// Check if GPS permissions are granted
  Future<bool> checkPermissions() async {
    final permission = await Geolocator.checkPermission();
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  /// Request GPS permissions
  Future<bool> requestPermissions() async {
    LocationPermission permission = await Geolocator.checkPermission();
    
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    
    if (permission == LocationPermission.deniedForever) {
      _updateStatus(GpsStatus.permissionDenied);
      return false;
    }
    
    if (permission == LocationPermission.denied) {
      _updateStatus(GpsStatus.permissionDenied);
      return false;
    }
    
    return true;
  }

  /// Check if location services are enabled
  Future<bool> isLocationServiceEnabled() async {
    return await Geolocator.isLocationServiceEnabled();
  }

  /// Start watching position
  Future<void> startWatching() async {
    // Check permissions first
    if (!await requestPermissions()) {
      _updateStatus(GpsStatus.permissionDenied);
      return;
    }

    // Check if location services are enabled
    if (!await isLocationServiceEnabled()) {
      _updateStatus(GpsStatus.disabled);
      return;
    }

    _updateStatus(GpsStatus.searching);

    // Configure location settings
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 25, // Trigger every 25m movement
      timeLimit: Duration(seconds: 30),
    );

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (position) {
        _lastPosition = position;
        _positionController.add(position);

        // Update status based on geofence
        if (isWithinGeofence(position)) {
          _updateStatus(GpsStatus.locked);
        } else {
          _updateStatus(GpsStatus.outsideGeofence);
        }
      },
      onError: (error) {
        _updateStatus(GpsStatus.disabled);
      },
    );

    // Get initial position
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      _lastPosition = position;
      _positionController.add(position);
      
      if (isWithinGeofence(position)) {
        _updateStatus(GpsStatus.locked);
      } else {
        _updateStatus(GpsStatus.outsideGeofence);
      }
    } catch (e) {
      // Will receive updates from stream
    }
  }

  /// Stop watching position
  void stopWatching() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
  }

  /// Check if position is within geofence (150km from Ottawa)
  /// Reference: checkGeofence() in wardrive.js
  bool isWithinGeofence(Position position) {
    final distanceMeters = Geolocator.distanceBetween(
      _ottawaLat,
      _ottawaLon,
      position.latitude,
      position.longitude,
    );
    return distanceMeters <= (_geofenceRadiusKm * 1000);
  }

  /// Calculate distance from last ping position
  double distanceFromLastPing(Position current) {
    if (_lastPingPosition == null) {
      return double.infinity; // Allow first ping
    }
    return Geolocator.distanceBetween(
      _lastPingPosition!.latitude,
      _lastPingPosition!.longitude,
      current.latitude,
      current.longitude,
    );
  }

  /// Check if current position is far enough from last ping (25m minimum)
  bool canPingAtPosition(Position position) {
    if (_lastPingPosition == null) return true;
    return distanceFromLastPing(position) >= minDistanceMeters;
  }

  /// Mark current position as ping location
  void markPingPosition(Position position) {
    _lastPingPosition = position;
  }

  /// Get current position (single request)
  Future<Position?> getCurrentPosition() async {
    if (!await requestPermissions()) {
      return null;
    }

    if (!await isLocationServiceEnabled()) {
      return null;
    }

    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
    } catch (e) {
      return null;
    }
  }

  /// Calculate distance between two positions in meters
  static double distanceBetween(
    double startLat,
    double startLon,
    double endLat,
    double endLon,
  ) {
    return Geolocator.distanceBetween(startLat, startLon, endLat, endLon);
  }

  /// Calculate bearing between two positions in degrees
  static double bearingBetween(
    double startLat,
    double startLon,
    double endLat,
    double endLon,
  ) {
    return Geolocator.bearingBetween(startLat, startLon, endLat, endLon);
  }

  /// Dispose of resources
  void dispose() {
    stopWatching();
    _statusController.close();
    _positionController.close();
  }
}
