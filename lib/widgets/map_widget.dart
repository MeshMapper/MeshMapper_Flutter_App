import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
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
import 'rx_path_chain.dart';

/// Satellite style as inline MapLibre style JSON (ArcGIS raster source).
/// The `glyphs` URL is required because our native symbol layers
/// (repeater cluster count, individual repeater hex IDs, distance labels)
/// use `textField`, and MapLibre iOS wedges its resource loader with
/// NSURLError -1002 if it tries to resolve glyphs against a style that
/// doesn't declare a glyphs URL.
const _satelliteStyleJson =
    '{"version":8,"glyphs":"https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf","sources":{"satellite":{"type":"raster","tiles":["https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"],"tileSize":256,"maxzoom":17}},"layers":[{"id":"satellite-layer","type":"raster","source":"satellite"}]}';

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

  /// Whether this style can be packaged as an offline region. Satellite uses
  /// inline raster JSON which MapLibre's offline downloader doesn't support.
  bool get isDownloadable {
    switch (this) {
      case MapStyle.dark:
      case MapStyle.light:
      case MapStyle.liberty:
        return true;
      case MapStyle.satellite:
        return false;
    }
  }

  /// Styles offered in the offline download picker.
  static List<MapStyle> get downloadable =>
      MapStyle.values.where((s) => s.isDownloadable).toList();
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

class _MapWidgetState extends State<MapWidget> with WidgetsBindingObserver {
  MapLibreMapController? _mapController;

  // Tracks the app lifecycle so we can suppress every animateCamera() call
  // while the app is not in the foreground OR while the GL surface is
  // settling after a state transition. MapLibre Native's
  // constrainCameraAndZoomToBounds (PR #2475) calls Projection::unproject
  // internally — when the GL surface is degenerate (zero-sized on first
  // frame, or not yet restored after iOS background suspension), unproject
  // produces NaN and the LatLng constructor throws std::domain_error →
  // SIGABRT. Suppressing animations for one frame after style-load and
  // after resume lets the surface reach a valid state first.
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  bool _cameraAnimationReady = false;
  bool get _canAnimateCamera =>
      _appLifecycleState == AppLifecycleState.resumed &&
      _cameraAnimationReady;

  // Auto-follow GPS like a navigation app
  bool _autoFollow = false; // Disabled by default - users often zoom out first
  bool _prefsApplied = false; // Guard to load saved prefs only once
  bool _isMapReady = false;
  LatLng? _lastGpsPosition;
  bool _hasInitialZoomed =
      false; // Track if we've done the one-time initial zoom to GPS
  bool _hasZoomedToLastKnown =
      false; // Track if we've zoomed to last known position (before GPS)
  bool _loggedMpxSanityCheck =
      false; // One-time log comparing formula vs MapLibre m/px

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

  // Double-buffered coverage overlay: each refresh allocates fresh suffixed
  // IDs so the new raster source/layer can be added on top of the previous
  // one and rendered before the old layer is removed. This prevents the
  // brief blank frame the user previously saw every cache-bust cycle.
  String? _activeCoverageSourceId;
  String? _activeCoverageLayerId;
  int _coverageBufferCounter = 0;
  // One-shot completer released by _onMapIdle (or the timeout fallback) to
  // signal the swap that new tiles have rendered and the old layer is safe
  // to remove. Null when no swap is in flight.
  Completer<void>? _coverageSwapIdleCompleter;
  Timer? _coverageSwapTimeoutTimer;
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

  // GPS marker sync runs on its own gate, separate from _syncAllAnnotations.
  // GPS position is camera/sensor state — it changes every tick during
  // auto-follow but the marker data (repeaters, pings, focus) does not.
  // Routing GPS through _syncAllAnnotations made setGeoJsonSource fire on
  // every tick, which triggered MapLibre's global symbol-collision recalc
  // and made base-style POI labels flicker. Splitting the gates keeps
  // _syncGpsSymbol cheap and lets _syncAllAnnotations idle when nothing
  // marker-related has changed.
  int _lastGpsSyncVersion = -1;
  bool _gpsSyncInFlight = false;

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

  // True while the focus-lines source + 1-2 line layers are installed in the
  // current style. Lets _updateFocusLines short-circuit when there's nothing
  // to remove and nothing to add — touching MapLibre's layer stack (even with
  // no-op removes that hit try/catch) crosses the platform channel and can
  // nudge the symbol-collision pass.
  bool _focusLinesInstalled = false;

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

  // Spiderfy source/layer IDs — non-clustered shadow source rendering spread
  // markers + leader lines for stacked repeaters that won't separate by zoom.
  static const _spiderSourceId = 'spider-source';
  static const _spiderLineLayerId = 'spider-leader-lines';
  static const _spiderSymbolLayerId = 'spider-symbols';
  // Matches the main source's clusterRadius (50px). Reused by the spiderfy
  // group-detection logic: pairs of repeaters within `clusterRadius × m/px
  // at the user's max zoom` of each other will visually overlap even when
  // fully zoomed in, so they're the candidates that won't be separated by
  // additional zoom and need to be spread apart instead.
  static const double _clusterRadiusPx = 50;
  static const double _spiderInnerRadiusPx = 44;
  static const double _spiderOuterRadiusPx = 80;
  static const double _leaderLineEndShortenPx = 8;
  // Camera-zoom delta past which an open spider must collapse (positions are
  // pixel-radius derived and become wrong if the user zooms far enough).
  static const double _spiderCollapseZoomDelta = 0.25;

  // Regional boundary (from /border API — always visible)
  static const _regionBorderSourceId = 'region-border-source';
  static const _regionBorderLineLayerId = 'region-border-line';
  static const _regionBorderLabelLayerId = 'region-border-label';
  int _lastBordersSignature = -1;

  // Tracks which marker style preference the coverage images are currently
  // registered for. When the user changes their preference, we re-register.
  String? _registeredCoverageStyle;

  // True after _registerMapImages() finishes — gates symbol creation.
  bool _imagesRegistered = false;

  // Last bearing seen by camera listener (for non-rotating GPS counter-rotation)
  double _lastBearing = 0;

  // Spiderfy state — when non-null, a stack of stacked repeaters has been
  // fanned out around _spiderCenter into the shadow `spider-source`.
  // Lifecycle: set by _spiderfy(), cleared by _collapseSpider().
  LatLng? _spiderCenter;
  List<Repeater> _spiderRepeaters = const [];
  // Captured on _spiderfy() so _onCameraChanged can detect a zoom delta past
  // _spiderCollapseZoomDelta and collapse (positions become invalid).
  double? _spiderOpenedAtZoom;

  // Default center (Ottawa)
  static const LatLng _defaultCenter = LatLng(45.4215, -75.6972);
  static const double _defaultZoom = 15.0; // Closer zoom for driving

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appLifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasBackground = _appLifecycleState != AppLifecycleState.resumed;
    _appLifecycleState = state;

    if (state != AppLifecycleState.resumed) {
      // Going to background — block camera animations immediately.
      _cameraAnimationReady = false;
    } else if (wasBackground && _isMapReady) {
      // Resuming from background — GL surface needs a frame to restore
      // before constrainCameraAndZoomToBounds can project without NaN.
      _cameraAnimationReady = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _cameraAnimationReady = true;
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tileLoadTimeoutTimer?.cancel();
    _coverageSwapTimeoutTimer?.cancel();
    final swapWaiter = _coverageSwapIdleCompleter;
    if (swapWaiter != null && !swapWaiter.isCompleted) {
      swapWaiter.complete();
    }
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

    // If a spider is open and the user has zoomed past the collapse-delta
    // threshold, drop the spider — pixel-radius spread positions are now wrong
    // for the new zoom. Pure pan never crosses this threshold (zoom doesn't
    // change), so the spider follows pan naturally via its geo coordinates.
    // Once `_spiderCenter` is null after collapse, this branch no-ops.
    if (_spiderCenter != null && _spiderOpenedAtZoom != null) {
      if ((pos.zoom - _spiderOpenedAtZoom!).abs() > _spiderCollapseZoomDelta) {
        _collapseSpider();
      }
    }

    if ((pos.bearing - _lastBearing).abs() < 0.5) return;
    _lastBearing = pos.bearing;
    _updateGpsSymbolRotation();
  }

