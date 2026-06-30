import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/coverage_tile_palette.dart';

void main() {
  group('CoverageTilePalette.colorsForStatus', () {
    test('none palette maps st to [fill, border]', () {
      expect(CoverageTilePalette.colorsForStatus('none', 1),
          ['#1e7e34', '#14522d']); // green
      expect(CoverageTilePalette.colorsForStatus('none', 2),
          ['#17a2b8', '#117a8b']); // cyan
      expect(CoverageTilePalette.colorsForStatus('none', 6),
          ['#bd2130', '#8b101b']); // red
    });

    test('unknown cvd mode falls back to none', () {
      expect(CoverageTilePalette.colorsForStatus('bogus', 1),
          CoverageTilePalette.colorsForStatus('none', 1));
    });

    test('clamps out-of-range st into 1..6', () {
      expect(CoverageTilePalette.colorsForStatus('none', 0),
          CoverageTilePalette.colorsForStatus('none', 1));
      expect(CoverageTilePalette.colorsForStatus('none', 99),
          CoverageTilePalette.colorsForStatus('none', 6));
    });

    test('a cvd palette differs from none', () {
      expect(CoverageTilePalette.colorsForStatus('protanopia', 1),
          isNot(CoverageTilePalette.colorsForStatus('none', 1)));
    });
  });
}
