// MapLibre base styles, keyed by the stored `UserPreferences.mapStyle` name.
// Shared by the phone map (`MapStyleExtension.styleUrl`) and the Android Auto
// map so both draw the style the user picked.

/// Satellite style as inline MapLibre style JSON (ArcGIS raster source).
/// The `glyphs` URL is required because our native symbol layers
/// (repeater cluster count, individual repeater hex IDs, distance labels)
/// use `textField`, and MapLibre iOS wedges its resource loader with
/// NSURLError -1002 if it tries to resolve glyphs against a style that
/// doesn't declare a glyphs URL.
const satelliteStyleJson =
    '{"version":8,"glyphs":"https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf","sources":{"satellite":{"type":"raster","tiles":["https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"],"tileSize":256,"maxzoom":17}},"layers":[{"id":"satellite-layer","type":"raster","source":"satellite"}]}';

/// Style URL, or inline style JSON for satellite, for a stored style name.
/// Unknown names fall back to Liberty, the default for new users.
String mapStyleUrlFor(String styleName) {
  switch (styleName) {
    case 'dark':
      return 'https://tiles.openfreemap.org/styles/dark';
    case 'light':
      return 'https://tiles.openfreemap.org/styles/bright';
    case 'satellite':
      return satelliteStyleJson;
    case 'liberty':
    default:
      return 'https://tiles.openfreemap.org/styles/liberty';
  }
}
