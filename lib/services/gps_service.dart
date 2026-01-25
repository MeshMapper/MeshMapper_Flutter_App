import 'dart:async';
import 'dart:io';

import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/connection_state.dart';
import '../utils/debug_logger_io.dart';
import 'gps_simulator_service.dart';

/// GPS service for location tracking
/// Ported from wardrive.js geolocation logic
/// Note: Zone validation is now handled server-side by the API
class GpsService {
  /// Minimum distance (meters) from last ping before allowing new ping
  static const double minDistanceMeters = 25.0;
  
  /// Maximum GPS age for manual pings (60 seconds)
  /// Reference: GPS_WATCH_MAX_AGE_MS in wardrive.js
  static const Duration maxGpsAgeForManualPing = Duration(seconds: 60);
  
  /// Maximum GPS accuracy threshold for pings (100 meters)
  /// Reference: GPS_ACCURACY_THRESHOLD_M in wardrive.js docs
  static const double maxAccuracyMetersForPing = 100.0;
  
  /// Maximum GPS accuracy threshold for zone checks (50 meters)
  /// Reference: getValidGpsForZoneCheck() in wardrive.js
  static const double maxAccuracyMetersForZoneCheck = 50.0;

  final _statusController = StreamController<GpsStatus>.broadcast();
  final _positionController = StreamController<Position>.broadcast();

  GpsStatus _status = GpsStatus.permissionDenied;
  Position? _lastPosition;
  Position? _lastPingPosition;
  StreamSubscription<Position>? _positionSubscription;

  /// GPS Simulator for testing
  GpsSimulatorService? _simulator;
  StreamSubscription<Position>? _simulatorSubscription;
  bool _simulatorEnabled = false;

  /// Check if simulator is enabled
  bool get isSimulatorEnabled => _simulatorEnabled;

  /// Get simulator instance (creates if needed)
  GpsSimulatorService get simulator {
    _simulator ??= GpsSimulatorService();
    return _simulator!;
  }

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

  /// Request GPS permissions (When In Use)
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

  /// Check if "Always" location permission is granted
  Future<bool> hasAlwaysPermission() async {
    final permission = await Geolocator.checkPermission();
    return permission == LocationPermission.always;
  }

  /// Request "Always" location permission for background mode
  /// On iOS, this triggers the second permission dialog after "When In Use" is granted
  /// On Android 10+, this triggers the "Allow all the time" dialog
  /// Returns true if permission is granted, false otherwise
  Future<bool> requestAlwaysPermission() async {
    debugLog('[GPS] Requesting Always location permission');

    final current = await Geolocator.checkPermission();

    // If already have "Always", we're good
    if (current == LocationPermission.always) {
      debugLog('[GPS] Already have Always permission');
      return true;
    }

    // If denied forever, can't request again - user must go to settings
    if (current == LocationPermission.deniedForever) {
      debugLog('[GPS] Permission denied forever - user must enable in Settings');
      return false;
    }

    // Platform-specific request
    if (Platform.isAndroid) {
      // Android: Use permission_handler to request locationAlways
      // This triggers "Allow all the time" dialog on Android 10+
      final status = await Permission.locationAlways.request();
      debugLog('[GPS] Android always permission result: $status');
      return status.isGranted;
    } else {
      // iOS: Use Geolocator for the upgrade dialog
      final permission = await Geolocator.requestPermission();
      debugLog('[GPS] iOS permission result: $permission');
      return permission == LocationPermission.always;
    }
  }

  /// Check if location services are enabled
  Future<bool> isLocationServiceEnabled() async {
    return await Geolocator.isLocationServiceEnabled();
  }

