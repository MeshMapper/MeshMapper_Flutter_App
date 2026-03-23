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
import '../utils/debug_logger_io.dart';
import '../utils/distance_formatter.dart';
import '../utils/ping_colors.dart';
import 'repeater_id_chip.dart';

/// Map style options
enum MapStyle {
  dark,
  light,
  satellite,
}

extension MapStyleExtension on MapStyle {
  /// Convert from stored string preference to MapStyle enum
  static MapStyle fromString(String value) {
    switch (value) {
      case 'light':
        return MapStyle.light;
      case 'satellite':
        return MapStyle.satellite;
      case 'dark':
      default:
        return MapStyle.dark;
    }
  }

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

  /// Whether this style supports retina tiles via {r} placeholder
  bool get supportsRetina {
    switch (this) {
      case MapStyle.dark:
        return true; // Carto supports @2x via {r}
      case MapStyle.light:
        return false; // OSM has no retina support
      case MapStyle.satellite:
        return false; // ArcGIS has no retina support
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

typedef MapState = ({
  bool preferencesLoaded,
  bool mapAutoFollow,
  bool mapAlwaysNorth,
  bool mapRotationLocked,
  String mapStyle,
  bool isImperial,
  dynamic currentPosition,
  ({double lat, double lon})? lastKnownPosition,
  String? zoneCode,
  int overlayCacheBust,
  bool discDropEnabled,
  int? effectiveHopBytes,
  int mapNavigationTrigger,
  ({double lat, double lon})? mapNavigationTarget,
  int mapDataRevision,
  double? distanceFromLastPing,
});

/// Map widget with TX/RX markers
/// Uses flutter_map with OpenStreetMap tiles
class MapWidget extends StatefulWidget {
  /// Bottom padding in pixels to account for overlays (e.g., control panel in portrait)
  /// The map will offset its center point upward by half this value
  final double bottomPaddingPixels;

  /// Right padding in pixels to account for overlays (e.g., side panel in landscape)
  /// The map will offset its center point left by half this value
  final double rightPaddingPixels;

  /// External control for map controls expanded state (landscape mode)
  /// When null, uses internal state
  final bool? mapControlsExpanded;

  /// Callback when map controls toggle is tapped (landscape mode)
  final VoidCallback? onMapControlsToggle;

  const MapWidget({
    super.key,
    this.bottomPaddingPixels = 0,
    this.rightPaddingPixels = 0,
    this.mapControlsExpanded,
    this.onMapControlsToggle,
  });

  @override
  State<MapWidget> createState() => _MapWidgetState();
}

class _MapWidgetState extends State<MapWidget> with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  late final SilentCancellableNetworkTileProvider _baseTileProvider;
  late final SilentCancellableNetworkTileProvider _overlayTileProvider;

  // Auto-follow GPS like a navigation app
  bool _autoFollow = false; // Disabled by default - users often zoom out first
  bool _prefsApplied = false; // Guard to load saved prefs only once
  bool _isMapReady = false;
  LatLng? _lastGpsPosition;
  bool _hasInitialZoomed = false; // Track if we've done the one-time initial zoom to GPS
  bool _hasZoomedToLastKnown = false; // Track if we've zoomed to last known position (before GPS)

  // Map rotation mode
  bool _alwaysNorth = true; // true = north always up, false = rotate with heading
  double? _lastHeading; // Track last heading for smooth rotation

  // MeshMapper overlay toggle (on by default)
  bool _showMeshMapperOverlay = true;

  // Collapsible map controls in landscape
  bool _mapControlsExpanded = true;

  // Rotation lock (disable rotation gestures while keeping pinch-to-zoom)
  bool _rotationLocked = false;

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
  void initState() {
    super.initState();
    _baseTileProvider = SilentCancellableNetworkTileProvider();
    _overlayTileProvider = SilentCancellableNetworkTileProvider();
  }

  @override
  void dispose() {
    _animationController?.dispose();
    _rotationAnimationController?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When padding changes (panel opened/closed/minimized/orientation change), re-center if auto-following
    if ((widget.bottomPaddingPixels != oldWidget.bottomPaddingPixels ||
         widget.rightPaddingPixels != oldWidget.rightPaddingPixels) &&
        _autoFollow &&
        _isMapReady &&
        _lastGpsPosition != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _autoFollow && _lastGpsPosition != null) {
          final adjustedPosition = _offsetPositionForPadding(
            _lastGpsPosition!,
            widget.bottomPaddingPixels,
            widget.rightPaddingPixels,
          );
          _animateToPosition(adjustedPosition);
        }
      });
    }
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
    const duration = Duration(milliseconds: 500); // Smooth zoom + pan

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
    while (targetRotation > 180) {
      targetRotation -= 360;
    }
    while (targetRotation < -180) {
      targetRotation += 360;
    }

    // Calculate shortest rotation path
    double delta = targetRotation - currentRotation;
    while (delta > 180) {
      delta -= 360;
    }
    while (delta < -180) {
      delta += 360;
    }

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

