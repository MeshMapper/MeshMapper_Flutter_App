import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../models/log_entry.dart';
import '../models/ping_data.dart';
import '../models/repeater.dart';
import '../providers/app_state_provider.dart';

/// Map style options
enum MapStyle {
  dark,
  light,
  satellite,
}

extension MapStyleExtension on MapStyle {
  String get label {
    switch (this) {
      case MapStyle.dark:
        return 'Dark';
      case MapStyle.light:
        return 'Light';
      case MapStyle.satellite:
        return 'Satellite';
    }
  }

  IconData get icon {
    switch (this) {
      case MapStyle.dark:
        return Icons.dark_mode;
      case MapStyle.light:
        return Icons.light_mode;
      case MapStyle.satellite:
        return Icons.satellite_alt;
    }
  }

  String get urlTemplate {
    switch (this) {
      case MapStyle.dark:
        return 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png';
      case MapStyle.light:
        return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
      case MapStyle.satellite:
        return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
    }
  }

  List<String>? get subdomains {
    switch (this) {
      case MapStyle.dark:
        return ['a', 'b', 'c', 'd'];
      case MapStyle.light:
        return null; // OSM doesn't use subdomains anymore
      case MapStyle.satellite:
        return null; // ArcGIS doesn't use subdomains
    }
  }
}

/// Custom tile provider that silently handles HTTP errors (404, 503, etc.)
/// instead of flooding the console with exceptions
final class SilentCancellableNetworkTileProvider extends CancellableNetworkTileProvider {
  SilentCancellableNetworkTileProvider() : super(
    dioClient: Dio(
      BaseOptions(
        validateStatus: (status) => true, // Accept all status codes
      ),
    ),
  );
}

/// Map widget with TX/RX markers
/// Uses flutter_map with OpenStreetMap tiles
class MapWidget extends StatefulWidget {
  const MapWidget({super.key});

  @override
  State<MapWidget> createState() => _MapWidgetState();
}

