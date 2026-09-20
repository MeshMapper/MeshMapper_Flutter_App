import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/ping_colors.dart';
import 'package:mesh_mapper/utils/repeater_marker_style.dart';

/// Evaluates the small subset of the MapLibre expression language the cluster
/// badge uses, over one feature's properties.
///
/// The badge's dominant state and presence dots are decided natively, inside
/// MapLibre, from expressions this app only ever hands over as JSON. Without
/// this the only way to find out whether those expressions agree with the Dart
/// reference implementations would be to look at a phone. Anything outside the
/// subset throws, so an expression that grows a new operator fails loudly here
/// rather than silently going unchecked.
Object _eval(Object expr, Map<String, Object> props) {
  if (expr is! List) return expr;
  final op = expr[0];
  final args = expr.sublist(1);
  switch (op) {
    case 'get':
      return props[args[0] as String] ?? 0;
    case 'max':
      return args
          .map((a) => _eval(a, props) as num)
          .reduce((a, b) => a > b ? a : b);
    case '+':
      return args.fold<num>(0, (sum, a) => sum + (_eval(a, props) as num));
    case '>':
      return (_eval(args[0], props) as num) > (_eval(args[1], props) as num);
    case '>=':
      return (_eval(args[0], props) as num) >= (_eval(args[1], props) as num);
    case '==':
      return _eval(args[0], props) == _eval(args[1], props);
    case 'all':
      return args.every((a) => _eval(a, props) == true);
    case 'case':
      for (var i = 0; i + 1 < args.length; i += 2) {
        if (_eval(args[i], props) == true) return _eval(args[i + 1], props);
      }
      return _eval(args.last, props);
    case 'step':
      final input = _eval(args[0], props) as num;
      var result = _eval(args[1], props);
      for (var i = 2; i + 1 < args.length + 1; i += 2) {
        final stop = args[i] as num;
        if (input < stop) break;
        result = _eval(args[i + 1], props);
      }
      return result;
    default:
      throw UnsupportedError('expression operator "$op" is not evaluated here');
  }
}

Map<String, Object> _clusterProps(List<int> counts) => {
      for (var i = 0; i < counts.length; i++)
        RepeaterMarkerStyle.countProperty(RepeaterMarkerStatus.values[i]):
            counts[i],
    };

