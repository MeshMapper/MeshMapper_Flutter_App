import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/coverage_summary.dart';

void main() {
  const segments = <CoverageLineSegment>[
    (lat: 45.01, lon: -75.01, color: '#00ff00'),
    (lat: 45.02, lon: -75.02, color: '#ffff00'),
  ];
  const drawn = RepeaterCoverageLines(
    repeaterId: 'a1b2c3d4',
    lat: 45.0,
    lon: -75.0,
    segments: segments,
  );

  group('RepeaterCoverageLines.visible', () {
    test('switch on draws every line', () {
      expect(drawn.visible(true), segments);
    });

    test('switch off draws none, which clears the layer', () {
      expect(drawn.visible(false), isEmpty);
    });
  });

  group('repeaterCoverageLinesAfterSwitch', () {
    test('on redraws the selected repeater\'s lines', () {
      expect(
          repeaterCoverageLinesAfterSwitch(drawn,
              show: true, selectedRepeaterId: 'a1b2c3d4', tileSelected: false),
          segments);
    });

    test('off clears the selected repeater\'s lines', () {
      expect(
          repeaterCoverageLinesAfterSwitch(drawn,
              show: false, selectedRepeaterId: 'a1b2c3d4', tileSelected: false),
          isEmpty);
    });

    test('no repeater coverage on the map leaves the layer alone', () {
      for (final show in [true, false]) {
        expect(
            repeaterCoverageLinesAfterSwitch(null,
                show: show,
                selectedRepeaterId: 'a1b2c3d4',
                tileSelected: false),
            isNull);
      }
    });

    test('a tapped tile owns the layer, so its fan-out is left alone', () {
      for (final show in [true, false]) {
        expect(
            repeaterCoverageLinesAfterSwitch(drawn,
                show: show, selectedRepeaterId: 'a1b2c3d4', tileSelected: true),
            isNull);
      }
    });

    test('lines kept for another repeater are never drawn back', () {
      for (final selected in ['ffff0000', null]) {
        expect(
            repeaterCoverageLinesAfterSwitch(drawn,
                show: true, selectedRepeaterId: selected, tileSelected: false),
            isNull);
      }
    });
  });
}
