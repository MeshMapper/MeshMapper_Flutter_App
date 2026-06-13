/// Colour tables + MapLibre style expressions for the VECTOR coverage tiles
/// (`vector_tile.php`). The server emits only an integer status category per
/// cell (`st`); colour is applied client-side via a `match` expression, so the
/// rendered fills are exactly the colours the raster tiles used to bake.
///
/// KEEP IN SYNC with `getCvdPaletteHex()` in MeshMapper_Server
/// `dev/cvd_palettes.php` — these are the server raster fill/border values,
/// NOT the lighter legend swatches in [PingColors] (those are tuned for how
/// the raster looks after layer opacity and stay legend-only).
///
/// `st` enum (ascending priority, lower wins; see VECTOR_TILES.md):
/// 1=green (BIDIR), 2=cyan (DISC/TRACE), 3=orange (TX), 4=purple (RX),
/// 5=grey (dead), 6=red (fail).
class CoverageTilePalette {
  CoverageTilePalette._();

  /// cvd mode -> [st 1..6] -> [fill, border] hex.
  static const Map<String, List<List<String>>> _palettes = {
    'none': [
      ['#1e7e34', '#14522d'], // 1 green
      ['#17a2b8', '#117a8b'], // 2 cyan
      ['#fd7e14', '#d96b0c'], // 3 orange
      ['#6f42c1', '#59359a'], // 4 purple
      ['#6c757d', '#545b62'], // 5 grey
      ['#bd2130', '#8b101b'], // 6 red
    ],
    'protanopia': [
      ['#0072B2', '#00507D'],
      ['#56B4E9', '#3C7EA3'],
      ['#E69F00', '#A16F00'],
      ['#CC79A7', '#8F5575'],
      ['#9E9E9E', '#6F6F6F'],
      ['#D55E00', '#954200'],
    ],
    // Server maps deuteranopia to the protanopia palette.
    'deuteranopia': [
      ['#0072B2', '#00507D'],
      ['#56B4E9', '#3C7EA3'],
      ['#E69F00', '#A16F00'],
      ['#CC79A7', '#8F5575'],
      ['#9E9E9E', '#6F6F6F'],
      ['#D55E00', '#954200'],
    ],
    'tritanopia': [
      ['#009E73', '#006F51'],
      ['#E69F00', '#A16F00'],
      ['#CC79A7', '#8F5575'],
      ['#CC79A7', '#8F5575'],
      ['#9E9E9E', '#6F6F6F'],
      ['#D55E00', '#954200'],
    ],
    'achromatopsia': [
      ['#E0E0E0', '#9D9D9D'],
      ['#BDBDBD', '#848484'],
      ['#9E9E9E', '#6F6F6F'],
      ['#757575', '#525252'],
      ['#616161', '#444444'],
      ['#424242', '#2E2E2E'],
    ],
  };

  static List<List<String>> _paletteFor(String cvdMode) =>
      _palettes[cvdMode] ?? _palettes['none']!;

  /// Builds `['match', ['get','st'], 1, c1, ..., 5, c5, c6]` — st 6 doubles
  /// as the match default so unknown future codes render as red, the same
  /// fallthrough the server-side mapping uses.
  static List<Object> _matchExpression(String cvdMode, int hexIndex) {
    final pal = _paletteFor(cvdMode);
    final expr = <Object>[
      'match',
      ['get', 'st'],
    ];
    for (var st = 1; st <= 5; st++) {
      expr.add(st);
      expr.add(pal[st - 1][hexIndex]);
    }
    expr.add(pal[5][hexIndex]); // default (st 6 / unknown)
    return expr;
  }

  /// MapLibre `fill-color` expression for the user's colour-vision mode.
  static List<Object> fillColorExpression(String cvdMode) =>
      _matchExpression(cvdMode, 0);

  /// MapLibre `fill-outline-color` expression (the raster's 1px cell border).
  static List<Object> borderColorExpression(String cvdMode) =>
      _matchExpression(cvdMode, 1);
}
