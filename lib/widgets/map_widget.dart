import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:provider/provider.dart';

import '../models/log_entry.dart';
import '../models/ping_data.dart';
import '../models/repeater.dart';
import '../providers/app_state_provider.dart';
import '../services/gps_service.dart';
import '../utils/debug_logger_io.dart';
import '../utils/distance_formatter.dart';
import '../utils/ping_colors.dart';
import 'repeater_id_chip.dart';

/// Satellite style as inline MapLibre style JSON (ArcGIS raster source).
/// The `glyphs` URL is required because our native symbol layers
/// (repeater cluster count, individual repeater hex IDs, distance labels)
/// use `textField`, and MapLibre iOS wedges its resource loader with
/// NSURLError -1002 if it tries to resolve glyphs against a style that
/// doesn't declare a glyphs URL.
const _satelliteStyleJson =
    '{"version":8,"glyphs":"https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf","sources":{"satellite":{"type":"raster","tiles":["https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"],"tileSize":256,"maxzoom":17}},"layers":[{"id":"satellite-layer","type":"raster","source":"satellite"}]}';

/// Blank style with dark background — used when mapTilesEnabled is false
/// (saves mobile data while still showing markers and overlays).
/// Includes a `glyphs` URL so native annotations using textField (repeater
/// hex IDs, distance labels) can render their text even when tiles are off.
// const _blankStyleJson =
//     '{"version":8,"glyphs":"https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf","sources":{},"layers":[{"id":"background","type":"background","paint":{"background-color":"#0F172A"}}]}';

/// Default font stack used for all native text labels (textField property).
/// Available in OpenFreeMap glyph sets (Liberty, Bright, Dark, Positron).
const _defaultFontStack = ['Noto Sans Regular'];

/// Image-name constants for the marker bitmaps registered via
/// `controller.addImage()` and referenced by `SymbolOptions.iconImage`.
///
/// Repeater shapes have one bitmap per (status color × hop_byte shape) — 12
/// total. Coverage markers have one bitmap per (ping type × success state) for
/// the user's currently-selected style — 8 total per style preference. GPS
/// marker has one bitmap per style — 6 total.
class _MapImages {
  _MapImages._();

  // Repeater shape bitmaps: status × hop_bytes
  // Names: rep_active_1, rep_dead_2, rep_dup_3, etc.
  static String repeater(String status, int hopBytes) =>
      'rep_${status}_$hopBytes';

  static const repeaterStatuses = ['active', 'dead', 'new', 'dup'];
  static const repeaterHopBytes = [1, 2, 3];

  // Coverage marker bitmaps: type × success state
  // Names: cov_tx_ok, cov_disc_fail, etc.
  static String coverage(String type, bool success) =>
      'cov_${type}_${success ? "ok" : "fail"}';

  static const coverageTypes = ['tx', 'rx', 'disc', 'trace'];

  // GPS marker bitmaps: one per style
  // Names: gps_arrow, gps_car, etc. The list of styles lives in
  // _registerMapImages where we map each style key to its CustomPainter.
  static String gps(String style) => 'gps_$style';
}

/// Renders a [CustomPainter] into a PNG byte buffer using `dart:ui`.
///
/// This is the bridge between our existing Flutter `CustomPainter` marker
/// rendering code and MapLibre's native annotation system. The bytes returned
/// here can be passed to `controller.addImage(name, bytes)` and then referenced
/// by `SymbolOptions.iconImage: name`. The native engine renders the symbol
/// in the same pass as the map tiles, eliminating the Flutter platform-view
/// sync lag that affects widget overlays.
///
/// [size] is the logical size in pixels — the output bitmap is upscaled by
/// [devicePixelRatio] for crispness on high-DPI screens. Default 3.0 covers
/// Renders a distance-label pill: white text on a semi-transparent rounded
/// rectangle background. Returns the PNG bytes and the logical size (width/
/// height in logical pixels, NOT device pixels) so the caller can use it for
/// screen-space collision tests.
///
/// Sized dynamically to the text — the pill grows with longer labels. Uses
/// devicePixelRatio=3.0 to match the other bitmap markers on this map.
Future<({Uint8List bytes, Size size})> _renderDistanceLabelPng(
  String text, {
  double devicePixelRatio = 3.0,
}) async {
  const fontSize = 11.0;
  const horizontalPad = 6.0;
  const verticalPad = 3.0;
  const cornerRadius = 6.0;

  // Measure the text first so we can size the pill to fit.
  final textPainter = TextPainter(
    text: TextSpan(
      text: text,
      style: const TextStyle(
        fontSize: fontSize,
        color: Colors.white,
        fontWeight: FontWeight.w600,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  final logicalWidth = textPainter.width + horizontalPad * 2;
  final logicalHeight = textPainter.height + verticalPad * 2;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(devicePixelRatio);

  // Background pill.
  final bgPaint = Paint()..color = Colors.black.withValues(alpha: 0.72);
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, logicalWidth, logicalHeight),
      const Radius.circular(cornerRadius),
    ),
    bgPaint,
  );

  // Subtle light border for separation from dark map backgrounds.
  final borderPaint = Paint()
    ..color = Colors.white.withValues(alpha: 0.25)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0;
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(0.5, 0.5, logicalWidth - 1, logicalHeight - 1),
      const Radius.circular(cornerRadius),
    ),
    borderPaint,
  );

  textPainter.paint(canvas, const Offset(horizontalPad, verticalPad));

  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (logicalWidth * devicePixelRatio).round(),
    (logicalHeight * devicePixelRatio).round(),
  );
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  if (byteData == null) {
    throw StateError('Failed to encode distance label to PNG bytes');
  }
  return (
    bytes: byteData.buffer.asUint8List(),
    size: Size(logicalWidth, logicalHeight),
  );
}