class _MapWidgetState extends State<MapWidget> with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  MapStyle _mapStyle = MapStyle.dark;

  // Auto-follow GPS like a navigation app
  bool _autoFollow = true;
  bool _isMapReady = false;
  LatLng? _lastGpsPosition;

  // Map rotation mode
  bool _alwaysNorth = true; // true = north always up, false = rotate with heading
  double? _lastHeading; // Track last heading for smooth rotation

  // MeshMapper overlay toggle (on by default)
  bool _showMeshMapperOverlay = true;

  // Map navigation trigger tracking (from log screen)
  int _lastNavigationTrigger = 0;

  // Smooth animation for map movement
  AnimationController? _animationController;
  Animation<double>? _animation;
  LatLng? _animationStartPosition;
  LatLng? _animationEndPosition;

  // Smooth animation for map rotation
  AnimationController? _rotationAnimationController;
  Animation<double>? _rotationAnimation;
  double? _rotationStartAngle;
  double? _rotationEndAngle;

  // Default center (Ottawa)
  static const LatLng _defaultCenter = LatLng(45.4215, -75.6972);
  static const double _defaultZoom = 15.0; // Closer zoom for driving

  @override
  void dispose() {
    _animationController?.dispose();
    _rotationAnimationController?.dispose();
    super.dispose();
  }

  /// Smoothly animate the map to a new position
  void _animateToPosition(LatLng target) {
    if (!_isMapReady || !mounted) return;

    // Get current position
    final currentCenter = _mapController.camera.center;

    // Skip if already at target (within small threshold)
    final distance = const Distance().as(LengthUnit.Meter, currentCenter, target);
    if (distance < 1) return; // Less than 1 meter, don't animate

    // Cancel any running animation
    _animationController?.stop();
    _animationController?.dispose();

    // Create new animation controller
    // Duration based on distance - shorter for small movements, longer for big jumps
    final duration = Duration(milliseconds: distance < 100 ? 200 : 300);

    _animationController = AnimationController(
      duration: duration,
      vsync: this,
    );

    _animation = CurvedAnimation(
      parent: _animationController!,
      curve: Curves.easeOutCubic, // Smooth deceleration
    );

    _animationStartPosition = currentCenter;
    _animationEndPosition = target;

    _animation!.addListener(() {
      if (!mounted || _animationStartPosition == null || _animationEndPosition == null) return;

      // Interpolate between start and end positions
      final t = _animation!.value;
      final lat = _animationStartPosition!.latitude +
          ((_animationEndPosition!.latitude - _animationStartPosition!.latitude) * t);
      final lng = _animationStartPosition!.longitude +
          ((_animationEndPosition!.longitude - _animationStartPosition!.longitude) * t);

      _mapController.move(LatLng(lat, lng), _mapController.camera.zoom);
    });

    _animationController!.forward();
  }

  /// Smoothly animate the map to a new position with zoom
  void _animateToPositionWithZoom(LatLng target, double targetZoom) {
    if (!_isMapReady || !mounted) return;

    // Get current position and zoom
    final currentCenter = _mapController.camera.center;
    final currentZoom = _mapController.camera.zoom;

    // Cancel any running animation
    _animationController?.stop();
    _animationController?.dispose();

    // Create new animation controller
    final duration = const Duration(milliseconds: 500); // Smooth zoom + pan

    _animationController = AnimationController(
      duration: duration,
      vsync: this,
    );

    _animation = CurvedAnimation(
      parent: _animationController!,
      curve: Curves.easeInOutCubic, // Smooth acceleration and deceleration
    );

    _animationStartPosition = currentCenter;
    _animationEndPosition = target;

    _animation!.addListener(() {
      if (!mounted || _animationStartPosition == null || _animationEndPosition == null) return;

      // Interpolate between start and end positions
      final t = _animation!.value;
      final lat = _animationStartPosition!.latitude +
          ((_animationEndPosition!.latitude - _animationStartPosition!.latitude) * t);
      final lng = _animationStartPosition!.longitude +
          ((_animationEndPosition!.longitude - _animationStartPosition!.longitude) * t);

      // Interpolate zoom
      final zoom = currentZoom + ((targetZoom - currentZoom) * t);

      _mapController.move(LatLng(lat, lng), zoom);
    });

    _animationController!.forward();
  }

  /// Smoothly animate the map rotation to match heading
  void _animateToRotation(double targetHeading) {
    if (!_isMapReady || !mounted || _alwaysNorth) return;

    // Get current rotation (in degrees)
    final currentRotation = _mapController.camera.rotation;

    // Normalize target heading to -180 to 180 range for smooth rotation
    // Map heading is counter-clockwise from north, GPS heading is clockwise
    // So we need to negate it: -targetHeading
    double targetRotation = -targetHeading;

    // Normalize angles to -180 to 180 range
    while (targetRotation > 180) targetRotation -= 360;
    while (targetRotation < -180) targetRotation += 360;

    // Calculate shortest rotation path
    double delta = targetRotation - currentRotation;
    while (delta > 180) delta -= 360;
    while (delta < -180) delta += 360;

    // Skip if rotation change is very small (less than 2 degrees)
    if (delta.abs() < 2) return;

    // Cancel any running rotation animation
    _rotationAnimationController?.stop();
    _rotationAnimationController?.dispose();

    // Create new rotation animation controller
    // Faster rotation for small changes, slower for large changes
    final duration = Duration(milliseconds: delta.abs() < 45 ? 300 : 500);

    _rotationAnimationController = AnimationController(
      duration: duration,
      vsync: this,
    );

    _rotationAnimation = CurvedAnimation(
      parent: _rotationAnimationController!,
      curve: Curves.easeInOutCubic, // Smooth acceleration and deceleration
    );

    _rotationStartAngle = currentRotation;
    _rotationEndAngle = currentRotation + delta;

    _rotationAnimation!.addListener(() {
      if (!mounted || _rotationStartAngle == null || _rotationEndAngle == null) return;

      // Interpolate between start and end angles
      final t = _rotationAnimation!.value;
      final rotation = _rotationStartAngle! +
          ((_rotationEndAngle! - _rotationStartAngle!) * t);

      _mapController.rotate(rotation);
    });

    _rotationAnimationController!.forward();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();

    // Determine map center
    LatLng center = _defaultCenter;
    if (appState.currentPosition != null) {
      center = LatLng(
        appState.currentPosition!.latitude,
        appState.currentPosition!.longitude,
      );

      // Auto-follow GPS position when enabled - use smooth animation
      if (_autoFollow && _isMapReady) {
        final newPosition = center;
        // Only animate if position has actually changed
        if (_lastGpsPosition == null ||
            _lastGpsPosition!.latitude != newPosition.latitude ||
            _lastGpsPosition!.longitude != newPosition.longitude) {
          _lastGpsPosition = newPosition;
          // Use post frame callback to avoid build-during-build issues
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _autoFollow) {
              _animateToPosition(newPosition); // Smooth animation instead of jump
            }
          });
        }
      }

      // Handle map rotation based on heading (when not in Always North mode)
      if (!_alwaysNorth && _isMapReady) {
        final heading = appState.currentPosition!.heading;
        // Only rotate if heading has changed significantly or is first time
        if (_lastHeading == null || (heading - _lastHeading!).abs() > 2) {
          _lastHeading = heading;
          // Use post frame callback to avoid build-during-build issues
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_alwaysNorth) {
              _animateToRotation(heading);
            }
          });
        }
      }
    }

    // Handle navigation trigger from log screen
    // Disable auto-follow and navigate to the target location
    if (_isMapReady && appState.mapNavigationTrigger != _lastNavigationTrigger) {
      _lastNavigationTrigger = appState.mapNavigationTrigger;
      final target = appState.mapNavigationTarget;
      if (target != null) {
        // Disable auto-follow when navigating from log
        _autoFollow = false;
        // Navigate to the coordinates with close zoom (18 = street level view)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _animateToPositionWithZoom(LatLng(target.lat, target.lon), 18.0);
          }
        });
      }
    }

    return Stack(
      children: [
        // Map
        _buildMap(appState, center),

        // GPS Info overlay (top-left)
        Positioned(
          top: 8,
          left: 8,
          child: _buildGpsInfoOverlay(appState),
        ),

        // Map controls (top-right) - Apple Maps style
        Positioned(
          top: 8,
          right: 8,
          child: _buildMapControls(appState),
        ),
      ],
    );
  }

  Widget _buildMap(AppStateProvider appState, LatLng center) {
    return Builder(
      builder: (context) => FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: center,
          initialZoom: _defaultZoom,
          minZoom: 3,
          maxZoom: 18,
          onMapReady: () {
            _isMapReady = true;
            // Initial center on GPS if available
            if (appState.currentPosition != null) {
              _mapController.move(center, _defaultZoom);
            }
          },
          // Detect user interaction - disable auto-follow when user drags
          onPositionChanged: (position, hasGesture) {
            if (hasGesture && _autoFollow) {
              setState(() {
                _autoFollow = false;
              });
            }
          },
        ),
        children: [
          // Tile layer (dynamic based on selected style)
          TileLayer(
            urlTemplate: _mapStyle.urlTemplate,
            subdomains: _mapStyle.subdomains ?? const [],
            userAgentPackageName: 'com.meshmapper.app',
            maxZoom: 19,
            retinaMode: RetinaMode.isHighDensity(context), // Enable high-res tiles on retina displays
            tileProvider: SilentCancellableNetworkTileProvider(), // Silently handles tile errors
          ),

          // MeshMapper coverage overlay (only when zone code available and overlay enabled)
          if (appState.zoneCode != null && _showMeshMapperOverlay)
            TileLayer(
              urlTemplate: 'https://${appState.zoneCode!.toLowerCase()}.meshmapper.net/tiles.php?x={x}&y={y}&z={z}',
              userAgentPackageName: 'com.meshmapper.app',
              maxZoom: 19,
              tileProvider: SilentCancellableNetworkTileProvider(),
            ),

          // TX markers (green)
        MarkerLayer(
          markers: _buildTxMarkers(appState.txPings),
        ),
        
        // RX markers (colored by repeater)
        MarkerLayer(
          markers: _buildRxMarkers(appState.rxPings),
        ),

        // DISC markers (purple circles for discovery observations)
        MarkerLayer(
          markers: _buildDiscMarkers(appState.discLogEntries),
        ),

        // Repeater markers (magenta circles with ID)
        MarkerLayer(
          markers: _buildRepeaterMarkers(appState.repeaters),
        ),

        // Current position marker (car icon)
        if (appState.currentPosition != null)
          MarkerLayer(
            markers: [
              Marker(
                point: LatLng(
                  appState.currentPosition!.latitude,
                  appState.currentPosition!.longitude,
                ),
                width: 48,
                height: 48,
                child: _buildCurrentPositionMarker(appState.currentPosition!.heading),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// GPS info overlay (top-left corner)
  Widget _buildGpsInfoOverlay(AppStateProvider appState) {
    final position = appState.currentPosition;
    final hasGps = position != null;
    final distanceFromLastPing = appState.distanceFromLastPing;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // GPS Status
          Icon(
            hasGps ? Icons.gps_fixed : Icons.gps_off,
            size: 14,
            color: hasGps ? _getAccuracyColor(position.accuracy) : Colors.grey,
          ),
          const SizedBox(width: 6),
          Text(
            hasGps ? '${position.accuracy.toStringAsFixed(0)}m' : 'No GPS',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: hasGps ? _getAccuracyColor(position.accuracy) : Colors.grey,
            ),
          ),
          // Distance since last TX ping (like wardrive.js)
          if (hasGps && distanceFromLastPing != null) ...[
            const SizedBox(width: 12),
            const Icon(
              Icons.straighten,
              size: 12,
              color: Colors.white70,
            ),
            const SizedBox(width: 4),
            Text(
              '${distanceFromLastPing.toStringAsFixed(0)}m',
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: Colors.white70,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _getAccuracyColor(double accuracy) {
    if (accuracy <= 10) return Colors.green;
    if (accuracy <= 30) return Colors.orange;
    return Colors.red;
  }

  /// Map controls (top-right corner) - Apple Maps style
  Widget _buildMapControls(AppStateProvider appState) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Map style toggle
          _buildControlButton(
            icon: _mapStyle.icon,
            tooltip: 'Map Style: ${_mapStyle.label}',
            onPressed: _cycleMapStyle,
          ),
          Container(
            height: 1,
            width: 32,
            color: Colors.white24,
          ),
          // Center on position / toggle auto-follow
          _buildControlButton(
            icon: _autoFollow ? Icons.my_location : Icons.location_searching,
            tooltip: _autoFollow ? 'Following GPS' : 'Center on Position',
            onPressed: appState.currentPosition != null ? _centerOnPosition : null,
            isActive: _autoFollow,
          ),
          Container(
            height: 1,
            width: 32,
            color: Colors.white24,
          ),
          // Always North toggle
          _buildControlButton(
            icon: _alwaysNorth ? Icons.navigation : Icons.explore,
            tooltip: _alwaysNorth ? 'Always North (Click to Rotate with Heading)' : 'Rotating with Heading (Click for Always North)',
            onPressed: _toggleNorthMode,
            isActive: !_alwaysNorth,
          ),
          // MeshMapper overlay toggle (only show when zone code available)
          if (appState.zoneCode != null) ...[
            Container(
              height: 1,
              width: 32,
              color: Colors.white24,
            ),
            _buildControlButton(
              icon: Icons.layers,
              tooltip: _showMeshMapperOverlay ? 'Hide Coverage Overlay' : 'Show Coverage Overlay',
              onPressed: _toggleMeshMapperOverlay,
              isActive: _showMeshMapperOverlay,
            ),
          ],
          // Legend button (always visible)
          Container(
            height: 1,
            width: 32,
            color: Colors.white24,
          ),
          _buildControlButton(
            icon: Icons.info_outline,
            tooltip: 'Map Legend',
            onPressed: _showLegendPopup,
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String tooltip,
    VoidCallback? onPressed,
    bool isActive = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            icon,
            size: 22,
            color: onPressed == null
                ? Colors.white38
                : isActive
                    ? Colors.blue
                    : Colors.white,
          ),
        ),
      ),
    );
  }

  void _cycleMapStyle() {
    setState(() {
      final styles = MapStyle.values;
      final currentIndex = styles.indexOf(_mapStyle);
      _mapStyle = styles[(currentIndex + 1) % styles.length];
    });
  }

  void _centerOnPosition() {
    final appState = context.read<AppStateProvider>();
    if (appState.currentPosition != null) {
      final targetPosition = LatLng(
        appState.currentPosition!.latitude,
        appState.currentPosition!.longitude,
      );
      // Re-enable auto-follow and animate to position with zoom
      setState(() {
        _autoFollow = true;
        _lastGpsPosition = targetPosition;
      });
      _animateToPositionWithZoom(targetPosition, 16.0); // Smooth animation with zoom
    }
  }

  void _toggleMeshMapperOverlay() {
    setState(() {
      _showMeshMapperOverlay = !_showMeshMapperOverlay;
    });
  }

  void _toggleNorthMode() {
    final appState = context.read<AppStateProvider>();
    setState(() {
      _alwaysNorth = !_alwaysNorth;

      // If switching to Always North mode, smoothly rotate map back to north
      if (_alwaysNorth && _isMapReady) {
        // Reset heading tracking
        _lastHeading = null;
        // Smoothly rotate back to north (0 degrees)
        final currentRotation = _mapController.camera.rotation;
        if (currentRotation.abs() > 2) {
          // Cancel any running rotation animation
          _rotationAnimationController?.stop();
          _rotationAnimationController?.dispose();

          // Create animation to rotate back to north
          final duration = Duration(milliseconds: 500);
          _rotationAnimationController = AnimationController(
            duration: duration,
            vsync: this,
          );

          _rotationAnimation = CurvedAnimation(
            parent: _rotationAnimationController!,
            curve: Curves.easeInOutCubic,
          );

          _rotationStartAngle = currentRotation;
          _rotationEndAngle = 0.0; // North

          _rotationAnimation!.addListener(() {
            if (!mounted || _rotationStartAngle == null || _rotationEndAngle == null) return;

            final t = _rotationAnimation!.value;
            final rotation = _rotationStartAngle! +
                ((_rotationEndAngle! - _rotationStartAngle!) * t);

            _mapController.rotate(rotation);
          });

          _rotationAnimationController!.forward();
        }
      } else if (!_alwaysNorth && appState.currentPosition != null) {
        // If switching to heading mode, immediately start rotating to current heading
        _lastHeading = null; // Force initial rotation
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_alwaysNorth && appState.currentPosition != null) {
            _animateToRotation(appState.currentPosition!.heading);
          }
        });
      }
    });
  }

  /// Show map legend popup explaining marker colors
  void _showLegendPopup() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blue.withValues(alpha: 0.4)),
                  ),
                  child: const Icon(Icons.map, color: Colors.blue, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Map Legend',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Legend items
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  _buildLegendItem(
                    color: const Color(0xFF7EE094),
                    label: 'BIDIR',
                    description: 'Heard repeats from the mesh AND successfully routed through it',
                  ),
                  Divider(height: 1, color: Colors.grey.shade700),
                  _buildLegendItem(
                    color: const Color(0xFF51D4E9),
                    label: 'DISC',
                    description: 'Wardriving app sent a discovery packet and heard a reply',
                  ),
                  Divider(height: 1, color: Colors.grey.shade700),
                  _buildLegendItem(
                    color: const Color(0xFFFD8928),
                    label: 'TX',
                    description: 'Successfully routed through, but no repeats heard back',
                  ),
                  Divider(height: 1, color: Colors.grey.shade700),
                  _buildLegendItem(
                    color: const Color(0xFF7D54C7),
                    label: 'RX',
                    description: 'Heard mesh traffic but did not transmit',
                  ),
                  Divider(height: 1, color: Colors.grey.shade700),
                  _buildLegendItem(
                    color: const Color(0xFF9E9689),
                    label: 'DEAD',
                    description: 'Repeater heard it, but no other radio received the repeat',
                  ),
                  Divider(height: 1, color: Colors.grey.shade700),
                  _buildLegendItem(
                    color: const Color(0xFFE04F5D),
                    label: 'DROP',
                    description: 'No repeats heard AND no successful route',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build a legend item row with colored circle, label, and description
  Widget _buildLegendItem({
    required Color color,
    required String label,
    required String description,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          // Colored circle indicator
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
          ),
          const SizedBox(width: 12),
          // Label
          SizedBox(
            width: 48,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
                color: Colors.grey.shade200,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Description
          Expanded(
            child: Text(
              description,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade400,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Marker> _buildTxMarkers(List<TxPing> pings) {
    return pings.map((ping) {
      return Marker(
        point: LatLng(ping.latitude, ping.longitude),
        width: 20,
        height: 20,
        child: GestureDetector(
          onTap: () => _showTxPingDetails(ping),
          child: Container(
            decoration: BoxDecoration(
              color: ping.heardRepeaters.isEmpty ? Colors.grey : Colors.green,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                const BoxShadow(
                  color: Colors.black26,
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            // Simple dot - no arrow (looks good at any map rotation)
          ),
        ),
      );
    }).toList();
  }

  List<Marker> _buildRxMarkers(List<RxPing> pings) {
    return pings.map((ping) {
      // Use blue to match the RX chip in status bar
      const color = Colors.blue;

      return Marker(
        point: LatLng(ping.latitude, ping.longitude),
        width: 20,
        height: 20,
        child: GestureDetector(
          onTap: () => _showRxPingDetails(ping),
          child: Container(
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                const BoxShadow(
                  color: Colors.black26,
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            // Simple dot - no arrow (looks good at any map rotation)
          ),
        ),
      );
    }).toList();
  }

  List<Marker> _buildDiscMarkers(List<DiscLogEntry> entries) {
    return entries.map((entry) {
      return Marker(
        point: LatLng(entry.latitude, entry.longitude),
        width: 20,
        height: 20,
        child: GestureDetector(
          onTap: () => _showDiscPingDetails(entry),
          child: Container(
            decoration: BoxDecoration(
              color: entry.nodeCount == 0 ? Colors.grey : _discMarkerColor,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                const BoxShadow(
                  color: Colors.black26,
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
          ),
        ),
      );
    }).toList();
  }

  /// DISC marker color (#7B68EE - medium slate blue/purple)
  static const Color _discMarkerColor = Color(0xFF7B68EE);

  /// Repeater marker color (#a52163 - magenta/pink) - Active
  static const Color _repeaterMarkerColor = Color(0xFFA52163);

  /// Duplicate repeater marker color (#a51d2a - red)
  static const Color _repeaterDuplicateColor = Color(0xFFA51D2A);

  /// New repeater marker color (#c05802 - orange)
  static const Color _repeaterNewColor = Color(0xFFC05802);

  /// Dead repeater marker color (grey)
  static const Color _repeaterDeadColor = Colors.grey;

  /// Get set of duplicate repeater IDs
  Set<String> _getDuplicateRepeaterIds(List<Repeater> repeaters) {
    final idCounts = <String, int>{};
    for (final repeater in repeaters) {
      idCounts[repeater.id] = (idCounts[repeater.id] ?? 0) + 1;
    }
    return idCounts.entries
        .where((e) => e.value > 1)
        .map((e) => e.key)
        .toSet();
  }

  /// Get marker color for a repeater based on status priority:
  /// 1. Duplicate → Red (always takes priority)
  /// 2. Dead → Grey (not heard in 24 hours)
  /// 3. New → Orange (created in past 7 days)
  /// 4. Active → Magenta (default healthy state)
  Color _getRepeaterMarkerColor(Repeater repeater, bool isDuplicate) {
    if (isDuplicate) return _repeaterDuplicateColor;
    if (repeater.isDead) return _repeaterDeadColor;
    if (repeater.isNew) return _repeaterNewColor;
    return _repeaterMarkerColor; // Active (default)
  }

  List<Marker> _buildRepeaterMarkers(List<Repeater> repeaters) {
    final duplicateIds = _getDuplicateRepeaterIds(repeaters);

    return repeaters.map((repeater) {
      final isDuplicate = duplicateIds.contains(repeater.id);
      final markerColor = _getRepeaterMarkerColor(repeater, isDuplicate);

      return Marker(
        point: LatLng(repeater.lat, repeater.lon),
        width: 28,
        height: 28,
        child: GestureDetector(
          onTap: () => _showRepeaterDetails(repeater, isDuplicate: isDuplicate),
          child: Container(
            decoration: BoxDecoration(
              color: markerColor,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                const BoxShadow(
                  color: Colors.black26,
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              repeater.id,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  Widget _buildCurrentPositionMarker(double heading) {
    // Convert heading from degrees to radians
    // heading is 0-360 degrees, 0 = North, 90 = East
    final headingRadians = heading * (math.pi / 180);

    // Clean directional arrow
    return Transform.rotate(
      angle: headingRadians,
      child: CustomPaint(
        size: const Size(24, 24),
        painter: _ArrowPainter(),
      ),
    );
  }

  /// Show TX ping details popup
  void _showTxPingDetails(TxPing ping) {
    // Use the heardRepeaters directly from the TxPing
    final heardRepeaters = ping.heardRepeaters;

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header with icon badge
            Row(
              children: [
                // Icon badge
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.green.withValues(alpha: 0.4)),
                  ),
                  child: const Icon(Icons.arrow_upward, color: Colors.green, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'TX Ping',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        _formatTime(ping.timestamp),
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade400,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Location chip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.location_on, size: 16, color: Colors.grey.shade400),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${ping.latitude.toStringAsFixed(5)}, ${ping.longitude.toStringAsFixed(5)}',
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        color: Colors.grey.shade300,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Repeaters section header
            Text(
              heardRepeaters.isEmpty ? 'No repeaters heard' : 'Heard Repeaters (${heardRepeaters.length})',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Colors.grey.shade400,
                letterSpacing: 0.5,
              ),
            ),

            if (heardRepeaters.isNotEmpty) ...[
              const SizedBox(height: 12),
              // Repeaters table
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    // Header row
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 60,
                            child: Text(
                              'Node',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade400,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              'SNR',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade400,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              'RSSI',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade400,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: Colors.grey.shade700),
                    // Data rows
                    ...heardRepeaters.map((repeater) {
                      // Calculate SNR chip color
                      Color snrColor;
                      if (repeater.snr <= -1) {
                        snrColor = Colors.red;
                      } else if (repeater.snr <= 5) {
                        snrColor = Colors.orange;
                      } else {
                        snrColor = Colors.green;
                      }

                      // Calculate RSSI chip color
                      Color rssiColor;
                      if (repeater.rssi >= -70) {
                        rssiColor = Colors.green;
                      } else if (repeater.rssi >= -100) {
                        rssiColor = Colors.orange;
                      } else {
                        rssiColor = Colors.red;
                      }

                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(
                          children: [
                            // Repeater ID
                            SizedBox(
                              width: 60,
                              child: Text(
                                repeater.repeaterId,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  fontFamily: 'monospace',
                                  color: Colors.grey.shade200,
                                ),
                              ),
                            ),
                            // SNR
                            Expanded(
                              child: Center(
                                child: _buildStatChip(
                                  value: repeater.snr.toStringAsFixed(1),
                                  color: snrColor,
                                ),
                              ),
                            ),
                            // RSSI
                            Expanded(
                              child: Center(
                                child: _buildStatChip(
                                  value: '${repeater.rssi}',
                                  color: rssiColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Show RX ping details popup
  void _showRxPingDetails(RxPing ping) {
    // Calculate SNR severity for chip color
    Color snrColor;
    if (ping.snr <= -1) {
      snrColor = Colors.red;
    } else if (ping.snr <= 5) {
      snrColor = Colors.orange;
    } else {
      snrColor = Colors.green;
    }

    // Calculate RSSI chip color based on signal strength
    Color rssiColor;
    if (ping.rssi >= -70) {
      rssiColor = Colors.green; // Strong: -30 to -70 dBm
    } else if (ping.rssi >= -100) {
      rssiColor = Colors.orange; // Medium: -70 to -100 dBm
    } else {
      rssiColor = Colors.red; // Weak: -100 to -120 dBm
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header with icon badge
            Row(
              children: [
                // Icon badge
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blue.withValues(alpha: 0.4)),
                  ),
                  child: const Icon(Icons.arrow_downward, color: Colors.blue, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'RX Ping',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        _formatTime(ping.timestamp),
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade400,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Location chip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.location_on, size: 16, color: Colors.grey.shade400),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${ping.latitude.toStringAsFixed(5)}, ${ping.longitude.toStringAsFixed(5)}',
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        color: Colors.grey.shade300,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Repeater info section
            Text(
              'Repeater',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Colors.grey.shade400,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 12),

            // Repeater table (single row)
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  // Header row
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 60,
                          child: Text(
                            'Node',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade400,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            'SNR',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade400,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            'RSSI',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade400,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: Colors.grey.shade700),
                  // Data row
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        // Repeater ID
                        SizedBox(
                          width: 60,
                          child: Text(
                            ping.repeaterId,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'monospace',
                              color: Colors.grey.shade200,
                            ),
                          ),
                        ),
                        // SNR
                        Expanded(
                          child: Center(
                            child: _buildStatChip(
                              value: ping.snr.toStringAsFixed(1),
                              color: snrColor,
                            ),
                          ),
                        ),
                        // RSSI
                        Expanded(
                          child: Center(
                            child: _buildStatChip(
                              value: '${ping.rssi}',
                              color: rssiColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Show DISC ping details popup
  void _showDiscPingDetails(DiscLogEntry entry) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header with icon badge
            Row(
              children: [
                // Icon badge
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _discMarkerColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _discMarkerColor.withValues(alpha: 0.4)),
                  ),
                  child: const Icon(Icons.radar, color: _discMarkerColor, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Disc Request',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        _formatTime(entry.timestamp),
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade400,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Location chip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.location_on, size: 16, color: Colors.grey.shade400),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${entry.latitude.toStringAsFixed(5)}, ${entry.longitude.toStringAsFixed(5)}',
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        color: Colors.grey.shade300,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Discovered nodes section header
            Text(
              entry.discoveredNodes.isEmpty
                  ? 'No nodes discovered'
                  : 'Discovered Nodes (${entry.discoveredNodes.length})',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Colors.grey.shade400,
                letterSpacing: 0.5,
              ),
            ),

            if (entry.discoveredNodes.isNotEmpty) ...[
              const SizedBox(height: 12),
              // Table with headers
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    // Header row
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 60,
                            child: Text(
                              'Node',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade400,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              'RX SNR',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade400,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              'RX RSSI',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade400,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              'TX SNR',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade400,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: Colors.grey.shade700),
                    // Data rows
                    ...entry.discoveredNodes.map((node) {
                      // Calculate colors
                      Color rxSnrColor;
                      if (node.localSnr <= -1) {
                        rxSnrColor = Colors.red;
                      } else if (node.localSnr <= 5) {
                        rxSnrColor = Colors.orange;
                      } else {
                        rxSnrColor = Colors.green;
                      }

                      Color rssiColor;
                      if (node.localRssi >= -70) {
                        rssiColor = Colors.green;
                      } else if (node.localRssi >= -100) {
                        rssiColor = Colors.orange;
                      } else {
                        rssiColor = Colors.red;
                      }

                      Color txSnrColor;
                      if (node.remoteSnr <= -1) {
                        txSnrColor = Colors.red;
                      } else if (node.remoteSnr <= 5) {
                        txSnrColor = Colors.orange;
                      } else {
                        txSnrColor = Colors.green;
                      }

                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(
                          children: [
                            // Node ID with type
                            SizedBox(
                              width: 60,
                              child: Row(
                                children: [
                                  Text(
                                    node.repeaterId,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      fontFamily: 'monospace',
                                      color: Colors.grey.shade200,
                                    ),
                                  ),
                                  Text(
                                    node.nodeTypeLabel,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w500,
                                      color: _discMarkerColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // RX SNR
                            Expanded(
                              child: Center(
                                child: _buildStatChip(
                                  value: node.localSnr.toStringAsFixed(1),
                                  color: rxSnrColor,
                                ),
                              ),
                            ),
                            // RSSI
                            Expanded(
                              child: Center(
                                child: _buildStatChip(
                                  value: '${node.localRssi}',
                                  color: rssiColor,
                                ),
                              ),
                            ),
                            // TX SNR
                            Expanded(
                              child: Center(
                                child: _buildStatChip(
                                  value: node.remoteSnr.toStringAsFixed(1),
                                  color: txSnrColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Build a status chip for the repeater popup
  Widget _buildRepeaterStatusChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  /// Show repeater details popup
  void _showRepeaterDetails(Repeater repeater, {bool isDuplicate = false}) {
    // Determine icon badge color based on primary status
    final iconColor = _getRepeaterMarkerColor(repeater, isDuplicate);

    // Determine status label and color
    String statusLabel;
    Color statusColor;
    if (repeater.isNew) {
      statusLabel = 'New';
      statusColor = _repeaterNewColor;
    } else if (repeater.isActive) {
      statusLabel = 'Active';
      statusColor = _repeaterMarkerColor;
    } else {
      statusLabel = 'Stale';
      statusColor = _repeaterDeadColor;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header with icon badge (containing ID) and name
            Row(
              children: [
                // Icon badge with ID (mirrors map marker)
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: iconColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    repeater.id,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    repeater.name,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Status chips row
            Row(
              children: [
                if (isDuplicate) ...[
                  _buildRepeaterStatusChip('Duplicate', _repeaterDuplicateColor),
                  const SizedBox(width: 8),
                ],
                _buildRepeaterStatusChip(statusLabel, statusColor),
              ],
            ),
            const SizedBox(height: 16),

            // Details card
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  // Location row
                  Row(
                    children: [
                      Icon(Icons.location_on, size: 16, color: Colors.grey.shade400),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${repeater.lat.toStringAsFixed(5)}, ${repeater.lon.toStringAsFixed(5)}',
                          style: TextStyle(
                            fontSize: 13,
                            fontFamily: 'monospace',
                            color: Colors.grey.shade300,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Last heard row
                  Row(
                    children: [
                      Icon(Icons.access_time, size: 16, color: Colors.grey.shade400),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          repeater.lastHeardFormatted,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade300,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build a labeled chip with prefix (e.g., "L: 5.2" for Local SNR)
  Widget _buildLabeledChip({
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label.isEmpty ? value : '$label: $value',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  /// Build a status chip matching the status bar theme
  /// Same styling as StatusBar._buildStatChip()
  Widget _buildStatChip({
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        value,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
  }
}

/// Paints a crisp directional arrow pointing up
class _ArrowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // White outline/shadow for visibility
    final outlinePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final outlinePath = ui.Path()
      ..moveTo(center.dx, center.dy - 11) // Top point
      ..lineTo(center.dx + 8, center.dy + 9) // Bottom right
      ..lineTo(center.dx, center.dy + 4) // Bottom center notch
      ..lineTo(center.dx - 8, center.dy + 9) // Bottom left
      ..close();

    canvas.drawPath(outlinePath, outlinePaint);

    // Blue arrow on top
    final arrowPaint = Paint()
      ..color = const Color(0xFF2196F3) // Material blue
      ..style = PaintingStyle.fill;

    final arrowPath = ui.Path()
      ..moveTo(center.dx, center.dy - 9) // Top point
      ..lineTo(center.dx + 6, center.dy + 7) // Bottom right
      ..lineTo(center.dx, center.dy + 3) // Bottom center notch
      ..lineTo(center.dx - 6, center.dy + 7) // Bottom left
      ..close();

    canvas.drawPath(arrowPath, arrowPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
