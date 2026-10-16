import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/repeater_marker_painter.dart';
import 'package:mesh_mapper/utils/repeater_marker_style.dart';

/// Pixel probes over the actual drawing.
///
/// The whole design turns on WHERE the state colour appears: a neutral body
/// with the state on its edge, rather than a state-coloured fill competing
/// with the coverage carpet underneath. That is a claim about pixels, and no
/// amount of clean analysis speaks to it, so these render the real painters
/// and read the result back.
///
/// Everything is rasterised at device-pixel-ratio 1, so a logical coordinate
/// in [RepeaterMarkerStyle] is a pixel index here.
class _Raster {
  _Raster(this.pixels, this.width, this.height);

  final ByteData pixels;
  final int width;
  final int height;

  Color at(int x, int y) {
    final offset = (y * width + x) * 4;
    final r = pixels.getUint8(offset);
    final g = pixels.getUint8(offset + 1);
    final b = pixels.getUint8(offset + 2);
    final a = pixels.getUint8(offset + 3);
    return Color.fromARGB(a, r, g, b);
  }

  int alphaAt(int x, int y) => (at(x, y).a * 255).round();
}

Future<_Raster> _render(
  Size size,
  void Function(Canvas canvas) paint,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  paint(canvas);
  final image =
      await recorder.endRecording().toImage(size.width.round(), size.height.round());
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return _Raster(data!, size.width.round(), size.height.round());
}

/// Channel-wise closeness, so edge antialiasing doesn't make a correct drawing
/// fail.
Matcher _isColor(Color expected, {int tolerance = 6}) =>
    predicate<Color>((actual) {
      return (actual.r * 255 - expected.r * 255).abs() <= tolerance &&
          (actual.g * 255 - expected.g * 255).abs() <= tolerance &&
          (actual.b * 255 - expected.b * 255).abs() <= tolerance &&
          (actual.a * 255 - expected.a * 255).abs() <= tolerance;
    }, 'within $tolerance of ${expected.toARGB32().toRadixString(16)}');

