import 'mvt_cells.dart';

/// The vector coverage tile URL template for a coverage host.
///
/// Shared by the phone map's overlay and the Android Auto map so both paint
/// the same grid, radio preset and time window. [radioFilter] is the
/// provider's `radioFilterQuery` (f_freq, f_bw, f_sf; never f_cr). Its values
/// are digits and dots, so nothing needs encoding.
String coverageTileUrlTemplate({
  required String coverageHostCode,
  required int gridSize,
  Map<String, String>? radioFilter,
  int? recentDays,
}) {
  final zone = coverageHostCode.toLowerCase();
  final recentSuffix = recentDays == null ? '' : '&f_days=$recentDays';
  final radioSuffix = radioFilter == null
      ? ''
      : '&f_freq=${radioFilter['f_freq']}&f_bw=${radioFilter['f_bw']}&f_sf=${radioFilter['f_sf']}';
  return 'https://$zone.meshmapper.net/vector_tile.php?z={z}&x={x}&y={y}'
      '&gsize=$gridSize&cf=$kCoverageTileFormat$radioSuffix$recentSuffix';
}