  /// Offset a lat/lon position by screen pixels (to account for UI overlays)
  /// Shifts the map center to keep the GPS marker centered in the visible map area
  /// - bottomPadding: shifts center down (portrait mode with bottom panel)
  /// - rightPadding: shifts center left (landscape mode with side panel)
  LatLng _offsetPositionForPadding(LatLng position, double bottomPadding, [double rightPadding = 0, double? atZoom]) {
    if (!_isMapReady) return position;
    if (bottomPadding <= 0 && rightPadding <= 0) return position;

    // Get meters per pixel at current zoom (or at a specific zoom if provided)
    // Approx: 40075km / (256 * 2^zoom) at equator, adjusted by cos(lat)
    final zoom = atZoom ?? _mapController.camera.zoom;
    final metersPerPixel = 40075000 / (256 * math.pow(2, zoom)) *
        math.cos(position.latitude * math.pi / 180);

    double latOffset = 0;
    double lonOffset = 0;

    // Bottom padding: shift center south (map moves up, marker appears centered)
    if (bottomPadding > 0) {
      final meterOffset = (bottomPadding / 2) * metersPerPixel;
      latOffset = -(meterOffset / 111000); // ~111km per degree latitude
    }

    // Right padding: shift center west (map moves right, marker appears centered)
    if (rightPadding > 0) {
      final meterOffset = (rightPadding / 2) * metersPerPixel;
      // Longitude degrees per meter varies with latitude
      lonOffset = -(meterOffset / (111000 * math.cos(position.latitude * math.pi / 180)));
    }

    // When the map is rotated (heading mode), geographic "south" no longer maps
    // to "screen down". Rotate the offset vector by the camera rotation so the
    // shift always points in the correct screen direction.
    final rotationDeg = _mapController.camera.rotation;
    if (rotationDeg.abs() > 0.1) {
      final rotationRad = -rotationDeg * math.pi / 180;
      final cosR = math.cos(rotationRad);
      final sinR = math.sin(rotationRad);
      final rotatedLat = latOffset * cosR - lonOffset * sinR;
      final rotatedLon = latOffset * sinR + lonOffset * cosR;
      latOffset = rotatedLat;
      lonOffset = rotatedLon;
    }

    return LatLng(position.latitude + latOffset, position.longitude + lonOffset);
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppStateProvider>();
    final mapState = context.select((AppStateProvider state) => (
          preferencesLoaded: state.preferencesLoaded,
          mapAutoFollow: state.preferences.mapAutoFollow,
          mapAlwaysNorth: state.preferences.mapAlwaysNorth,
          mapRotationLocked: state.preferences.mapRotationLocked,
          mapStyle: state.preferences.mapStyle,
          isImperial: state.preferences.isImperial,
          currentPosition: state.currentPosition,
          lastKnownPosition: state.lastKnownPosition,
          zoneCode: state.zoneCode,
          overlayCacheBust: state.overlayCacheBust,
          discDropEnabled: state.discDropEnabled,
          effectiveHopBytes: state.enforceHopBytes ? state.effectiveHopBytes : null,
          mapNavigationTrigger: state.mapNavigationTrigger,
          mapNavigationTarget: state.mapNavigationTarget,
          mapDataRevision: state.mapDataRevision,
          distanceFromLastPing: state.distanceFromLastPing,
        ));
    final overlayState = context.select((AppStateProvider state) => (
          showTopRepeaters: state.preferences.showTopRepeaters,
          topRepeaters: state.topRepeatersBySnr,
          rxOverlaySlot: state.rxOverlaySlot,
        ));

    // Load saved map toggle preferences once, after Hive has finished loading
    if (!_prefsApplied && mapState.preferencesLoaded) {
      _prefsApplied = true;
      _autoFollow = mapState.mapAutoFollow;
      _alwaysNorth = mapState.mapAlwaysNorth;
      _rotationLocked = mapState.mapRotationLocked;
    }

    // Determine map center - prefer current GPS, fallback to last known, then Ottawa
    LatLng center = _defaultCenter;
    if (mapState.currentPosition != null) {
      center = LatLng(
        mapState.currentPosition!.latitude,
        mapState.currentPosition!.longitude,
      );
    } else if (mapState.lastKnownPosition != null) {
      center = LatLng(
        mapState.lastKnownPosition!.lat,
        mapState.lastKnownPosition!.lon,
      );
    }

    // One-time zoom to last known position when GPS is not yet available
    // This runs before GPS locks, so user sees their previous location instead of Ottawa
    if (mapState.currentPosition == null &&
        mapState.lastKnownPosition != null &&
        !_hasZoomedToLastKnown &&
        _isMapReady) {
      _hasZoomedToLastKnown = true;
      final lastKnownCenter = LatLng(
        mapState.lastKnownPosition!.lat,
        mapState.lastKnownPosition!.lon,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _animateToPositionWithZoom(lastKnownCenter, 15.0);
          debugLog('[MAP] Initial zoom to last known position');
        }
      });
    }

    if (mapState.currentPosition != null) {
      // One-time initial zoom to GPS when we first get a position
      // This happens even with auto-follow disabled so user sees their location
      // Don't apply panel offset - center directly on GPS so pin is in middle of screen
      if (!_hasInitialZoomed && _isMapReady) {
        _hasInitialZoomed = true;
        final initialPosition = center;
        _lastGpsPosition = initialPosition;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            if (_autoFollow) {
              // Auto-follow is on and panel may be open — apply panel offset so
              // the marker appears centered in the visible map area.
              final adjustedPosition = _offsetPositionForPadding(initialPosition, widget.bottomPaddingPixels, widget.rightPaddingPixels, 16.0);
              _animateToPositionWithZoom(adjustedPosition, 16.0);
              debugLog('[MAP] Initial zoom to GPS position (with panel offset)');
            } else {
              _animateToPositionWithZoom(initialPosition, 16.0);
              debugLog('[MAP] Initial zoom to GPS position');
            }
          }
        });
      }

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
              // Apply offset for bottom padding when control panel is open
              final adjustedPosition = _offsetPositionForPadding(newPosition, widget.bottomPaddingPixels, widget.rightPaddingPixels);
              _animateToPosition(adjustedPosition); // Smooth animation instead of jump
            }
          });
        }
      }

      // Handle map rotation based on heading (when not in Always North mode)
      if (!_alwaysNorth && _isMapReady) {
        final heading = mapState.currentPosition!.heading;
        if (_lastHeading == null) {
          // First heading after startup — store without rotating so the
          // initial zoom animation can settle at rotation 0 (where the
          // panel offset was computed). Heading mode will begin rotating
          // on the next GPS update when heading changes.
          _lastHeading = heading;
          debugLog('[MAP] First heading after startup (${heading.toStringAsFixed(1)}°) — stored without rotating');
        } else if ((heading - _lastHeading!).abs() > 2) {
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

    // Handle navigation trigger from log screen or graph
    // Reset map state and navigate to the target location
    if (_isMapReady && mapState.mapNavigationTrigger != _lastNavigationTrigger) {
      _lastNavigationTrigger = mapState.mapNavigationTrigger;
      final target = mapState.mapNavigationTarget;
      if (target != null) {
        // Reset map controls to default state
        _autoFollow = false;      // Disable center on GPS
        _alwaysNorth = true;      // Set to north-up mode
        _rotationLocked = false;  // Unlock rotation
        _lastHeading = null;      // Reset heading tracking

        // Navigate to the coordinates with close zoom (18 = street level view)
        // Center directly on target without offset - we want the pin in the middle
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            final targetPosition = LatLng(target.lat, target.lon);

            // Rotate map back to north (0 degrees) first
            final currentRotation = _mapController.camera.rotation;
            if (currentRotation.abs() > 2) {
              _mapController.rotate(0);
            }

            // Animate to the exact target position (no offset)
            _animateToPositionWithZoom(targetPosition, 18.0);
          }
        });
      }
    }

    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    // Get safe area padding for dynamic island/notch in landscape
    final safePadding = MediaQuery.of(context).padding;
    final topPadding = isLandscape ? 16.0 : 8.0;
    final leftPadding = isLandscape ? safePadding.left + 8 : 8.0;

    return Stack(
      children: [
        // Map
        _buildMap(appState, mapState, center),

        // GPS Info + Top Repeaters overlay (top-left, respects dynamic island in landscape)
        Positioned(
          top: topPadding,
          left: leftPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildGpsInfoOverlay(mapState),
              if (overlayState.showTopRepeaters) ...[
                const SizedBox(height: 6),
                _buildTopRepeatersOverlay(overlayState.topRepeaters, overlayState.rxOverlaySlot),
              ],
            ],
          ),
        ),

        // Map controls - top-right in both orientations, collapsible
        Positioned(
          top: topPadding,
          right: 8,
          child: _buildCollapsibleMapControls(appState, mapState.mapStyle, mapState.zoneCode != null),
        ),
      ],
    );
  }

  /// Collapsible map controls (toggle at top, expands downward)
  Widget _buildCollapsibleMapControls(AppStateProvider appState, String mapStyleName, bool hasZoneOverlay) {
    // Use external state if provided, otherwise use internal state
    final isExpanded = widget.mapControlsExpanded ?? _mapControlsExpanded;
    final onToggle = widget.onMapControlsToggle ?? () => setState(() => _mapControlsExpanded = !_mapControlsExpanded);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Toggle button (always visible) - at top
        GestureDetector(
          onTap: onToggle,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.7),
              borderRadius: isExpanded
                  ? const BorderRadius.vertical(top: Radius.circular(8))
                  : BorderRadius.circular(8),
            ),
            child: Icon(
              isExpanded ? Icons.expand_less : Icons.expand_more,
              color: Colors.white,
              size: 22,
            ),
          ),
        ),
        // Map controls (only when expanded) - below the toggle button
        if (isExpanded)
          _buildMapControls(appState, mapStyleName, hasZoneOverlay),
      ],
    );
  }

  Widget _buildMap(AppStateProvider appState, MapState mapState, LatLng center) {
    return Builder(
      builder: (context) => FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: center,
          initialZoom: _defaultZoom,
          minZoom: 3,
          maxZoom: 17,
          interactionOptions: InteractionOptions(
            flags: _rotationLocked
                ? InteractiveFlag.all & ~InteractiveFlag.rotate
                : InteractiveFlag.all,
          ),
          onMapReady: () {
            _isMapReady = true;
            // Initial center on GPS if available
            if (appState.currentPosition != null) {
              _mapController.move(center, _defaultZoom);
            }
          },
        ),
        children: [
          // Tile layer (dynamic based on selected style from preferences)
          Builder(
            builder: (context) {
              final mapStyle = MapStyleExtension.fromString(mapState.mapStyle);
              return TileLayer(
                urlTemplate: mapStyle.urlTemplate,
                subdomains: mapStyle.subdomains ?? const [],
                userAgentPackageName: 'com.meshmapper.app',
                maxZoom: 17,
                retinaMode: mapStyle.supportsRetina && RetinaMode.isHighDensity(context),
                tileProvider: _baseTileProvider,
              );
            },
          ),

          // MeshMapper coverage overlay (only when zone code available and overlay enabled)
          if (mapState.zoneCode != null && _showMeshMapperOverlay)
            TileLayer(
              urlTemplate: 'https://${mapState.zoneCode!.toLowerCase()}.meshmapper.net/tiles.php?x={x}&y={y}&z={z}&t=${mapState.overlayCacheBust}',
              userAgentPackageName: 'com.meshmapper.app',
              minZoom: 3,
              maxZoom: 17,
              tileDisplay: const TileDisplay.fadeIn(
                reloadStartOpacity: 1.0, // Keep old tile visible until new one loads
              ),
              tileProvider: _overlayTileProvider,
            ),

          // Coverage markers (TX, RX, DISC, Trace) — sorted by timestamp, newest on top
          MarkerLayer(
            markers: _buildCoverageMarkers(
              txPings: appState.txPings,
              rxPings: appState.rxPings,
              discEntries: appState.discLogEntries,
              discDropEnabled: appState.discDropEnabled,
              traceEntries: appState.traceLogEntries,
            ),
          ),

          // Repeater markers (magenta with ID, rotate with map)
          MarkerLayer(
            rotate: true,
            markers: _buildRepeaterMarkers(
              appState.repeaters,
              mapState.effectiveHopBytes,
            ),
          ),

          // Current position marker (car icon)
          if (mapState.currentPosition != null)
            MarkerLayer(
              markers: [
                Marker(
                  point: LatLng(
                    mapState.currentPosition.latitude,
                    mapState.currentPosition.longitude,
                  ),
                  width: 48,
                  height: 48,
                  child: _buildCurrentPositionMarker(mapState.currentPosition.heading),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// Color for the overlay ping-type dot
  static Color _overlayTypeColor(OverlayPingType type) {
    return switch (type) {
      OverlayPingType.tx => PingColors.txSuccess,
      OverlayPingType.disc => PingColors.discSuccess,
      OverlayPingType.trace => PingColors.traceSuccess,
      OverlayPingType.rx => PingColors.rx,
    };
  }

  /// Build a single overlay table row with colored dot, repeater ID, and SNR
  TableRow _overlayRow(String repeaterId, double snr, Color dotColor) {
    return TableRow(
      children: [
        TableCell(
          verticalAlignment: TableCellVerticalAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dotColor,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Text(
            repeaterId,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Text(
            snr.toStringAsFixed(1),
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
              color: _snrColor(snr),
            ),
          ),
        ),
      ],
    );
  }

  /// GPS info overlay (top-left corner)
  Widget _buildGpsInfoOverlay(MapState mapState) {
    final position = mapState.currentPosition;
    final distanceFromLastPing = mapState.distanceFromLastPing;

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
            position != null ? Icons.gps_fixed : Icons.gps_off,
            size: 14,
            color: position != null ? _getAccuracyColor(position.accuracy) : Colors.grey,
          ),
          const SizedBox(width: 6),
          Text(
            position != null ? formatMeters(position.accuracy, isImperial: mapState.isImperial) : 'No GPS',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: position != null ? _getAccuracyColor(position.accuracy) : Colors.grey,
            ),
          ),
          // Distance since last TX ping (like wardrive.js)
          if (position != null && distanceFromLastPing != null) ...[
            const SizedBox(width: 12),
            const Icon(
              Icons.straighten,
              size: 12,
              color: Colors.white70,
            ),
            const SizedBox(width: 4),
            Text(
              formatMeters(distanceFromLastPing, isImperial: mapState.isImperial),
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

  /// Top heard repeaters overlay (bottom-right of map)
  Widget _buildTopRepeatersOverlay(
    List<({String repeaterId, double snr, OverlayPingType type})> topRepeaters,
    ({String repeaterId, double snr})? rxSlot,
  ) {
    final isEmpty = topRepeaters.isEmpty && rxSlot == null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Top Heard',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w500,
              color: Colors.white54,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 2),
          if (isEmpty)
            const Text(
              '---',
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: Colors.white38,
              ),
            ),
          if (!isEmpty)
            Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              columnWidths: const {
                0: IntrinsicColumnWidth(), // dot
                1: IntrinsicColumnWidth(), // ID
                2: FixedColumnWidth(8),    // spacer
                3: IntrinsicColumnWidth(), // SNR
              },
              children: [
                for (final r in topRepeaters)
                  _overlayRow(r.repeaterId, r.snr, _overlayTypeColor(r.type)),
                if (rxSlot != null)
                  _overlayRow(rxSlot.repeaterId, rxSlot.snr, _overlayTypeColor(OverlayPingType.rx)),
              ],
            ),
        ],
      ),
    );
  }

  /// SNR color: green > 5, orange -1..5, red <= -1
  static Color _snrColor(double snr) {
    if (snr <= -1) return Colors.red;
    if (snr <= 5) return Colors.orange;
    return Colors.green;
  }

  Color _getAccuracyColor(double accuracy) {
    if (accuracy <= 10) return Colors.green;
    if (accuracy <= 30) return Colors.orange;
    return Colors.red;
  }

  /// Map controls (always vertical, used inside collapsible wrapper)
  Widget _buildMapControls(AppStateProvider appState, String mapStyleName, bool hasZoneOverlay) {
    final mapStyle = MapStyleExtension.fromString(mapStyleName);

    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        // Controls are below the toggle button, so rounded bottom only
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Map style toggle
          _buildControlButton(
            icon: mapStyle.icon,
            tooltip: 'Map Style: ${mapStyle.label}',
            onPressed: () => _cycleMapStyle(appState),
          ),
          // MeshMapper overlay toggle (only show when zone code available)
          if (hasZoneOverlay) ...[
            _buildControlDivider(),
            _buildControlButton(
              icon: Icons.layers,
              tooltip: _showMeshMapperOverlay ? 'Hide Coverage Overlay' : 'Show Coverage Overlay',
              onPressed: _toggleMeshMapperOverlay,
              isActive: _showMeshMapperOverlay,
            ),
          ],
          _buildControlDivider(),
          // Center on position / toggle auto-follow
          _buildControlButton(
            icon: _autoFollow ? Icons.my_location : Icons.location_searching,
            tooltip: _autoFollow ? 'Following GPS' : 'Center on Position',
            onPressed: appState.currentPosition != null ? _centerOnPosition : null,
            isActive: _autoFollow,
          ),
          _buildControlDivider(),
          // Always North toggle
          _buildControlButton(
            icon: _alwaysNorth ? Icons.navigation : Icons.explore,
            tooltip: _alwaysNorth ? 'Always North (Click to Rotate with Heading)' : 'Rotating with Heading (Click for Always North)',
            onPressed: _toggleNorthMode,
            isActive: !_alwaysNorth,
          ),
          _buildControlDivider(),
          // Rotation lock toggle
          _buildControlButton(
            icon: _rotationLocked ? Icons.sync_disabled : Icons.rotate_right,
            tooltip: _rotationLocked ? 'Unlock Rotation' : 'Lock Rotation',
            onPressed: _toggleRotationLock,
            isActive: _rotationLocked,
          ),
          _buildControlDivider(),
          // Legend button
          _buildControlButton(
            icon: Icons.info_outline,
            tooltip: 'Legend & Info',
            onPressed: _showLegendPopup,
          ),
        ],
      ),
    );
  }

  /// Divider between control buttons
  Widget _buildControlDivider() {
    return Container(
      height: 1,
      width: 32,
      color: Colors.white24,
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

  void _cycleMapStyle(AppStateProvider appState) {
    const styles = MapStyle.values;
    final currentStyle = MapStyleExtension.fromString(appState.preferences.mapStyle);
    final currentIndex = styles.indexOf(currentStyle);
    final newStyle = styles[(currentIndex + 1) % styles.length];
    appState.setMapStyle(newStyle.name);
  }

  void _centerOnPosition() {
    final appState = context.read<AppStateProvider>();
    // If already following, toggle off
    if (_autoFollow) {
      setState(() {
        _autoFollow = false;
      });
      appState.setMapAutoFollow(false);
      return;
    }

    // Otherwise, enable auto-follow and center on position at street level
    if (appState.currentPosition != null) {
      final targetPosition = LatLng(
        appState.currentPosition!.latitude,
        appState.currentPosition!.longitude,
      );
      setState(() {
        _autoFollow = true;
        _lastGpsPosition = targetPosition;
      });
      appState.setMapAutoFollow(true);
      // Apply offset for bottom padding when control panel is open
      final adjustedPosition = _offsetPositionForPadding(targetPosition, widget.bottomPaddingPixels, widget.rightPaddingPixels);
      _animateToPositionWithZoom(adjustedPosition, 17.0); // Street level zoom when enabling follow
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
          const duration = Duration(milliseconds: 500);
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
    appState.setMapAlwaysNorth(_alwaysNorth);
  }

  void _toggleRotationLock() {
    final appState = context.read<AppStateProvider>();
    setState(() {
      _rotationLocked = !_rotationLocked;

      // When enabling lock in "Always North" mode, rotate back to north
      // When in "Rotate with Heading" mode, keep current rotation
      if (_rotationLocked && _isMapReady && _alwaysNorth) {
        final currentRotation = _mapController.camera.rotation;
        if (currentRotation.abs() > 2) {
          // Cancel any running rotation animation
          _rotationAnimationController?.stop();
          _rotationAnimationController?.dispose();

          // Create animation to rotate back to north
          const duration = Duration(milliseconds: 500);
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
      }
    });
    appState.setMapRotationLocked(_rotationLocked);
  }

  /// Show map legend popup explaining marker colors and types
  void _showLegendPopup() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.92,
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              child: Row(
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
                      'Legend & Info',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Scrollable content with fade indicator
            Expanded(
              child: Stack(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 140),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Map Markers section
              Text(
                'Map Markers',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                ),
                child: Column(
                  children: [
                    _buildLegendItem(
                      context: context,
                      color: PingColors.txSuccessLegend,
                      label: 'TX',
                      description: 'Location where you sent a ping and heard a repeater',
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                    _buildLegendItem(
                      context: context,
                      color: PingColors.txFail,
                      label: 'TX',
                      description: 'Location where you sent a ping but no repeater was heard',
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                    _buildLegendItem(
                      context: context,
                      color: PingColors.rx,
                      label: 'RX',
                      description: 'Location where you received a message from the mesh',
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                    _buildLegendItem(
                      context: context,
                      color: PingColors.discSuccess,
                      label: 'DISC',
                      description: 'Location where you sent a discovery request and a repeater responded',
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                    _buildLegendItem(
                      context: context,
                      color: PingColors.traceSuccess,
                      label: 'TRC',
                      description: 'Location where a trace reached the repeater',
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2)),
                    _buildLegendItem(
                      context: context,
                      color: PingColors.discFail,
                      label: 'DISC',
                      description: 'Location where you sent a discovery request but no repeater responded',
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2)),
                    _buildLegendItem(
                      context: context,
                      color: PingColors.noResponse,
                      label: 'TRC',
                      description: 'Location where a trace got no response',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Coverage Layer section
              Text(
                'Coverage Layer',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                ),
                child: Column(
                  children: [
                    _buildLayerItem(
                      context: context,
                      color: const Color(0xFF7EE094),
                      label: 'BIDIR',
                      description: 'Heard repeats from the mesh AND successfully routed through it',
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                    _buildLayerItem(
                      context: context,
                      color: const Color(0xFF51D4E9),
                      label: 'DISC',
                      description: 'Wardriving app sent a discovery packet and heard a reply',
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                    _buildLayerItem(
                      context: context,
                      color: const Color(0xFFFD8928),
                      label: 'TX',
                      description: 'Successfully routed through, but no repeats heard back',
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                    _buildLayerItem(
                      context: context,
                      color: const Color(0xFF7D54C7),
                      label: 'RX',
                      description: 'Heard mesh traffic but did not transmit',
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                    _buildLayerItem(
                      context: context,
                      color: const Color(0xFF9E9689),
                      label: 'DEAD',
                      description: 'Repeater heard it, but no other radio received the repeat',
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                    _buildLayerItem(
                      context: context,
                      color: const Color(0xFFE04F5D),
                      label: 'DROP',
                      description: 'No repeats heard AND no successful route',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Sound Notifications section
              Text(
                'Sound Notifications',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                ),
                child: Column(
                  children: [
                    _buildSoundItem(
                      context: context,
                      icon: Icons.cell_tower,
                      label: 'TX Sound',
                      description: 'Plays when sending a ping or discovery request',
                      onPlay: () {
                        final appState = context.read<AppStateProvider>();
                        appState.audioService.playTransmitSound();
                      },
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                    _buildSoundItem(
                      context: context,
                      icon: Icons.hearing,
                      label: 'RX Sound',
                      description: 'Plays when a repeater echo or mesh message is received',
                      onPlay: () {
                        final appState = context.read<AppStateProvider>();
                        appState.audioService.playReceiveSound();
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Map Controls section
              Text(
                'Map Controls',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                ),
                child: Column(
                  children: [
                    _buildHelpItem(
                      context: context,
                      icon: Icons.dark_mode,
                      label: 'Map Style',
                      description: 'Cycle between Dark, Light, and Satellite map styles',
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                    _buildHelpItem(
                      context: context,
                      icon: Icons.layers,
                      label: 'Coverage Overlay',
                      description: 'Toggle MeshMapper coverage overlay showing community-reported mesh coverage',
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                    _buildHelpItem(
                      context: context,
                      icon: Icons.my_location,
                      label: 'Center/Follow',
                      description: 'Center map on GPS position. Tap again to toggle auto-follow mode',
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                    _buildHelpItem(
                      context: context,
                      icon: Icons.navigation,
                      label: 'Always North',
                      description: 'Toggle between always-north orientation or rotate with heading',
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                    _buildHelpItem(
                      context: context,
                      icon: Icons.sync_disabled,
                      label: 'Lock Rotation',
                      description: 'Prevent accidental rotation of the map',
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                    _buildHelpItem(
                      context: context,
                      icon: Icons.info_outline,
                      label: 'Legend & Info',
                      description: 'Show this help popup with legend and control explanations',
                    ),
                  ],
                ),
              ),
                      ],
                    ),
                  ),
                  // Bottom fade gradient to indicate scrollable content
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: Container(
                        height: 120,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0),
                              Theme.of(context).colorScheme.surfaceContainerHighest,
                            ],
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.keyboard_arrow_down,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          size: 20,
                        ),
                      ),
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

  /// Build a sound item row with play button, label, and description
  Widget _buildSoundItem({
    required BuildContext context,
    required IconData icon,
    required String label,
    required String description,
    required VoidCallback onPlay,
  }) {
    return _SoundItemWidget(
      icon: icon,
      label: label,
      description: description,
      onPlay: onPlay,
    );
  }

  /// Build a legend item row with colored circle, label, and description
  Widget _buildLegendItem({
    required BuildContext context,
    required Color color,
    required String label,
    required String description,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
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
              border: Border.all(color: colorScheme.surface, width: 1.5),
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
                color: colorScheme.onSurface,
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
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Build a layer item row with colored square, label, and description
  Widget _buildLayerItem({
    required BuildContext context,
    required Color color,
    required String label,
    required String description,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          // Colored square indicator
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
              border: Border.all(color: colorScheme.surface, width: 1.5),
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
                color: colorScheme.onSurface,
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
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Build a help item row with icon, label, and description for map controls
  Widget _buildHelpItem({
    required BuildContext context,
    required IconData icon,
    required String label,
    required String description,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          // Icon indicator
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: colorScheme.onSurface.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, size: 16, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          // Label
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
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
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Shared decoration for coverage dots — diminished border for readability.
  BoxDecoration _coverageDotDecoration(Color color) => BoxDecoration(
    color: color,
    shape: BoxShape.circle,
    border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 1),
    boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 2, offset: Offset(0, 1))],
  );

  /// Build all coverage dot markers sorted by timestamp (oldest first = drawn underneath).
  /// Newer pings always render on top regardless of type.
  List<Marker> _buildCoverageMarkers({
    required List<TxPing> txPings,
    required List<RxPing> rxPings,
    required List<DiscLogEntry> discEntries,
    required bool discDropEnabled,
    required List<TraceLogEntry> traceEntries,
  }) {
    final timestamped = <(DateTime, Marker)>[
      for (final ping in txPings)
        (ping.timestamp, _buildTxMarker(ping)),
      for (final ping in rxPings)
        (ping.timestamp, _buildRxMarker(ping)),
      for (final entry in discEntries)
        (entry.timestamp, _buildDiscMarker(entry, discDropEnabled)),
      for (final entry in traceEntries)
        (entry.timestamp, _buildTraceMarker(entry)),
    ];

    timestamped.sort((a, b) => a.$1.compareTo(b.$1));
    return timestamped.map((e) => e.$2).toList();
  }

  Marker _buildTxMarker(TxPing ping) {
    return Marker(
      point: LatLng(ping.latitude, ping.longitude),
      width: 20,
      height: 20,
      child: GestureDetector(
        onTap: () => _showTxPingDetails(ping),
        child: Container(
          decoration: _coverageDotDecoration(
            ping.heardRepeaters.isEmpty ? PingColors.txFail : PingColors.txSuccess,
          ),
        ),
      ),
    );
  }

  Marker _buildRxMarker(RxPing ping) {
    return Marker(
      point: LatLng(ping.latitude, ping.longitude),
      width: 20,
      height: 20,
      child: GestureDetector(
        onTap: () => _showRxPingDetails(ping),
        child: Container(
          decoration: _coverageDotDecoration(PingColors.rx),
        ),
      ),
    );
  }

  Marker _buildDiscMarker(DiscLogEntry entry, bool discDropEnabled) {
    return Marker(
      point: LatLng(entry.latitude, entry.longitude),
      width: 20,
      height: 20,
      child: GestureDetector(
        onTap: () => _showDiscPingDetails(entry),
        child: Container(
          decoration: _coverageDotDecoration(
            entry.nodeCount == 0
                ? (discDropEnabled ? Colors.red : Colors.grey)
                : _discMarkerColor,
          ),
        ),
      ),
    );
  }

  Marker _buildTraceMarker(TraceLogEntry entry) {
    return Marker(
      point: LatLng(entry.latitude, entry.longitude),
      width: 20,
      height: 20,
      child: GestureDetector(
        onTap: () => _showTraceDetails(entry),
        child: Container(
          decoration: _coverageDotDecoration(
            entry.success ? Colors.cyan : Colors.grey,
          ),
        ),
      ),
    );
  }

  void _showTraceDetails(TraceLogEntry entry) {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: SingleChildScrollView(
          child: Container(
            padding: EdgeInsets.fromLTRB(20, 24, 20, 32 + MediaQuery.of(context).viewPadding.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header with icon badge
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.cyan.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.cyan.withValues(alpha: 0.4)),
                      ),
                      child: const Icon(Icons.gps_fixed, color: Colors.cyan, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Trace',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            _formatTime(entry.timestamp),
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                    border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.location_on, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${entry.latitude.toStringAsFixed(5)}, ${entry.longitude.toStringAsFixed(5)}',
                          style: TextStyle(
                            fontSize: 13,
                            fontFamily: 'monospace',
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Target repeater section header
                Text(
                  entry.success
                      ? 'Target Repeater'
                      : 'No response from target repeater',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    letterSpacing: 0.5,
                  ),
                ),

                if (entry.success) ...[
                  const SizedBox(height: 12),
                  // Table with headers
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
                    ),
                    child: Column(
                      children: [
                        // Header row
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              SizedBox(
                                width: _nodeColumnWidth(),
                                child: Text(
                                  'Node',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(height: 1, color: Theme.of(context).dividerColor),
                        // Data row
                        Builder(builder: (context) {
                          final localSnr = entry.localSnr ?? 0;
                          final localRssi = entry.localRssi ?? 0;
                          final remoteSnr = entry.remoteSnr ?? 0;

                          Color rxSnrColor;
                          if (localSnr <= -1) {
                            rxSnrColor = Colors.red;
                          } else if (localSnr <= 5) {
                            rxSnrColor = Colors.orange;
                          } else {
                            rxSnrColor = Colors.green;
                          }

                          Color rssiColor;
                          if (localRssi >= -70) {
                            rssiColor = Colors.green;
                          } else if (localRssi >= -100) {
                            rssiColor = Colors.orange;
                          } else {
                            rssiColor = Colors.red;
                          }

                          Color txSnrColor;
                          if (remoteSnr <= -1) {
                            txSnrColor = Colors.red;
                          } else if (remoteSnr <= 5) {
                            txSnrColor = Colors.orange;
                          } else {
                            txSnrColor = Colors.green;
                          }

                          return InkWell(
                            onTap: () => RepeaterIdChip.showRepeaterPopup(context, entry.targetRepeaterId),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              child: Row(
                                children: [
                                  RepeaterIdChip(repeaterId: entry.targetRepeaterId, fontSize: 13, width: _nodeColumnWidth()),
                                  // RX SNR
                                  Expanded(
                                    child: Center(
                                      child: _buildStatChip(
                                        value: localSnr.toStringAsFixed(1),
                                        color: rxSnrColor,
                                      ),
                                    ),
                                  ),
                                  // RX RSSI
                                  Expanded(
                                    child: Center(
                                      child: _buildStatChip(
                                        value: '$localRssi',
                                        color: rssiColor,
                                      ),
                                    ),
                                  ),
                                  // TX SNR
                                  Expanded(
                                    child: Center(
                                      child: _buildStatChip(
                                        value: remoteSnr.toStringAsFixed(1),
                                        color: txSnrColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
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
        ),
      ),
    );
  }

  /// DISC marker color (#51D4E9 - cyan, matches DISC/TRACE web map squares)
  static const Color _discMarkerColor = PingColors.discSuccess;

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

  List<Marker> _buildRepeaterMarkers(List<Repeater> repeaters, int? regionHopBytesOverride) {
    final duplicateIds = _getDuplicateRepeaterIds(repeaters);

    return repeaters.map((repeater) {
      final isDuplicate = duplicateIds.contains(repeater.id);
      final markerColor = _getRepeaterMarkerColor(repeater, isDuplicate);

      // Display hex ID based on per-repeater hop_bytes (or regional admin override)
      final displayId = repeater.displayHexId(overrideHopBytes: regionHopBytesOverride);
      final effectiveBytes = regionHopBytesOverride ?? repeater.hopBytes;
      final isLongId = displayId.length > 2;
      final markerWidth = displayId.length > 4 ? 48.0 : isLongId ? 40.0 : 28.0;

      // Shape varies by hop bytes: 1=square, 2=rounded rect, 3=more rounded
      final borderRadius = effectiveBytes >= 3
          ? BorderRadius.circular(8)
          : effectiveBytes == 2
              ? BorderRadius.circular(6)
              : BorderRadius.circular(4);

      return Marker(
        point: LatLng(repeater.lat, repeater.lon),
        width: markerWidth,
        height: 28,
        child: GestureDetector(
          onTap: () => _showRepeaterDetails(repeater, isDuplicate: isDuplicate, regionHopBytesOverride: regionHopBytesOverride),
          child: Container(
            padding: isLongId
                ? const EdgeInsets.symmetric(horizontal: 4)
                : EdgeInsets.zero,
            decoration: BoxDecoration(
              color: markerColor,
              borderRadius: borderRadius,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              displayId,
              style: TextStyle(
                fontSize: displayId.length > 4 ? 8 : isLongId ? 9 : 10,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                fontFamily: 'monospace',
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

  /// Compute node column width based on hop byte count.
  /// [extraPadding] adds space for additional content (e.g. nodeTypeLabel in DISC popup).
  double _nodeColumnWidth({double extraPadding = 0}) {
    final appState = context.read<AppStateProvider>();
    final hopBytes = appState.enforceHopBytes ? appState.effectiveHopBytes : appState.hopBytes;
    switch (hopBytes) {
      case 2:
        return 70 + extraPadding;
      case 3:
        return 80 + extraPadding;
      default:
        return 60 + extraPadding;
    }
  }

  /// Show TX ping details popup
  void _showTxPingDetails(TxPing ping) {
    // Use the heardRepeaters directly from the TxPing
    final heardRepeaters = ping.heardRepeaters;

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: SingleChildScrollView(
          child: Container(
            padding: EdgeInsets.fromLTRB(20, 24, 20, 32 + MediaQuery.of(context).viewPadding.bottom),
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
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                    border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.location_on, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${ping.latitude.toStringAsFixed(5)}, ${ping.longitude.toStringAsFixed(5)}',
                          style: TextStyle(
                            fontSize: 13,
                            fontFamily: 'monospace',
                            color: Theme.of(context).colorScheme.onSurface,
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
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                      border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
                    ),
                    child: Column(
                      children: [
                        // Header row
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              SizedBox(
                                width: _nodeColumnWidth(),
                                child: Text(
                                  'Node',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(height: 1, color: Theme.of(context).dividerColor),
                        // Data rows
                        ...heardRepeaters.map((repeater) {
                          // Calculate SNR chip color
                          Color snrColor;
                          if (repeater.snr == null) {
                            snrColor = Colors.grey;
                          } else if (repeater.snr! <= -1) {
                            snrColor = Colors.red;
                          } else if (repeater.snr! <= 5) {
                            snrColor = Colors.orange;
                          } else {
                            snrColor = Colors.green;
                          }

                          // Calculate RSSI chip color
                          Color rssiColor;
                          if (repeater.rssi == null) {
                            rssiColor = Colors.grey;
                          } else if (repeater.rssi! >= -70) {
                            rssiColor = Colors.green;
                          } else if (repeater.rssi! >= -100) {
                            rssiColor = Colors.orange;
                          } else {
                            rssiColor = Colors.red;
                          }

                          return InkWell(
                            onTap: () => RepeaterIdChip.showRepeaterPopup(context, repeater.repeaterId),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              child: Row(
                                children: [
                                  // Repeater ID
                                  RepeaterIdChip(repeaterId: repeater.repeaterId, fontSize: 13, width: _nodeColumnWidth()),
                                  // SNR
                                  Expanded(
                                    child: Center(
                                      child: _buildStatChip(
                                        value: repeater.snr?.toStringAsFixed(1) ?? '-',
                                        color: snrColor,
                                      ),
                                    ),
                                  ),
                                  // RSSI
                                  Expanded(
                                    child: Center(
                                      child: _buildStatChip(
                                        value: repeater.rssi != null ? '${repeater.rssi}' : '-',
                                        color: rssiColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
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
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Container(
        padding: EdgeInsets.fromLTRB(20, 24, 20, 32 + MediaQuery.of(context).viewPadding.bottom),
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
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  Icon(Icons.location_on, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${ping.latitude.toStringAsFixed(5)}, ${ping.longitude.toStringAsFixed(5)}',
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        color: Theme.of(context).colorScheme.onSurface,
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
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 12),

            // Repeater table (single row)
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
              ),
              child: Column(
                children: [
                  // Header row
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        SizedBox(
                          width: _nodeColumnWidth(),
                          child: Text(
                            'Node',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: Theme.of(context).dividerColor),
                  // Data row
                  InkWell(
                    onTap: () => RepeaterIdChip.showRepeaterPopup(context, ping.repeaterId),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          // Repeater ID
                          RepeaterIdChip(repeaterId: ping.repeaterId, fontSize: 13, width: _nodeColumnWidth()),
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
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: SingleChildScrollView(
          child: Container(
            padding: EdgeInsets.fromLTRB(20, 24, 20, 32 + MediaQuery.of(context).viewPadding.bottom),
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
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                    border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.location_on, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${entry.latitude.toStringAsFixed(5)}, ${entry.longitude.toStringAsFixed(5)}',
                          style: TextStyle(
                            fontSize: 13,
                            fontFamily: 'monospace',
                            color: Theme.of(context).colorScheme.onSurface,
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
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                      border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
                    ),
                    child: Column(
                      children: [
                        // Header row
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              SizedBox(
                                width: _nodeColumnWidth(extraPadding: 20),
                                child: Text(
                                  'Node',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(height: 1, color: Theme.of(context).dividerColor),
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

                          return InkWell(
                            onTap: () => RepeaterIdChip.showRepeaterPopup(context, node.repeaterId, fullHexId: node.pubkeyHex),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              child: Row(
                                children: [
                                  // Node ID with type
                                  SizedBox(
                                    width: _nodeColumnWidth(extraPadding: 20),
                                    child: Row(
                                      children: [
                                        RepeaterIdChip(repeaterId: node.repeaterId, fontSize: 13),
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
  void _showRepeaterDetails(Repeater repeater, {bool isDuplicate = false, int? regionHopBytesOverride}) {
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
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Container(
        padding: EdgeInsets.fromLTRB(20, 24, 20, 32 + MediaQuery.of(context).viewPadding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header with icon badge (containing ID) and name
            Row(
              children: [
                // Icon badge with hex ID (mirrors map marker)
                Builder(builder: (context) {
                  final displayId = repeater.displayHexId(overrideHopBytes: regionHopBytesOverride);
                  final isLongId = displayId.length > 2;
                  return Container(
                    constraints: const BoxConstraints(minWidth: 44),
                    height: 44,
                    padding: isLongId
                        ? const EdgeInsets.symmetric(horizontal: 8)
                        : EdgeInsets.zero,
                    decoration: BoxDecoration(
                      color: iconColor,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      displayId,
                      style: TextStyle(
                        fontSize: isLongId ? 13 : 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        fontFamily: 'monospace',
                      ),
                    ),
                  );
                }),
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
                border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
              ),
              child: Column(
                children: [
                  // Location row
                  Row(
                    children: [
                      Icon(Icons.location_on, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${repeater.lat.toStringAsFixed(5)}, ${repeater.lon.toStringAsFixed(5)}',
                          style: TextStyle(
                            fontSize: 13,
                            fontFamily: 'monospace',
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Last heard row
                  Row(
                    children: [
                      Icon(Icons.access_time, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          repeater.lastHeardFormatted,
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.onSurface,
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

/// A stateful widget for sound item with play button visual feedback
class _SoundItemWidget extends StatefulWidget {
  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onPlay;

  const _SoundItemWidget({
    required this.icon,
    required this.label,
    required this.description,
    required this.onPlay,
  });

  @override
  State<_SoundItemWidget> createState() => _SoundItemWidgetState();
}

class _SoundItemWidgetState extends State<_SoundItemWidget> {
  bool _isPlaying = false;

  void _handlePlay() {
    setState(() => _isPlaying = true);
    widget.onPlay();
    // Reset after short delay
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _isPlaying = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          // Play button with visual feedback
          GestureDetector(
            onTap: _handlePlay,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: _isPlaying
                    ? Colors.blue.withValues(alpha: 0.5)
                    : Colors.blue.withValues(alpha: 0.2),
                shape: BoxShape.circle,
                border: Border.all(
                  color: _isPlaying ? Colors.blue : Colors.blue.withValues(alpha: 0.5),
                  width: _isPlaying ? 2 : 1,
                ),
              ),
              child: Icon(
                _isPlaying ? Icons.volume_up : Icons.play_arrow,
                size: 18,
                color: Colors.blue,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Icon and label
          Icon(widget.icon, size: 16, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Description
          Expanded(
            child: Text(
              widget.description,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
