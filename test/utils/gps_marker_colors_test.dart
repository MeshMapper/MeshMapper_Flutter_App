import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/gps_marker_colors.dart';

const _styles = ['arrow', 'car', 'bike', 'boat', 'walk', 'dog', 'chomper'];

void main() {
  group('normalize', () {
    test('keeps every known choice', () {
      for (final choice in GpsMarkerColors.choices) {
        expect(GpsMarkerColors.normalize(choice), choice);
      }
    });

    test('reads null and unknown values as the default', () {
      for (final value in [null, '', 'purple', 'Green']) {
        expect(GpsMarkerColors.normalize(value), 'default',
            reason: 'value $value');
      }
    });
  });

  group('forStyle', () {
    test('the default keeps the colours the markers always had', () {
      for (final style in _styles.where((s) => s != 'chomper')) {
        final colors = GpsMarkerColors.forStyle(style, 'default');
        expect(colors.body, const Color(0xFF2196F3), reason: style);
        expect(colors.shade, const Color(0xFF1565C0), reason: style);
        expect(colors.light, const Color(0xFF64B5F6), reason: style);
      }
      expect(GpsMarkerColors.forStyle('chomper', 'default').body,
          const Color(0xFF00BCD4));
    });

    test('green applies to every style, Chomper included', () {
      for (final style in _styles) {
        expect(GpsMarkerColors.forStyle(style, 'green'), GpsMarkerColors.green,
            reason: style);
      }
    });

    test('an unknown choice paints the default', () {
      expect(GpsMarkerColors.forStyle('car', 'purple'), GpsMarkerColors.blue);
      expect(
          GpsMarkerColors.forStyle('chomper', 'purple'), GpsMarkerColors.cyan);
    });

    test('green is darker than a bidirectional coverage square', () {
      // The pale green coverage fill the marker most often sits on.
      const bidir = Color(0xFF7EE094);
      expect(GpsMarkerColors.green.body.computeLuminance(),
          lessThan(bidir.computeLuminance() / 2));
    });

    test('each palette has a darker shade and a lighter accent', () {
      for (final colors in [
        GpsMarkerColors.blue,
        GpsMarkerColors.cyan,
        GpsMarkerColors.green,
      ]) {
        final body = colors.body.computeLuminance();
        expect(colors.shade.computeLuminance(), lessThan(body));
        expect(colors.light.computeLuminance(), greaterThan(body));
      }
    });
  });
}
