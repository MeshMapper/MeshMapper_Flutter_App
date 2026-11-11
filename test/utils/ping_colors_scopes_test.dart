import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/ping_colors.dart';
import 'package:mesh_mapper/utils/repeater_marker_style.dart';

/// The log tab's dark card background (`main.dart`'s `darkColorScheme.surface`,
/// which `surfaceContainerHigh` falls back to when unset). Mirrors how
/// `repeater_marker_style_test.dart` checks its accents against a fixed
/// background rather than a live theme.
const _cardBackground = Color(0xFF1E293B);

/// The light theme's card background (`main.dart`'s `lightColorScheme.surface`).
const _lightCardBackground = Color(0xFFF8FAFC);

/// [accent] at 15% over [card]: the fill behind a scope chip's text.
Color _chipFill(Color accent, Color card) =>
    Color.alphaBlend(accent.withValues(alpha: 0.15), card);

void main() {
  tearDown(() {
    PingColors.setColorVisionType(ColorVisionType.none);
  });

  group('PingColors.scopes', () {
    for (final cvd in ColorVisionType.values) {
      for (final (theme, brightness, card) in [
        ('dark', Brightness.dark, _cardBackground),
        ('light', Brightness.light, _lightCardBackground),
      ]) {
        test('${cvd.name}: clears 3:1 on the $theme card and chip fill', () {
          PingColors.setColorVisionType(cvd);
          final ink = PingColors.scopesFor(brightness);
          for (final bg in [card, _chipFill(ink, card)]) {
            final ratio = RepeaterMarkerStyle.contrastRatio(ink, bg);
            expect(ratio, greaterThanOrEqualTo(3.0),
                reason: 'scopes on the $theme ${cvd.name} card is only '
                    '${ratio.toStringAsFixed(2)}:1');
          }
        });
      }

      test('${cvd.name}: the dark theme keeps the plain accent', () {
        PingColors.setColorVisionType(cvd);
        expect(PingColors.scopesFor(Brightness.dark), PingColors.scopes);
      });

      test('${cvd.name}: distinct from every other log type accent', () {
        PingColors.setColorVisionType(cvd);
        final others = {
          'txSuccess': PingColors.txSuccess,
          'rx': PingColors.rx,
          'discSuccess': PingColors.discSuccess,
          'traceSuccess': PingColors.traceSuccess,
        };
        final scopesArgb = PingColors.scopes.toARGB32();
        others.forEach((name, color) {
          expect(scopesArgb, isNot(color.toARGB32()),
              reason: 'scopes matches $name under ${cvd.name}');
        });
      });
    }
  });
}