  @override
  void didUpdateWidget(MapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When padding changes (panel opened/closed/minimized/orientation change), re-center if auto-following
    final paddingChanged =
        widget.bottomPaddingPixels != oldWidget.bottomPaddingPixels ||
            widget.rightPaddingPixels != oldWidget.rightPaddingPixels;
    if (paddingChanged) {
      debugLog('[MAP CENTER] didUpdateWidget padding change: '
          'bottom ${oldWidget.bottomPaddingPixels}->${widget.bottomPaddingPixels} '
          'right ${oldWidget.rightPaddingPixels}->${widget.rightPaddingPixels} '
          '_autoFollow=$_autoFollow _isMapReady=$_isMapReady '
          '_lastGpsPosition=${_lastGpsPosition != null}');
    }
    if (paddingChanged &&
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
          final cam = _mapController?.cameraPosition;
          debugLog('[MAP CENTER] re-center after padding change: '
              'gps=(${_lastGpsPosition!.latitude.toStringAsFixed(6)},${_lastGpsPosition!.longitude.toStringAsFixed(6)}) '
              'target=(${adjustedPosition.latitude.toStringAsFixed(6)},${adjustedPosition.longitude.toStringAsFixed(6)}) '
              'deltaLat=${(adjustedPosition.latitude - _lastGpsPosition!.latitude).toStringAsFixed(6)} '
              'deltaLon=${(adjustedPosition.longitude - _lastGpsPosition!.longitude).toStringAsFixed(6)} '
              'zoom=${targetZoom.toStringAsFixed(2)} bearing=${targetBearing.toStringAsFixed(2)} '
              'curZoom=${cam?.zoom.toStringAsFixed(2)} curBearing=${cam?.bearing.toStringAsFixed(2)} '
              'alwaysNorth=$_alwaysNorth');
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
    if (_mapController == null ||
        !_isMapReady ||
        !mounted ||
        !_canAnimateCamera) {
      return;
    }
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
    if (_mapController == null ||
        !_isMapReady ||
        !mounted ||
        !_canAnimateCamera) {
      return;
    }
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
    if (_mapController == null ||
        !_isMapReady ||
        !mounted ||
        !_canAnimateCamera) {
      return;
    }

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
    if (_mapController == null ||
        !_isMapReady ||
        !mounted ||
        _alwaysNorth ||
        !_canAnimateCamera) {
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

    // MapLibre's internal projection uses 512-logical-px tile units (see
    // MapLibre style spec — vector and raster sources are reprojected onto a
    // 512px grid regardless of source tile size). The previous formula here
    // assumed 256-px tiles, which made every offset 2× too large and pushed
    // the GPS marker far above the visible-area centre.
    final zoom = atZoom ?? _mapController!.cameraPosition?.zoom ?? _defaultZoom;
    final metersPerPixel = 40075000 /
        (512 * math.pow(2, zoom)) *
        math.cos(position.latitude * math.pi / 180);

    // One-time sanity check: log MapLibre's authoritative m/px and compare
    // to our formula. If they differ, the tile-size assumption is wrong.
    if (!_loggedMpxSanityCheck) {
      _loggedMpxSanityCheck = true;
      _mapController!
          .getMetersPerPixelAtLatitude(position.latitude)
          .then((mapLibreMpx) {
        debugLog('[MAP CENTER] m/px sanity: formula=${metersPerPixel.toStringAsFixed(4)} '
            'maplibre=${mapLibreMpx.toStringAsFixed(4)} '
            'ratio=${(metersPerPixel / mapLibreMpx).toStringAsFixed(3)} '
            '(zoom=${zoom.toStringAsFixed(2)} lat=${position.latitude.toStringAsFixed(4)})');
      }).catchError((e) {
        debugLog('[MAP CENTER] m/px sanity check failed: $e');
      });
    }

    // Compute the desired camera shift in WORLD METERS along the
    // (north, east) axes. Working in metres up front avoids the previous
    // unit-mixing bug, where lat-degrees and lon-degrees were rotated as if
    // they were the same unit (1° lat ≠ 1° lon away from the equator).
    //
    // We want the marker (at `position`) to appear shifted "screen-up" by
    // `bottomPadding/2` and "screen-left" by `rightPadding/2` relative to
    // screen centre, so the camera target itself shifts in the opposite
    // direction (screen-down + screen-right).
    final bearingDeg =
        atBearing ?? _mapController!.cameraPosition?.bearing ?? 0;
    final bearingRad = bearingDeg * math.pi / 180;
    final cosB = math.cos(bearingRad);
    final sinB = math.sin(bearingRad);

    // At bearing β (clockwise from north), world unit-vectors of the
    // screen axes are:
    //   screen-down  = (-cosβ, -sinβ)   in (north, east)
    //   screen-right = (-sinβ,  cosβ)
    final downMetres = bottomPadding / 2 * metersPerPixel;
    final rightMetres = rightPadding / 2 * metersPerPixel;
    final northShift = downMetres * -cosB + rightMetres * -sinB;
    final eastShift = downMetres * -sinB + rightMetres * cosB;

    // Convert metres → degrees. 1° latitude ≈ 111 km everywhere; 1° longitude
    // shrinks by cos(latitude).
    final latOffset = northShift / 111000;
    final lonOffset =
        eastShift / (111000 * math.cos(position.latitude * math.pi / 180));

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
        _isMapReady &&
        _canAnimateCamera) {
      _hasZoomedToLastKnown = true;
      final lastKnownCenter = LatLng(
        appState.lastKnownPosition!.lat,
        appState.lastKnownPosition!.lon,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _animateToPositionWithZoom(lastKnownCenter, 15.0 - _zoomEpsilon);
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
      if (!_hasInitialZoomed && _isMapReady && _canAnimateCamera) {
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
                  16.0 - _zoomEpsilon);
              _animateToPositionWithZoom(
                  adjustedPosition, 16.0 - _zoomEpsilon);
              debugLog(
                  '[MAP] Initial zoom to GPS position (with panel offset)');
            } else {
              _animateToPositionWithZoom(initialPosition, 16.0 - _zoomEpsilon);
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
            if (currentBearing.abs() > 2 && _canAnimateCamera) {
              _mapController!.animateCamera(CameraUpdate.bearingTo(0));
            }

            // Animate to the exact target position (no offset)
            _animateToPositionWithZoom(targetPosition, 18.0 - _zoomEpsilon);
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

    // GPS marker has its own lightweight gate. Position/heading change every
    // GPS tick during auto-follow, but updating the GPS symbol is one cheap
    // updateSymbol call — it does not need the heavy _syncAllAnnotations
    // pipeline, and routing it through there caused setGeoJsonSource on the
    // repeater cluster source to fire every tick, which made MapLibre
    // re-run its global symbol collision pass and flickered the base-style
    // POI labels at high zoom. The gpsMarkerStyle pref is included so style
    // changes (arrow → walk, etc.) re-render the marker's bitmap.
    if (_isMapReady && _styleLoaded && _imagesRegistered) {
      final gpsVersion = Object.hash(
        appState.currentPosition?.latitude,
        appState.currentPosition?.longitude,
        _computedHeading,
        appState.preferences.gpsMarkerStyle,
      );
      if (gpsVersion != _lastGpsSyncVersion) {
        _lastGpsSyncVersion = gpsVersion;
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          if (_gpsSyncInFlight) return;
          _gpsSyncInFlight = true;
          try {
            await _syncGpsSymbol(appState);
          } catch (e) {
            debugError('[MAP] _syncGpsSymbol failed: $e');
          } finally {
            _gpsSyncInFlight = false;
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

  /// Method channel to the iOS native bridge (AppDelegate.swift). iOS
  /// maplibre_gl 0.25.0 has no `setOffline` implementation, so we ship our
  /// own: a URLProtocol that fails tile requests fast while offline mode is
  /// engaged, letting MapLibre-iOS render only its cached tiles.
  static const _iosOfflineChannel =
      MethodChannel('meshmapper/ios_map_offline');

  /// Toggle MapLibre between online (network tiles) and offline (cache-only).
  /// Android uses the plugin's native `setOffline`; iOS uses our bridge.
  Future<void> _setOfflineIfSupported(bool offline) async {
    if (kIsWeb) return;
    try {
      if (Platform.isIOS) {
        await _iosOfflineChannel
            .invokeMethod('setOffline', {'offline': offline});
      } else {
        await setOffline(offline);
      }
      debugLog('[MAP] setOffline($offline) — '
          'tiles ${offline ? "cache-only" : "enabled"}');
    } catch (e) {
      debugWarn('[MAP] setOffline failed: $e');
    }
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
    //
    // When disabling tiles, also drop the coverage overlay source/layer:
    // MapLibre's ambient cache would still serve previously-fetched tiles,
    // but the overlay is a live-data layer and shouldn't linger on the map
    // in an indeterminate half-cached state once the user opted out. When
    // re-enabling, re-add it so it reappears without waiting for a style
    // reload or cache-bust.
    final tilesEnabled = appState.preferences.mapTilesEnabled;
    if (_lastMapTilesEnabled != tilesEnabled && _isMapReady) {
      final wasEnabled = _lastMapTilesEnabled;
      _lastMapTilesEnabled = tilesEnabled;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await _setOfflineIfSupported(!tilesEnabled);
        if (wasEnabled == true && !tilesEnabled) {
          await _removeCoverageOverlay();
        } else if (wasEnabled == false && tilesEnabled && _styleLoaded) {
          await _addCoverageOverlay(appState);
        }
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

    // Watch for region boundary polygon changes. Signature is derived from
    // the polygon codes AND point counts so zone transfers (same code, new
    // shape) and refreshes both trigger a rebuild.
    final borders = appState.regionBorders;
    final bordersSig = Object.hashAll(borders.map(
      (p) => Object.hash(p['code'], (p['polygon'] as List?)?.length ?? 0),
    ));
    if (bordersSig != _lastBordersSignature && _isMapReady && _styleLoaded) {
      _lastBordersSignature = bordersSig;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refreshRegionBorders(appState);
      });
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
          minMaxZoomPreference: const MinMaxZoomPreference(3, _maxUserZoom),
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
          // onMapClick fires ONLY for taps that DON'T hit an interactive
          // layer (the iOS/Android plugin routes feature hits to
          // `feature#onTap` and doesn't dispatch onMapClick in that case).
          // That's exactly what we need for the empty-area-collapse path —
          // tapping the map background closes any open spider.
          // Custom-layer feature taps still flow through
          // `controller.onFeatureTapped` (registered in _onMapCreated).
          onMapClick: _onMapEmptyTap,
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

  /// Fires for taps on the map background that don't hit any interactive
  /// custom-layer feature. Used to close an open spider when the user taps
  /// somewhere outside the spread / cluster — the standard "click empty
  /// area to dismiss" interaction. Wired via the MapLibreMap `onMapClick`
  /// parameter.
  void _onMapEmptyTap(math.Point<double> point, LatLng coordinates) {
    if (!mounted) return;
    if (_spiderCenter != null) {
      _collapseSpider();
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

    // Spider spread marker: open the detail sheet for the tapped repeater.
    // Spider stays open — users frequently compare stacked repeaters back to
    // back, so collapsing on every selection would be annoying.
    if (layerId == _spiderSymbolLayerId) {
      _showRepeaterDetailsById(id);
      return;
    }

    // Cluster tap: zoom in by default, but spiderfy first when the cluster
    // contains markers stacked tightly enough that no further zoom would
    // separate them. We accept hits on either the bubble circle layer or
    // the count-text symbol layer (either may win the platform-side
    // top-down hit-test depending on tap position).
    //
    // The explicit 200ms duration is important for perceived responsiveness.
    // Without it, iOS uses setCamera(animated: true) which has a slow ease-in
    // start (~150ms before any noticeable motion). Passing a duration switches
    // the native code path to fly(to:withDuration:) which ramps in faster and
    // finishes in 200ms, making the tap feel "instant" rather than delayed.
    if (layerId == _repeaterClusterBubbleLayerId ||
        layerId == _repeaterClusterCountLayerId) {
      _handleClusterBubbleTap(point, coordinates);
      return;
    }

    // Individual repeater: open the detail sheet. At max zoom we ALSO check
    // for stacked siblings within the spider stick threshold and spread them
    // out (covers the rare case where clustering didn't pick them up — e.g.
    // identical-coordinate markers that just slipped past clusterRadius
    // due to a recent data update). Below max zoom, spiderfy is disabled —
    // the user is expected to zoom further first.
    if (layerId == _repeaterIndividualLayerId) {
      // If a spider is open and the user tapped a non-spider individual
      // (originals are filtered out via `inSpider`, so this can only be a
      // marker outside the spider's group), collapse the existing spider.
      if (_spiderCenter != null) {
        _collapseSpider();
      }

      if (_isAtMaxZoom()) {
        final appState = context.read<AppStateProvider>();
        final group = _findSpiderGroup(coordinates, appState);
        if (group.length >= 2) {
          _spiderfy(coordinates, group);
          return;
        }
      }

      _showRepeaterDetailsById(id);
      return;
    }

    // Regional boundary: either the line or the label → info dialog.
    if (layerId == _regionBorderLineLayerId ||
        layerId == _regionBorderLabelLayerId) {
      _showBorderInfoDialog();
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

  /// Handle a tap on a cluster bubble (or its count label). Spiderfy is gated
  /// to max zoom; below that we just zoom in.
  ///
  /// At max zoom, the spider group is computed from the actual MapLibre
  /// cluster's `point_count` (queried back from the rendered feature) — we
  /// take the N nearest repeaters to the tapped coordinate. This deliberately
  /// avoids the transitive single-link clustering used by [_findSpiderGroup],
  /// which could chain across separate visual clusters when markers form a
  /// 42m-spaced trail and pull every chained marker into a single spider.
  Future<void> _handleClusterBubbleTap(
      math.Point<double> point, LatLng coordinates) async {
    if (!mounted) return;

    // Below max zoom: zoom in further so the user has a chance to separate
    // the stack visually before we resort to the spread UI. _spiderCenter is
    // always null at non-max zoom (the camera-change collapse fires when the
    // user zooms out), so no collapse-handling is needed here.
    if (!_isAtMaxZoom()) {
      if (_canAnimateCamera) {
        final currentZoom =
            _mapController?.cameraPosition?.zoom ?? _defaultZoom;
        final newZoom = math.min(currentZoom + 2, _maxUserZoom);
        _mapController?.animateCamera(
          CameraUpdate.newLatLngZoom(coordinates, newZoom),
          duration: const Duration(milliseconds: 200),
        );
      }
      return;
    }

    // Read the tapped cluster's point_count from MapLibre. This is the
    // authoritative count of leaves Supercluster grouped into this bubble —
    // matching it ensures the spider expands exactly the markers represented
    // by the tapped bubble, not a chained connected component.
    int? pointCount;
    try {
      final features = await _mapController?.queryRenderedFeatures(
        point,
        const [
          _repeaterClusterBubbleLayerId,
          _repeaterClusterCountLayerId,
        ],
        null,
      );
      if (features != null) {
        for (final f in features) {
          final props = ((f as Map)['properties'] as Map?) ?? const {};
          if (props['cluster'] == true) {
            final pc = props['point_count'];
            if (pc is num) {
              pointCount = pc.toInt();
              break;
            }
          }
        }
      }
    } catch (e) {
      debugError('[MAP] cluster point_count query failed: $e');
    }

    if (!mounted) return;

    final appState = context.read<AppStateProvider>();
    // If we couldn't read point_count (race with style reload, etc.), fall
    // back to the BFS-based group — better to spiderfy something than nothing.
    final group = pointCount != null
        ? _findSpiderGroupForCluster(coordinates, pointCount, appState)
        : _findSpiderGroup(coordinates, appState);

    // Re-tap on the open spider's own group → collapse instead of churn.
    if (_spiderCenter != null) {
      final spiderIds = _spiderRepeaters.map((r) => r.id).toSet();
      if (group.any((r) => spiderIds.contains(r.id))) {
        _collapseSpider();
        return;
      }
      _collapseSpider();
    }

    if (group.length >= 2) {
      _spiderfy(coordinates, group);
    }
    // Already at max zoom with a single-marker group: nothing useful to
    // zoom into and no stack to spread. Silent no-op.
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
      // Query the spider symbols FIRST so a tap on a spread marker hidden
      // under the GPS overlay still routes to the spider's detail sheet
      // (rather than the original repeater layer beneath it).
      final features = await _mapController!.queryRenderedFeatures(
        point,
        const [
          _spiderSymbolLayerId,
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
      // Mirrors the cluster path in _handleFeatureTap, including the
      // max-zoom gate on spiderfy. We already have the feature in hand here,
      // so read `point_count` directly instead of re-querying.
      if (properties['cluster'] == true) {
        if (!_isAtMaxZoom()) {
          if (_canAnimateCamera) {
            final currentZoom =
                _mapController?.cameraPosition?.zoom ?? _defaultZoom;
            final newZoom = math.min(currentZoom + 2, _maxUserZoom);
            _mapController?.animateCamera(
              CameraUpdate.newLatLngZoom(coordinates, newZoom),
              duration: const Duration(milliseconds: 200),
            );
          }
          return;
        }
        final appState = context.read<AppStateProvider>();
        final pcRaw = properties['point_count'];
        final pointCount = pcRaw is num ? pcRaw.toInt() : null;
        final group = pointCount != null
            ? _findSpiderGroupForCluster(coordinates, pointCount, appState)
            : _findSpiderGroup(coordinates, appState);
        if (_spiderCenter != null) {
          final spiderIds = _spiderRepeaters.map((r) => r.id).toSet();
          if (group.any((r) => spiderIds.contains(r.id))) {
            _collapseSpider();
            return;
          }
          _collapseSpider();
        }
        if (group.length >= 2) {
          _spiderfy(coordinates, group);
        }
        return;
      }

      // Individual repeater (cluster or spider symbol). The feature `id`
      // field is the repeater.id we set in our feature builders. Spider
      // symbols never need spiderfy expansion — they ARE the spread; just
      // open the detail sheet and leave the spider open.
      final repeaterId =
          (feature['id'] ?? properties['repeaterId'])?.toString();
      if (repeaterId == null) return;

      // For an individual layer hit (not a spider symbol), apply the same
      // stacked-siblings test as the direct tap path — but ONLY at max zoom.
      // queryRenderedFeatures doesn't expose layerId per result in 0.25, so
      // we infer: if a spider is open, the original individuals are filtered
      // out, so any individual hit must be a non-stacked marker → just open
      // the detail sheet. If no spider is open AND we're at max zoom, run
      // the spiderfy test.
      if (_spiderCenter != null) {
        // User tapped outside the open spider's group — collapse + show
        // detail sheet for the tapped marker.
        _collapseSpider();
      } else if (_isAtMaxZoom()) {
        final appState = context.read<AppStateProvider>();
        final group = _findSpiderGroup(coordinates, appState);
        if (group.length >= 2) {
          _spiderfy(coordinates, group);
          return;
        }
      }
      _showRepeaterDetailsById(repeaterId);
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

    final duplicates = _getDuplicateRepeaterIds(_mapVisibleRepeaters(appState));
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

      // Let the GL surface render one frame before allowing camera animations.
      // Without this, constrainCameraAndZoomToBounds can produce NaN on the
      // very first flyTo/easeTo after style load (the viewport may be
      // zero-sized or the projection matrix degenerate).
      _cameraAnimationReady = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _cameraAnimationReady = true;
        }
      });

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

      // Style reload wipes the native layer stack, so any tracked coverage
      // overlay IDs now reference layers that no longer exist. Reset them so
      // the next _swapCoverageOverlay treats this as a fresh add (no old
      // buffer to retire) instead of attempting a doomed removal.
      _activeCoverageSourceId = null;
      _activeCoverageLayerId = null;
      // Same reasoning for the focus-lines source/layers — gone with the
      // style. Clear the flag so _updateFocusLines won't try to remove
      // already-gone layers next time it's called.
      _focusLinesInstalled = false;

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

      // Regional boundary layer — style reload wipes custom sources/layers.
      // Reset the signature so the build()-driven watcher will repaint even
      // if the polygon list hasn't changed (it almost always hasn't).
      _lastBordersSignature = -1;
      await _refreshRegionBorders(appState);

      // Start tile-load timeout. If onMapIdle doesn't fire within N seconds,
      // we assume tiles are failing to load (network down, server error, etc.)
      // and surface a banner. Cleared as soon as onMapIdle fires.
      // When tiles are disabled (cache-only mode), suppress the warning — cached
      // tiles load instantly or not at all; a timeout would be misleading.
      _tileLoadTimeoutTimer?.cancel();
      final tilesEnabled = appState.preferences.mapTilesEnabled;
      _lastMapTilesEnabled = tilesEnabled;
      // Ensure MapLibre offline mode matches the user's preference.
      _setOfflineIfSupported(!tilesEnabled);
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
        if (appState.currentPosition != null && _canAnimateCamera) {
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
        // Same idea for the GPS-only sync gate: _syncAllAnnotations already
        // ran _syncGpsSymbol, so capture the current GPS version to keep the
        // next build from scheduling a redundant updateSymbol call.
        _lastGpsSyncVersion = Object.hash(
          appState.currentPosition?.latitude,
          appState.currentPosition?.longitude,
          _computedHeading,
          appState.preferences.gpsMarkerStyle,
        );
        if (mounted) setState(() {});
      }
    } finally {
      _styleLoadInProgress = false;
    }
  }

  /// Fires when the map finishes loading visible tiles and the camera is idle.
  /// We use this as the "tiles loaded successfully" signal — clears the failure
  /// timer and hides any tile-load warning banner. Also releases any pending
  /// coverage-overlay swap waiter so the previous buffer can be retired now
  /// that the new tiles have rendered.
  void _onMapIdle() {
    _tileLoadTimeoutTimer?.cancel();
    if (_tileLoadFailed && mounted) {
      debugLog('[MAP] Tiles recovered after earlier load failure');
      setState(() => _tileLoadFailed = false);
    }
    final waiter = _coverageSwapIdleCompleter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }

  /// Fires when the camera stops moving — after both gestures and
  /// programmatic animations. Auto-follow uses [_autoFollowDesiredZoom] as
  /// a *one-shot* zoom target: tap-to-follow sets it to [_maxUserZoom],
  /// the resulting animateCamera lands at that zoom, and this idle handler
  /// then clears it. Subsequent GPS ticks fall through to the camera's
  /// current zoom (line ~1005), so the user can pinch-zoom freely while
  /// auto-follow is on without each tick snapping the zoom back.
  void _onCameraIdle() {
    if (!_autoFollow || _mapController == null) return;
    _autoFollowDesiredZoom = null;
  }

  /// Add MeshMapper coverage raster overlay as a MapLibre source+layer.
  /// Allocates fresh suffixed IDs each call so a previous layer can remain
  /// in place (and continue rendering its tiles) while the new one's tiles
  /// load on top — see [_swapCoverageOverlay] for the double-buffer flow.
  Future<void> _addCoverageOverlay(AppStateProvider appState) async {
    if (_mapController == null || !_showMeshMapperOverlay) return;
    if (!appState.preferences.mapTilesEnabled) return;
    if (appState.zoneCode == null || appState.zoneCode!.isEmpty) return;

    final cvdParam = appState.preferences.colorVisionType != 'none'
        ? '&cvd=${appState.preferences.colorVisionType}'
        : '';
    final url =
        'https://${appState.zoneCode!.toLowerCase()}.meshmapper.net/tiles.php?x={x}&y={y}&z={z}&t=${appState.overlayCacheBust}$cvdParam';

    final sourceId = _nextCoverageSourceId();
    final layerId = _coverageLayerIdFor(sourceId);

    try {
      await _mapController!.addSource(
        sourceId,
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
      //
      // Using the same belowLayerId for the new layer as the previous overlay
      // intentionally places this insertion directly under the marker stack
      // and ABOVE the previous raster layer — so as the new tiles render
      // they paint over the old ones rather than the old being torn down
      // first. _swapCoverageOverlay removes the old layer once the new tiles
      // have settled.
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
        sourceId,
        layerId,
        RasterLayerProperties(rasterOpacity: opacity),
        belowLayerId: belowLayer,
      );
      _activeCoverageSourceId = sourceId;
      _activeCoverageLayerId = layerId;
      _lastAppliedCoverageOpacity = opacity;
      debugLog(
          '[MAP] Coverage overlay added as $layerId (below ${belowLayer ?? "top"}, opacity ${opacity.toStringAsFixed(2)})');
    } catch (e) {
      debugLog('[MAP] Failed to add coverage overlay: $e');
    }
  }

  String _nextCoverageSourceId() =>
      'meshmapper-overlay-${++_coverageBufferCounter}';

  String _coverageLayerIdFor(String sourceId) => '$sourceId-layer';

  /// Apply a new coverage overlay opacity to the live raster layer without
  /// removing/re-adding it. No-op if the layer doesn't exist yet.
  Future<void> _applyCoverageOverlayOpacity(double opacity) async {
    if (_mapController == null) return;
    final layerId = _activeCoverageLayerId;
    if (layerId == null) return;
    try {
      await _mapController!.setLayerProperties(
        layerId,
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

  /// Remove the active coverage overlay source and layer (if any) and clear
  /// the tracked IDs. Called by the mapTilesEnabled-toggle teardown and on
  /// style reload — it does NOT participate in the double-buffer swap path.
  Future<void> _removeCoverageOverlay() async {
    final layerId = _activeCoverageLayerId;
    final sourceId = _activeCoverageSourceId;
    _activeCoverageLayerId = null;
    _activeCoverageSourceId = null;
    if (layerId != null && sourceId != null) {
      await _removeCoverageLayerById(layerId, sourceId);
    }
  }

  /// Remove a specific coverage source+layer pair without touching the
  /// active-ID tracking. Used by [_swapCoverageOverlay] to retire the
  /// previous buffer once new tiles have rendered.
  Future<void> _removeCoverageLayerById(
      String layerId, String sourceId) async {
    if (_mapController == null) return;
    try {
      await _mapController!.removeLayer(layerId);
    } catch (_) {}
    try {
      await _mapController!.removeSource(sourceId);
    } catch (_) {}
  }

  /// Refresh coverage overlay using a double-buffered swap so the current
  /// tiles stay visible until the new ones have rendered on top.
  Future<void> _refreshCoverageOverlay(AppStateProvider appState) =>
      _swapCoverageOverlay(appState);

  /// Double-buffered overlay refresh:
  ///   1. Capture the currently-active source/layer IDs (the "old" buffer).
  ///   2. Add the new source+layer — [_addCoverageOverlay] uses the same
  ///      belowLayerId so the new layer lands directly above the old one,
  ///      and updates the active-ID fields to point at the new buffer.
  ///   3. Wait for [_onMapIdle] (or a short timeout) so the new tiles have
  ///      a chance to paint over the old.
  ///   4. Remove the old source+layer.
  ///
  /// If the add was skipped (overlay disabled, no zone, etc.) the old
  /// buffer is dropped immediately — there's nothing to buffer against.
  Future<void> _swapCoverageOverlay(AppStateProvider appState) async {
    final oldSourceId = _activeCoverageSourceId;
    final oldLayerId = _activeCoverageLayerId;

    await _addCoverageOverlay(appState);

    final addedNewBuffer = _activeCoverageSourceId != oldSourceId &&
        _activeCoverageSourceId != null;

    if (!addedNewBuffer) {
      // Add was a no-op (preconditions failed). Drop the previous buffer if
      // the overlay should no longer be visible. _addCoverageOverlay's
      // preconditions match the conditions under which we want the overlay
      // gone, so this is the correct place to retire it.
      if (oldSourceId != null && oldLayerId != null) {
        _activeCoverageSourceId = null;
        _activeCoverageLayerId = null;
        await _removeCoverageLayerById(oldLayerId, oldSourceId);
      }
      return;
    }

    if (oldSourceId == null || oldLayerId == null) {
      // No previous buffer to retire (first add since style load or after a
      // teardown). Nothing more to do.
      return;
    }

    await _waitForCoverageSwapIdle(timeout: const Duration(seconds: 3));
    if (!mounted) return;
    await _removeCoverageLayerById(oldLayerId, oldSourceId);
  }

  /// Block until [_onMapIdle] completes the swap completer, or [timeout]
  /// elapses (whichever happens first). Replaces any prior in-flight waiter
  /// so a new swap starting mid-flight doesn't strand the old waiter.
  Future<void> _waitForCoverageSwapIdle({required Duration timeout}) async {
    final prior = _coverageSwapIdleCompleter;
    if (prior != null && !prior.isCompleted) {
      prior.complete();
    }
    final completer = Completer<void>();
    _coverageSwapIdleCompleter = completer;
    _coverageSwapTimeoutTimer?.cancel();
    _coverageSwapTimeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete();
    });
    try {
      await completer.future;
    } finally {
      if (identical(_coverageSwapIdleCompleter, completer)) {
        _coverageSwapIdleCompleter = null;
      }
      _coverageSwapTimeoutTimer?.cancel();
      _coverageSwapTimeoutTimer = null;
    }
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
    final visible = _mapVisibleRepeaters(appState);
    final duplicates = _getDuplicateRepeaterIds(visible);
    final hopOverride =
        appState.enforceHopBytes ? appState.effectiveHopBytes : null;
    final focusActive = _focusedPingLocation != null;
    // While a spider is open, repeaters in the spread set are tagged with
    // `inSpider:true`. The individual symbol layer's filter excludes those
    // features so the spread markers from `_spiderSourceId` render in their
    // place. Cluster aggregation is not affected — the cluster bubble keeps
    // its full point_count.
    final spiderIds = _spiderRepeaters.map((r) => r.id).toSet();

    final features = <Map<String, dynamic>>[];
    for (final repeater in visible) {
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
          if (spiderIds.contains(repeater.id)) 'inSpider': true,
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

    // Idempotent: tear down any existing source/layers from a previous style load.
    // Spider layers are torn down first because they reference `_spiderSourceId`.
    for (final layerId in [
      _spiderSymbolLayerId,
      _spiderLineLayerId,
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
    try {
      await _mapController!.removeSource(_spiderSourceId);
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
          // Cluster at every reachable zoom (max user zoom is 17). Stacked
          // markers — those within `clusterRadius` pixels at the current
          // zoom — stay as a cluster bubble + count instead of degenerating
          // into a pile of overlapping individual symbols when the user is
          // zoomed all the way in. Tap a cluster → spiderfy. Markers far
          // enough apart that they exceed `clusterRadius` pixels at higher
          // zooms still separate into individuals naturally on zoom.
          clusterMaxZoom: 17,
        ),
      );

      // Place all three layers BELOW the symbol annotation manager so coverage
      // markers / GPS / distance labels still render on top of repeater clusters.
      final belowLayer = _symbolAnnotationLayerId();

      // Layer 1: individual repeater markers (when not part of a cluster).
      // Data-driven properties read from each feature's `properties` map.
      // Filter excludes both clustered features AND any feature tagged
      // `inSpider` (spiderfy hides the originals so the spread markers from
      // _spiderSourceId render in their place).
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
          'all',
          [
            '!',
            ['has', 'point_count']
          ],
          [
            '!=',
            ['get', 'inSpider'],
            true
          ],
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

      // Spider shadow source + layers — non-clustered. Carries spread Point
      // features (one per spiderfied repeater) and LineString features for
      // leader lines from the cluster centre to each spread position.
      // Cluster on this source MUST stay false; we want every Point to render
      // verbatim where _computeSpiderRing placed it.
      await _mapController!.addSource(
        _spiderSourceId,
        const GeojsonSourceProperties(
          data: <String, dynamic>{
            'type': 'FeatureCollection',
            'features': <dynamic>[]
          },
        ),
      );

      // Layer 4: spider leader lines (LineString features). Inserted just
      // below the individual repeater layer so lines render BENEATH every
      // repeater layer — the cluster bubble (which sits above individuals)
      // visually contains the lines' inner endpoints, and the spread markers
      // (added next, above the annotation manager's siblings) hide the outer
      // endpoints. Static filter selects LineString geometry only so Point
      // features in the same source don't try to render as zero-length lines.
      await _mapController!.addLineLayer(
        _spiderSourceId,
        _spiderLineLayerId,
        const LineLayerProperties(
          lineColor: '#888888',
          lineWidth: 1.0,
          lineOpacity: 0.7,
          lineCap: 'round',
        ),
        filter: [
          '==',
          ['geometry-type'],
          'LineString'
        ],
        belowLayerId: _repeaterIndividualLayerId,
      );

      // Layer 5: spider symbols (Point features). Same icon/text styling as
      // the individual repeater layer so spread markers look identical to the
      // originals. Inserted just below the symbol annotation manager — that
      // puts it ABOVE the individual repeater layer (so spread markers win
      // hit-tests against the now-hidden originals) but BELOW the GPS marker
      // / coverage symbols on the annotation manager. iconAllowOverlap +
      // iconIgnorePlacement are critical: without them MapLibre's collision
      // detector hides adjacent spread markers and defeats the spread.
      await _mapController!.addSymbolLayer(
        _spiderSourceId,
        _spiderSymbolLayerId,
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
          '==',
          ['geometry-type'],
          'Point'
        ],
        belowLayerId: belowLayer,
      );

      // All 3 layers + source + spider source/layers created successfully —
      // mark ready so the build()-triggered post-frame sync can run, and so
      // _syncRepeaterSymbols is allowed to push data via setGeoJsonSource.
      _clusterLayersReady = true;
    } catch (e) {
      debugError('[MAP] Failed to set up repeater cluster layers: $e');
    }
  }

  /// Pushes the current repeater state into the cluster source. MapLibre
  /// re-clusters natively whenever the source data changes. Replaces the
  /// previous per-symbol addSymbol/updateSymbol/removeSymbol diff loop.
  ///
  /// When a spider is open, also schedules a post-frame push of the spider
  /// shadow source. Deferring one frame avoids an iOS race where the main
  /// source's reclustering and the spider source's symbol render arrive in
  /// different frames, briefly showing originals + spread together.
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
    // Also push the spider source. Empty FeatureCollection if no spider open.
    final currentZoom =
        _mapController?.cameraPosition?.zoom ?? _defaultZoom;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncSpiderSymbols(appState, currentZoom);
    });
  }

  // ---------------------------------------------------------------------------
  // Spiderfy helpers — see plan: stacked repeaters fan out around the centroid
  // when a tap can't be resolved by zooming further.
  // ---------------------------------------------------------------------------

  /// Web-Mercator metres-per-pixel at the given latitude and zoom.
  double _metersPerPxAtZoom(double latDeg, num zoom) {
    return 156543.03392 *
        math.cos(latDeg * math.pi / 180) /
        math.pow(2, zoom);
  }

  /// Great-circle distance between two LatLngs in metres (haversine).
  /// Used for the spider candidate / connectivity tests — accurate at any
  /// latitude, including the poles.
  double _haversineMeters(LatLng a, LatLng b) {
    const earthRadiusM = 6378137.0;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return 2 *
        earthRadiusM *
        math.asin(math.min(1.0, math.sqrt(h)));
  }

  /// MapLibre Native (Android SDK 12.3.1 / iOS 6.19.1, both bound by
  /// maplibre_gl 0.25.0) blinks symbol-layer labels for one frame when an
  /// `animateCamera` call ends on an exact integer zoom level (15.0, 16.0,
  /// 17.0, …). Tracking issue:
  /// https://github.com/maplibre/maplibre-native/issues/2477
  ///
  /// Workaround until upstream fix: nudge every programmatic zoom value
  /// in this file by this epsilon so the camera never settles on an
  /// integer. Visually identical (~0.001 zoom is sub-pixel at any scale)
  /// but avoids the bug. When it's resolved upstream, set this to 0.0
  /// (or remove the subtractions).
  static const double _zoomEpsilon = 0.001;

  /// Maximum zoom the camera can reach (matches `minMaxZoomPreference`).
  /// Subtracted by [_zoomEpsilon] to dodge the integer-zoom label-blink
  /// bug described above.
  static const double _maxUserZoom = 17.0 - _zoomEpsilon;

  /// True when the camera is at (or floating-point close to) the user's
  /// hard zoom cap. Spider expansion is gated on this — at any lower zoom
  /// taps just zoom in further so the user has a chance to separate the
  /// stack visually before falling back to the spider UI.
  bool _isAtMaxZoom() {
    final z = _mapController?.cameraPosition?.zoom;
    if (z == null) return false;
    // Small epsilon: zoom can settle at e.g. 16.997 even when the user has
    // pinched all the way in; treat that as max.
    return z >= _maxUserZoom - 0.05;
  }

  /// Find the connected component of repeaters around [anchor] that would
  /// still visually overlap at [_maxUserZoom] (the "won't break apart by
  /// more zoom" group).
  ///
  /// Two repeaters are linked when their geographic distance is ≤ the
  /// "stick threshold" — `_clusterRadiusPx × metres-per-pixel at the max
  /// zoom`. At lat 45° this is ~42 m. Markers within this distance of
  /// each other are within the cluster radius even at the user's deepest
  /// zoom, so zooming will not separate them visually.
  ///
  /// BFS seed: repeater closest to [anchor]. Returns at least the seed when
  /// any repeater is within the broad search disc; caller should treat a
  /// result of length < 2 as "no spiderfy needed".
  List<Repeater> _findSpiderGroup(LatLng anchor, AppStateProvider appState) {
    final mPerPxMaxZoom =
        _metersPerPxAtZoom(anchor.latitude, _maxUserZoom);
    final stickThresholdM = _clusterRadiusPx * mPerPxMaxZoom;

    // Broad initial radius: 10× the stick threshold so we don't miss an
    // indirect CC member that's near another member but far from the anchor.
    // Bounded fixed multiplier — keeps the candidate set small even when a
    // user taps a continent-scale cluster at low zoom.
    final broadRadiusM = stickThresholdM * 10;
    final candidates = <Repeater>[];
    for (final r in _mapVisibleRepeaters(appState)) {
      if (_haversineMeters(anchor, LatLng(r.lat, r.lon)) <= broadRadiusM) {
        candidates.add(r);
      }
    }
    if (candidates.isEmpty) return const [];

    // Pick the closest-to-anchor as the BFS seed.
    Repeater seed = candidates.first;
    var bestD = double.infinity;
    for (final r in candidates) {
      final d = _haversineMeters(anchor, LatLng(r.lat, r.lon));
      if (d < bestD) {
        bestD = d;
        seed = r;
      }
    }

    // Connected component (single-link clustering at stick threshold).
    final visited = <String>{seed.id};
    final queue = <Repeater>[seed];
    final result = <Repeater>[seed];
    while (queue.isNotEmpty) {
      final cur = queue.removeAt(0);
      final curPos = LatLng(cur.lat, cur.lon);
      for (final r in candidates) {
        if (visited.contains(r.id)) continue;
        if (_haversineMeters(curPos, LatLng(r.lat, r.lon)) <=
            stickThresholdM) {
          visited.add(r.id);
          result.add(r);
          queue.add(r);
        }
      }
    }
    return result;
  }

  /// Find the [pointCount] repeaters nearest to [anchor], used when expanding
  /// a tapped MapLibre cluster bubble.
  ///
  /// Unlike [_findSpiderGroup] (transitive BFS connected component), this is
  /// a non-transitive proximity query — it cannot chain across separate
  /// visual clusters. The count comes from Supercluster's `point_count` on
  /// the tapped feature, so the result matches the bubble exactly in every
  /// realistic case (centroid drift in extreme layouts may shuffle a 1–2
  /// marker boundary, but the spider count is always correct).
  List<Repeater> _findSpiderGroupForCluster(
      LatLng anchor, int pointCount, AppStateProvider appState) {
    if (pointCount <= 0) return const [];
    // Bound the candidate set with a generous radius. Supercluster's max
    // cluster diameter at maxZoom is ~2× the cluster radius (centroid
    // drift); pointCount × stickThreshold is a comfortable upper bound for
    // any plausible cluster size.
    final mPerPxMaxZoom =
        _metersPerPxAtZoom(anchor.latitude, _maxUserZoom);
    final stickThresholdM = _clusterRadiusPx * mPerPxMaxZoom;
    final broadRadiusM = stickThresholdM * math.max(10, pointCount);
    final candidates = <MapEntry<Repeater, double>>[];
    for (final r in _mapVisibleRepeaters(appState)) {
      final d = _haversineMeters(anchor, LatLng(r.lat, r.lon));
      if (d <= broadRadiusM) {
        candidates.add(MapEntry(r, d));
      }
    }
    candidates.sort((a, b) => a.value.compareTo(b.value));
    return candidates.take(pointCount).map((e) => e.key).toList();
  }

  /// Layout the [n] spread positions around [center]. Uses a single ring up to
  /// 8 markers, two concentric rings up to 20, and a Fermat / golden-angle
  /// spiral past 20.
  List<LatLng> _computeSpiderRing(
      LatLng center, int n, double currentZoom) {
    final mPerPx = _metersPerPxAtZoom(center.latitude, currentZoom);
    final lat0 = center.latitude;
    final lon0 = center.longitude;
    final cosLat = math.cos(lat0 * math.pi / 180);

    // Convert (dx_px, dy_px) — screen-space offset from centre — back to a
    // geographic LatLng. Screen y grows downward; flip dy so positive screen-y
    // maps to a southward (lower-latitude) offset.
    LatLng offset(double dxPx, double dyPx) {
      final dxM = dxPx * mPerPx;
      final dyM = dyPx * mPerPx;
      final dLat = -dyM / 111320;
      final dLon = dxM / (111320 * cosLat);
      return LatLng(lat0 + dLat, lon0 + dLon);
    }

    final positions = <LatLng>[];
    if (n <= 8) {
      // Single ring at the inner radius, evenly spaced from top (-π/2).
      for (var i = 0; i < n; i++) {
        final angle = -math.pi / 2 + 2 * math.pi * i / n;
        positions.add(offset(
          _spiderInnerRadiusPx * math.cos(angle),
          _spiderInnerRadiusPx * math.sin(angle),
        ));
      }
    } else if (n <= 20) {
      // Two concentric rings: 7 inner + (n−7) outer with a half-angle stagger
      // so outer markers don't sit directly behind inner ones.
      const innerCount = 7;
      final outerCount = n - innerCount;
      for (var i = 0; i < innerCount; i++) {
        final angle = -math.pi / 2 + 2 * math.pi * i / innerCount;
        positions.add(offset(
          _spiderInnerRadiusPx * math.cos(angle),
          _spiderInnerRadiusPx * math.sin(angle),
        ));
      }
      for (var i = 0; i < outerCount; i++) {
        final angle = -math.pi / 2 +
            math.pi / outerCount +
            2 * math.pi * i / outerCount;
        positions.add(offset(
          _spiderOuterRadiusPx * math.cos(angle),
          _spiderOuterRadiusPx * math.sin(angle),
        ));
      }
    } else {
      // Golden-angle spiral — markers self-space without overlap.
      const goldenAngle = 137.508 * math.pi / 180;
      for (var i = 0; i < n; i++) {
        final angle = i * goldenAngle - math.pi / 2;
        final r = 30 + 9 * math.sqrt(i + 1);
        positions.add(offset(
          r * math.cos(angle),
          r * math.sin(angle),
        ));
      }
    }
    return positions;
  }

  /// Build the spider shadow source's FeatureCollection — Point features for
  /// every spread marker plus LineString features for the leader lines.
  /// Returns an empty collection when no spider is open.
  Map<String, dynamic> _buildSpiderFeatureCollection(
      AppStateProvider appState, double currentZoom) {
    if (_spiderCenter == null || _spiderRepeaters.isEmpty) {
      return {
        'type': 'FeatureCollection',
        'features': <Map<String, dynamic>>[]
      };
    }
    final center = _spiderCenter!;
    final positions =
        _computeSpiderRing(center, _spiderRepeaters.length, currentZoom);
    final mPerPx = _metersPerPxAtZoom(center.latitude, currentZoom);
    final cosLat = math.cos(center.latitude * math.pi / 180);

    final duplicates = _getDuplicateRepeaterIds(_mapVisibleRepeaters(appState));
    final hopOverride =
        appState.enforceHopBytes ? appState.effectiveHopBytes : null;

    final features = <Map<String, dynamic>>[];
    for (var i = 0; i < _spiderRepeaters.length; i++) {
      final repeater = _spiderRepeaters[i];
      final pos = positions[i];

      final isDuplicate = duplicates.contains(repeater.id);
      final statusKey = _repeaterStatusKey(repeater, isDuplicate);
      final effectiveBytes = hopOverride ?? repeater.hopBytes;
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
          'coordinates': [pos.longitude, pos.latitude],
        },
      });

      // Leader line — shortened by `_leaderLineEndShortenPx` at the marker
      // end so it doesn't punch through the icon / label halo. Compute the
      // shortening in screen-pixel space, then convert back to lat/lon.
      final dxM =
          (pos.longitude - center.longitude) * 111320 * cosLat;
      final dyM = (pos.latitude - center.latitude) * 111320;
      final dxPx = dxM / mPerPx;
      final dyPx = dyM / mPerPx;
      final lenPx = math.sqrt(dxPx * dxPx + dyPx * dyPx);
      if (lenPx <= _leaderLineEndShortenPx) continue;
      final scale = (lenPx - _leaderLineEndShortenPx) / lenPx;
      final endLon =
          center.longitude + (pos.longitude - center.longitude) * scale;
      final endLat =
          center.latitude + (pos.latitude - center.latitude) * scale;
      features.add({
        'type': 'Feature',
        'properties': {'repeaterId': repeater.id},
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [center.longitude, center.latitude],
            [endLon, endLat],
          ],
        },
      });
    }

    return {'type': 'FeatureCollection', 'features': features};
  }

  /// Push the current spider state to the spider GeoJSON source. Called from
  /// `_syncRepeaterSymbols` (post-frame) and after spider state mutations.
  Future<void> _syncSpiderSymbols(
      AppStateProvider appState, double currentZoom) async {
    if (_mapController == null || !_clusterLayersReady) return;
    try {
      final geojson =
          _buildSpiderFeatureCollection(appState, currentZoom);
      await _mapController!.setGeoJsonSource(_spiderSourceId, geojson);
    } catch (e) {
      debugError('[MAP] Failed to update spider source: $e');
    }
  }

  /// Open the spider — fan out [repeaters] around [center]. No-op for groups
  /// of fewer than 2 (caller should fall through to detail-sheet/zoom paths).
  void _spiderfy(LatLng center, List<Repeater> repeaters) {
    if (repeaters.length < 2 || _mapController == null || !mounted) return;
    setState(() {
      _spiderCenter = center;
      _spiderRepeaters = List.unmodifiable(repeaters);
      _spiderOpenedAtZoom = _mapController!.cameraPosition?.zoom;
    });
    debugLog(
        '[MAP] Spider opened with ${repeaters.length} markers at ${center.latitude.toStringAsFixed(5)},${center.longitude.toStringAsFixed(5)}');
    // Resync the main source (so the inSpider tag hides originals on the
    // individual layer) and the spider source (post-frame inside the sync).
    _syncRepeaterSymbols(context.read<AppStateProvider>());
  }

  /// Close the spider — clears state and resyncs both sources.
  void _collapseSpider() {
    if (_spiderCenter == null || !mounted) return;
    setState(() {
      _spiderCenter = null;
      _spiderRepeaters = const [];
      _spiderOpenedAtZoom = null;
    });
    debugLog('[MAP] Spider collapsed');
    _syncRepeaterSymbols(context.read<AppStateProvider>());
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

    final hasFocus =
        _focusedPingLocation != null && _focusedRepeaters.isNotEmpty;

    // No focus → no install. Skip the platform calls entirely when there's
    // nothing on the map to begin with; only run the remove block when a
    // previous activation actually installed the layers.
    if (!hasFocus) {
      if (!_focusLinesInstalled) return;
      try {
        await _mapController!.removeLayer(_focusLinesLayerId);
      } catch (_) {}
      try {
        await _mapController!.removeLayer(_focusLinesAmbiguousLayerId);
      } catch (_) {}
      try {
        await _mapController!.removeSource(_focusLinesSourceId);
      } catch (_) {}
      _focusLinesInstalled = false;
      return;
    }

    // Focus is active — remove any prior install before re-adding with the
    // current focus state. Order matters: layers BEFORE their source.
    if (_focusLinesInstalled) {
      try {
        await _mapController!.removeLayer(_focusLinesLayerId);
      } catch (_) {}
      try {
        await _mapController!.removeLayer(_focusLinesAmbiguousLayerId);
      } catch (_) {}
      try {
        await _mapController!.removeSource(_focusLinesSourceId);
      } catch (_) {}
      _focusLinesInstalled = false;
    }

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
      _focusLinesInstalled = true;
    } catch (e) {
      debugError('[MAP] Failed to add focus lines: $e');
    }
  }

  /// Rebuilds the regional boundary layer from `appState.regionBorders`.
  /// Always-on: renders whenever polygons are present, independent of BLE
  /// or auth state. Idempotent — safe to call repeatedly (removes existing
  /// source/layers first).
  Future<void> _refreshRegionBorders(AppStateProvider appState) async {
    if (_mapController == null || !_styleLoaded) return;

    // Remove existing layers (label, line) and source. Order matters: layers
    // reference the source, so they must go first. Each try/catch tolerates
    // a missing layer on the first call.
    try {
      await _mapController!.removeLayer(_regionBorderLabelLayerId);
    } catch (_) {}
    try {
      await _mapController!.removeLayer(_regionBorderLineLayerId);
    } catch (_) {}
    try {
      await _mapController!.removeSource(_regionBorderSourceId);
    } catch (_) {}

    final borders = appState.regionBorders;
    if (borders.isEmpty) return;

    // Build a FeatureCollection. API sends `[lat, lon]` pairs; GeoJSON wants
    // `[lon, lat]` — flip during conversion. Polygon rings must be closed,
    // so append the first point if the last doesn't already match.
    final features = <Map<String, dynamic>>[];
    for (final entry in borders) {
      final code = entry['code']?.toString() ?? '';
      final raw = entry['polygon'];
      if (raw is! List || raw.length < 3) continue;

      final ring = <List<double>>[];
      for (final pt in raw) {
        if (pt is! List || pt.length < 2) continue;
        final lat = (pt[0] as num).toDouble();
        final lon = (pt[1] as num).toDouble();
        ring.add([lon, lat]);
      }
      if (ring.length < 3) continue;
      if (ring.first[0] != ring.last[0] || ring.first[1] != ring.last[1]) {
        ring.add([ring.first[0], ring.first[1]]);
      }

      features.add({
        'type': 'Feature',
        'properties': {
          'iata': code,
          'label': '$code BOUNDARY',
        },
        'geometry': {
          'type': 'Polygon',
          'coordinates': [ring],
        },
      });
    }

    if (features.isEmpty) return;

    final geojson = <String, dynamic>{
      'type': 'FeatureCollection',
      'features': features,
    };

    try {
      await _mapController!.addSource(
        _regionBorderSourceId,
        GeojsonSourceProperties(data: geojson),
      );

      // Render beneath the repeater cluster so repeaters stay tappable on top.
      // Fallback gracefully if cluster layer isn't ready yet.
      final belowLayer =
          _clusterLayersReady ? _repeaterClusterBubbleLayerId : null;

      await _mapController!.addLineLayer(
        _regionBorderSourceId,
        _regionBorderLineLayerId,
        const LineLayerProperties(
          lineColor: '#FF6A00',
          lineOpacity: 0.9,
          lineWidth: 3.0,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        belowLayerId: belowLayer,
      );

      await _mapController!.addSymbolLayer(
        _regionBorderSourceId,
        _regionBorderLabelLayerId,
        const SymbolLayerProperties(
          symbolPlacement: 'line',
          textField: ['get', 'label'],
          textSize: 12,
          textColor: '#FF6A00',
          textHaloColor: '#FFFFFF',
          textHaloWidth: 1.5,
          textKeepUpright: true,
          textFont: _defaultFontStack,
        ),
        minzoom: 13,
        belowLayerId: belowLayer,
      );
    } catch (e) {
      debugError('[MAP] Failed to add region border layer: $e');
    }
  }

  /// Shows the dialog explaining how to expand the regional boundary.
  void _showBorderInfoDialog() {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Region Boundary'),
        content: const Text(
          'To expand the boundary, talk to your MeshMapper regional admin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
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
      const targetZoom =
          _maxUserZoom; // Street-level zoom when enabling follow (already nudged off integer)
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
        if (currentBearing.abs() > 2 && _canAnimateCamera) {
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
        if (currentBearing.abs() > 2 && _canAnimateCamera) {
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
                  // Table with headers — reserve a sliver of node-column
                  // width for the inline `location_off` indicator when the
                  // target repeater has no GPS on file.
                  Builder(builder: (context) {
                    final chipWidth = _nodeColumnWidth();
                    final lacksLocation =
                        _hexIdLacksLocation(entry.targetRepeaterId);
                    final iconReserve = lacksLocation ? 18.0 : 0.0;
                    final nodeColWidth = chipWidth + iconReserve;
                    return Container(
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
                                width: nodeColWidth,
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
                                  // Repeater ID + optional no-location icon,
                                  // pinned to the node column width so the
                                  // SNR/RSSI/TX columns stay aligned.
                                  SizedBox(
                                    width: nodeColWidth,
                                    child: Row(
                                      children: [
                                        RepeaterIdChip(
                                            repeaterId: entry.targetRepeaterId,
                                            fontSize: 13,
                                            width: chipWidth),
                                        if (lacksLocation)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                left: 4),
                                            child: _noLocationIndicator(),
                                          ),
                                      ],
                                    ),
                                  ),
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
                  );
                  }),
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

  /// Look up the first matching [Repeater] by hex-ID prefix (case-insensitive).
  /// Used by focus bottom-sheet rows to decide whether to surface the
  /// `location_off` indicator. Returns null when no match is found — callers
  /// treat that as "no location" too, since we have no coordinates.
  Repeater? _lookupRepeaterByHexId(String hexId) {
    if (hexId.isEmpty) return null;
    final all = context.read<AppStateProvider>().repeaters;
    final key = hexId.toLowerCase();
    for (final r in all) {
      if (r.hexId.toLowerCase().startsWith(key)) return r;
    }
    return null;
  }

  /// True when we should show a "no location" hint for the given hex ID,
  /// either because the matched repeater is at `(0, 0)` or because there is
  /// no match at all.
  bool _hexIdLacksLocation(String hexId) {
    final r = _lookupRepeaterByHexId(hexId);
    return r == null || !r.hasLocation;
  }

  /// Small grey [Icons.location_off] used inline next to repeater chips in
  /// the focus bottom sheets to signal "we heard this repeater but don't
  /// know where it is". Tooltip explains on long-press.
  Widget _noLocationIndicator() {
    return Tooltip(
      message: 'No location on file',
      child: Icon(
        Icons.location_off,
        size: 14,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  /// Activate ping focus mode — draw lines, fade markers, zoom to fit.
  void _activatePingFocus(LatLng pingLocation, DateTime timestamp,
      List<_ResolvedRepeater> repeaters) {
    // Drop repeaters lacking GPS — they would draw lines off to (0, 0).
    // The bottom-sheet row builder still surfaces them with a no-location
    // icon. If nothing is left to focus on, skip activation entirely so
    // the user's current map view (zoom, autofollow, rotation) is kept.
    final located =
        repeaters.where((r) => r.repeater.hasLocation).toList(growable: false);
    if (located.isEmpty) return;

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
      if (_isMapReady && _mapController != null && _canAnimateCamera) {
        _mapController!.animateCamera(
          CameraUpdate.bearingTo(0),
          duration: const Duration(milliseconds: 1),
        );
      }
    }

    setState(() {
      _focusedPingLocation = pingLocation;
      _focusedPingTimestamp = timestamp;
      _focusedRepeaters = located;
    });

    // Hide the MeshMapper coverage raster overlay for a clean focus view.
    // Uses opacity=0 rather than removing the layer to avoid a tile refetch
    // on dismiss. No-ops gracefully if the layer isn't present.
    _applyCoverageOverlayOpacity(0.0);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusedPingLocation != null) {
        _zoomToFocusBounds(pingLocation, located);
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

  /// Repeaters eligible for map rendering — excludes anything not heard in
  /// the past 30 days so long-stale entries don't appear, contribute to
  /// clusters, or get pulled into spider expansions. All map-rendering
  /// paths route through this; non-map consumers (log, picker) keep using
  /// `appState.repeaters` directly.
  List<Repeater> _mapVisibleRepeaters(AppStateProvider appState) =>
      appState.repeaters.where((r) => r.isHeardRecently).toList();

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
                  // If any heard repeater is missing GPS, reserve a sliver of
                  // node-column width for the inline `location_off` indicator
                  // so SNR/RSSI columns stay aligned row-to-row.
                  Builder(builder: (context) {
                    final chipWidth = _nodeColumnWidth();
                    final anyLacksLocation = heardRepeaters
                        .any((hr) => _hexIdLacksLocation(hr.repeaterId));
                    final iconReserve = anyLacksLocation ? 18.0 : 0.0;
                    final nodeColWidth = chipWidth + iconReserve;
                    return Container(
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
                                width: nodeColWidth,
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
                          final lacksLocation =
                              _hexIdLacksLocation(repeater.repeaterId);

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
                                  // Repeater ID + optional no-location icon,
                                  // pinned to the node column width.
                                  SizedBox(
                                    width: nodeColWidth,
                                    child: Row(
                                      children: [
                                        RepeaterIdChip(
                                            repeaterId: repeater.repeaterId,
                                            fontSize: 13,
                                            width: chipWidth),
                                        if (lacksLocation)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                left: 4),
                                            child: _noLocationIndicator(),
                                          ),
                                      ],
                                    ),
                                  ),
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
                  );
                  }),
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
                    color: PingColors.rx.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: PingColors.rx.withValues(alpha: 0.4)),
                  ),
                  child: Icon(Icons.arrow_downward,
                      color: PingColors.rx, size: 24),
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

            // Repeater table (single row). When the repeater has no GPS on
            // file, surface a small grey location_off icon next to the chip
            // so the user knows the focus map deliberately skipped it.
            Builder(builder: (context) {
              final chipWidth = _nodeColumnWidth();
              final lacksLocation = _hexIdLacksLocation(ping.repeaterId);
              final iconReserve = lacksLocation ? 18.0 : 0.0;
              final nodeColWidth = chipWidth + iconReserve;
              return Container(
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
                          width: nodeColWidth,
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
                          // Repeater ID + optional no-location icon, pinned
                          // to the node column width so SNR/RSSI stay aligned.
                          SizedBox(
                            width: nodeColWidth,
                            child: Row(
                              children: [
                                RepeaterIdChip(
                                    repeaterId: ping.repeaterId,
                                    fontSize: 13,
                                    width: chipWidth),
                                if (lacksLocation)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: _noLocationIndicator(),
                                  ),
                              ],
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
                  ),
                ],
              ),
            );
            }),

            // Path section (origin → ... → us). Skipped when the path is
            // unavailable, e.g. RxPings reloaded from Hive (transient field).
            if (ping.pathHops.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Path',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .outline
                          .withValues(alpha: 0.5)),
                ),
                child: RxPathChain(
                  hops: ping.pathHops,
                  fromLatLng: (lat: ping.latitude, lon: ping.longitude),
                  fontSize: 13,
                ),
              ),
            ],
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
                  // Table with headers — reserve a sliver of node-column
                  // width for the inline `location_off` indicator when any
                  // discovered node has no GPS on file, so the RX/RSSI/TX
                  // columns stay aligned row-to-row.
                  Builder(builder: (context) {
                    final anyLacksLocation = entry.discoveredNodes
                        .any((n) => _hexIdLacksLocation(n.repeaterId));
                    final nodeExtra = 20.0 + (anyLacksLocation ? 18.0 : 0.0);
                    return Container(
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
                                width:
                                    _nodeColumnWidth(extraPadding: nodeExtra),
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
                          final lacksLocation =
                              _hexIdLacksLocation(node.repeaterId);

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
                                  // Node ID with type (+ optional no-loc icon)
                                  SizedBox(
                                    width:
                                        _nodeColumnWidth(extraPadding: nodeExtra),
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
                                        if (lacksLocation)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                left: 4),
                                            child: _noLocationIndicator(),
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
                  );
                  }),
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