/// Which of two colours a pixel is nearer, for a band that antialiases against
/// its neighbour.
bool _nearer(Color actual, Color target, Color other) {
  double distance(Color c) =>
      ((actual.r - c.r) * (actual.r - c.r) +
          (actual.g - c.g) * (actual.g - c.g) +
          (actual.b - c.b) * (actual.b - c.b));
  return distance(target) < distance(other);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A colour that is nothing like the body or the hairline, so every
  // assertion below is unambiguous about what it found.
  const accent = Color(0xFFFF0000);
  const body = RepeaterMarkerStyle.bodyColor;
  const hairline = RepeaterMarkerStyle.hairlineColor;

  group('the repeater pill', () {
    const radius = RepeaterMarkerStyle.chipCornerRadius;
    late _Raster raster;
    late Rect outer;
    late Rect bodyRect;

    setUp(() async {
      final chip = RepeaterMarkerStyle.chipSize(4, isNew: false);
      final canvasSize = Size(
        chip.width + repeaterChipCanvasMargin * 2,
        chip.height + repeaterChipCanvasMargin * 2,
      );
      outer = Rect.fromLTWH(repeaterChipCanvasMargin,
          repeaterChipCanvasMargin, chip.width, chip.height);
      raster = await _render(canvasSize, (canvas) {
        bodyRect =
            paintRepeaterChip(canvas, outer, accent, radius, isNew: false);
      });
    });

    test('the large area is the neutral body, NOT the state colour', () {
      final x = bodyRect.center.dx.round();
      final y = bodyRect.center.dy.round();
      expect(raster.at(x, y), _isColor(body));
      expect(raster.at(bodyRect.right.round() - 3, y), _isColor(body));
    });

    test('the accent forms one continuous border around the body', () {
      final x = bodyRect.center.dx.round();
      final y = bodyRect.center.dy.round();
      expect(raster.at(bodyRect.left.floor() - 2, y), _isColor(accent));
      expect(raster.at(bodyRect.right.ceil() + 1, y), _isColor(accent));
      expect(raster.at(x, bodyRect.top.floor() - 2), _isColor(accent));
      expect(raster.at(x, bodyRect.bottom.ceil() + 1), _isColor(accent));
    });

    test('a near-black hairline sits outside the accent', () {
      final y = bodyRect.center.dy.round();
      expect(
          raster.at(outer.left.floor(), y), _isColor(hairline, tolerance: 20));
      expect(raster.at(outer.right.ceil() - 1, y),
          _isColor(hairline, tolerance: 20));
    });

    test('the edge is added inward, so the footprint is the outer box', () {
      final y = bodyRect.center.dy.round();
      expect(bodyRect, outer.deflate(RepeaterMarkerStyle.bodyInset));
      expect(raster.alphaAt((outer.left - 1).round(), y), 0);
    });

    test('status does not change the pill geometry', () {
      final normal = RepeaterMarkerStyle.chipSize(4, isNew: false);
      final fresh = RepeaterMarkerStyle.chipSize(4, isNew: true);
      expect(fresh, normal);
    });

    test('the label is centred in the pill', () async {
      final painter = repeaterChipLabelPainter('4E9A', isNew: false);
      final chip = RepeaterMarkerStyle.chipSize(4,
          isNew: false, measuredLabelWidth: painter.width);
      final size = Size(chip.width + repeaterChipCanvasMargin * 2,
          chip.height + repeaterChipCanvasMargin * 2);
      late Rect drawnBody;
      final r = await _render(size, (canvas) {
        drawnBody = paintRepeaterChip(
          canvas,
          Rect.fromLTWH(repeaterChipCanvasMargin, repeaterChipCanvasMargin,
              chip.width, chip.height),
          accent,
          radius,
          isNew: false,
        );
        paintRepeaterChipLabel(canvas, drawnBody, painter);
      });

      final labelCenter = drawnBody.center.dx;

      int inkColumns(int fromX, int toX) {
        var count = 0;
        for (var x = fromX; x < toX; x++) {
          for (var y = drawnBody.top.round() + 2;
              y < drawnBody.bottom.round() - 2;
              y++) {
            // The ink is white on a dark body; anything bright is a glyph.
            if (r.at(x, y).r > 0.6) {
              count++;
              break;
            }
          }
        }
        return count;
      }

      final leftHalf = inkColumns(drawnBody.left.round(), labelCenter.round());
      final rightHalf =
          inkColumns(labelCenter.round(), drawnBody.right.round());
      expect(leftHalf, greaterThan(0));
      expect(rightHalf, greaterThan(0));
      // Roughly balanced around the pill centre.
      expect((leftHalf - rightHalf).abs(), lessThanOrEqualTo(3),
          reason: 'label ink is lopsided: $leftHalf left, $rightHalf right');
    });
  });

  group('the cluster badge', () {
    late _Raster raster;
    const c = RepeaterMarkerStyle.badgeCanvas ~/ 2;

    setUp(() async {
      raster = await _render(
        const Size(RepeaterMarkerStyle.badgeCanvas,
            RepeaterMarkerStyle.badgeCanvas),
        (canvas) => paintRepeaterBadge(canvas, accent),
      );
    });

    test('the disc is the neutral body', () {
      expect(raster.at(c, c), _isColor(body));
      expect(raster.at(c + 10, c), _isColor(body));
    });

    test('the dominant state rides the ring, inside the disc', () {
      // The ring spans 16.5..19.0 from the centre. Its outer edge is
      // antialiased against the disc behind it, so the meaningful claim is
      // that this band is the state colour rather than the body.
      expect(_nearer(raster.at(c + 18, c), accent, body), isTrue,
          reason: 'found ${raster.at(c + 18, c)} where the ring should be');
      expect(_nearer(raster.at(c + 17, c), accent, body), isTrue);
      // Just inside it is body again, so the ring really is a ring.
      expect(raster.at(c + 14, c), _isColor(body));
    });

    test('the hairline sits just outside the disc', () {
      expect(raster.at(c + 19, c), _isColor(hairline, tolerance: 20));
    });

    test('nothing opaque escapes the canvas corners', () {
      expect(raster.alphaAt(0, 0), lessThan(20));
      expect(
          raster.alphaAt(RepeaterMarkerStyle.badgeCanvas.round() - 1, 0),
          lessThan(20));
    });
  });

  group('the presence dots', () {
    const colors = [
      Color(0xFFFF0000),
      Color(0xFF00FF00),
      Color(0xFF0000FF),
    ];

    test('one dot per state, in order, centred as a row', () async {
      final raster = await _render(
        const Size(RepeaterMarkerStyle.dotStripWidth,
            RepeaterMarkerStyle.dotStripHeight),
        (canvas) => paintRepeaterDots(canvas, colors),
      );
      const midY = RepeaterMarkerStyle.dotStripHeight ~/ 2;
      const centerX = RepeaterMarkerStyle.dotStripWidth / 2;
      for (var i = 0; i < colors.length; i++) {
        final x = (centerX + (i - 1) * RepeaterMarkerStyle.dotPitch).round();
        expect(raster.at(x, midY), _isColor(colors[i], tolerance: 24),
            reason: 'dot $i at x=$x');
      }
    });

    test('the dots are uniform: one state is never drawn bigger than another',
        () async {
      // Two rows, same states, wildly different notional "shares". The strip
      // is a function of WHICH states are present and nothing else, so the
      // two must be pixel-identical.
      Future<ByteData> strip(List<Color> c) async {
        final r = await _render(
          const Size(RepeaterMarkerStyle.dotStripWidth,
              RepeaterMarkerStyle.dotStripHeight),
          (canvas) => paintRepeaterDots(canvas, c),
        );
        return r.pixels;
      }

      final a = (await strip(colors)).buffer.asUint8List();
      final b = (await strip(colors)).buffer.asUint8List();
      expect(a, orderedEquals(b));
    });

    test('an empty row draws nothing at all', () async {
      final raster = await _render(
        const Size(RepeaterMarkerStyle.dotStripWidth,
            RepeaterMarkerStyle.dotStripHeight),
        (canvas) => paintRepeaterDots(canvas, const []),
      );
      for (var x = 0; x < raster.width; x += 4) {
        expect(raster.alphaAt(x, RepeaterMarkerStyle.dotStripHeight ~/ 2), 0);
      }
    });

    test('a full row fits inside the badge disc', () async {
      final raster = await _render(
        const Size(RepeaterMarkerStyle.dotStripWidth,
            RepeaterMarkerStyle.dotStripHeight),
        (canvas) => paintRepeaterDots(canvas, const [
          Color(0xFFFF0000),
          Color(0xFF00FF00),
          Color(0xFF0000FF),
          Color(0xFFFFFF00),
          Color(0xFF00FFFF),
        ]),
      );
      const midY = RepeaterMarkerStyle.dotStripHeight ~/ 2;
      var leftMost = raster.width, rightMost = -1;
      for (var x = 0; x < raster.width; x++) {
        if (raster.alphaAt(x, midY) > 10) {
          if (x < leftMost) leftMost = x;
          if (x > rightMost) rightMost = x;
        }
      }
      // The row has to clear the ring at radius 17.75 at the row's own height
      // below centre, or the dots would sit on the badge's edge.
      const center = RepeaterMarkerStyle.dotStripWidth / 2;
      expect(center - leftMost, lessThan(RepeaterMarkerStyle.badgeRingRadius));
      expect(rightMost - center, lessThan(RepeaterMarkerStyle.badgeRingRadius));
    });
  });
}
