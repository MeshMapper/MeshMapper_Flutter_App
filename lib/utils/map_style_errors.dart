/// Classifiers for MapLibre style-mutation platform errors.
///
/// Whether a native style object survived an earlier failed teardown is not
/// observable from Dart; the only signal is the add call throwing "already
/// exists" (Android `CannotAddLayerException` / `CannotAddSourceException`,
/// surfaced as a PlatformException). Install paths use this to ADOPT the
/// existing object instead of reporting failure: reporting failure left the
/// installed-flag false forever, and the still-rendering native layer froze
/// at its last pushed data (#482, the stuck GPS arrow).
bool mapStyleObjectAlreadyExists(Object error) =>
    error.toString().toLowerCase().contains('already exists');