void main() {
  setUp(() {
    PingColors.setColorVisionType(ColorVisionType.none);
    RepeaterMarkerStyle.resetStatusWarnings();
  });

  group('label ink is derived, never assumed', () {
    test('white and black sit either side of the equal-contrast threshold', () {
      expect(RepeaterMarkerStyle.relativeLuminance(Colors.white),
          closeTo(1.0, 0.0001));
      expect(RepeaterMarkerStyle.relativeLuminance(Colors.black),
          closeTo(0.0, 0.0001));
      expect(RepeaterMarkerStyle.labelInkFor(Colors.white), Colors.black);
      expect(RepeaterMarkerStyle.labelInkFor(Colors.black), Colors.white);
    });

    test('the real body resolves to white', () {
      expect(RepeaterMarkerStyle.labelInkFor(RepeaterMarkerStyle.bodyColor),
          Colors.white);
    });

    test('a hypothetical pale body would flip the ink rather than stay white',
        () {
      // The whole reason the ink is derived: a future palette cannot ship an
      // unreadable label without this flipping first.
      expect(RepeaterMarkerStyle.labelInkFor(const Color(0xFFE8E8E8)),
          Colors.black);
    });

    test('the threshold is where white and black contrast equally', () {
      // Pick a colour sitting essentially on the threshold and check the two
      // contrast ratios meet there.
      const onThreshold = Color(0xFF767676);
      final white = RepeaterMarkerStyle.contrastRatio(
          onThreshold, Colors.white);
      final black = RepeaterMarkerStyle.contrastRatio(
          onThreshold, Colors.black);
      expect((white - black).abs(), lessThan(0.35));
    });
  });

  group('every palette keeps its accents legible on the body', () {
    for (final cvd in ColorVisionType.values) {
      test('${cvd.name}: all five accents clear 3:1 on the body', () {
        PingColors.setColorVisionType(cvd);
        for (final status in RepeaterMarkerStatus.values) {
          final ratio = RepeaterMarkerStyle.contrastRatio(
            RepeaterMarkerStyle.colorFor(status),
            RepeaterMarkerStyle.bodyColor,
          );
          expect(ratio, greaterThanOrEqualTo(3.0),
              reason: '${status.wireKey} on ${cvd.name} is only '
                  '${ratio.toStringAsFixed(2)}:1');
        }
      });

      test('${cvd.name}: the five accents are distinct from one another', () {
        PingColors.setColorVisionType(cvd);
        final seen = <int, String>{};
        for (final status in RepeaterMarkerStatus.values) {
          final argb = RepeaterMarkerStyle.colorFor(status).toARGB32();
          expect(seen.containsKey(argb), isFalse,
              reason: '${status.wireKey} has the same hex as ${seen[argb]} '
                  'under ${cvd.name}');
          seen[argb] = status.wireKey;
        }
      });
    }

    test('backbone gold stays light enough to read as gold, not brown', () {
      PingColors.setColorVisionType(ColorVisionType.none);
      final gold =
          RepeaterMarkerStyle.colorFor(RepeaterMarkerStatus.backbone);
      expect(gold, const Color(0xFFE8B923));
      // Below roughly L* 75 this hue turns brown, which is the bug the web
      // side fixed by lightening it. Guard the lightness, not just the hex.
      expect(HSLColor.fromColor(gold).lightness, greaterThan(0.5));
    });
  });

  group('status registry', () {
    test('every wire key resolves', () {
      for (final status in RepeaterMarkerStatus.values) {
        expect(RepeaterMarkerStyle.statusForKey(status.wireKey), status);
        expect(RepeaterMarkerStyle.colorForKey(status.wireKey),
            RepeaterMarkerStyle.colorFor(status));
      }
    });

    test('an unregistered key falls back to active rather than drawing wrong',
        () {
      expect(RepeaterMarkerStyle.statusForKey('mystery'), isNull);
      expect(RepeaterMarkerStyle.colorForKey('mystery'),
          PingColors.repeaterActive);
    });

    test('the dot and tie-break order is a, n, s, x, b', () {
      expect([for (final s in RepeaterMarkerStatus.values) s.wireKey],
          ['active', 'new', 'dead', 'dup', 'backbone']);
    });
  });

  group('chip geometry', () {
    test('a short id gets the fixed minimum, plus the bar', () {
      expect(RepeaterMarkerStyle.chipSize(2, isNew: false).width,
          24 + RepeaterMarkerStyle.barWidth);
      expect(RepeaterMarkerStyle.chipSize(1, isNew: false).width,
          24 + RepeaterMarkerStyle.barWidth);
    });

    test('a longer id grows with the label, plus the bar', () {
      expect(RepeaterMarkerStyle.chipSize(4, isNew: false).width,
          10 + 4 * 7 + RepeaterMarkerStyle.barWidth);
      expect(RepeaterMarkerStyle.chipSize(6, isNew: false).width,
          10 + 6 * 7 + RepeaterMarkerStyle.barWidth);
    });

    test('a new repeater gets the taller chip', () {
      expect(RepeaterMarkerStyle.chipSize(4, isNew: false).height,
          RepeaterMarkerStyle.chipHeight);
      expect(RepeaterMarkerStyle.chipSize(4, isNew: true).height,
          RepeaterMarkerStyle.chipHeightNew);
    });

    test('a measured label only ever widens the chip, never narrows it', () {
      final rule = RepeaterMarkerStyle.chipSize(6, isNew: false).width;
      expect(
          RepeaterMarkerStyle.chipSize(6, isNew: false, measuredLabelWidth: 1)
              .width,
          rule);
      expect(
          RepeaterMarkerStyle.chipSize(6, isNew: false, measuredLabelWidth: 200)
              .width,
          greaterThan(rule));
    });

    test('the label always has room right of the bar', () {
      for (final length in [2, 4, 6]) {
        final width = RepeaterMarkerStyle.chipSize(length, isNew: false).width;
        // Roughly 7 px a character is what the width rule assumes, and the
        // padding has to survive on top of it.
        expect(RepeaterMarkerStyle.chipLabelWidth(width),
            greaterThan(length * 7.0),
            reason: 'a $length-character hex has no room');
      }
    });

    test('the edge is added inward, so the footprint is the spec width', () {
      // bodyInset is exactly the state line plus the hairline: the two-tone
      // edge costs nothing outside the box it is drawn in.
      expect(RepeaterMarkerStyle.bodyInset,
          RepeaterMarkerStyle.stateLineWidth + RepeaterMarkerStyle.hairlineWidth);
    });
  });

  group('badge geometry', () {
    test('the ring sits inside the disc and the hairline just outside it', () {
      // ring spans 16.5..19.0, disc ends at 19.0, hairline spans 19.0..20.0.
      expect(
          RepeaterMarkerStyle.badgeRingRadius +
              RepeaterMarkerStyle.badgeRingWidth / 2,
          RepeaterMarkerStyle.badgeRadius);
      expect(
          RepeaterMarkerStyle.badgeHairlineRadius -
              RepeaterMarkerStyle.hairlineWidth / 2,
          RepeaterMarkerStyle.badgeRadius);
    });

    test('the widest dot row and the shadow both fit the canvas', () {
      const half = RepeaterMarkerStyle.badgeCanvas / 2;
      final rowHalfWidth =
          (RepeaterMarkerStyle.statuses.length - 1) *
                  RepeaterMarkerStyle.dotPitch /
                  2 +
              RepeaterMarkerStyle.dotRadius;
      expect(rowHalfWidth, lessThan(RepeaterMarkerStyle.dotStripWidth / 2));
      expect(
          RepeaterMarkerStyle.badgeHairlineRadius +
              RepeaterMarkerStyle.hairlineWidth / 2 +
              RepeaterMarkerStyle.badgeShadowBlur +
              RepeaterMarkerStyle.badgeShadowOffsetY,
          lessThanOrEqualTo(half));
    });

    test('the dot row clears the count text', () {
      expect(RepeaterMarkerStyle.dotRowCenterY,
          greaterThan(RepeaterMarkerStyle.countCenterY));
    });
  });

  group('dominant state', () {
    test('a plurality wins', () {
      expect(RepeaterMarkerStyle.dominantStatus([1, 5, 2, 0, 0]),
          RepeaterMarkerStatus.fresh);
      expect(RepeaterMarkerStyle.dominantStatus([0, 0, 0, 0, 3]),
          RepeaterMarkerStatus.backbone);
    });

    test('a tie breaks towards the earlier status', () {
      expect(RepeaterMarkerStyle.dominantStatus([2, 2, 0, 0, 0]),
          RepeaterMarkerStatus.active);
      expect(RepeaterMarkerStyle.dominantStatus([0, 0, 4, 4, 4]),
          RepeaterMarkerStatus.stale);
    });

    test('the MapLibre expression agrees with the Dart reference', () {
      final expr = RepeaterMarkerStyle.dominantStatusExpression(
          (status) => status.wireKey);
      for (final counts in _sampleCounts()) {
        expect(_eval(expr, _clusterProps(counts)),
            RepeaterMarkerStyle.dominantStatus(counts).wireKey,
            reason: 'counts $counts');
      }
    });

    test('they agree on EVERY tie and plurality shape, not just samples', () {
      // Counts drawn from {0, 1, 2} over five states cover every shape that
      // can decide the winner: absent, present, and present-more-than-another.
      // The same 243 cases run against the real iOS SDK in
      // test/native/check_repeater_expressions.py, but that one needs a booted
      // simulator, so this is the copy that runs everywhere.
      final expr = RepeaterMarkerStyle.dominantStatusExpression(
          (status) => status.wireKey);
      for (final counts in _everyCountShape()) {
        expect(_eval(expr, _clusterProps(counts)),
            RepeaterMarkerStyle.dominantStatus(counts).wireKey,
            reason: 'counts $counts');
      }
    });
  });

  group('presence mask', () {
    test('one bit per state present, in declaration order', () {
      expect(RepeaterMarkerStyle.presenceMask([1, 0, 0, 0, 0]), 1);
      expect(RepeaterMarkerStyle.presenceMask([0, 1, 0, 0, 0]), 2);
      expect(RepeaterMarkerStyle.presenceMask([0, 0, 0, 0, 7]), 16);
      expect(RepeaterMarkerStyle.presenceMask([3, 0, 9, 0, 0]), 1 | 4);
      expect(RepeaterMarkerStyle.presenceMask([1, 1, 1, 1, 1]),
          RepeaterMarkerStyle.presenceMaskCount - 1);
    });

    test('a count says nothing about the mask beyond present or not', () {
      expect(RepeaterMarkerStyle.presenceMask([1, 0, 0, 0, 0]),
          RepeaterMarkerStyle.presenceMask([99, 0, 0, 0, 0]));
    });

    test('statusesInMask lists them in dot-row order', () {
      expect(RepeaterMarkerStyle.statusesInMask(1 | 4 | 16), [
        RepeaterMarkerStatus.active,
        RepeaterMarkerStatus.stale,
        RepeaterMarkerStatus.backbone,
      ]);
      expect(RepeaterMarkerStyle.statusesInMask(0), isEmpty);
    });

    test('the MapLibre expression agrees with the Dart reference', () {
      final expr = RepeaterMarkerStyle.presenceMaskExpression();
      for (final counts in _everyCountShape()) {
        expect(_eval(expr, _clusterProps(counts)),
            RepeaterMarkerStyle.presenceMask(counts),
            reason: 'counts $counts');
      }
    });

    test('the image step expression picks the strip for the mask', () {
      final expr =
          RepeaterMarkerStyle.presenceMaskImageExpression((mask) => 'dots$mask');
      for (final counts in _sampleCounts()) {
        expect(_eval(expr, _clusterProps(counts)),
            'dots${RepeaterMarkerStyle.presenceMask(counts)}',
            reason: 'counts $counts');
      }
    });
  });

  group('cluster properties', () {
    test('one running count per state, accumulated with +', () {
      final props = RepeaterMarkerStyle.clusterProperties();
      expect(props.keys.toSet(), {
        for (final s in RepeaterMarkerStatus.values)
          RepeaterMarkerStyle.countProperty(s)
      });
      for (final value in props.values) {
        // [operator, map_expression]; only '+' is used, because that is the
        // accumulator both native bridges are exercised with.
        expect((value as List).first, '+');
      }
    });

    test('a point contributes 1 to its own state and 0 to the others', () {
      final props = RepeaterMarkerStyle.clusterProperties();
      for (final status in RepeaterMarkerStatus.values) {
        final feature = {RepeaterMarkerStyle.statusProperty: status.wireKey};
        for (final other in RepeaterMarkerStatus.values) {
          final mapExpr =
              (props[RepeaterMarkerStyle.countProperty(other)] as List)[1];
          expect(_eval(mapExpr, feature), status == other ? 1 : 0,
              reason: 'a ${status.wireKey} point counted as ${other.wireKey}');
        }
      }
    });
  });
}