  /// Start watching position
  /// Note: This only CHECKS permissions, does not REQUEST them.
  /// Permission requests are handled by the disclosure flow in MainScaffold.
  Future<void> startWatching() async {
    // Check if location services are enabled first (system-level setting)
    if (!await isLocationServiceEnabled()) {
      debugLog('[GPS] Location services disabled at system level');
      _updateStatus(GpsStatus.disabled);
      return;
    }

    // Check permissions (don't request - disclosure flow handles that)
    if (!await checkPermissions()) {
      debugLog('[GPS] Permissions not granted yet, waiting for disclosure flow');
      _updateStatus(GpsStatus.permissionDenied);
      return;
    }

    _updateStatus(GpsStatus.searching);

    // Configure location settings for position stream
    // Note: No timeLimit - we want continuous GPS tracking even when stationary
    // The distanceFilter handles update frequency (10m for RX batch checks at 25m)
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10, // Trigger every 10m movement (check RX batches at 25m)
      ),
    ).listen(
      (position) {
        debugLog('[GPS SERVICE] Position stream fired: lat=${position.latitude.toStringAsFixed(5)}, '
            'lon=${position.longitude.toStringAsFixed(5)}, accuracy=${position.accuracy.toStringAsFixed(1)}m');
        _lastPosition = position;
        _positionController.add(position);

        // GPS signal acquired
        _updateStatus(GpsStatus.locked);
      },
      onError: (error) {
        debugError('[GPS SERVICE] Position stream error: $error');
        _updateStatus(GpsStatus.disabled);
      },
    );

    // Get initial position
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );
      _lastPosition = position;
      _positionController.add(position);
      _updateStatus(GpsStatus.locked);
    } catch (e) {
      // Will receive updates from stream
    }
  }

  /// Stop watching position
  void stopWatching() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
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

  /// Check if GPS position is fresh enough for manual pings (< 60s old)
  /// Reference: GPS_WATCH_MAX_AGE_MS validation in wardrive.js
  bool isPositionFresh(Position position) {
    final age = DateTime.now().difference(position.timestamp);
    return age <= maxGpsAgeForManualPing;
  }
  
  /// Check if GPS position has acceptable accuracy for pings (< 100m)
  /// Reference: GPS_ACCURACY_THRESHOLD_M in wardrive.js
  bool isAccuracyAcceptableForPing(Position position) {
    return position.accuracy <= maxAccuracyMetersForPing;
  }
  
  /// Check if GPS position has acceptable accuracy for zone checks (< 50m)
  /// Reference: getValidGpsForZoneCheck() in wardrive.js
  bool isAccuracyAcceptableForZoneCheck(Position position) {
    return position.accuracy <= maxAccuracyMetersForZoneCheck;
  }
  
  /// Validate position for ping operation
  /// Checks freshness (< 60s old) and accuracy (< 100m)
  /// Returns null if valid, error message if invalid
  String? validatePositionForPing(Position position) {
    // Check freshness
    if (!isPositionFresh(position)) {
      final age = DateTime.now().difference(position.timestamp).inSeconds;
      debugWarn('[GPS] Position too old: ${age}s (max 60s)');
      return 'GPS data too old ($age seconds)';
    }
    
    // Check accuracy
    if (!isAccuracyAcceptableForPing(position)) {
      final accuracy = position.accuracy.toInt();
      debugWarn('[GPS] Position too inaccurate: ${accuracy}m (max 100m)');
      return 'GPS accuracy too low ($accuracy meters)';
    }
    
    return null; // Valid
  }
  
  /// Validate position for zone check operation
  /// Checks freshness (< 60s old) and accuracy (< 50m, stricter than ping)
  /// Returns null if valid, error message if invalid
  String? validatePositionForZoneCheck(Position position) {
    // Check freshness
    if (!isPositionFresh(position)) {
      final age = DateTime.now().difference(position.timestamp).inSeconds;
      debugWarn('[GPS] [AUTH] Position too old: ${age}s (max 60s)');
      return 'GPS data too old ($age seconds)';
    }
    
    // Check accuracy (stricter for zone checks)
    if (!isAccuracyAcceptableForZoneCheck(position)) {
      final accuracy = position.accuracy.toInt();
      debugWarn('[GPS] [AUTH] Position too inaccurate: ${accuracy}m (max 50m)');
      return 'GPS accuracy too low ($accuracy meters)';
    }
    
    return null; // Valid
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
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
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

  /// Enable GPS simulator (for testing)
  /// Stops real GPS and starts simulated position updates
  void enableSimulator({
    double? startLatitude,
    double? startLongitude,
    double speed = 50.0,
    SimulatorPattern pattern = SimulatorPattern.randomWalk,
  }) {
    if (_simulatorEnabled) return;

    debugLog('[GPS] Enabling simulator mode');

    // Stop real GPS
    stopWatching();

    // Configure and start simulator
    simulator.configure(
      latitude: startLatitude,
      longitude: startLongitude,
      speed: speed,
      pattern: pattern,
    );

    // Subscribe to simulator positions
    _simulatorSubscription = simulator.positionStream.listen((position) {
      _lastPosition = position;
      _positionController.add(position);

      // Simulator position acquired
      _updateStatus(GpsStatus.locked);
    });

    simulator.start();
    _simulatorEnabled = true;

    // Set initial position immediately from simulator
    if (simulator.currentPosition != null) {
      _lastPosition = simulator.currentPosition;
      _positionController.add(simulator.currentPosition!);
    }

    _updateStatus(GpsStatus.locked); // Simulator always has "lock"
  }

  /// Disable GPS simulator and return to real GPS
  void disableSimulator() {
    if (!_simulatorEnabled) return;

    debugLog('[GPS] Disabling simulator mode');

    // Stop simulator
    simulator.stop();
    _simulatorSubscription?.cancel();
    _simulatorSubscription = null;
    _simulatorEnabled = false;

    // Restart real GPS
    startWatching();
  }

  /// Configure simulator parameters (speed, pattern)
  void configureSimulator({
    double? speed,
    SimulatorPattern? pattern,
    double? heading,
  }) {
    simulator.configure(
      speed: speed,
      pattern: pattern,
      heading: heading,
    );
  }

  /// Dispose of resources
  void dispose() {
    stopWatching();
    simulator.dispose();
    _simulatorSubscription?.cancel();
    _statusController.close();
    _positionController.close();
  }
}
