import '../../utils/coverage_tile_palette.dart';
import '../../utils/coverage_tile_url.dart';
import '../../utils/mvt_cells.dart';

/// The map half of the Android Auto snapshot.
///
/// The car draws its own MapLibre map (MeshMapperCarMapRenderer.kt), so it
/// needs everything the phone's map widget reads to paint the same picture:
/// where the driver is, the base style, the coverage tile source and palette,
/// and the session's freshly patched cells. Everything that encodes a rule
/// (the tile URL, the colour table) is resolved here, in Dart, so the car can
/// never drift from the phone by re-deriving it.
class AndroidAutoMapProjection {
  AndroidAutoMapProjection._();

  /// Cells sent per snapshot. The patch holds up to 5000 and the snapshot is
  /// re-sent on every change, so only the newest cells, the ones a driver is
  /// actually passing, cross the channel.
  static const int maximumPatchCells = 400;

  static Map<String, Object?> build({
    required double? latitude,
    required double? longitude,
    required double? heading,
    required String style,
    required String? coverageHostCode,
    required bool mapTilesEnabled,
    required int gridSize,
    required Map<String, String>? radioFilter,
    required int? recentDays,
    required String colorVisionType,
    required double coverageOpacity,
    required Iterable<CoverageCell> patchCells,
    required int patchVersion,
  }) {
    final host = coverageHostCode?.trim();
    final hasCoverage = mapTilesEnabled && host != null && host.isNotEmpty;
    final validPosition = latitude != null &&
        longitude != null &&
        latitude.isFinite &&
        longitude.isFinite;
    final validHeading = heading != null && heading.isFinite && heading >= 0;

    return {
      if (validPosition) 'lat': latitude,
      if (validPosition) 'lon': longitude,
      if (validPosition && validHeading) 'heading': heading,
      'style': style,
      'coverageTiles': hasCoverage
          ? coverageTileUrlTemplate(
              coverageHostCode: host,
              gridSize: gridSize,
              radioFilter: radioFilter,
              recentDays: recentDays,
            )
          : null,
      'coverageOpacity': coverageOpacity.clamp(0.0, 1.0),
      // [fill, border] for st 1..6, in order.
      'palette': [
        for (var st = 1; st <= 6; st++)
          CoverageTilePalette.colorsForStatus(colorVisionType, st),
      ],
      'patchVersion': patchVersion,
      'patch': hasCoverage ? _patch(patchCells, gridSize) : const [],
    };
  }

  /// `[lat0, lon0, latStep, lonStep, st]` per cell, newest last. The patch map
  /// re-inserts a cell when it changes, so its iteration order is age order.
  static List<List<num>> _patch(Iterable<CoverageCell> cells, int gridSize) {
    final all = cells.toList(growable: false);
    final start =
        all.length > maximumPatchCells ? all.length - maximumPatchCells : 0;
    return [
      for (final cell in all.skip(start)) [...cell.bounds(gridSize), cell.st],
    ];
  }
}