/// most modern phones (typical DPR is 2.0–3.5).
Future<Uint8List> _renderPainterToPng(
  CustomPainter painter,
  Size size, {
  double devicePixelRatio = 3.0,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // Scale the canvas so the painter still draws at logical size, but the
  // resulting bitmap has more actual pixels.
  canvas.scale(devicePixelRatio);
  painter.paint(canvas, size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (size.width * devicePixelRatio).round(),
    (size.height * devicePixelRatio).round(),
  );
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  if (byteData == null) {
    throw StateError('Failed to encode CustomPainter to PNG bytes');
  }
  return byteData.buffer.asUint8List();
}

/// Map style options.
///
/// Declaration order matters: it determines the cycle order when the user
/// taps the "switch style" button (see `_cycleMapStyle`). Liberty is first
/// because it's the default for new users.
enum MapStyle {
  liberty,
  dark,
  light,
  satellite,
}

extension MapStyleExtension on MapStyle {
  /// Convert from stored string preference to MapStyle enum.
  /// Defaults to Liberty for unknown / unset preferences.
  static MapStyle fromString(String value) {
    switch (value) {
      case 'dark':
        return MapStyle.dark;
      case 'light':
        return MapStyle.light;
      case 'satellite':
        return MapStyle.satellite;
      case 'liberty':
      default:
        return MapStyle.liberty;
    }
  }

  String get label {
    switch (this) {
      case MapStyle.dark:
        return 'Dark';
      case MapStyle.light:
        return 'Light';
      case MapStyle.liberty:
        return 'Liberty';
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
      case MapStyle.liberty:
        return Icons.map;
      case MapStyle.satellite:
        return Icons.satellite_alt;
    }
  }

  /// MapLibre style URL (or inline JSON for satellite)
  String get styleUrl {
    switch (this) {
      case MapStyle.dark:
        return 'https://tiles.openfreemap.org/styles/dark';
      case MapStyle.light:
        return 'https://tiles.openfreemap.org/styles/bright';
      case MapStyle.liberty:
        return 'https://tiles.openfreemap.org/styles/liberty';
      case MapStyle.satellite:
        return _satelliteStyleJson;
    }
  }
}

/// Resolved repeater with SNR and ambiguity info for ping focus mode.
/// Line color is based on [snr] (green/yellow/red). When a short hex ID
/// matches multiple repeaters, [ambiguous] is true and the line gets a
/// distinct border to indicate uncertainty.
class _ResolvedRepeater {
  final Repeater repeater;
  final double? snr;
  final bool ambiguous;
  const _ResolvedRepeater(this.repeater, this.snr, this.ambiguous);
}

/// Map widget with TX/RX markers
/// Uses MapLibre GL with OpenFreeMap vector tiles
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

class _MapWidgetState extends State<MapWidget> {
  MapLibreMapController? _mapController;

  // Auto-follow GPS like a navigation app
  bool _autoFollow = false; // Disabled by default - users often zoom out first
  bool _prefsApplied = false; // Guard to load saved prefs only once
  bool _isMapReady = false;
  LatLng? _lastGpsPosition;
  bool _hasInitialZoomed =
      false; // Track if we've done the one-time initial zoom to GPS
  bool _hasZoomedToLastKnown =
      false; // Track if we've zoomed to last known position (before GPS)

  // Map rotation mode
  bool _alwaysNorth =
      true; // true = north always up, false = rotate with heading
  double? _lastHeading; // Track last heading for smooth rotation

  // Desired camera zoom while auto-follow is active. Set when the user taps
  // "center on position" and updated when the user pinch-zooms. Each auto-
  // follow GPS tick uses this as the animation target zoom — otherwise a tick
  // that arrives during the initial zoom animation cancels it (animateCamera
  // replaces in-flight animations), leaving the camera stuck at an
  // intermediate zoom and the marker off-center.
  double? _autoFollowDesiredZoom;

  // Bearing derivation state. geolocator's Position.heading is only reliable
  // at speed — on both Android (Location.getBearing() requires hasBearing()
  // and speed > 0) and iOS (CLLocation.course == -1 when invalid) it's
  // effectively 0 or -1 when stationary or walking slowly. We keep our own
  // anchor-to-current bearing as a fallback so the arrow/walk marker and
  // heading-mode map rotation behave correctly at low speeds.
  LatLng? _bearingAnchor; // last fix used as the bearing origin
  double? _computedHeading; // last known-good bearing in degrees 0..360

  // MeshMapper overlay toggle (on by default)
  bool _showMeshMapperOverlay = true;

  // Collapsible map controls in landscape
  bool _mapControlsExpanded = true;

  // Rotation lock (disable rotation gestures while keeping pinch-to-zoom)
  bool _rotationLocked = false;

  // Map navigation trigger tracking (from log screen)
  int _lastNavigationTrigger = 0;

  // Ping focus mode — highlight connected repeaters when a marker is tapped
  LatLng? _focusedPingLocation;
  DateTime? _focusedPingTimestamp;
  List<_ResolvedRepeater> _focusedRepeaters = [];
  LatLng? _preFocusCenter;
  double? _preFocusZoom;
  bool _wasAutoFollowBeforeFocus = false;
  bool _wasRotatingBeforeFocus = false; // true if heading mode was active

  // MapLibre style and overlay tracking
  int _lastCacheBust = 0;
  // Tracks the zone code we last rendered the coverage overlay for. When the
  // zone check succeeds after the style has already loaded (e.g. first check
  // failed with gps_inaccurate and a later retry succeeded), _addCoverageOverlay
  // would otherwise never re-run and the raster layer would stay missing.
  String? _lastOverlayZoneCode;
  // Last coverage overlay opacity we pushed into MapLibre. Compared against
  // the current preference in _buildMap to detect slider changes and apply
  // them live via _applyCoverageOverlayOpacity (no layer rebuild needed).
  double? _lastAppliedCoverageOpacity;
  // Guard flag that coalesces multiple overlay-refresh triggers (cache bust
  // and zone change) in the same frame into a single post-frame callback.
  // Without this, two watchers can schedule concurrent _refreshCoverageOverlay
  // runs whose remove/add calls interleave and produce "Source already exists"
  // errors in the native log.
  bool _coverageRefreshScheduled = false;
  bool _styleLoaded = false;
  bool _hasStyleLoadedOnce =
      false; // True after first onStyleLoadedCallback (prevents re-centering on style switch)

  // Tracks the last marker data version we synced to native annotations.
  // The build() method computes a version hash from app state and only triggers
  // _syncAllAnnotations when the hash changes (avoiding unnecessary diff work).
  int _lastMarkerDataVersion = -1;
  // Serializes concurrent _syncAllAnnotations runs. Without this, a second
  // build() can fire a sync while the previous one is still awaiting platform
  // calls — both would mutate _coverageSymbols / _distanceLabelSymbols, and
  // the older sync's cleanup loop would remove symbols the newer sync just
  // added. The flag causes re-entrant post-frame callbacks to bail; after the
  // in-flight sync finishes, the finally block checks if the data version
  // advanced during the run and triggers a rebuild if so.
  bool _syncInFlight = false;

  // Tile load failure detection — shows a banner if map tiles haven't loaded
  // within a timeout after style load. Cleared when onMapIdle fires.
  bool _tileLoadFailed = false;

  /// Tracks the last-applied mapTilesEnabled value so we can detect changes
  /// in _buildMap and call setOffline() without a full style reload.
  bool? _lastMapTilesEnabled;
  Timer? _tileLoadTimeoutTimer;
  static const _tileLoadTimeoutSeconds = 8;

  // Re-entrance guard for _onStyleLoaded. The iOS plugin can fire
  // onStyleLoadedCallback multiple times during a single style switch,
  // which causes the sync logic to race against itself. This flag bails
  // any nested call.
  bool _styleLoadInProgress = false;

  // True only after _setupRepeaterClusterLayers has finished creating the
  // cluster GeoJSON source AND all 3 layers. Set to false at the start of
  // each style load. Used as an additional guard for build()-triggered post-
  // frame syncs so they don't race ahead of source creation and try to call
  // setGeoJsonSource on a source that doesn't exist yet (which produces the
  // "Failed to update repeater source: sourceNotFound" error at startup).
  bool _clusterLayersReady = false;

  // Native annotation tracking — populated by sync methods.
  // Maps from app-state IDs to MapLibre Symbol/Line objects so we can diff
  // (add new, update existing, remove deleted) on each data version change.
  // NOTE: repeaters do NOT use the annotation manager — they live in a custom
  // cluster-enabled GeoJSON source so MapLibre can group nearby markers into
  // count bubbles at low zoom. See _setupRepeaterClusterLayers().
  final Map<String, Symbol> _coverageSymbols = {}; // key: "{type}_{ts.ms}"
  final Map<String, Symbol> _distanceLabelSymbols =
      {}; // key: focused repeater id
  // Per focused-repeater metadata used by the collision-avoidance reflow:
  // the image size (for hit-box overlap tests) and the repeater lat/lon (so
  // we can slide the label along the ping→repeater line at a new parameter t).
  final Map<String, Size> _distanceLabelImageSize = {};
  final Map<String, LatLng> _distanceLabelRepeaterPos = {};
  // Tracks distance-label image names we've registered via addImage, so the
  // style-reload path can drop stale names from the map's image cache if ever
  // needed. Right now we just re-addImage on each sync (idempotent).
  final Set<String> _registeredDistanceLabelImages = {};
  Symbol? _gpsSymbol; // single GPS marker

  // Repeater cluster source/layer IDs (custom GeoJSON layer with cluster: true)
  static const _repeaterSourceId = 'repeaters-source';
  static const _repeaterIndividualLayerId = 'repeaters-individual';
  static const _repeaterClusterBubbleLayerId = 'repeaters-cluster-bubble';
  static const _repeaterClusterCountLayerId = 'repeaters-cluster-count';

  // Tracks which marker style preference the coverage images are currently
  // registered for. When the user changes their preference, we re-register.
  String? _registeredCoverageStyle;

  // True after _registerMapImages() finishes — gates symbol creation.
  bool _imagesRegistered = false;

  // Last bearing seen by camera listener (for non-rotating GPS counter-rotation)
  double _lastBearing = 0;

  // Default center (Ottawa)
  static const LatLng _defaultCenter = LatLng(45.4215, -75.6972);
  static const double _defaultZoom = 15.0; // Closer zoom for driving

  @override
  void dispose() {
    _tileLoadTimeoutTimer?.cancel();
    final controller = _mapController;
    if (controller != null) {
      controller.removeListener(_onCameraChanged);
      // Symbol/feature tap listeners are registered in _onMapCreated onto
      // separate callback collections that ChangeNotifier.dispose() does NOT
      // clear. Remove them explicitly so an in-flight tap that gets queued
      // before the platform channel is torn down can't reach into a disposed
      // State. try/catch swallows the edge case where _onMapCreated never ran.
      try {
        controller.onSymbolTapped.remove(_handleSymbolTap);
      } catch (_) {}
      try {
        controller.onFeatureTapped.remove(_handleFeatureTap);
      } catch (_) {}
    }
    super.dispose();
  }

  /// Camera change listener — fires every frame during pan/zoom (because
  /// trackCameraPosition: true is set on MapLibreMap). With native annotations,
  /// the markers themselves don't need a per-frame rebuild — they're rendered
  /// by the native map engine and stay in sync automatically. The only thing
  /// we still need to do here is update the GPS marker's iconRotate when the
  /// camera bearing changes, because for rotating styles (arrow/walk/chomper)
  /// iconRotate = heading - bearing and the bearing animates continuously in
  /// heading mode. Throttled by a small bearing delta to avoid spamming
  /// updateSymbol.
  void _onCameraChanged() {
    if (!mounted || _mapController == null) return;
    final pos = _mapController!.cameraPosition;
    if (pos == null) return;
    if ((pos.bearing - _lastBearing).abs() < 0.5) return;
    _lastBearing = pos.bearing;
    _updateGpsSymbolRotation();
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
          final double targetBearing =
              (!_alwaysNorth && _computedHeading != null)
                  ? _computedHeading!
                  : 0.0;
          final double targetZoom = _autoFollowDesiredZoom ??
              _mapController?.cameraPosition?.zoom ??
              _defaultZoom;
          final adjustedPosition = _offsetPositionForPadding(
            _lastGpsPosition!,
            widget.bottomPaddingPixels,
            widget.rightPaddingPixels,
            targetZoom,
            targetBearing,
          );
          _animateAutoFollowCamera(
            target: adjustedPosition,
            zoom: targetZoom,
            bearing: targetBearing,
          );
        }
      });
    }
  }

  /// Smoothly animate the map to a new position with zoom
  void _animateToPositionWithZoom(LatLng target, double targetZoom) {
    if (_mapController == null || !_isMapReady || !mounted) return;
    _mapController!.animateCamera(
      CameraUpdate.newLatLngZoom(target, targetZoom),
      duration: const Duration(milliseconds: 500),
    );
  }

  /// Atomic auto-follow camera update: animates target, zoom, and bearing
  /// together in a single animateCamera call.
  ///
  /// Using separate animateCamera calls for position and rotation races —
  /// the second call cancels the first, so each GPS tick in heading mode
  /// lost either the pan or the rotation. Bundling everything into one
  /// newCameraPosition update avoids the race entirely and also keeps the
  /// initial zoom animation from being cancelled by the first auto-follow
  /// tick.
  void _animateAutoFollowCamera({
    required LatLng target,
    required double zoom,
    required double bearing,
    int durationMs = 300,
  }) {
    if (_mapController == null || !_isMapReady || !mounted) return;
    _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(
        target: target,
        zoom: zoom,
        bearing: bearing,
      )),
      duration: Duration(milliseconds: durationMs),
    );
  }

  /// Zoom to fit a focused ping and its connected repeaters on screen
  void _zoomToFocusBounds(
      LatLng pingLocation, List<_ResolvedRepeater> repeaters) {
    if (_mapController == null || !_isMapReady || !mounted) return;

    final points = [
      pingLocation,
      ...repeaters.map((r) => LatLng(r.repeater.lat, r.repeater.lon))
    ];
    if (points.length < 2) return;

    // Build bounding box from all points
    double minLat = points[0].latitude, maxLat = points[0].latitude;
    double minLon = points[0].longitude, maxLon = points[0].longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLon),
      northeast: LatLng(maxLat, maxLon),
    );

    final bottomPad = MediaQuery.of(context).size.height * 0.4;
    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(bounds,
          left: 60, top: 60, right: 60, bottom: bottomPad),
      duration: const Duration(milliseconds: 500),
    );
  }

  /// Smoothly animate the map rotation to match heading
  /// MapLibre bearing is clockwise from north (same as GPS heading)
  void _animateToRotation(double targetHeading) {
    if (_mapController == null || !_isMapReady || !mounted || _alwaysNorth) {
      return;
    }

    final currentBearing = _mapController!.cameraPosition?.bearing ?? 0;

    // Calculate shortest rotation path
    double delta = targetHeading - currentBearing;
    while (delta > 180) {
      delta -= 360;
    }
    while (delta < -180) {
      delta += 360;
    }

    // Skip if rotation change is very small (less than 2 degrees)
    if (delta.abs() < 2) return;

    _mapController!.animateCamera(
      CameraUpdate.bearingTo(targetHeading),
      duration: Duration(milliseconds: delta.abs() < 45 ? 300 : 500),
    );
  }

  /// Produce a reliable heading in degrees (0..360) from successive GPS fixes.
  ///
  /// Prefers `Position.heading` when the device is moving fast enough for the
  /// hardware bearing to be trustworthy; otherwise derives the bearing from
  /// the delta between the last anchor fix and the current one. Returns the
  /// last known-good value (possibly null) when we don't have enough motion
  /// yet. This exists because geolocator reports heading=0 (Android) or
  /// -1 (iOS) at rest and during slow/stop-and-go movement, which would
  /// otherwise leave the arrow/walk marker stuck pointing north.
  double? _computeHeading(Position p) {
    final here = LatLng(p.latitude, p.longitude);

    // Fast path: trust the GPS chip when it's actually moving.
    // geolocator reports speed in m/s. 1 m/s ≈ 3.6 km/h — slower than that,
    // the hardware bearing is either stale or not computed.
    final gpsHeading = p.heading;
    if (p.speed >= 1.0 && gpsHeading >= 0 && gpsHeading <= 360) {
      _bearingAnchor = here;
      _computedHeading = gpsHeading;
      return _computedHeading;
    }

    // Slow/stationary path: compute our own bearing once we have enough travel.
    if (_bearingAnchor == null) {
      _bearingAnchor = here;
    } else {
      final moved = Geolocator.distanceBetween(
        _bearingAnchor!.latitude,
        _bearingAnchor!.longitude,
        here.latitude,
        here.longitude,
      );
      if (moved >= 5.0) {
        final bearing = Geolocator.bearingBetween(
          _bearingAnchor!.latitude,
          _bearingAnchor!.longitude,
          here.latitude,
          here.longitude,
        );
        // bearingBetween returns -180..180; normalize to 0..360.
        _computedHeading = (bearing + 360) % 360;
        _bearingAnchor = here;
      }
    }

    return _computedHeading; // may be null until first meaningful motion
  }

  /// Offset a lat/lon position by screen pixels (to account for UI overlays).
  /// Shifts the camera target so the GPS marker sits in the visible (unpadded)
  /// part of the map:
  /// - bottomPadding > 0: camera shifts "screen-down" so marker appears toward
  ///   the top half (portrait with bottom panel open).
  /// - rightPadding > 0: camera shifts "screen-right" so marker appears toward
  ///   the left half (landscape with side panel open on the right).
  ///
  /// [atZoom] and [atBearing] override the current camera values. Callers that
  /// are *about* to animate the camera to a new zoom/bearing must pass the
  /// target values — otherwise the offset gets computed at an interpolated
  /// mid-animation value and the marker settles off-center.
  LatLng _offsetPositionForPadding(
    LatLng position,
    double bottomPadding, [
    double rightPadding = 0,
    double? atZoom,
    double? atBearing,
  ]) {
    if (_mapController == null || !_isMapReady) return position;
    if (bottomPadding <= 0 && rightPadding <= 0) return position;

    // Get meters per pixel at the target zoom (or current camera zoom).
    // Approx: 40075km / (256 * 2^zoom) at equator, adjusted by cos(lat)
    final zoom = atZoom ?? _mapController!.cameraPosition?.zoom ?? _defaultZoom;
    final metersPerPixel = 40075000 /
        (256 * math.pow(2, zoom)) *
        math.cos(position.latitude * math.pi / 180);

    // Start with the offset expressed as if the map were north-up
    // (bearing = 0): bottom padding shifts the target geographic-south,
    // right padding shifts the target geographic-west.
    double latOffset = 0;
    double lonOffset = 0;
    if (bottomPadding > 0) {
      final meterOffset = (bottomPadding / 2) * metersPerPixel;
      latOffset = -(meterOffset / 111000); // ~111km per degree latitude
    }
    if (rightPadding > 0) {
      final meterOffset = (rightPadding / 2) * metersPerPixel;
      lonOffset = -(meterOffset /
          (111000 * math.cos(position.latitude * math.pi / 180)));
    }

    // When the map is rotated, "screen-down" no longer points geographic
    // south — it points wherever bearing + 180° aims. Rotate the offset
    // vector so the shift still lands in the correct screen direction.
    //
    // MapLibre bearing is clockwise from north (heading east => bearing 90,
    // screen-down => world-west). To send a south-pointing input vector to
    // the world direction that corresponds to screen-down at the given
    // bearing, we rotate it clockwise by `bearing` — i.e. by +bearing, not
    // -bearing as the previous implementation did.
    final bearingDeg =
        atBearing ?? _mapController!.cameraPosition?.bearing ?? 0;
    if (bearingDeg.abs() > 0.1) {
      final rotationRad = bearingDeg * math.pi / 180;
      final cosR = math.cos(rotationRad);
      final sinR = math.sin(rotationRad);
      final rotatedLat = latOffset * cosR - lonOffset * sinR;
      final rotatedLon = latOffset * sinR + lonOffset * cosR;
      latOffset = rotatedLat;
      lonOffset = rotatedLon;
    }

    return LatLng(
        position.latitude + latOffset, position.longitude + lonOffset);
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();

    // Load saved map toggle preferences once, after Hive has finished loading
    if (!_prefsApplied && appState.preferencesLoaded) {
      _prefsApplied = true;
      _autoFollow = appState.preferences.mapAutoFollow;
      _alwaysNorth = appState.preferences.mapAlwaysNorth;
      _rotationLocked = appState.preferences.mapRotationLocked;
    }

    // Determine map center - prefer current GPS, fallback to last known, then Ottawa
    LatLng center = _defaultCenter;
    if (appState.currentPosition != null) {
      center = LatLng(
        appState.currentPosition!.latitude,
        appState.currentPosition!.longitude,
      );
    } else if (appState.lastKnownPosition != null) {
      center = LatLng(
        appState.lastKnownPosition!.lat,
        appState.lastKnownPosition!.lon,
      );
    }

    // One-time zoom to last known position when GPS is not yet available
    // This runs before GPS locks, so user sees their previous location instead of Ottawa
    if (appState.currentPosition == null &&
        appState.lastKnownPosition != null &&
        !_hasZoomedToLastKnown &&
        _isMapReady) {
      _hasZoomedToLastKnown = true;
      final lastKnownCenter = LatLng(
        appState.lastKnownPosition!.lat,
        appState.lastKnownPosition!.lon,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _animateToPositionWithZoom(lastKnownCenter, 15.0);
          debugLog('[MAP] Initial zoom to last known position');
        }
      });
    }

    if (appState.currentPosition != null) {
      // Recompute our derived heading for this frame. _computedHeading is
      // updated as a side effect; use it below instead of reading
      // currentPosition.heading directly (which is unreliable at low speeds).
      _computeHeading(appState.currentPosition!);

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
              final adjustedPosition = _offsetPositionForPadding(
                  initialPosition,
                  widget.bottomPaddingPixels,
                  widget.rightPaddingPixels,
                  16.0);
              _animateToPositionWithZoom(adjustedPosition, 16.0);
              debugLog(
                  '[MAP] Initial zoom to GPS position (with panel offset)');
            } else {
              _animateToPositionWithZoom(initialPosition, 16.0);
              debugLog('[MAP] Initial zoom to GPS position');
            }
          }
        });
      }

      // Auto-follow GPS position when enabled. When auto-follow is on we
      // bundle pan, zoom, and bearing into a single animateCamera call so
      // the three don't race each other. _autoFollowDesiredZoom is the
      // zoom the camera is animating toward — using it instead of the
      // (potentially interpolated) current zoom prevents drift during the
      // initial zoom animation after tapping center-on-position.
      if (_autoFollow && _isMapReady) {
        final newPosition = center;
        if (_lastGpsPosition == null ||
            _lastGpsPosition!.latitude != newPosition.latitude ||
            _lastGpsPosition!.longitude != newPosition.longitude) {
          _lastGpsPosition = newPosition;
          final double targetBearing =
              (!_alwaysNorth && _computedHeading != null)
                  ? _computedHeading!
                  : 0.0;
          final double targetZoom = _autoFollowDesiredZoom ??
              _mapController?.cameraPosition?.zoom ??
              _defaultZoom;
          // Track _lastHeading here too so the separate rotation block
          // below (which runs when auto-follow is off) doesn't fire a
          // redundant rotation animation on the next frame.
          if (!_alwaysNorth && _computedHeading != null) {
            _lastHeading = _computedHeading;
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _autoFollow) {
              final adjustedPosition = _offsetPositionForPadding(
                newPosition,
                widget.bottomPaddingPixels,
                widget.rightPaddingPixels,
                targetZoom,
                targetBearing,
              );
              _animateAutoFollowCamera(
                target: adjustedPosition,
                zoom: targetZoom,
                bearing: targetBearing,
              );
            }
          });
        }
      }

      // Handle map rotation based on heading when NOT auto-following.
      // When auto-follow is on, rotation is bundled into the combined
      // camera update above so we don't race two animateCamera calls.
      if (!_autoFollow &&
          !_alwaysNorth &&
          _isMapReady &&
          _computedHeading != null) {
        final heading = _computedHeading!;
        if (_lastHeading == null) {
          // First heading after startup — store without rotating so the
          // initial zoom animation can settle at rotation 0 (where the
          // panel offset was computed). Heading mode will begin rotating
          // on the next GPS update when heading changes.
          _lastHeading = heading;
          debugLog(
              '[MAP] First heading after startup (${heading.toStringAsFixed(1)}°) — stored without rotating');
        } else if ((heading - _lastHeading!).abs() > 2) {
          _lastHeading = heading;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_alwaysNorth && !_autoFollow) {
              _animateToRotation(heading);
            }
          });
        }
      }
    } else {
      // GPS lock lost — clear bearing state so reacquisition starts fresh
      // instead of snapping the marker/map to a stale direction.
      _bearingAnchor = null;
      _computedHeading = null;
    }

    // Handle navigation trigger from log screen or graph
    // Reset map state and navigate to the target location
    if (_isMapReady &&
        appState.mapNavigationTrigger != _lastNavigationTrigger) {
      _lastNavigationTrigger = appState.mapNavigationTrigger;
      final target = appState.mapNavigationTarget;
      if (target != null) {
        // Reset map controls to default state
        _autoFollow = false; // Disable center on GPS
        _autoFollowDesiredZoom = null;
        _alwaysNorth = true; // Set to north-up mode
        _rotationLocked = false; // Unlock rotation
        _lastHeading = null; // Reset heading tracking
        _bearingAnchor = null; // Reset derived-heading anchor
        _computedHeading = null;

        // Navigate to the coordinates with close zoom (18 = street level view)
        // Center directly on target without offset - we want the pin in the middle
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _mapController != null) {
            final targetPosition = LatLng(target.lat, target.lon);

            // Rotate map back to north (0 degrees) first
            final currentBearing = _mapController!.cameraPosition?.bearing ?? 0;
            if (currentBearing.abs() > 2) {
              _mapController!.animateCamera(CameraUpdate.bearingTo(0));
            }

            // Animate to the exact target position (no offset)
            _animateToPositionWithZoom(targetPosition, 18.0);
          }
        });
      }
    }

    // Sync native annotations whenever marker data changes (provider triggers
    // a rebuild). The version hash detects changes to ping/repeater counts,
    // GPS position, focus state, prefs, etc. Native annotations stay in sync
    // with the camera automatically — we only need to push data updates.
    //
    // _clusterLayersReady is the critical guard here: it ensures the cluster
    // GeoJSON source actually exists before any sync attempts to push data
    // into it. Without this, a Provider data update arriving in the brief
    // window between _registerMapImages and _setupRepeaterClusterLayers
    // (inside _onStyleLoaded) would race ahead and call setGeoJsonSource on
    // a not-yet-created source, throwing "sourceNotFound".
    if (_isMapReady &&
        _styleLoaded &&
        _imagesRegistered &&
        _clusterLayersReady) {
      final dataVersion = _computeMarkerDataVersion(appState);
      if (dataVersion != _lastMarkerDataVersion) {
        _lastMarkerDataVersion = dataVersion;
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          // Guard against concurrent build()-triggered syncs stepping on each
          // other. _syncAllAnnotations awaits multiple native platform calls
          // and can take ~100ms+; during auto-ping bursts multiple rebuilds
          // would otherwise schedule overlapping runs whose cleanup loops
          // would remove symbols the other sync just added.
          if (_syncInFlight) return;
          _syncInFlight = true;
          try {
            await _syncAllAnnotations(appState);
          } catch (e) {
            debugError('[MAP] _syncAllAnnotations failed: $e');
          } finally {
            _syncInFlight = false;
          }
        });
      }
    }

    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    // Get safe area padding for dynamic island/notch in landscape
    final safePadding = MediaQuery.of(context).padding;
    final topPadding = isLandscape ? 16.0 : 8.0;
    final leftPadding = isLandscape ? safePadding.left + 8 : 8.0;

    return Stack(
      children: [
        // Map — wait for Hive-loaded preferences before constructing
        // MapLibreMap, otherwise the default mapStyle ('liberty') would
        // render first and then swap to the user's saved style.
        if (appState.preferencesLoaded)
          _buildMap(appState, center)
        else
          const ColoredBox(
            color: Color(0xFF1A1A1A),
            child: SizedBox.expand(),
          ),

        // GPS Info + Top Repeaters overlay (top-left, respects dynamic island in landscape)
        Positioned(
          top: topPadding,
          left: leftPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildGpsInfoOverlay(appState),
              if (appState.preferences.showTopRepeaters) ...[
                const SizedBox(height: 6),
                _buildTopRepeatersOverlay(appState),
              ],
            ],
          ),
        ),

        // Map controls - top-right in both orientations, collapsible
        Positioned(
          top: topPadding,
          right: 8,
          child: _buildCollapsibleMapControls(appState),
        ),

        // Tile load failure banner — appears if base tiles haven't finished
        // loading within ${_tileLoadTimeoutSeconds}s after style load.
        if (_tileLoadFailed)
          Positioned(
            top: topPadding,
            left: 0,
            right: 0,
            child: Center(
              child: _buildTileLoadFailedBanner(),
            ),
          ),
      ],
    );
  }

  /// Banner shown when map tiles fail to load within the timeout window.
  Widget _buildTileLoadFailedBanner() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 80),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.orange.shade900.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.shade700, width: 1),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, color: Colors.white, size: 16),
          SizedBox(width: 8),
          Flexible(
            child: Text(
              'Map tiles unavailable — check connection',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Collapsible map controls (toggle at top, expands downward)
  Widget _buildCollapsibleMapControls(AppStateProvider appState) {
    // Use external state if provided, otherwise use internal state
    final isExpanded = widget.mapControlsExpanded ?? _mapControlsExpanded;
    final onToggle = widget.onMapControlsToggle ??
        () => setState(() => _mapControlsExpanded = !_mapControlsExpanded);

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
        if (isExpanded) _buildMapControls(appState),
      ],
    );
  }

  Widget _buildMap(AppStateProvider appState, LatLng center) {
    final mapStyle =
        MapStyleExtension.fromString(appState.preferences.mapStyle);
    // Always use the real style so downloaded offline tiles can render from
    // cache. Network access is controlled via setOffline() instead.
    final newStyleUrl = mapStyle.styleUrl;

    // Detect mapTilesEnabled toggle changes and switch MapLibre between
    // online (network tiles) and offline (cache-only) mode. This avoids
    // a full style reload — the same style stays loaded but MapLibre stops
    // or starts making network requests for tiles.
    final tilesEnabled = appState.preferences.mapTilesEnabled;
    if (_lastMapTilesEnabled != tilesEnabled && _isMapReady) {
      _lastMapTilesEnabled = tilesEnabled;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setOffline(!tilesEnabled);
        debugPrint(
            '[MAP] setOffline(${!tilesEnabled}) — tiles ${tilesEnabled ? "enabled" : "disabled (cache only)"}');
      });
    }

    // Style changes flow through MapLibreMap.styleString — the plugin's
    // didUpdateWidget detects the new value and fires a native setStyle.
    // onStyleLoadedCallback → _onStyleLoaded re-registers images, rebuilds
    // cluster layers, re-adds the coverage overlay, and re-syncs annotations.

    // Detect cache bust or zoneCode change → schedule a SINGLE coalesced
    // refresh. Previously each watcher scheduled its own post-frame callback,
    // which could race when both changed in the same frame (e.g. a zone
    // transition that also rotates cache bust). The _coverageRefreshScheduled
    // flag ensures at most one refresh is queued per frame.
    //
    // The zoneCode watcher is needed because _addCoverageOverlay only runs
    // during _onStyleLoaded — if the first zone check failed with
    // gps_inaccurate, the style loads with zoneCode=null and the overlay is
    // skipped. When a later retry sets the zone, nothing else would trigger
    // the raster layer.
    final cacheBustChanged = appState.overlayCacheBust != _lastCacheBust &&
        _isMapReady &&
        _styleLoaded;
    final zoneChanged = appState.zoneCode != _lastOverlayZoneCode &&
        _isMapReady &&
        _styleLoaded;
    if (cacheBustChanged || zoneChanged) {
      if (cacheBustChanged) _lastCacheBust = appState.overlayCacheBust;
      if (zoneChanged) _lastOverlayZoneCode = appState.zoneCode;
      if (!_coverageRefreshScheduled) {
        _coverageRefreshScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          _coverageRefreshScheduled = false;
          if (!mounted) return;
          await _refreshCoverageOverlay(appState);
        });
      }
    }

    // Detect coverage overlay opacity change (user dragged the slider in
    // Settings → General) and push it to the live raster layer without
    // rebuilding the whole overlay. Skipped while ping focus mode is active —
    // focus forces opacity to 0 and _dismissPingFocus restores the preference
    // value directly.
    final wantedOpacity = appState.preferences.coverageOverlayOpacity;
    if (_isMapReady &&
        _styleLoaded &&
        _focusedPingLocation == null &&
        _lastAppliedCoverageOpacity != null &&
        _lastAppliedCoverageOpacity != wantedOpacity) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyCoverageOverlayOpacity(wantedOpacity);
      });
    }

    return Stack(
      children: [
        // MapLibre GL map (base tiles via style; coverage overlay added programmatically)
        MapLibreMap(
          styleString: newStyleUrl,
          initialCameraPosition: CameraPosition(
            target: center,
            zoom: _defaultZoom,
          ),
          minMaxZoomPreference: const MinMaxZoomPreference(3, 17),
          rotateGesturesEnabled: !_rotationLocked,
          scrollGesturesEnabled: true,
          zoomGesturesEnabled: true,
          tiltGesturesEnabled: false, // 2D wardriving map
          compassEnabled: false, // We have our own controls
          // CRITICAL: must be true so the controller's `cameraPosition` getter
          // stays synced with the platform side. Without this, the Dart-side
          // _cameraPosition is set once at construction and never updated, which
          // breaks our sync projection (markers project to stale positions and
          // get filtered out by viewport bounds). Also enables camera-move events
          // during gestures so _onCameraChanged fires every frame for live
          // marker overlay updates.
          trackCameraPosition: true,
          onMapCreated: _onMapCreated,
          onStyleLoadedCallback: () => _onStyleLoaded(appState),
          onMapIdle: _onMapIdle,
          onCameraIdle: _onCameraIdle,
          // NOTE: we do NOT pass onMapClick here. The iOS plugin's
          // handleMapTap fires `feature#onTap` when a tap hits any
          // interactive layer (including our cluster source layers) and
          // does NOT fire `map#onMapClick` in that case. We register a
          // listener on `controller.onFeatureTapped` in _onMapCreated
          // instead — that fires for taps on custom layer features.
        ),
        // No widget marker overlay — markers are now native MapLibre
        // annotations rendered by the platform view itself.
      ],
    );
  }

  void _onMapCreated(MapLibreMapController controller) {
    _mapController = controller;
    // Wire up native annotation tap callbacks. These streams fire when the
    // user taps on a symbol/line that the platform-side hit-test matches.
    // Since the controller is created exactly once, this listener registration
    // happens exactly once too — no need to remove and re-add on style switch.
    controller.onSymbolTapped.add(_handleSymbolTap);
    // Generic feature tap handler — fires for ANY interactive style layer,
    // including our custom repeater cluster + individual layers (which are
    // NOT managed by the annotation manager). We dispatch in _handleFeatureTap
    // based on the layerId.
    controller.onFeatureTapped.add(_handleFeatureTap);
  }

  /// Routes a native symbol tap to the appropriate detail sheet.
  /// The tap event carries the [Symbol] object, which has the metadata Map we
  /// attached when calling addSymbol() in the various sync methods. We use the
  /// `kind` and `id` keys to look up the original ping/repeater object from
  /// app state and call the existing `_show*Details()` method (which expects
  /// the full object, not just an ID).
  void _handleSymbolTap(Symbol symbol) {
    if (!mounted) return;
    final data = symbol.data;
    if (data == null) return;
    final kind = data['kind'] as String?;
    final id = data['id'];
    final appState = context.read<AppStateProvider>();

    switch (kind) {
      // 'repeater' is no longer handled here — repeaters are in a custom
      // cluster GeoJSON layer (not the annotation manager) and dispatch
      // through _handleMapClick + queryRenderedFeatures instead.
      case 'tx':
        final ping = appState.txPings
            .where((p) => p.timestamp.millisecondsSinceEpoch == id)
            .firstOrNull;
        if (ping != null) _showTxPingDetails(ping);
        break;
      case 'rx':
        final ping = appState.rxPings
            .where((p) => p.timestamp.millisecondsSinceEpoch == id)
            .firstOrNull;
        if (ping != null) _showRxPingDetails(ping);
        break;
      case 'disc':
        final entry = appState.discLogEntries
            .where((e) => e.timestamp.millisecondsSinceEpoch == id)
            .firstOrNull;
        if (entry != null) _showDiscPingDetails(entry);
        break;
      case 'trace':
        final entry = appState.traceLogEntries
            .where((e) => e.timestamp.millisecondsSinceEpoch == id)
            .firstOrNull;
        if (entry != null) _showTraceDetails(entry);
        break;
      // gps, distance-label: not tappable in original — no action
    }
  }

  /// Handles taps on custom layer features (repeater cluster bubbles and
  /// individual repeaters). Wired in [_onMapCreated] via
  /// `controller.onFeatureTapped.add(_handleFeatureTap)`.
  ///
  /// The iOS/Android tap dispatcher calls this for ANY tap that hits an
  /// interactive style layer, BEFORE falling back to `onMapClick`. Since our
  /// cluster source layers are interactive, taps on repeaters/clusters always
  /// route here (not through onMapClick).
  ///
  /// We dispatch by [layerId]:
  ///  - cluster bubble layer → zoom in 2 levels around the tap point
  ///  - individual repeater layer → look up the Repeater by id and open the
  ///    existing detail sheet
  ///
  /// [id] is the GeoJSON Feature `id` (which we set to `repeater.id` for
  /// individual repeaters; MapLibre auto-generates one for cluster features).
  /// [annotation] is always null here since these layers aren't managed by
  /// the annotation manager.
  void _handleFeatureTap(
    math.Point<double> point,
    LatLng coordinates,
    String id,
    String layerId,
    Annotation? annotation,
  ) {
    if (!mounted) return;

    // Cluster tap: just zoom in. We accept hits on EITHER the bubble circle
    // layer OR the count-text symbol layer that sits on top of it. The
    // platform-side hit-test iterates layers top-down and returns the first
    // feature it finds; for cluster taps, the centered count text usually
    // gets hit before the underlying bubble, so we have to recognise both
    // layer IDs as "user tapped a cluster". Either way the action is the
    // same: animate-zoom in 2 levels around the tap point.
    //
    // The explicit 200ms duration is important for perceived responsiveness.
    // Without it, iOS uses setCamera(animated: true) which has a slow ease-in
    // start (~150ms before any noticeable motion). Passing a duration switches
    // the native code path to fly(to:withDuration:) which ramps in faster and
    // finishes in 200ms, making the tap feel "instant" rather than delayed.
    if (layerId == _repeaterClusterBubbleLayerId ||
        layerId == _repeaterClusterCountLayerId) {
      final currentZoom = _mapController?.cameraPosition?.zoom ?? _defaultZoom;
      final newZoom = math.min(currentZoom + 2, 17.0);
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(coordinates, newZoom),
        duration: const Duration(milliseconds: 200),
      );
      return;
    }

    // Individual repeater: look up by id (which is repeater.id) and open the
    // existing detail sheet. We recompute isDuplicate and hopOverride from
    // app state rather than carrying them in feature properties — the values
    // are cheap to derive and always reflect the latest data.
    if (layerId == _repeaterIndividualLayerId) {
      _showRepeaterDetailsById(id);
      return;
    }

    // GPS marker tap: the GPS marker is a non-interactive symbol on the
    // annotation manager layer (which sits ON TOP of all custom layers in
    // paint order). Without intervention, taps on the GPS marker hit the
    // annotation layer first and stop the iOS dispatcher from checking the
    // cluster layers underneath. Detect that case here and re-query the
    // cluster layers at the same screen point so the user can still tap
    // a cluster/repeater that the GPS marker happens to be sitting on top of.
    if (annotation is Symbol) {
      final kind = annotation.data?['kind'] as String?;
      if (kind == 'gps') {
        _fallThroughToRepeaterAt(point, coordinates);
        return;
      }
    }
  }

  /// When a tap hits the GPS marker (which has no detail sheet), try to find
  /// any repeater cluster or individual repeater under the same point and
  /// dispatch THAT instead. We use [queryRenderedFeatures] explicitly scoped
  /// to the cluster source's layers, since the iOS native tap dispatcher
  /// already short-circuited at the GPS marker layer above.
  Future<void> _fallThroughToRepeaterAt(
    math.Point<double> point,
    LatLng coordinates,
  ) async {
    if (_mapController == null) return;
    try {
      final features = await _mapController!.queryRenderedFeatures(
        point,
        const [
          _repeaterClusterCountLayerId,
          _repeaterClusterBubbleLayerId,
          _repeaterIndividualLayerId,
        ],
        null,
      );
      if (features.isEmpty || !mounted) return;

      // The Dart-side wrapper jsonDecodes each feature into a Map for us
      // (see method_channel_maplibre_gl.dart::queryRenderedFeatures). So we
      // can read properties directly without parsing JSON.
      final feature = features.first as Map;
      final properties = (feature['properties'] as Map?) ?? {};

      // Cluster (auto-tagged by MapLibre when cluster: true is set on source).
      // Same explicit 200ms duration as the direct cluster path in
      // _handleFeatureTap so both tap routes feel identical.
      if (properties['cluster'] == true) {
        final currentZoom =
            _mapController?.cameraPosition?.zoom ?? _defaultZoom;
        final newZoom = math.min(currentZoom + 2, 17.0);
        _mapController?.animateCamera(
          CameraUpdate.newLatLngZoom(coordinates, newZoom),
          duration: const Duration(milliseconds: 200),
        );
        return;
      }

      // Individual repeater. The feature `id` field is the repeater.id we set
      // in _buildRepeaterFeatureCollection (or fall back to the property).
      final repeaterId =
          (feature['id'] ?? properties['repeaterId'])?.toString();
      if (repeaterId != null) {
        _showRepeaterDetailsById(repeaterId);
      }
    } catch (e) {
      debugError('[MAP] queryRenderedFeatures fall-through failed: $e');
    }
  }

  /// Open the repeater detail sheet for a given [repeaterId]. Looks up the
  /// Repeater object from app state and recomputes the duplicate/hopOverride
  /// flags. Used by both direct tap dispatch and the GPS fall-through path.
  void _showRepeaterDetailsById(String repeaterId) {
    if (!mounted) return;
    final appState = context.read<AppStateProvider>();
    final repeater =
        appState.repeaters.where((r) => r.id == repeaterId).firstOrNull;
    if (repeater == null) return;

    final duplicates = _getDuplicateRepeaterIds(appState.repeaters);
    final isDuplicate = duplicates.contains(repeater.id);
    final hopOverride =
        appState.enforceHopBytes ? appState.effectiveHopBytes : null;

    _showRepeaterDetails(
      repeater,
      isDuplicate: isDuplicate,
      regionHopBytesOverride: hopOverride,
    );
  }

  Future<void> _onStyleLoaded(AppStateProvider appState) async {
    // Re-entrance guard. iOS plugin sometimes fires onStyleLoadedCallback
    // multiple times during a single setStyle. The race causes "Layer not
    // found" errors during the symbol manager's _rebuildLayers and
    // double-registers images. Bail any nested call so the first invocation
    // runs to completion uninterrupted.
    if (_styleLoadInProgress) {
      debugLog(
          '[MAP] _onStyleLoaded re-entered while already running, skipping');
      return;
    }
    _styleLoadInProgress = true;
    try {
      _styleLoaded = true;
      _isMapReady = true;

      // CRITICAL: clear stale Symbol references from any previous style load.
      // Style reloads cause maplibre_gl to construct a brand-new SymbolManager
      // with empty internal _idToAnnotation maps. Our _gpsSymbol /
      // _coverageSymbols / _distanceLabelSymbols still reference the OLD
      // Symbol objects whose IDs are not in the new manager — calling
      // updateSymbol on them throws "you can only set existing annotations".
      // Clearing them now means the next sync will call addSymbol (which
      // creates fresh symbols in the new manager) instead of updateSymbol.
      _gpsSymbol = null;
      _coverageSymbols.clear();
      _distanceLabelSymbols.clear();
      // Distance-label companions: the native side wipes registered images on
      // style reload, so the "already registered" cache must be cleared too or
      // the next focus mode will skip addImage() and reference a non-existent
      // image. The size/repeater-position maps are cleared for consistency.
      _distanceLabelImageSize.clear();
      _distanceLabelRepeaterPos.clear();
      _registeredDistanceLabelImages.clear();
      // Mark cluster layers as not-ready until _setupRepeaterClusterLayers
      // creates them on the new style. This gates build()-driven post-frame
      // syncs from racing ahead of source creation.
      _clusterLayersReady = false;

      // Disable symbol decluttering on the annotation manager. By default,
      // MapLibre symbol layers hide overlapping icons/labels at lower zoom to
      // reduce visual clutter — but for wardriving we want every coverage
      // marker visible regardless of density. (Repeaters are now in their own
      // cluster-enabled GeoJSON layer with its own per-layer overlap settings.)
      await _configureSymbolDecluttering();

      // Pre-render and register all marker bitmaps for native annotations.
      // Style reloads (e.g., user switches dark→liberty) wipe registered images,
      // so we always re-register on every style load. Awaited so the cluster
      // layer (which references icon image names) sees them when it's created.
      _imagesRegistered = false;
      await _registerMapImages(appState);

      // Set up the repeater cluster source + 3 layers. Must run AFTER images
      // are registered, since the individual symbol layer's iconImage expression
      // looks up names registered by _registerMapImages.
      await _setupRepeaterClusterLayers();

      // Re-add coverage overlay AFTER cluster layers exist so _addCoverageOverlay
      // can target the bottom repeater layer as its belowLayerId reference. This
      // keeps the insertion point consistent with the zoneCode watcher path —
      // both end up with raster at the bottom of the repeater stack, not above it.
      await _refreshCoverageOverlay(appState);
      _lastOverlayZoneCode = appState.zoneCode;

      // Start tile-load timeout. If onMapIdle doesn't fire within N seconds,
      // we assume tiles are failing to load (network down, server error, etc.)
      // and surface a banner. Cleared as soon as onMapIdle fires.
      // When tiles are disabled (cache-only mode), suppress the warning — cached
      // tiles load instantly or not at all; a timeout would be misleading.
      _tileLoadTimeoutTimer?.cancel();
      final tilesEnabled = appState.preferences.mapTilesEnabled;
      _lastMapTilesEnabled = tilesEnabled;
      // Ensure MapLibre offline mode matches the user's preference.
      setOffline(!tilesEnabled);
      if (tilesEnabled) {
        _tileLoadFailed = false;
        _tileLoadTimeoutTimer =
            Timer(const Duration(seconds: _tileLoadTimeoutSeconds), () {
          if (mounted && !_tileLoadFailed) {
            debugWarn(
                '[MAP] Tile load timeout — tiles did not finish loading within ${_tileLoadTimeoutSeconds}s');
            setState(() => _tileLoadFailed = true);
          }
        });
      } else {
        // Cache-only mode — never show the tile-load warning
        _tileLoadFailed = false;
      }

      // First-load-only setup: center on GPS and register camera listener.
      // On subsequent style switches, preserve the user's pan position.
      if (!_hasStyleLoadedOnce) {
        _hasStyleLoadedOnce = true;

        // Center on GPS if available (initial centering)
        if (appState.currentPosition != null) {
          final center = LatLng(
            appState.currentPosition!.latitude,
            appState.currentPosition!.longitude,
          );
          _mapController!.animateCamera(
            CameraUpdate.newLatLngZoom(center, _defaultZoom),
          );
        }

        // Register camera listener ONCE so marker overlay positions update on pan/zoom
        _mapController!.addListener(_onCameraChanged);
      }

      // Force an initial annotation sync now that images are registered AND the
      // cluster source/layers exist. This pushes the current app state into the
      // newly-created native annotations on first style load (and again whenever
      // the style is reloaded, since style reloads wipe everything).
      if (mounted) {
        await _syncAllAnnotations(appState);
        // Update the data version to match what we just synced. Without this,
        // the build()-driven post-frame sync would fire AGAIN with the same
        // data because _lastMarkerDataVersion still holds the previous value
        // — that double-sync was racing the first sync's symbol refs and
        // throwing "you can only set existing annotations" errors twice.
        _lastMarkerDataVersion = _computeMarkerDataVersion(appState);
        if (mounted) setState(() {});
      }
    } finally {
      _styleLoadInProgress = false;
    }
  }

  /// Fires when the map finishes loading visible tiles and the camera is idle.
  /// We use this as the "tiles loaded successfully" signal — clears the failure
  /// timer and hides any tile-load warning banner.
  void _onMapIdle() {
    _tileLoadTimeoutTimer?.cancel();
    if (_tileLoadFailed && mounted) {
      debugLog('[MAP] Tiles recovered after earlier load failure');
      setState(() => _tileLoadFailed = false);
    }
  }

  /// Fires when the camera stops moving — after both gestures and
  /// programmatic animations. While auto-follow is on, we use this as the
  /// point to sync our tracked target zoom with whatever zoom the camera
  /// actually settled at (e.g. after the user pinch-zoomed). That keeps the
  /// next auto-follow GPS tick from snapping the camera back to a stale
  /// target zoom.
  void _onCameraIdle() {
    if (!_autoFollow || _mapController == null) return;
    final currentZoom = _mapController!.cameraPosition?.zoom;
    if (currentZoom != null) {
      _autoFollowDesiredZoom = currentZoom;
    }
  }

  /// Add MeshMapper coverage raster overlay as a MapLibre source+layer
  Future<void> _addCoverageOverlay(AppStateProvider appState) async {
    if (_mapController == null || !_showMeshMapperOverlay) return;
    if (!appState.preferences.mapTilesEnabled) return;
    if (appState.zoneCode == null || appState.zoneCode!.isEmpty) return;

    final cvdParam = appState.preferences.colorVisionType != 'none'
        ? '&cvd=${appState.preferences.colorVisionType}'
        : '';
    final url =
        'https://${appState.zoneCode!.toLowerCase()}.meshmapper.net/tiles.php?x={x}&y={y}&z={z}&t=${appState.overlayCacheBust}$cvdParam';

    try {
      await _mapController!.addSource(
        'meshmapper-overlay',
        RasterSourceProperties(tiles: [url], tileSize: 256, maxzoom: 17),
      );
      // Target the bottom of the repeater cluster stack when it exists, so the
      // raster lands beneath ALL marker layers (repeater clusters + symbol
      // annotations). During the initial style load, _setupRepeaterClusterLayers
      // runs before this — so _clusterLayersReady is true and we use the
      // individual repeater layer as the reference. The zoneCode watcher also
      // fires after cluster setup, so both paths converge to the same stack.
      // Fallback to the symbol annotation layer only if cluster layers haven't
      // been created yet (shouldn't happen in practice, but keeps the raster
      // underneath markers either way).
      final belowLayer = _clusterLayersReady
          ? _repeaterIndividualLayerId
          : _symbolAnnotationLayerId();
      // While ping focus mode is active, force the newly added raster layer
      // to opacity 0 so a cache-bust tile refresh (fires 5s after every API
      // upload success — see AppStateProvider._tileRefreshTimer) doesn't
      // make the overlay pop back into view in the middle of focus mode.
      // Dismissing focus restores the preference value via
      // _applyCoverageOverlayOpacity in _dismissPingFocus.
      final opacity = _focusedPingLocation != null
          ? 0.0
          : appState.preferences.coverageOverlayOpacity;
      await _mapController!.addRasterLayer(
        'meshmapper-overlay',
        'meshmapper-overlay-layer',
        RasterLayerProperties(rasterOpacity: opacity),
        belowLayerId: belowLayer,
      );
      _lastAppliedCoverageOpacity = opacity;
      debugLog(
          '[MAP] Coverage overlay added (below ${belowLayer ?? "top"}, opacity ${opacity.toStringAsFixed(2)})');
    } catch (e) {
      debugLog('[MAP] Failed to add coverage overlay: $e');
    }
  }

  /// Apply a new coverage overlay opacity to the live raster layer without
  /// removing/re-adding it. No-op if the layer doesn't exist yet.
  Future<void> _applyCoverageOverlayOpacity(double opacity) async {
    if (_mapController == null) return;
    try {
      await _mapController!.setLayerProperties(
        'meshmapper-overlay-layer',
        RasterLayerProperties(rasterOpacity: opacity),
      );
      _lastAppliedCoverageOpacity = opacity;
      debugLog(
          '[MAP] Coverage overlay opacity updated to ${opacity.toStringAsFixed(2)}');
    } catch (e) {
      // Layer may not exist yet (e.g. before first style load or when the
      // overlay is hidden). Safe to ignore — next _addCoverageOverlay call
      // will pick up the current preference value.
      debugLog('[MAP] Coverage overlay opacity update skipped: $e');
    }
  }

  /// Returns the layer ID of the symbol annotation manager's first (and only)
  /// layer, or `null` if the manager isn't initialized yet. Used as a
  /// `belowLayerId` reference to insert other layers (coverage overlay, focus
  /// lines) BENEATH the marker symbols so markers always render on top.
  String? _symbolAnnotationLayerId() {
    final manager = _mapController?.symbolManager;
    if (manager == null) return null;
    return '${manager.id}_0';
  }

  /// Disables MapLibre's default symbol-collision behavior for our marker
  /// annotations. Without this, repeater markers fade out as you zoom out
  /// because the symbol layer hides overlapping icons + labels to reduce
  /// visual clutter — undesirable for a wardriving app where every marker
  /// matters. Called once per style load, before any symbols are added.
  Future<void> _configureSymbolDecluttering() async {
    if (_mapController == null) return;
    try {
      await _mapController!.setSymbolIconAllowOverlap(true);
      await _mapController!.setSymbolIconIgnorePlacement(true);
      await _mapController!.setSymbolTextAllowOverlap(true);
      await _mapController!.setSymbolTextIgnorePlacement(true);
    } catch (e) {
      debugError('[MAP] Failed to configure symbol decluttering: $e');
    }
  }

  /// Remove coverage overlay source and layer
  Future<void> _removeCoverageOverlay() async {
    if (_mapController == null) return;
    try {
      await _mapController!.removeLayer('meshmapper-overlay-layer');
      await _mapController!.removeSource('meshmapper-overlay');
    } catch (_) {}
  }

  /// Refresh coverage overlay (remove and re-add with new URL)
  Future<void> _refreshCoverageOverlay(AppStateProvider appState) async {
    await _removeCoverageOverlay();
    await _addCoverageOverlay(appState);
  }

  /// Returns the fill color for a repeater status keyword.
  /// Mirrors the priority logic in [_getRepeaterMarkerColor].
  Color _repeaterStatusColor(String status) {
    switch (status) {
      case 'dup':
        return PingColors.repeaterDuplicate;
      case 'dead':
        return PingColors.repeaterDead;
      case 'new':
        return PingColors.repeaterNew;
      case 'active':
      default:
        return PingColors.repeaterActive;
    }
  }

  /// Returns the color for a coverage marker (TX/RX/DISC/Trace × success/fail).
  Color _coverageStatusColor(String type, bool success) {
    switch (type) {
      case 'tx':
        return success ? PingColors.txSuccess : PingColors.txFail;
      case 'rx':
        return PingColors.rx;
      case 'disc':
        return success ? PingColors.discSuccess : PingColors.discFail;
      case 'trace':
        return success ? Colors.cyan : Colors.grey;
      default:
        return Colors.grey;
    }
  }

  /// Returns the borderRadius value for a repeater shape based on hop_bytes.
  /// Mirrors the values in the original `_buildRepeaterMarkers` (lines ~2390).
  double _repeaterBorderRadius(int hopBytes) {
    if (hopBytes >= 3) return 8;
    if (hopBytes == 2) return 6;
    return 4;
  }

  /// Pre-renders and registers all marker bitmaps that the native MapLibre
  /// symbols reference via `iconImage`. Called from [_onStyleLoaded] after the
  /// style is ready (so addImage can succeed). Idempotent — safe to call again
  /// if a style reload happens; addImage replaces existing entries by name.
  ///
  /// Generates:
  ///   - 12 repeater shape bitmaps (4 status colors × 3 hop_byte radii) — fixed
  ///     width 48px, the widest case (6-char hex IDs); shorter text is centered
  ///     by MapLibre's textField rendering.
  ///   - 8 coverage marker bitmaps for the user's currently-selected style.
  ///   - 6 GPS marker bitmaps (one per style).
  ///
  /// Marker style preference changes are handled separately by
  /// [_reregisterCoverageImages] which only re-runs the coverage section.
  Future<void> _registerMapImages(AppStateProvider appState) async {
    if (_mapController == null) return;

    try {
      // 1. Repeater shapes — 12 variants
      const repeaterSize = Size(48, 28);
      for (final status in _MapImages.repeaterStatuses) {
        final color = _repeaterStatusColor(status);
        for (final hopBytes in _MapImages.repeaterHopBytes) {
          final painter = _RepeaterShapePainter(
            fillColor: color,
            borderRadius: _repeaterBorderRadius(hopBytes),
          );
          final bytes = await _renderPainterToPng(painter, repeaterSize);
          await _mapController!.addImage(
            _MapImages.repeater(status, hopBytes),
            bytes,
          );
        }
      }

      // 2. Coverage markers — 8 variants for current style
      await _registerCoverageImages(appState.preferences.markerStyle);

      // 3. GPS marker variants — 6 styles
      const gpsSize = Size(48, 48);
      final gpsPainters = <String, CustomPainter>{
        'arrow': const _ArrowPainter(),
        'car': const _CarMarkerPainter(),
        'bike': const _BikeMarkerPainter(),
        'boat': const _BoatMarkerPainter(),
        'walk': const _WalkMarkerPainter(),
        'chomper': const _ChomperMarkerPainter(),
      };
      for (final entry in gpsPainters.entries) {
        final bytes = await _renderPainterToPng(entry.value, gpsSize);
        await _mapController!.addImage(_MapImages.gps(entry.key), bytes);
      }

      _imagesRegistered = true;
      debugLog(
          '[MAP] Registered ${_MapImages.repeaterStatuses.length * _MapImages.repeaterHopBytes.length} repeater + 8 coverage + ${gpsPainters.length} GPS marker images');
      // NOTE: do NOT trigger _syncAllAnnotations here. The repeater cluster
      // source/layers haven't been created yet — _onStyleLoaded calls
      // _setupRepeaterClusterLayers AFTER us, then triggers the initial sync
      // once everything is in place.
    } catch (e) {
      debugError('[MAP] Failed to register marker images: $e');
    }
  }

  /// Generates and registers the 8 coverage marker bitmaps for [styleName].
  /// Called from [_registerMapImages] on initial setup, and from the
  /// preference-change handler when the user picks a different marker shape.
  Future<void> _registerCoverageImages(String styleName) async {
    if (_mapController == null) return;
    // 40×40 canvas with the 24×24 glyph centered inside it — the transparent
    // padding enlarges the native symbol hit target (~40×40 px) without
    // changing the visual marker size. Fixes finicky taps on small markers.
    const coverageSize = Size(40, 40);
    for (final type in _MapImages.coverageTypes) {
      for (final success in [true, false]) {
        final painter = _CoverageMarkerPainter(
          style: styleName,
          color: _coverageStatusColor(type, success),
        );
        final bytes = await _renderPainterToPng(painter, coverageSize);
        await _mapController!.addImage(
          _MapImages.coverage(type, success),
          bytes,
        );
      }
    }
    _registeredCoverageStyle = styleName;
  }

  /// Returns the status keyword used as the iconImage suffix for a repeater.
  /// Mirrors the priority logic in [_getRepeaterMarkerColor]: duplicate > dead
  /// > new > active.
  String _repeaterStatusKey(Repeater repeater, bool isDuplicate) {
    if (isDuplicate) return 'dup';
    if (repeater.isDead) return 'dead';
    if (repeater.isNew) return 'new';
    return 'active';
  }

  /// Converts a Flutter [Color] to a `#RRGGBB` (or `#RRGGBBAA`) hex string
  /// for MapLibre symbol/line properties (which take CSS-style color strings).
  String _colorToHex(Color color, {bool includeAlpha = false}) {
    final argb = color.toARGB32() & 0xFFFFFFFF;
    final rr = ((argb >> 16) & 0xFF).toRadixString(16).padLeft(2, '0');
    final gg = ((argb >> 8) & 0xFF).toRadixString(16).padLeft(2, '0');
    final bb = (argb & 0xFF).toRadixString(16).padLeft(2, '0');
    if (includeAlpha) {
      final aa = ((argb >> 24) & 0xFF).toRadixString(16).padLeft(2, '0');
      return '#$rr$gg$bb$aa';
    }
    return '#$rr$gg$bb';
  }

  /// Builds a GeoJSON FeatureCollection of all repeaters in app state, with
  /// per-feature properties used by the data-driven symbol layer expressions
  /// (iconImage, color, opacity, hex). Re-pushed to the cluster source whenever
  /// the marker data version changes — MapLibre handles re-clustering natively.
  Map<String, dynamic> _buildRepeaterFeatureCollection(
      AppStateProvider appState) {
    final duplicates = _getDuplicateRepeaterIds(appState.repeaters);
    final hopOverride =
        appState.enforceHopBytes ? appState.effectiveHopBytes : null;
    final focusActive = _focusedPingLocation != null;

    final features = <Map<String, dynamic>>[];
    for (final repeater in appState.repeaters) {
      final isDuplicate = duplicates.contains(repeater.id);
      final statusKey = _repeaterStatusKey(repeater, isDuplicate);
      final isConnected = focusActive &&
          _focusedRepeaters.any((r) => r.repeater.id == repeater.id);
      // In focus mode, hide repeaters not involved in the focused ping entirely
      // (skip the feature) rather than dimming — cleaner focus view and prevents
      // them from contributing to clusters.
      if (focusActive && !isConnected) continue;
      final effectiveBytes = hopOverride ?? repeater.hopBytes;
      // Clamp to the 1/2/3 hop_byte image variants we registered
      final shapeBytes = effectiveBytes >= 3
          ? 3
          : effectiveBytes == 2
              ? 2
              : 1;
      final iconImage = _MapImages.repeater(statusKey, shapeBytes);
      final hex = repeater.displayHexId(overrideHopBytes: hopOverride);
      final colorHex = _colorToHex(_repeaterStatusColor(statusKey));

      features.add({
        'type': 'Feature',
        'id': repeater.id,
        'properties': {
          'repeaterId': repeater.id,
          'iconImage': iconImage,
          'color': colorHex,
          'hex': hex,
          'isDuplicate': isDuplicate,
          if (hopOverride != null) 'hopOverride': hopOverride,
        },
        'geometry': {
          'type': 'Point',
          // GeoJSON convention: [longitude, latitude]
          'coordinates': [repeater.lon, repeater.lat],
        },
      });
    }

    return {'type': 'FeatureCollection', 'features': features};
  }

  /// Creates the cluster-enabled GeoJSON source and three rendering layers
  /// (individual symbols, cluster bubble circles, cluster count text). Called
  /// once per style load AFTER images are registered (the individual symbol
  /// layer references the registered icon names via a data-driven expression).
  Future<void> _setupRepeaterClusterLayers() async {
    if (_mapController == null) return;

    // Idempotent: tear down any existing source/layers from a previous style load
    for (final layerId in [
      _repeaterClusterCountLayerId,
      _repeaterClusterBubbleLayerId,
      _repeaterIndividualLayerId,
    ]) {
      try {
        await _mapController!.removeLayer(layerId);
      } catch (_) {}
    }
    try {
      await _mapController!.removeSource(_repeaterSourceId);
    } catch (_) {}

    // Empty source with cluster enabled. We'll push real data via setGeoJsonSource
    // from _syncRepeaterSymbols whenever the marker data version changes.
    //
    // IMPORTANT: pass `data` as a Dart Map (NOT jsonEncode-d string). The iOS
    // plugin's `buildShapeSource` assumes that if `data` is a String, it must be
    // a URL — and crashes via JSONSerialization.data() if a non-URL string is
    // passed and the URL parse fails. Maps are handled correctly.
    try {
      await _mapController!.addSource(
        _repeaterSourceId,
        const GeojsonSourceProperties(
          data: <String, dynamic>{
            'type': 'FeatureCollection',
            'features': <dynamic>[]
          },
          cluster: true,
          clusterRadius: 50,
          clusterMaxZoom: 14,
        ),
      );

      // Place all three layers BELOW the symbol annotation manager so coverage
      // markers / GPS / distance labels still render on top of repeater clusters.
      final belowLayer = _symbolAnnotationLayerId();

      // Layer 1: individual repeater markers (when not part of a cluster).
      // Data-driven properties read from each feature's `properties` map.
      await _mapController!.addSymbolLayer(
        _repeaterSourceId,
        _repeaterIndividualLayerId,
        const SymbolLayerProperties(
          iconImage: ['get', 'iconImage'],
          iconColor: ['get', 'color'],
          iconSize: 1.4,
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
          textField: ['get', 'hex'],
          textColor: '#FFFFFF',
          textHaloColor: '#000000',
          textHaloWidth: 1.5,
          textSize: 13,
          textAllowOverlap: true,
          textIgnorePlacement: true,
          textFont: _defaultFontStack,
        ),
        filter: [
          '!',
          ['has', 'point_count']
        ],
        belowLayerId: belowLayer,
      );

      // Layer 2: cluster bubble (circle, sized by point_count).
      // The 'step' expression makes the bubble grow as more repeaters merge:
      //   - default radius 18px (clusters of 2-9)
      //   - 22px for clusters of 10+
      //   - 26px for clusters of 50+
      await _mapController!.addCircleLayer(
        _repeaterSourceId,
        _repeaterClusterBubbleLayerId,
        CircleLayerProperties(
          circleColor: _colorToHex(PingColors.repeaterActive),
          circleRadius: const [
            'step',
            ['get', 'point_count'],
            18,
            10,
            22,
            50,
            26,
          ],
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 2,
          circleOpacity: 0.9,
        ),
        filter: ['has', 'point_count'],
        belowLayerId: belowLayer,
      );

      // Layer 3: cluster count text (uses MapLibre's built-in
      // 'point_count_abbreviated' property — automatically formatted as
      // "1.2k" for large counts).
      await _mapController!.addSymbolLayer(
        _repeaterSourceId,
        _repeaterClusterCountLayerId,
        const SymbolLayerProperties(
          textField: ['get', 'point_count_abbreviated'],
          textColor: '#FFFFFF',
          textSize: 14,
          textHaloColor: '#000000',
          textHaloWidth: 1,
          textAllowOverlap: true,
          textIgnorePlacement: true,
          textFont: _defaultFontStack,
        ),
        filter: ['has', 'point_count'],
        belowLayerId: belowLayer,
      );

      // All 3 layers + source created successfully — mark ready so the
      // build()-triggered post-frame sync can run, and so _syncRepeaterSymbols
      // is allowed to push data via setGeoJsonSource.
      _clusterLayersReady = true;
    } catch (e) {
      debugError('[MAP] Failed to set up repeater cluster layers: $e');
    }
  }

  /// Pushes the current repeater state into the cluster source. MapLibre
  /// re-clusters natively whenever the source data changes. Replaces the
  /// previous per-symbol addSymbol/updateSymbol/removeSymbol diff loop.
  Future<void> _syncRepeaterSymbols(AppStateProvider appState) async {
    if (_mapController == null ||
        !_styleLoaded ||
        !_imagesRegistered ||
        !_clusterLayersReady) {
      return;
    }
    try {
      final geojson = _buildRepeaterFeatureCollection(appState);
      await _mapController!.setGeoJsonSource(_repeaterSourceId, geojson);
    } catch (e) {
      debugError('[MAP] Failed to update repeater source: $e');
    }
  }

  /// Composite key for a coverage marker symbol — kind + timestamp ms + lat/lon.
  /// Used as the map key in [_coverageSymbols] and to detect updates/removals.
  /// Lat/lon at 5-decimal precision (~1.1m) is included so two distinct pings
  /// that happen to land in the same millisecond (possible under heavy RX
  /// traffic) don't collide on a shared key.
  String _coverageKey(String type, DateTime ts, double lat, double lon) =>
      '${type}_${ts.millisecondsSinceEpoch}_'
      '${lat.toStringAsFixed(5)}_${lon.toStringAsFixed(5)}';

  /// Diff-syncs native coverage symbols (TX/RX/DISC/Trace) against app state.
  /// One symbol per ping, image varies by type/success state, opacity reflects
  /// focus mode (faded if focus active and this isn't the focused ping).
  ///
  /// Marker style preference changes are NOT handled here — when the user
  /// switches between circle/pin/diamond/dot, the caller must first call
  /// [_handleMarkerStyleChange] to re-register the bitmap variants.
  Future<void> _syncCoverageSymbols(AppStateProvider appState) async {
    if (_mapController == null || !_styleLoaded || !_imagesRegistered) return;

    // Re-register coverage images if the user changed their style preference
    final currentStyle = appState.preferences.markerStyle;
    if (_registeredCoverageStyle != currentStyle) {
      await _registerCoverageImages(currentStyle);
      // After re-registering, all existing coverage symbols still reference
      // the same image names — but the underlying bitmaps have changed shape.
      // The native side picks up the new bitmaps automatically. No need to
      // update each symbol.
    }

    final wantedKeys = <String>{};
    final focusActive = _focusedPingLocation != null;

    Future<void> syncOne({
      required String type,
      required double lat,
      required double lon,
      required DateTime ts,
      required bool success,
      required int idForMetadata,
    }) async {
      final key = _coverageKey(type, ts, lat, lon);
      final isFocused = _isFocusedPing(lat, lon, ts);
      // In focus mode, hide every coverage marker except the focused ping.
      // Skipping wantedKeys lets the cleanup loop remove them entirely so the
      // map is uncluttered. Dismissing focus re-syncs and restores them.
      if (focusActive && !isFocused) return;
      wantedKeys.add(key);

      final options = SymbolOptions(
        geometry: LatLng(lat, lon),
        iconImage: _MapImages.coverage(type, success),
        iconSize: isFocused ? 1.2 : 1.0,
      );

      final existing = _coverageSymbols[key];
      if (existing == null) {
        try {
          final symbol = await _mapController!.addSymbol(
            options,
            {'kind': type, 'id': idForMetadata},
          );
          _coverageSymbols[key] = symbol;
        } catch (e) {
          debugError('[MAP] addSymbol($type) failed at $ts: $e');
        }
      } else {
        try {
          await _mapController!.updateSymbol(existing, options);
        } catch (e) {
          debugError('[MAP] updateSymbol($type) failed at $ts: $e');
        }
      }
    }

    // TX pings
    for (final ping in appState.txPings) {
      await syncOne(
        type: 'tx',
        lat: ping.latitude,
        lon: ping.longitude,
        ts: ping.timestamp,
        success: ping.heardRepeaters.isNotEmpty,
        idForMetadata: ping.timestamp.millisecondsSinceEpoch,
      );
    }

    // RX pings
    for (final ping in appState.rxPings) {
      await syncOne(
        type: 'rx',
        lat: ping.latitude,
        lon: ping.longitude,
        ts: ping.timestamp,
        success: true, // RX has no fail state — always uses the rx color
        idForMetadata: ping.timestamp.millisecondsSinceEpoch,
      );
    }

    // DISC entries (success = received node responses; drop = treat as TX fail)
    for (final entry in appState.discLogEntries) {
      final received = entry.nodeCount > 0;
      // When discDropEnabled, "no response" should look like a TX fail color.
      // We model that by using the 'tx' image variant for failed DISCs:
      final type = (!received && appState.discDropEnabled) ? 'tx' : 'disc';
      await syncOne(
        type: type,
        lat: entry.latitude,
        lon: entry.longitude,
        ts: entry.timestamp,
        success: received,
        idForMetadata: entry.timestamp.millisecondsSinceEpoch,
      );
    }

    // Trace entries
    for (final entry in appState.traceLogEntries) {
      await syncOne(
        type: 'trace',
        lat: entry.latitude,
        lon: entry.longitude,
        ts: entry.timestamp,
        success: entry.success,
        idForMetadata: entry.timestamp.millisecondsSinceEpoch,
      );
    }

    // Remove symbols for pings that no longer exist (e.g., user cleared markers)
    final toRemove =
        _coverageSymbols.keys.where((k) => !wantedKeys.contains(k)).toList();
    for (final key in toRemove) {
      final sym = _coverageSymbols.remove(key);
      if (sym != null) {
        try {
          await _mapController!.removeSymbol(sym);
        } catch (_) {}
      }
    }
  }

  /// Returns true if the given GPS marker style should rotate to face the
  /// user's heading (vs staying screen-aligned). Arrow/walk/pacman face the
  /// heading; car/bike/boat icons stay upright on a rotated map.
  bool _gpsStyleFacesHeading(String style) =>
      style == 'arrow' || style == 'walk' || style == 'chomper';

  /// Computes the iconRotate value for the GPS marker.
  ///
  /// MapLibre annotation symbols use the default `icon-rotation-alignment: auto`
  /// which resolves to `viewport` for point symbols — meaning iconRotate is
  /// applied in screen space, not map space. That has two consequences:
  ///
  ///  - Rotating styles (arrow/walk/chomper) must point in the direction of
  ///    travel both in always-north mode (where bearing = 0, so iconRotate
  ///    = heading) AND in heading mode (where the map is rotated so that
  ///    direction-of-travel is screen-up — so iconRotate should be 0).
  ///    The single formula that works for both is `heading - bearing`.
  ///
  ///  - Non-rotating styles (car/bike/boat) should always be drawn upright
  ///    on screen. With viewport alignment that's iconRotate = 0 regardless
  ///    of bearing; the icon is already screen-aligned by default.
  double _gpsIconRotate(String style, double heading) {
    final bearing = _mapController?.cameraPosition?.bearing ?? 0;
    if (_gpsStyleFacesHeading(style)) {
      final rotated = heading - bearing;
      // Normalize to 0..360 so MapLibre doesn't take the "long way around"
      // when iconRotate crosses the ±180° seam during interpolation.
      return (rotated % 360 + 360) % 360;
    }
    return 0;
  }

  /// Adds, updates, or removes the single GPS position symbol to match
  /// [appState.currentPosition]. Called from the post-frame sync trigger.
  Future<void> _syncGpsSymbol(AppStateProvider appState) async {
    if (_mapController == null || !_styleLoaded || !_imagesRegistered) return;

    final pos = appState.currentPosition;
    if (pos == null) {
      // No GPS lock — remove existing GPS symbol if present
      if (_gpsSymbol != null) {
        try {
          await _mapController!.removeSymbol(_gpsSymbol!);
        } catch (_) {}
        _gpsSymbol = null;
      }
      return;
    }

    final style = appState.preferences.gpsMarkerStyle;
    // Use the derived heading (updated by _computeHeading in build()) so the
    // arrow/walk/chomper markers actually point in the direction of travel
    // even when pos.heading is stale or unset.
    final iconRotate = _gpsIconRotate(style, _computedHeading ?? 0);

    final options = SymbolOptions(
      geometry: LatLng(pos.latitude, pos.longitude),
      iconImage: _MapImages.gps(style),
      iconRotate: iconRotate,
    );

    if (_gpsSymbol == null) {
      try {
        _gpsSymbol = await _mapController!.addSymbol(options, {'kind': 'gps'});
      } catch (e) {
        debugError('[MAP] addSymbol(gps) failed: $e');
      }
    } else {
      try {
        await _mapController!.updateSymbol(_gpsSymbol!, options);
      } catch (e) {
        debugError('[MAP] updateSymbol(gps) failed: $e');
      }
    }
  }

  /// Updates only the GPS symbol's iconRotate. Called from the camera-change
  /// listener when the bearing changes — under viewport alignment, rotating
  /// styles (arrow/walk/chomper) are the ones whose iconRotate depends on the
  /// bearing (iconRotate = heading - bearing), so they need refreshing as the
  /// bearing animates. Non-rotating styles use iconRotate = 0 and don't care.
  /// Cheaper than calling [_syncGpsSymbol] which also updates position.
  Future<void> _updateGpsSymbolRotation() async {
    if (_gpsSymbol == null || _mapController == null) return;
    final appState = context.read<AppStateProvider>();
    final pos = appState.currentPosition;
    if (pos == null) return;
    final style = appState.preferences.gpsMarkerStyle;
    if (!_gpsStyleFacesHeading(style)) return;
    try {
      await _mapController!.updateSymbol(
        _gpsSymbol!,
        SymbolOptions(iconRotate: _gpsIconRotate(style, _computedHeading ?? 0)),
      );
    } catch (_) {}
  }

  // Source/layer ID constants for the focus-mode dotted lines
  static const _focusLinesSourceId = 'focus-lines-source';
  static const _focusLinesLayerId = 'focus-lines-layer';
  static const _focusLinesAmbiguousLayerId = 'focus-lines-ambiguous-border';

  /// Builds and applies the focus-mode dotted polylines that visually connect
  /// a focused ping to each repeater that heard it. Color-coded by SNR;
  /// ambiguous matches get a wider white outline drawn underneath.
  ///
  /// Implementation uses a GeoJSON source + line layer (rather than the
  /// annotation-level addLine API) because LineOptions does not expose
  /// `lineDasharray`, but LineLayerProperties does.
  ///
  /// Idempotent: removes any existing source/layers first, then re-adds with
  /// the latest focus state.
  Future<void> _updateFocusLines() async {
    if (_mapController == null || !_styleLoaded) return;

    // Always remove existing layers/source first (silently ignore if absent).
    // Order matters: remove the layers BEFORE the source they reference.
    try {
      await _mapController!.removeLayer(_focusLinesLayerId);
    } catch (_) {}
    try {
      await _mapController!.removeLayer(_focusLinesAmbiguousLayerId);
    } catch (_) {}
    try {
      await _mapController!.removeSource(_focusLinesSourceId);
    } catch (_) {}

    if (_focusedPingLocation == null || _focusedRepeaters.isEmpty) return;

    // Build a FeatureCollection with one LineString per connected repeater.
    // Per-feature properties carry the line color (data-driven styling) and
    // ambiguous flag (used as a layer filter for the border line).
    final features = <Map<String, dynamic>>[];
    for (final r in _focusedRepeaters) {
      final color = r.snr != null ? PingColors.snrColor(r.snr!) : Colors.grey;
      features.add({
        'type': 'Feature',
        'properties': {
          'color': _colorToHex(color),
          'ambiguous': r.ambiguous,
        },
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [_focusedPingLocation!.longitude, _focusedPingLocation!.latitude],
            [r.repeater.lon, r.repeater.lat],
          ],
        },
      });
    }

    // Pass the FeatureCollection as a Dart Map (NOT a jsonEncode-d string).
    // The iOS plugin's buildShapeSource crashes if `data` is a string that's
    // not a URL — see fix in _setupRepeaterClusterLayers for the same gotcha.
    final geojson = <String, dynamic>{
      'type': 'FeatureCollection',
      'features': features,
    };

    try {
      await _mapController!.addSource(
        _focusLinesSourceId,
        GeojsonSourceProperties(data: geojson),
      );

      // Insert focus line layers BELOW the individual repeater layer so
      // repeater boxes (and the cluster bubbles/count text above them, plus
      // the symbol annotation markers on top of those) all render on top of
      // the connecting lines. This is especially important at the repeater
      // end of each line, where the dotted stroke would otherwise draw over
      // the repeater box.
      const belowLayer = _repeaterIndividualLayerId;

      // Border line (white, wider, only for ambiguous matches) — added FIRST
      // so it renders BENEATH the colored line on top.
      await _mapController!.addLineLayer(
        _focusLinesSourceId,
        _focusLinesAmbiguousLayerId,
        const LineLayerProperties(
          lineColor: '#FFFFFF',
          lineOpacity: 0.6,
          lineWidth: 6.5,
          lineDasharray: [2, 4],
          lineCap: 'round',
        ),
        filter: [
          '==',
          ['get', 'ambiguous'],
          true
        ],
        belowLayerId: belowLayer,
      );

      // Main colored line (color from feature property via data-driven expression)
      await _mapController!.addLineLayer(
        _focusLinesSourceId,
        _focusLinesLayerId,
        const LineLayerProperties(
          lineColor: ['get', 'color'],
          lineOpacity: 0.9,
          lineWidth: 3.5,
          lineDasharray: [2, 4],
          lineCap: 'round',
        ),
        belowLayerId: belowLayer,
      );
    } catch (e) {
      debugError('[MAP] Failed to add focus lines: $e');
    }
  }

  /// Diff-syncs the distance label symbols shown in focus mode. Each label is
  /// a bitmap pill (white text on a dark rounded rectangle background, baked
  /// into an addImage icon) placed at the midpoint of the ping→repeater line.
  ///
  /// A later pass ([_reflowDistanceLabelsForCollisions]) may slide individual
  /// labels along their lines after the zoom-to-fit animation settles, to
  /// prevent them from overlapping on screen.
  Future<void> _syncDistanceLabels(AppStateProvider appState) async {
    if (_mapController == null || !_styleLoaded) return;

    // No focus → remove all existing labels and wipe the tracking maps.
    //
    // Order matters here: snapshot the symbols to remove and clear the
    // tracking maps SYNCHRONOUSLY before awaiting any removeSymbol call.
    //
    // Why: removeSymbol is async. If we cleared after the await loop, a
    // concurrent _syncDistanceLabels call (triggered by e.g. the user
    // tapping a new ping and its focus activating during the yield) would
    // see the old tracking data — populate new symbols for the new focus
    // into the still-populated map — and then our late `.clear()` would
    // wipe the new-focus entries from tracking, leaving orphaned native
    // symbols on the map and causing the NEXT sync to double-add them.
    // By clearing first, any concurrent sync starts from a clean slate.
    if (_focusedPingLocation == null || _focusedRepeaters.isEmpty) {
      final toRemove = List.of(_distanceLabelSymbols.values);
      _distanceLabelSymbols.clear();
      _distanceLabelImageSize.clear();
      _distanceLabelRepeaterPos.clear();
      for (final sym in toRemove) {
        try {
          await _mapController!.removeSymbol(sym);
        } catch (_) {}
      }
      return;
    }

    final isImperial = appState.preferences.isImperial;
    final ping = _focusedPingLocation!;
    final wantedKeys = <String>{};

    for (final r in _focusedRepeaters) {
      final key = r.repeater.id;
      wantedKeys.add(key);
      final midLat = (ping.latitude + r.repeater.lat) / 2;
      final midLon = (ping.longitude + r.repeater.lon) / 2;
      final meters = GpsService.distanceBetween(
        ping.latitude,
        ping.longitude,
        r.repeater.lat,
        r.repeater.lon,
      );
      final labelText = meters < 1000
          ? formatMeters(meters, isImperial: isImperial)
          : formatKilometers(meters / 1000, isImperial: isImperial);

      // Dedup the bitmap image by label text — identical distances reuse one
      // registered image. addImage is idempotent by name, so re-registering
      // the same name is a no-op on subsequent calls.
      final imageName = 'distance-label-${labelText.hashCode}';
      Size? imageSize;
      if (!_registeredDistanceLabelImages.contains(imageName)) {
        try {
          final rendered = await _renderDistanceLabelPng(labelText);
          await _mapController!.addImage(imageName, rendered.bytes);
          _registeredDistanceLabelImages.add(imageName);
          imageSize = rendered.size;
        } catch (e) {
          debugError('[MAP] render/addImage(distance label) failed: $e');
        }
      }
      // If we didn't just render (reuse case) we still need the size for
      // collision tests. Re-render for measurement; this is cheap and rare.
      if (imageSize == null) {
        try {
          final rendered = await _renderDistanceLabelPng(labelText);
          imageSize = rendered.size;
        } catch (_) {
          imageSize = const Size(60, 18);
        }
      }
      _distanceLabelImageSize[key] = imageSize;
      _distanceLabelRepeaterPos[key] = LatLng(r.repeater.lat, r.repeater.lon);

      final options = SymbolOptions(
        geometry: LatLng(midLat, midLon),
        iconImage: imageName,
        iconSize: 1.0,
        iconAnchor: 'center',
      );

      final existing = _distanceLabelSymbols[key];
      if (existing == null) {
        try {
          _distanceLabelSymbols[key] = await _mapController!.addSymbol(
            options,
            {'kind': 'distance'},
          );
        } catch (e) {
          debugError('[MAP] addSymbol(distance) failed: $e');
        }
      } else {
        try {
          await _mapController!.updateSymbol(existing, options);
        } catch (e) {
          debugError('[MAP] updateSymbol(distance) failed: $e');
        }
      }
    }

    // Remove labels for repeaters no longer in focus
    final toRemove = _distanceLabelSymbols.keys
        .where((k) => !wantedKeys.contains(k))
        .toList();
    for (final key in toRemove) {
      final sym = _distanceLabelSymbols.remove(key);
      _distanceLabelImageSize.remove(key);
      _distanceLabelRepeaterPos.remove(key);
      if (sym != null) {
        try {
          await _mapController!.removeSymbol(sym);
        } catch (_) {}
      }
    }
  }

  /// After the focus zoom-to-fit animation settles, walks the placed distance
  /// labels and slides any that overlap on screen to a different position
  /// along their ping→repeater line. Uses toScreenLocationBatch to sample
  /// candidate t values (0.5, 0.4, 0.6, 0.3, 0.7, 0.25, 0.75) for each label
  /// and greedily picks the first non-colliding slot.
  Future<void> _reflowDistanceLabelsForCollisions() async {
    if (_mapController == null || !mounted) return;
    if (_focusedPingLocation == null) return;
    if (_distanceLabelSymbols.isEmpty) return;

    final ping = _focusedPingLocation!;
    // Deterministic order: iterate focused repeaters in the list order we got
    // them in (SNR-ranked upstream), so the "primary" label wins t=0.5.
    final orderedIds = _focusedRepeaters
        .map((r) => r.repeater.id)
        .where(_distanceLabelSymbols.containsKey)
        .toList();
    if (orderedIds.isEmpty) return;

    // Candidate t values to try, in preference order.
    const candidateTs = [0.5, 0.4, 0.6, 0.3, 0.7, 0.25, 0.75];

    // Step 1: compute all candidate LatLngs for every label so we can batch
    // the toScreenLocation calls (one round-trip instead of N×T).
    final candidateLatLngs = <LatLng>[];
    for (final id in orderedIds) {
      final repeaterPos = _distanceLabelRepeaterPos[id];
      if (repeaterPos == null) continue;
      for (final t in candidateTs) {
        candidateLatLngs.add(LatLng(
          ping.latitude + (repeaterPos.latitude - ping.latitude) * t,
          ping.longitude + (repeaterPos.longitude - ping.longitude) * t,
        ));
      }
    }

    List<math.Point<num>> screenPoints;
    try {
      screenPoints =
          await _mapController!.toScreenLocationBatch(candidateLatLngs);
    } catch (e) {
      debugError('[MAP] toScreenLocationBatch(distance labels) failed: $e');
      return;
    }
    if (!mounted || _focusedPingLocation == null) return;

    // Step 2: greedily place each label at the first candidate t whose
    // screen rect doesn't overlap any already-placed label rect.
    const gap = 4.0; // extra spacing between pills in logical pixels
    final placedRects = <Rect>[];
    var cursor = 0;
    for (final id in orderedIds) {
      final repeaterPos = _distanceLabelRepeaterPos[id];
      final labelSize = _distanceLabelImageSize[id] ?? const Size(60, 18);
      if (repeaterPos == null) {
        cursor += candidateTs.length;
        continue;
      }

      int bestIdx = 0;
      Rect? bestRect;
      for (var i = 0; i < candidateTs.length; i++) {
        final sp = screenPoints[cursor + i];
        final rect = Rect.fromCenter(
          center: Offset(sp.x.toDouble(), sp.y.toDouble()),
          width: labelSize.width + gap,
          height: labelSize.height + gap,
        );
        final collides = placedRects.any((r) => r.overlaps(rect));
        if (!collides) {
          bestIdx = i;
          bestRect = rect;
          break;
        }
        // Fallback: keep the first candidate rect so we still place somewhere
        // if every slot collides.
        bestRect ??= rect;
      }

      final tChosen = candidateTs[bestIdx];
      final targetLatLng = LatLng(
        ping.latitude + (repeaterPos.latitude - ping.latitude) * tChosen,
        ping.longitude + (repeaterPos.longitude - ping.longitude) * tChosen,
      );
      placedRects.add(bestRect!);

      final symbol = _distanceLabelSymbols[id];
      if (symbol != null) {
        try {
          await _mapController!.updateSymbol(
            symbol,
            SymbolOptions(geometry: targetLatLng),
          );
        } catch (e) {
          debugError('[MAP] updateSymbol(distance reflow) failed: $e');
        }
      }

      cursor += candidateTs.length;
    }
  }

  /// Single entry point that syncs all native annotations against current
  /// app state. Called from the post-frame callback in [build] when the
  /// marker data version changes (so we don't sync on every camera tick).
  Future<void> _syncAllAnnotations(AppStateProvider appState) async {
    await _syncRepeaterSymbols(appState);
    await _syncCoverageSymbols(appState);
    await _syncGpsSymbol(appState);
    await _updateFocusLines();
    await _syncDistanceLabels(appState);
  }

  /// Compute a version hash of all data that affects the marker list.
  /// When this changes, the cached marker list is rebuilt; otherwise it's reused
  /// across camera-change rebuilds (which happen at ~60Hz during pan/zoom).
  ///
  /// Captures **in-place** mutations too: TX pings grow `heardRepeaters` during
  /// the 7s echo window, and DISC entries grow `discoveredNodes` as late
  /// responses land. Summing counts makes the hash sensitive to these additions
  /// even though the parent list length doesn't change.
  int _computeMarkerDataVersion(AppStateProvider appState) {
    int txEchoTotal = 0;
    for (final p in appState.txPings) {
      txEchoTotal += p.heardRepeaters.length;
    }
    int discNodeTotal = 0;
    for (final e in appState.discLogEntries) {
      discNodeTotal += e.discoveredNodes.length;
    }

    return Object.hash(
      appState.txPings.length,
      appState.rxPings.length,
      appState.discLogEntries.length,
      appState.traceLogEntries.length,
      appState.repeaters.length,
      appState.discDropEnabled,
      appState.enforceHopBytes,
      appState.effectiveHopBytes,
      _focusedPingLocation,
      _focusedPingTimestamp,
      _focusedRepeaters.length,
      appState.preferences.gpsMarkerStyle,
      appState.preferences.markerStyle,
      appState.currentPosition?.latitude,
      appState.currentPosition?.longitude,
      _computedHeading,
      txEchoTotal,
      discNodeTotal,
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
  /// Top heard repeaters overlay (bottom-right of map)
  Widget _buildTopRepeatersOverlay(AppStateProvider appState) {
    final topRepeaters = appState.topRepeatersBySnr;
    final rxSlot = appState.rxOverlaySlot;
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
                2: FixedColumnWidth(8), // spacer
                3: IntrinsicColumnWidth(), // SNR
              },
              children: [
                for (final r in topRepeaters)
                  _overlayRow(r.repeaterId, r.snr, _overlayTypeColor(r.type)),
                if (rxSlot != null)
                  _overlayRow(rxSlot.repeaterId, rxSlot.snr,
                      _overlayTypeColor(OverlayPingType.rx)),
              ],
            ),
        ],
      ),
    );
  }

  /// SNR color (delegates to active palette)
  static Color _snrColor(double snr) => PingColors.snrColor(snr);

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
            hasGps
                ? formatMeters(position.accuracy,
                    isImperial: appState.preferences.isImperial)
                : 'No GPS',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color:
                  hasGps ? _getAccuracyColor(position.accuracy) : Colors.grey,
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
              formatMeters(distanceFromLastPing,
                  isImperial: appState.preferences.isImperial),
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
    if (accuracy <= 10) return PingColors.signalGood;
    if (accuracy <= 30) return PingColors.signalMedium;
    return PingColors.signalBad;
  }

  /// Map controls (always vertical, used inside collapsible wrapper)
  Widget _buildMapControls(AppStateProvider appState) {
    final mapStyle =
        MapStyleExtension.fromString(appState.preferences.mapStyle);

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
          if (appState.zoneCode != null) ...[
            _buildControlDivider(),
            _buildControlButton(
              icon: Icons.layers,
              tooltip: _showMeshMapperOverlay
                  ? 'Hide Coverage Overlay'
                  : 'Show Coverage Overlay',
              onPressed: _toggleMeshMapperOverlay,
              isActive: _showMeshMapperOverlay,
            ),
          ],
          _buildControlDivider(),
          // Center on position / toggle auto-follow
          _buildControlButton(
            icon: _autoFollow ? Icons.my_location : Icons.location_searching,
            tooltip: _autoFollow ? 'Following GPS' : 'Center on Position',
            onPressed:
                appState.currentPosition != null ? _centerOnPosition : null,
            isActive: _autoFollow,
          ),
          _buildControlDivider(),
          // Always North toggle
          _buildControlButton(
            icon: _alwaysNorth ? Icons.navigation : Icons.explore,
            tooltip: _alwaysNorth
                ? 'Always North (Click to Rotate with Heading)'
                : 'Rotating with Heading (Click for Always North)',
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
    final currentStyle =
        MapStyleExtension.fromString(appState.preferences.mapStyle);
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
        _autoFollowDesiredZoom = null;
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
      const targetZoom = 17.0; // Street level zoom when enabling follow
      setState(() {
        _autoFollow = true;
        _lastGpsPosition = targetPosition;
        _autoFollowDesiredZoom = targetZoom;
      });
      appState.setMapAutoFollow(true);
      // Bundle target + zoom + bearing into one animation so the
      // initial centering can't be half-cancelled by a racing GPS tick.
      final double targetBearing =
          (!_alwaysNorth && _computedHeading != null) ? _computedHeading! : 0.0;
      final adjustedPosition = _offsetPositionForPadding(
        targetPosition,
        widget.bottomPaddingPixels,
        widget.rightPaddingPixels,
        targetZoom,
        targetBearing,
      );
      _animateAutoFollowCamera(
        target: adjustedPosition,
        zoom: targetZoom,
        bearing: targetBearing,
        durationMs: 500,
      );
    }
  }

  void _toggleMeshMapperOverlay() {
    setState(() {
      _showMeshMapperOverlay = !_showMeshMapperOverlay;
    });
    if (_showMeshMapperOverlay) {
      _addCoverageOverlay(context.read<AppStateProvider>());
    } else {
      _removeCoverageOverlay();
    }
  }

  void _toggleNorthMode() {
    final appState = context.read<AppStateProvider>();
    setState(() {
      _alwaysNorth = !_alwaysNorth;

      // If switching to Always North mode, smoothly rotate map back to north
      if (_alwaysNorth && _isMapReady && _mapController != null) {
        _lastHeading = null;
        final currentBearing = _mapController!.cameraPosition?.bearing ?? 0;
        if (currentBearing.abs() > 2) {
          _mapController!.animateCamera(
            CameraUpdate.bearingTo(0),
            duration: const Duration(milliseconds: 500),
          );
        }
      } else if (!_alwaysNorth && appState.currentPosition != null) {
        // If switching to heading mode, immediately start rotating to current heading
        _lastHeading = null; // Force initial rotation
        // Prefer our derived heading; fall back to whatever GPS reports (may
        // be 0 if we haven't moved yet — better than no rotation at all).
        final initialHeading =
            _computedHeading ?? appState.currentPosition!.heading;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_alwaysNorth && appState.currentPosition != null) {
            _animateToRotation(initialHeading);
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
      if (_rotationLocked &&
          _isMapReady &&
          _alwaysNorth &&
          _mapController != null) {
        final currentBearing = _mapController!.cameraPosition?.bearing ?? 0;
        if (currentBearing.abs() > 2) {
          _mapController!.animateCamera(
            CameraUpdate.bearingTo(0),
            duration: const Duration(milliseconds: 500),
          );
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
                      border:
                          Border.all(color: Colors.blue.withValues(alpha: 0.4)),
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
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outline
                                    .withValues(alpha: 0.3)),
                          ),
                          child: Column(
                            children: [
                              _buildLegendItem(
                                context: context,
                                color: PingColors.txSuccessLegend,
                                label: 'TX',
                                description:
                                    'Location where you sent a ping and heard a repeater',
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.3)),
                              _buildLegendItem(
                                context: context,
                                color: PingColors.txFail,
                                label: 'TX',
                                description:
                                    'Location where you sent a ping but no repeater was heard',
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.3)),
                              _buildLegendItem(
                                context: context,
                                color: PingColors.rx,
                                label: 'RX',
                                description:
                                    'Location where you received a message from the mesh',
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.3)),
                              _buildLegendItem(
                                context: context,
                                color: PingColors.discSuccess,
                                label: 'DISC',
                                description:
                                    'Location where you sent a discovery request and a repeater responded',
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.3)),
                              _buildLegendItem(
                                context: context,
                                color: PingColors.traceSuccess,
                                label: 'TRC',
                                description:
                                    'Location where a trace reached the repeater',
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.2)),
                              _buildLegendItem(
                                context: context,
                                color: PingColors.discFail,
                                label: 'DISC',
                                description:
                                    'Location where you sent a discovery request but no repeater responded',
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.2)),
                              _buildLegendItem(
                                context: context,
                                color: PingColors.noResponse,
                                label: 'TRC',
                                description:
                                    'Location where a trace got no response',
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
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outline
                                    .withValues(alpha: 0.3)),
                          ),
                          child: Column(
                            children: [
                              _buildLayerItem(
                                context: context,
                                color: PingColors.coverageBidir,
                                label: 'BIDIR',
                                description:
                                    'Heard repeats from the mesh AND successfully routed through it',
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.3)),
                              _buildLayerItem(
                                context: context,
                                color: PingColors.coverageDisc,
                                label: 'DISC',
                                description:
                                    'Wardriving app sent a discovery packet and heard a reply',
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.3)),
                              _buildLayerItem(
                                context: context,
                                color: PingColors.coverageTx,
                                label: 'TX',
                                description:
                                    'Successfully routed through, but no repeats heard back',
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.3)),
                              _buildLayerItem(
                                context: context,
                                color: PingColors.coverageRx,
                                label: 'RX',
                                description:
                                    'Heard mesh traffic but did not transmit',
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.3)),
                              _buildLayerItem(
                                context: context,
                                color: PingColors.coverageDead,
                                label: 'DEAD',
                                description:
                                    'Repeater heard it, but no other radio received the repeat',
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.3)),
                              _buildLayerItem(
                                context: context,
                                color: PingColors.coverageDrop,
                                label: 'DROP',
                                description:
                                    'No repeats heard AND no successful route',
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
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outline
                                    .withValues(alpha: 0.3)),
                          ),
                          child: Column(
                            children: [
                              _buildSoundItem(
                                context: context,
                                icon: Icons.cell_tower,
                                label: 'TX Sound',
                                description:
                                    'Plays when sending a ping or discovery request',
                                onPlay: () {
                                  final appState =
                                      context.read<AppStateProvider>();
                                  appState.audioService.playTransmitSound();
                                },
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.3)),
                              _buildSoundItem(
                                context: context,
                                icon: Icons.hearing,
                                label: 'RX Sound',
                                description:
                                    'Plays when a repeater echo or mesh message is received',
                                onPlay: () {
                                  final appState =
                                      context.read<AppStateProvider>();
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
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outline
                                    .withValues(alpha: 0.3)),
                          ),
                          child: Column(
                            children: [
                              _buildHelpItem(
                                context: context,
                                icon: Icons.dark_mode,
                                label: 'Map Style',
                                description:
                                    'Cycle between Dark, Light, and Satellite map styles',
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.3)),
                              _buildHelpItem(
                                context: context,
                                icon: Icons.layers,
                                label: 'Coverage Overlay',
                                description:
                                    'Toggle MeshMapper coverage overlay showing community-reported mesh coverage',
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.3)),
                              _buildHelpItem(
                                context: context,
                                icon: Icons.my_location,
                                label: 'Center/Follow',
                                description:
                                    'Center map on GPS position. Tap again to toggle auto-follow mode',
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.3)),
                              _buildHelpItem(
                                context: context,
                                icon: Icons.navigation,
                                label: 'Always North',
                                description:
                                    'Toggle between always-north orientation or rotate with heading',
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.3)),
                              _buildHelpItem(
                                context: context,
                                icon: Icons.sync_disabled,
                                label: 'Lock Rotation',
                                description:
                                    'Prevent accidental rotation of the map',
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.3)),
                              _buildHelpItem(
                                context: context,
                                icon: Icons.info_outline,
                                label: 'Legend & Info',
                                description:
                                    'Show this help popup with legend and control explanations',
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
                              Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest
                                  .withValues(alpha: 0),
                              Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
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

  /// Build a coverage marker child widget based on the user's marker style preference.
  /// Check if a ping at given lat/lon/timestamp is the currently focused ping.
  /// Used by the native annotation sync to apply focus-mode styling (size,
  /// opacity) to the focused ping vs other pings.
  bool _isFocusedPing(double lat, double lon, DateTime timestamp) {
    return _focusedPingLocation != null &&
        _focusedPingTimestamp == timestamp &&
        _focusedPingLocation!.latitude == lat &&
        _focusedPingLocation!.longitude == lon;
  }

  void _showTraceDetails(TraceLogEntry entry) {
    // Activate focus mode for successful traces with a known repeater
    if (entry.success) {
      final resolved = _resolveRepeatersByHexIds(
        [entry.targetRepeaterId],
        snrValues: [entry.localSnr],
      );
      if (resolved.isNotEmpty) {
        _activatePingFocus(
            LatLng(entry.latitude, entry.longitude), entry.timestamp, resolved);
      }
    }

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      // Transparent barrier so the map stays fully bright during focus mode —
      // the default Colors.black54 scrim would defeat the purpose of focus.
      barrierColor: Colors.transparent,
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
            padding: EdgeInsets.fromLTRB(
                20, 24, 20, 32 + MediaQuery.of(context).viewPadding.bottom),
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
                        border: Border.all(
                            color: Colors.cyan.withValues(alpha: 0.4)),
                      ),
                      child: const Icon(Icons.gps_fixed,
                          color: Colors.cyan, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Trace',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          Text(
                            _formatTime(entry.timestamp),
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .outline
                            .withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.location_on,
                          size: 16,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
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
                      border: Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .outline
                              .withValues(alpha: 0.5)),
                    ),
                    child: Column(
                      children: [
                        // Header row
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              SizedBox(
                                width: _nodeColumnWidth(),
                                child: Text(
                                  'Node',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
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
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
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
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
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
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(
                            height: 1, color: Theme.of(context).dividerColor),
                        // Data row
                        Builder(builder: (context) {
                          final localSnr = entry.localSnr ?? 0;
                          final localRssi = entry.localRssi ?? 0;
                          final remoteSnr = entry.remoteSnr ?? 0;

                          final rxSnrColor = PingColors.snrColor(localSnr);
                          final rssiColor = PingColors.rssiColor(localRssi);
                          final txSnrColor =
                              PingColors.snrColor(remoteSnr.toDouble());

                          return InkWell(
                            onTap: () => RepeaterIdChip.showRepeaterPopup(
                                context, entry.targetRepeaterId, fromLatLng: (
                              lat: entry.latitude,
                              lon: entry.longitude
                            )),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              child: Row(
                                children: [
                                  RepeaterIdChip(
                                      repeaterId: entry.targetRepeaterId,
                                      fontSize: 13,
                                      width: _nodeColumnWidth()),
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
    ).whenComplete(() => _dismissPingFocus());
  }

  /// DISC marker color (delegates to active palette)
  static Color get _discMarkerColor => PingColors.discSuccess;

  /// Repeater marker color - Active (delegates to active palette)
  static Color get _repeaterMarkerColor => PingColors.repeaterActive;

  /// Duplicate repeater marker color (delegates to active palette)
  static Color get _repeaterDuplicateColor => PingColors.repeaterDuplicate;

  /// New repeater marker color (delegates to active palette)
  static Color get _repeaterNewColor => PingColors.repeaterNew;

  /// Dead repeater marker color (delegates to active palette)
  static Color get _repeaterDeadColor => PingColors.repeaterDead;

  /// Get set of duplicate repeater IDs
  /// Resolve heard repeater hex IDs to Repeater objects with GPS coordinates.
  /// Marks matches as ambiguous when a single hex ID matches multiple repeaters.
  /// [snrValues] provides the SNR for each hex ID (same index) for line coloring.
  List<_ResolvedRepeater> _resolveRepeatersByHexIds(
    List<String> hexIds, {
    List<String?> fullHexIds = const [],
    List<double?> snrValues = const [],
  }) {
    final allRepeaters = context.read<AppStateProvider>().repeaters;
    final resolved = <_ResolvedRepeater>[];
    for (int i = 0; i < hexIds.length; i++) {
      final fullHex = i < fullHexIds.length ? fullHexIds[i] : null;
      final snr = i < snrValues.length ? snrValues[i] : null;
      final matchKey = (fullHex != null && fullHex.length >= 8)
          ? fullHex.substring(0, 8)
          : hexIds[i];
      final matches = allRepeaters
          .where(
              (r) => r.hexId.toLowerCase().startsWith(matchKey.toLowerCase()))
          .toList();
      final ambiguous = matches.length > 1;
      resolved.addAll(matches.map((r) => _ResolvedRepeater(r, snr, ambiguous)));
    }
    return resolved;
  }

  /// Activate ping focus mode — draw lines, fade markers, zoom to fit.
  void _activatePingFocus(LatLng pingLocation, DateTime timestamp,
      List<_ResolvedRepeater> repeaters) {
    final pos = _mapController?.cameraPosition;
    _preFocusCenter = pos?.target;
    _preFocusZoom = pos?.zoom;
    _wasAutoFollowBeforeFocus = _autoFollow;
    _wasRotatingBeforeFocus = !_alwaysNorth;

    if (_autoFollow) {
      _autoFollow = false;
    }

    // Lock to north-up during focus so the zoom-to-fit view is stable
    if (!_alwaysNorth) {
      _alwaysNorth = true;
      // Snap rotation to north (instant — avoids wobble before zoom-to-fit animation)
      if (_isMapReady && _mapController != null) {
        _mapController!.animateCamera(
          CameraUpdate.bearingTo(0),
          duration: const Duration(milliseconds: 1),
        );
      }
    }

    setState(() {
      _focusedPingLocation = pingLocation;
      _focusedPingTimestamp = timestamp;
      _focusedRepeaters = repeaters;
    });

    // Hide the MeshMapper coverage raster overlay for a clean focus view.
    // Uses opacity=0 rather than removing the layer to avoid a tile refetch
    // on dismiss. No-ops gracefully if the layer isn't present.
    _applyCoverageOverlayOpacity(0.0);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusedPingLocation != null) {
        _zoomToFocusBounds(pingLocation, repeaters);
      }
    });

    // Once the 500ms zoom-to-fit animation settles, re-flow the distance
    // labels so any that collide on screen slide along their lines to a
    // non-overlapping slot. 600ms gives the camera a bit of buffer beyond
    // the animation duration.
    Future.delayed(const Duration(milliseconds: 600), () {
      if (!mounted || _focusedPingLocation == null) return;
      _reflowDistanceLabelsForCollisions();
    });
  }

  /// Dismiss ping focus mode — restore map state.
  void _dismissPingFocus() {
    if (_focusedPingLocation == null || !mounted) return;

    final center = _preFocusCenter;
    final zoom = _preFocusZoom;
    final shouldRestoreAutoFollow = _wasAutoFollowBeforeFocus && !_autoFollow;
    final shouldRestoreRotation = _wasRotatingBeforeFocus && _alwaysNorth;

    // Clear focus state but do NOT restore auto-follow or rotation yet —
    // they would immediately trigger animations in the build method that
    // override our zoom-back animation (both share _animationController).
    setState(() {
      _focusedPingLocation = null;
      _focusedPingTimestamp = null;
      _focusedRepeaters = [];
    });

    // Restore the MeshMapper coverage raster overlay opacity. Safe if the
    // layer was hidden via the toggle during focus — setLayerProperties is
    // wrapped in try/catch inside the helper.
    final appState = context.read<AppStateProvider>();
    _applyCoverageOverlayOpacity(appState.preferences.coverageOverlayOpacity);

    if (center != null && zoom != null) {
      _animateToPositionWithZoom(center, zoom);

      // Restore auto-follow and heading rotation after the zoom-back
      // animation completes (500ms) so they don't clobber it mid-flight.
      if (shouldRestoreAutoFollow || shouldRestoreRotation) {
        Future.delayed(const Duration(milliseconds: 550), () {
          if (mounted) {
            setState(() {
              if (shouldRestoreAutoFollow) _autoFollow = true;
              if (shouldRestoreRotation) _alwaysNorth = false;
            });
          }
        });
      }
    } else {
      setState(() {
        if (shouldRestoreAutoFollow) _autoFollow = true;
        if (shouldRestoreRotation) _alwaysNorth = false;
      });
    }
  }

  Set<String> _getDuplicateRepeaterIds(List<Repeater> repeaters) {
    final idCounts = <String, int>{};
    for (final repeater in repeaters) {
      idCounts[repeater.id] = (idCounts[repeater.id] ?? 0) + 1;
    }
    return idCounts.entries.where((e) => e.value > 1).map((e) => e.key).toSet();
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

  /// Compute node column width based on hop byte count.
  /// [extraPadding] adds space for additional content (e.g. nodeTypeLabel in DISC popup).
  double _nodeColumnWidth({double extraPadding = 0}) {
    final appState = context.read<AppStateProvider>();
    final hopBytes = appState.enforceHopBytes
        ? appState.effectiveHopBytes
        : appState.hopBytes;
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

    // Activate focus mode if the ping was heard by known repeaters
    if (heardRepeaters.isNotEmpty) {
      final resolved = _resolveRepeatersByHexIds(
        heardRepeaters.map((r) => r.repeaterId).toList(),
        snrValues: heardRepeaters.map((r) => r.snr).toList(),
      );
      if (resolved.isNotEmpty) {
        _activatePingFocus(
            LatLng(ping.latitude, ping.longitude), ping.timestamp, resolved);
      }
    }

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      // Transparent barrier so the map stays fully bright during focus mode —
      // the default Colors.black54 scrim would defeat the purpose of focus.
      barrierColor: Colors.transparent,
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
            padding: EdgeInsets.fromLTRB(
                20, 24, 20, 32 + MediaQuery.of(context).viewPadding.bottom),
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
                        color: PingColors.txSuccess.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: PingColors.txSuccess.withValues(alpha: 0.4)),
                      ),
                      child: Icon(Icons.arrow_upward,
                          color: PingColors.txSuccess, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'TX Ping',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          Text(
                            _formatTime(ping.timestamp),
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .outline
                            .withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.location_on,
                          size: 16,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
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
                  heardRepeaters.isEmpty
                      ? 'No repeaters heard'
                      : 'Heard Repeaters (${heardRepeaters.length})',
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
                      border: Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .outline
                              .withValues(alpha: 0.5)),
                    ),
                    child: Column(
                      children: [
                        // Header row
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              SizedBox(
                                width: _nodeColumnWidth(),
                                child: Text(
                                  'Node',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
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
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
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
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(
                            height: 1, color: Theme.of(context).dividerColor),
                        // Data rows
                        ...heardRepeaters.map((repeater) {
                          final snrColor = repeater.snr != null
                              ? PingColors.snrColor(repeater.snr!)
                              : Colors.grey;
                          final rssiColor = repeater.rssi != null
                              ? PingColors.rssiColor(repeater.rssi!)
                              : Colors.grey;

                          return InkWell(
                            onTap: () => RepeaterIdChip.showRepeaterPopup(
                                context, repeater.repeaterId, fromLatLng: (
                              lat: ping.latitude,
                              lon: ping.longitude
                            )),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              child: Row(
                                children: [
                                  // Repeater ID
                                  RepeaterIdChip(
                                      repeaterId: repeater.repeaterId,
                                      fontSize: 13,
                                      width: _nodeColumnWidth()),
                                  // SNR
                                  Expanded(
                                    child: Center(
                                      child: _buildStatChip(
                                        value:
                                            repeater.snr?.toStringAsFixed(1) ??
                                                '-',
                                        color: snrColor,
                                      ),
                                    ),
                                  ),
                                  // RSSI
                                  Expanded(
                                    child: Center(
                                      child: _buildStatChip(
                                        value: repeater.rssi != null
                                            ? '${repeater.rssi}'
                                            : '-',
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
    ).whenComplete(() => _dismissPingFocus());
  }

  /// Show RX ping details popup
  void _showRxPingDetails(RxPing ping) {
    final snrColor = PingColors.snrColor(ping.snr);
    final rssiColor = PingColors.rssiColor(ping.rssi);

    // Activate focus mode for the RX ping's repeater
    final resolved = _resolveRepeatersByHexIds(
      [ping.repeaterId],
      snrValues: [ping.snr],
    );
    if (resolved.isNotEmpty) {
      _activatePingFocus(
          LatLng(ping.latitude, ping.longitude), ping.timestamp, resolved);
    }

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      // Transparent barrier so the map stays fully bright during focus mode —
      // the default Colors.black54 scrim would defeat the purpose of focus.
      barrierColor: Colors.transparent,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Container(
        padding: EdgeInsets.fromLTRB(
            20, 24, 20, 32 + MediaQuery.of(context).viewPadding.bottom),
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
                    border:
                        Border.all(color: Colors.blue.withValues(alpha: 0.4)),
                  ),
                  child: const Icon(Icons.arrow_downward,
                      color: Colors.blue, size: 24),
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
                border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .outline
                        .withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  Icon(Icons.location_on,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .outline
                        .withValues(alpha: 0.5)),
              ),
              child: Column(
                children: [
                  // Header row
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        SizedBox(
                          width: _nodeColumnWidth(),
                          child: Text(
                            'Node',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
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
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
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
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: Theme.of(context).dividerColor),
                  // Data row
                  InkWell(
                    onTap: () => RepeaterIdChip.showRepeaterPopup(
                        context, ping.repeaterId,
                        fromLatLng: (lat: ping.latitude, lon: ping.longitude)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          // Repeater ID
                          RepeaterIdChip(
                              repeaterId: ping.repeaterId,
                              fontSize: 13,
                              width: _nodeColumnWidth()),
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
    ).whenComplete(() => _dismissPingFocus());
  }

  /// Show DISC ping details popup
  void _showDiscPingDetails(DiscLogEntry entry) {
    // Activate focus mode for discovered nodes with known repeater positions
    if (entry.discoveredNodes.isNotEmpty) {
      final resolved = _resolveRepeatersByHexIds(
        entry.discoveredNodes.map((n) => n.repeaterId).toList(),
        fullHexIds: entry.discoveredNodes.map((n) => n.pubkeyHex).toList(),
        snrValues:
            entry.discoveredNodes.map((n) => n.localSnr as double?).toList(),
      );
      if (resolved.isNotEmpty) {
        _activatePingFocus(
            LatLng(entry.latitude, entry.longitude), entry.timestamp, resolved);
      }
    }

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      // Transparent barrier so the map stays fully bright during focus mode —
      // the default Colors.black54 scrim would defeat the purpose of focus.
      barrierColor: Colors.transparent,
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
            padding: EdgeInsets.fromLTRB(
                20, 24, 20, 32 + MediaQuery.of(context).viewPadding.bottom),
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
                        border: Border.all(
                            color: _discMarkerColor.withValues(alpha: 0.4)),
                      ),
                      child:
                          Icon(Icons.radar, color: _discMarkerColor, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Disc Request',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          Text(
                            _formatTime(entry.timestamp),
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .outline
                            .withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.location_on,
                          size: 16,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
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
                      border: Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .outline
                              .withValues(alpha: 0.5)),
                    ),
                    child: Column(
                      children: [
                        // Header row
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              SizedBox(
                                width: _nodeColumnWidth(extraPadding: 20),
                                child: Text(
                                  'Node',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
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
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
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
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
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
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(
                            height: 1, color: Theme.of(context).dividerColor),
                        // Data rows
                        ...entry.discoveredNodes.map((node) {
                          final rxSnrColor = PingColors.snrColor(node.localSnr);
                          final rssiColor =
                              PingColors.rssiColor(node.localRssi);
                          final txSnrColor =
                              PingColors.snrColor(node.remoteSnr.toDouble());

                          return InkWell(
                            onTap: () => RepeaterIdChip.showRepeaterPopup(
                                context, node.repeaterId,
                                fullHexId: node.pubkeyHex,
                                fromLatLng: (
                                  lat: entry.latitude,
                                  lon: entry.longitude
                                )),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              child: Row(
                                children: [
                                  // Node ID with type
                                  SizedBox(
                                    width: _nodeColumnWidth(extraPadding: 20),
                                    child: Row(
                                      children: [
                                        RepeaterIdChip(
                                            repeaterId: node.repeaterId,
                                            fontSize: 13),
                                        Text(
                                          node.nodeTypeLabel,
                                          style: TextStyle(
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
                                        value:
                                            node.remoteSnr.toStringAsFixed(1),
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
    ).whenComplete(() => _dismissPingFocus());
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
  void _showRepeaterDetails(Repeater repeater,
      {bool isDuplicate = false, int? regionHopBytesOverride}) {
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
        padding: EdgeInsets.fromLTRB(
            20, 24, 20, 32 + MediaQuery.of(context).viewPadding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header with icon badge (containing ID) and name
            Row(
              children: [
                // Icon badge with hex ID (mirrors map marker)
                Builder(builder: (context) {
                  final displayId = repeater.displayHexId(
                      overrideHopBytes: regionHopBytesOverride);
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
                  _buildRepeaterStatusChip(
                      'Duplicate', _repeaterDuplicateColor),
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
                border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .outline
                        .withValues(alpha: 0.5)),
              ),
              child: Column(
                children: [
                  // Location row
                  Row(
                    children: [
                      Icon(Icons.location_on,
                          size: 16,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
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
                      Icon(Icons.access_time,
                          size: 16,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
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
  const _ArrowPainter();

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

/// Paints a car silhouette for GPS position marker
class _CarMarkerPainter extends CustomPainter {
  const _CarMarkerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // White outline
    final outlinePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    // Car body outline (rounded rect, slightly larger)
    final outlineRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy), width: 14, height: 20),
      const Radius.circular(4),
    );
    canvas.drawRRect(outlineRect, outlinePaint);

    // Blue car body
    final bodyPaint = Paint()
      ..color = const Color(0xFF2196F3)
      ..style = PaintingStyle.fill;

    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy), width: 11, height: 17),
      const Radius.circular(3),
    );
    canvas.drawRRect(bodyRect, bodyPaint);

    // Windshield (darker blue rectangle near top)
    final windshieldPaint = Paint()
      ..color = const Color(0xFF1565C0)
      ..style = PaintingStyle.fill;
    final windshieldRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy - 3), width: 7, height: 4),
      const Radius.circular(1),
    );
    canvas.drawRRect(windshieldRect, windshieldPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Paints a bicycle silhouette for GPS position marker
class _BikeMarkerPainter extends CustomPainter {
  const _BikeMarkerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    final outlinePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    final bikePaint = Paint()
      ..color = const Color(0xFF2196F3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    final fillPaint = Paint()
      ..color = const Color(0xFF2196F3)
      ..style = PaintingStyle.fill;

    // Two wheels
    const wheelR = 4.0;
    final leftWheel = Offset(cx - 5, cy + 3);
    final rightWheel = Offset(cx + 5, cy + 3);

    // White outlines for wheels
    canvas.drawCircle(leftWheel, wheelR + 1, outlinePaint);
    canvas.drawCircle(rightWheel, wheelR + 1, outlinePaint);

    // Frame outline
    final framePath = ui.Path()
      ..moveTo(leftWheel.dx, leftWheel.dy)
      ..lineTo(cx, cy - 5) // Up to handlebars
      ..lineTo(rightWheel.dx, rightWheel.dy) // Down to rear
      ..moveTo(cx, cy - 5)
      ..lineTo(cx + 2, cy - 7); // Handlebar
    canvas.drawPath(
        framePath,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round);

    // Blue wheels
    canvas.drawCircle(leftWheel, wheelR, bikePaint);
    canvas.drawCircle(rightWheel, wheelR, bikePaint);

    // Blue frame
    canvas.drawPath(framePath, bikePaint);

    // Seat dot
    canvas.drawCircle(Offset(cx - 1, cy - 4), 1.5, fillPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Paints a boat silhouette for GPS position marker
class _BoatMarkerPainter extends CustomPainter {
  const _BoatMarkerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // White outline
    final outlinePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final fillPaint = Paint()
      ..color = const Color(0xFF2196F3)
      ..style = PaintingStyle.fill;

    // Hull outline (wider)
    final hullOutline = ui.Path()
      ..moveTo(cx - 9, cy + 1)
      ..lineTo(cx - 6, cy + 8)
      ..lineTo(cx + 6, cy + 8)
      ..lineTo(cx + 9, cy + 1)
      ..close();
    canvas.drawPath(hullOutline, outlinePaint);

    // Hull fill
    final hull = ui.Path()
      ..moveTo(cx - 7, cy + 2)
      ..lineTo(cx - 5, cy + 7)
      ..lineTo(cx + 5, cy + 7)
      ..lineTo(cx + 7, cy + 2)
      ..close();
    canvas.drawPath(hull, fillPaint);

    // Mast outline
    canvas.drawLine(
        Offset(cx, cy + 2),
        Offset(cx, cy - 9),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round);
    // Mast
    canvas.drawLine(
        Offset(cx, cy + 2),
        Offset(cx, cy - 9),
        Paint()
          ..color = const Color(0xFF2196F3)
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round);

    // Sail outline
    final sailOutline = ui.Path()
      ..moveTo(cx + 1, cy - 8)
      ..lineTo(cx + 7, cy)
      ..lineTo(cx + 1, cy)
      ..close();
    canvas.drawPath(sailOutline, outlinePaint);

    // Sail
    final sail = ui.Path()
      ..moveTo(cx + 1, cy - 7)
      ..lineTo(cx + 6, cy - 0.5)
      ..lineTo(cx + 1, cy - 0.5)
      ..close();
    canvas.drawPath(
        sail,
        Paint()
          ..color = const Color(0xFF64B5F6)
          ..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Paints a walking person silhouette for GPS position marker
class _WalkMarkerPainter extends CustomPainter {
  const _WalkMarkerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    final outlinePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    final personPaint = Paint()
      ..color = const Color(0xFF2196F3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    final fillPaint = Paint()
      ..color = const Color(0xFF2196F3)
      ..style = PaintingStyle.fill;

    // Head outline + fill
    canvas.drawCircle(
        Offset(cx, cy - 7),
        3.5,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.fill);
    canvas.drawCircle(Offset(cx, cy - 7), 2.5, fillPaint);

    // Body outline
    canvas.drawLine(Offset(cx, cy - 4), Offset(cx, cy + 3), outlinePaint);
    // Body
    canvas.drawLine(Offset(cx, cy - 4), Offset(cx, cy + 3), personPaint);

    // Arms outline
    canvas.drawLine(
        Offset(cx - 5, cy - 1), Offset(cx + 5, cy - 1), outlinePaint);
    // Arms
    canvas.drawLine(
        Offset(cx - 5, cy - 1), Offset(cx + 5, cy - 1), personPaint);

    // Left leg outline
    canvas.drawLine(Offset(cx, cy + 3), Offset(cx - 4, cy + 10), outlinePaint);
    // Right leg outline
    canvas.drawLine(Offset(cx, cy + 3), Offset(cx + 4, cy + 10), outlinePaint);
    // Left leg
    canvas.drawLine(Offset(cx, cy + 3), Offset(cx - 4, cy + 10), personPaint);
    // Right leg
    canvas.drawLine(Offset(cx, cy + 3), Offset(cx + 4, cy + 10), personPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Paints a Chomper (cyan wedge) GPS position marker — mouth faces up (direction of travel)
class _ChomperMarkerPainter extends CustomPainter {
  const _ChomperMarkerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    const radius = 10.0;

    // Mouth opening angle: 70° total (35° each side of the top)
    // In canvas coordinates, 0° = 3 o'clock, so "up" = -90° = -π/2.
    // Arc sweeps clockwise. We start at (-90 + 35)° and sweep (360 - 70)°.
    const mouthAngle = 70.0 * (math.pi / 180);
    const startAngle = -math.pi / 2 + mouthAngle / 2; // right edge of mouth
    const sweepAngle = 2 * math.pi - mouthAngle;

    // White outline for visibility
    final outlinePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final outlinePath = ui.Path()
      ..moveTo(cx, cy)
      ..arcTo(
        Rect.fromCircle(center: Offset(cx, cy), radius: radius + 1.5),
        startAngle,
        sweepAngle,
        false,
      )
      ..close();
    canvas.drawPath(outlinePath, outlinePaint);

    // Cyan body
    final bodyPaint = Paint()
      ..color = const Color(0xFF00BCD4)
      ..style = PaintingStyle.fill;

    final bodyPath = ui.Path()
      ..moveTo(cx, cy)
      ..arcTo(
        Rect.fromCircle(center: Offset(cx, cy), radius: radius),
        startAngle,
        sweepAngle,
        false,
      )
      ..close();
    canvas.drawPath(bodyPath, bodyPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Paints a teardrop/pin marker for coverage dots
class _PinMarkerPainter extends CustomPainter {
  final Color color;
  const _PinMarkerPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final outlinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);

    const headRadius = 6.0;
    final headCenter = Offset(cx, cy - 2);
    final tipY = cy + 9;

    // Combined shadow
    final pinPath = ui.Path()
      ..addOval(Rect.fromCircle(center: headCenter, radius: headRadius))
      ..moveTo(cx - 4, cy + 1)
      ..lineTo(cx, tipY)
      ..lineTo(cx + 4, cy + 1)
      ..close();
    canvas.drawPath(pinPath, shadowPaint);

    // Triangle point
    final triPath = ui.Path()
      ..moveTo(cx - 4, cy + 1)
      ..lineTo(cx, tipY)
      ..lineTo(cx + 4, cy + 1)
      ..close();
    canvas.drawPath(triPath, fillPaint);

    // Circle head
    canvas.drawCircle(headCenter, headRadius, fillPaint);
    canvas.drawCircle(headCenter, headRadius, outlinePaint);

    // Inner dot
    canvas.drawCircle(
        headCenter, 2.0, Paint()..color = Colors.white.withValues(alpha: 0.9));
  }

  @override
  bool shouldRepaint(covariant _PinMarkerPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Paints a diamond marker for coverage dots
class _DiamondMarkerPainter extends CustomPainter {
  final Color color;
  const _DiamondMarkerPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    final outlinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);

    final path = ui.Path()
      ..moveTo(cx, cy - 8) // Top
      ..lineTo(cx + 8, cy) // Right
      ..lineTo(cx, cy + 8) // Bottom
      ..lineTo(cx - 8, cy) // Left
      ..close();

    canvas.drawPath(path, shadowPaint);
    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, outlinePaint);
  }

  @override
  bool shouldRepaint(covariant _DiamondMarkerPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Paints a repeater marker shape (filled colored rounded box with white border
/// and drop shadow). Used at startup to generate bitmap variants for native
/// MapLibre symbols. The text (hex ID) is rendered separately by the symbol's
/// `textField` property at runtime — this painter only draws the box itself.
class _RepeaterShapePainter extends CustomPainter {
  final Color fillColor;
  final double borderRadius;

  const _RepeaterShapePainter({
    required this.fillColor,
    required this.borderRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Inset the box by the shadow blur amount so the shadow has room to draw
    const shadowBlur = 4.0;
    final boxRect = Rect.fromLTWH(
      shadowBlur,
      shadowBlur,
      size.width - 2 * shadowBlur,
      size.height - 2 * shadowBlur,
    );

    // Drop shadow (positioned 2px below the box)
    final shadowPaint = Paint()
      ..color = Colors.black26
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, shadowBlur);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        boxRect.shift(const Offset(0, 2)),
        Radius.circular(borderRadius),
      ),
      shadowPaint,
    );

    // Filled colored box
    final fillPaint = Paint()..color = fillColor;
    canvas.drawRRect(
      RRect.fromRectAndRadius(boxRect, Radius.circular(borderRadius)),
      fillPaint,
    );

    // White border (2px wide, drawn inside the box edge)
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final innerRect = boxRect.deflate(1);
    canvas.drawRRect(
      RRect.fromRectAndRadius(innerRect, Radius.circular(borderRadius - 1)),
      borderPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _RepeaterShapePainter old) =>
      old.fillColor != fillColor || old.borderRadius != borderRadius;
}

/// Paints a coverage ping marker (TX/RX/DISC/Trace) in one of the four user
/// styles. Used at startup to generate bitmap variants for native MapLibre
/// symbols. Reuses _PinMarkerPainter and _DiamondMarkerPainter for those styles.
class _CoverageMarkerPainter extends CustomPainter {
  final String style; // 'circle' / 'pin' / 'diamond' / 'dot'
  final Color color;

  const _CoverageMarkerPainter({required this.style, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    // Visible glyph area — the canvas is typically larger (40×40) so the
    // surrounding pixels stay transparent, giving MapLibre a bigger native
    // tap hit target without enlarging the actual marker visual.
    const innerSize = Size(24, 24);
    final dx = (size.width - innerSize.width) / 2;
    final dy = (size.height - innerSize.height) / 2;
    canvas.save();
    canvas.translate(dx, dy);
    switch (style) {
      case 'pin':
        _PinMarkerPainter(color).paint(canvas, innerSize);
        break;
      case 'diamond':
        _DiamondMarkerPainter(color).paint(canvas, innerSize);
        break;
      case 'circle':
        _paintCircle(canvas, innerSize, borderAlpha: 1.0, borderWidth: 2.0);
        break;
      case 'dot':
      default:
        _paintCircle(canvas, innerSize, borderAlpha: 0.6, borderWidth: 1.5);
        break;
    }
    canvas.restore();
  }

  void _paintCircle(Canvas canvas, Size size,
      {required double borderAlpha, required double borderWidth}) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 2;

    // Drop shadow (slightly below)
    final shadowPaint = Paint()
      ..color = Colors.black12
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    canvas.drawCircle(center.translate(0, 1), radius, shadowPaint);

    // Filled circle
    canvas.drawCircle(center, radius, Paint()..color = color);

    // White border
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white.withValues(alpha: borderAlpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = borderWidth,
    );
  }

  @override
  bool shouldRepaint(covariant _CoverageMarkerPainter old) =>
      old.style != style || old.color != color;
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
                  color: _isPlaying
                      ? Colors.blue
                      : Colors.blue.withValues(alpha: 0.5),
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
