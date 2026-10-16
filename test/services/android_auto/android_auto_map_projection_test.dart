import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/android_auto/android_auto_map_projection.dart';
import 'package:mesh_mapper/utils/coverage_tile_url.dart';
import 'package:mesh_mapper/utils/map_style_urls.dart';
import 'package:mesh_mapper/utils/mvt_cells.dart';

void main() {
  Map<String, Object?> build({
    double? lat = 45.4,
    double? lon = -75.7,
    double? heading = 90,
    String? host = 'YOW',
    bool tiles = true,
    Map<String, String>? radio,
    int? days,
    Iterable<CoverageCell> cells = const [],
  }) =>
      AndroidAutoMapProjection.build(
        latitude: lat,
        longitude: lon,
        heading: heading,
        style: mapStyleUrlFor('liberty'),
        coverageHostCode: host,
        mapTilesEnabled: tiles,
        gridSize: 300,
        radioFilter: radio,
        recentDays: days,
        colorVisionType: 'none',
        coverageOpacity: 0.7,
        patchCells: cells,
        patchVersion: 3,
      );

  test('coverage URL matches the phone overlay template', () {
    expect(
      coverageTileUrlTemplate(
        coverageHostCode: 'YOW',
        gridSize: 100,
        radioFilter: {'f_freq': '910.525', 'f_bw': '62.5', 'f_sf': '7'},
        recentDays: 14,
      ),
      'https://yow.meshmapper.net/vector_tile.php?z={z}&x={x}&y={y}'
      '&gsize=100&cf=$kCoverageTileFormat'
      '&f_freq=910.525&f_bw=62.5&f_sf=7&f_days=14',
    );
  });

  test('carries position, style, palette and tile source', () {
    final map = build();
    expect(map['lat'], 45.4);
    expect(map['lon'], -75.7);
    expect(map['heading'], 90);
    expect(map['style'], 'https://tiles.openfreemap.org/styles/liberty');
    expect(map['coverageTiles'], startsWith('https://yow.meshmapper.net/'));
    expect(map['coverageOpacity'], 0.7);
    expect(map['palette'], hasLength(6));
    expect((map['palette'] as List).first, ['#1e7e34', '#14522d']);
    expect(map['patchVersion'], 3);
  });

  test('omits an unknown position and an invalid heading', () {
    final map = build(lat: null, lon: null);
    expect(map.containsKey('lat'), isFalse);
    expect(map.containsKey('heading'), isFalse);
    expect(build(heading: -1).containsKey('heading'), isFalse);
  });

  test('no coverage source without a host or with tiles turned off', () {
    expect(build(host: null)['coverageTiles'], isNull);
    expect(build(host: '  ')['coverageTiles'], isNull);
    expect(build(tiles: false)['coverageTiles'], isNull);
    expect(
        build(tiles: false, cells: const [CoverageCell(1, 0, 0, 1)])['patch'],
        isEmpty);
  });

  test('patch sends only the newest cells, as rectangles with status', () {
    final cells = [
      for (var n = 0; n < AndroidAutoMapProjection.maximumPatchCells + 5; n++)
        CoverageCell(n, n, n, (n % 6) + 1),
    ];
    final patch = build(cells: cells)['patch'] as List;
    expect(patch, hasLength(AndroidAutoMapProjection.maximumPatchCells));
    final last = cells.last;
    expect(patch.last, [...last.bounds(300), last.st]);
  });
}