/// Every count vector over {0, 1, 2} for the five states: 243 in all, the same
/// grid the native check walks.
Iterable<List<int>> _everyCountShape() sync* {
  final n = RepeaterMarkerStatus.values.length;
  final total = [for (var i = 0; i < n; i++) 3].fold<int>(1, (a, b) => a * b);
  for (var sample = 0; sample < total; sample++) {
    var value = sample;
    final counts = <int>[];
    for (var i = 0; i < n; i++) {
      counts.add(value % 3);
      value ~/= 3;
    }
    yield counts;
  }
}

/// Count vectors worth checking: every single state alone, a few pluralities,
/// every tie shape, and the all-present case.
Iterable<List<int>> _sampleCounts() sync* {
  const n = 5;
  for (var i = 0; i < n; i++) {
    yield [for (var j = 0; j < n; j++) j == i ? 3 : 0];
  }
  yield [1, 1, 1, 1, 1];
  yield [0, 0, 0, 0, 0];
  yield [5, 4, 3, 2, 1];
  yield [1, 2, 3, 4, 5];
  yield [2, 2, 1, 0, 0];
  yield [0, 3, 3, 0, 0];
  yield [0, 0, 2, 2, 2];
  yield [7, 0, 0, 0, 7];
  yield [12, 1, 0, 0, 0];
}
