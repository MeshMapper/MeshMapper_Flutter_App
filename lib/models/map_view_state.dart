/// How the user last left the map screen: the camera zoom and which panels
/// were folded away. Restored on the next launch so the map comes back the way
/// it was left.
///
/// Stored as its own key (`map_view_state`) in the `user_preferences` Hive box,
/// beside `preferences` rather than inside it, because it is screen state that
/// changes during a pinch: a write here must not run the settings save path or
/// notify anything that keys on [UserPreferences].
///
/// Only lasting state lives here. A focus camera on a tapped ping or cell, the
/// history session view and a log-screen jump are transient and never recorded.
class MapViewState {
  /// Lowest zoom the map allows (matches the map's `minMaxZoomPreference`).
  static const double minZoom = 3.0;

  /// Highest zoom the map allows: 17 nudged off the integer, because MapLibre
  /// blinks labels when the camera settles on an integer zoom.
  static const double maxZoom = 17.0 - zoomEpsilon;

  /// The nudge applied to every programmatic zoom (see [maxZoom]).
  static const double zoomEpsilon = 0.001;

  /// Smallest zoom change worth a write. Auto-follow animates the camera on
  /// every GPS tick and each one ends in a camera-idle at the same zoom.
  static const double zoomSaveThreshold = 0.01;

  /// Last zoom the user left the map at; null until one has been recorded, in
  /// which case the map keeps its first-launch zooms.
  final double? zoom;

  /// The control panel (portrait bottom card, landscape side card) is folded to
  /// its compact strip. Shared by both orientations.
  final bool controlsMinimized;

  /// Landscape only: the control panel is shown at all (closed = a small
  /// Controls button).
  final bool controlPanelShown;

  /// Landscape only: the map's control column is open.
  final bool landscapeMapControlsExpanded;

  /// Portrait only: the map's control column on the right is open.
  final bool mapControlsExpanded;

  const MapViewState({
    this.zoom,
    this.controlsMinimized = false,
    this.controlPanelShown = true,
    this.landscapeMapControlsExpanded = false,
    this.mapControlsExpanded = true,
  });

  /// Read a stored value back. Anything missing or malformed falls back to the
  /// first-launch default for that field, so a bad entry never throws.
  factory MapViewState.fromStored(Object? stored) {
    if (stored is! Map) return const MapViewState();
    bool flag(String key, bool fallback) {
      final v = stored[key];
      return v is bool ? v : fallback;
    }

    return MapViewState(
      zoom: clampZoom(stored['zoom']),
      controlsMinimized: flag('controlsMinimized', false),
      controlPanelShown: flag('controlPanelShown', true),
      landscapeMapControlsExpanded:
          flag('landscapeMapControlsExpanded', false),
      mapControlsExpanded: flag('mapControlsExpanded', true),
    );
  }

  /// The value written to Hive.
  Map<String, dynamic> toStorage() => {
        if (zoom != null) 'zoom': zoom,
        'controlsMinimized': controlsMinimized,
        'controlPanelShown': controlPanelShown,
        'landscapeMapControlsExpanded': landscapeMapControlsExpanded,
        'mapControlsExpanded': mapControlsExpanded,
      };

  /// A zoom the map can safely be handed: null for anything not a finite
  /// number, otherwise clamped to [minZoom]..[maxZoom] and nudged off an
  /// integer by [zoomEpsilon].
  static double? clampZoom(Object? value) {
    if (value is! num || !value.isFinite) return null;
    var z = value.toDouble().clamp(minZoom, maxZoom).toDouble();
    if ((z - z.roundToDouble()).abs() < zoomEpsilon / 2) {
      z = z.roundToDouble() - zoomEpsilon;
      if (z < minZoom) z = minZoom + zoomEpsilon;
    }
    return z;
  }

  /// Whether a camera at [current] differs enough from the remembered zoom to
  /// be worth recording.
  static bool zoomWorthSaving(double? remembered, double current) {
    if (!current.isFinite) return false;
    if (remembered == null) return true;
    return (current - remembered).abs() >= zoomSaveThreshold;
  }

  MapViewState copyWith({
    double? zoom,
    bool? controlsMinimized,
    bool? controlPanelShown,
    bool? landscapeMapControlsExpanded,
    bool? mapControlsExpanded,
  }) {
    return MapViewState(
      zoom: zoom ?? this.zoom,
      controlsMinimized: controlsMinimized ?? this.controlsMinimized,
      controlPanelShown: controlPanelShown ?? this.controlPanelShown,
      landscapeMapControlsExpanded:
          landscapeMapControlsExpanded ?? this.landscapeMapControlsExpanded,
      mapControlsExpanded: mapControlsExpanded ?? this.mapControlsExpanded,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MapViewState &&
      other.zoom == zoom &&
      other.controlsMinimized == controlsMinimized &&
      other.controlPanelShown == controlPanelShown &&
      other.landscapeMapControlsExpanded == landscapeMapControlsExpanded &&
      other.mapControlsExpanded == mapControlsExpanded;

  @override
  int get hashCode => Object.hash(zoom, controlsMinimized, controlPanelShown,
      landscapeMapControlsExpanded, mapControlsExpanded);

  @override
  String toString() => 'MapViewState(zoom=${zoom?.toStringAsFixed(2)}, '
      'controlsMinimized=$controlsMinimized, '
      'controlPanelShown=$controlPanelShown, '
      'landscapeMapControlsExpanded=$landscapeMapControlsExpanded, '
      'mapControlsExpanded=$mapControlsExpanded)';
}
