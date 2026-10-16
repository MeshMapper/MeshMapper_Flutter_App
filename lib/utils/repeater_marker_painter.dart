import 'package:flutter/material.dart';

import 'repeater_marker_style.dart';

/// Draws the repeater markers. Split out of the map widget so the drawing can
/// be probed pixel by pixel in a test: the whole design turns on WHERE the
/// state colour appears, and "the code compiles" says nothing about that.
///
/// [RepeaterMarkerStyle] holds the measurements and the reasoning; this file
/// only puts paint on a canvas. MapLibre plumbing (encoding these to PNG and
/// registering them by name) stays in the map widget.

/// Transparent margin around every baked chip for antialiased outer corners.
const double repeaterChipCanvasMargin = 2;

/// Paints one repeater chip into [outer] and returns the body rect, so a
/// caller that also draws a label knows where the label may go.
///
/// The body is neutral in every state. The state appears only in the border,
/// which keeps the marker from competing with the coverage carpet drawn
/// underneath. See [RepeaterMarkerStyle] for the measurements behind that.
Rect paintRepeaterChip(
  Canvas canvas,
  Rect outer,
  Color accent,
  double cornerRadius, {
  required bool isNew,
}) {
  // Draw nested fills rather than strokes so both borders stay entirely
  // inside [outer] and remain crisp at every device scale.
  canvas.drawRRect(
    RRect.fromRectAndRadius(outer, Radius.circular(cornerRadius)),
    Paint()..color = RepeaterMarkerStyle.hairlineColor,
  );

  final accentRect = outer.deflate(RepeaterMarkerStyle.hairlineWidth);
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      accentRect,
      Radius.circular(cornerRadius - RepeaterMarkerStyle.hairlineWidth),
    ),
    Paint()..color = accent,
  );

  final body = outer.deflate(RepeaterMarkerStyle.bodyInset);
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      body,
      Radius.circular(cornerRadius - RepeaterMarkerStyle.bodyInset),
    ),
    Paint()..color = RepeaterMarkerStyle.bodyColor,
  );

  return body;
}

/// Lays out a chip's bold hex label, inked from the body rather than hardcoded
/// white. See [RepeaterMarkerStyle.labelInkFor].
TextPainter repeaterChipLabelPainter(String hex, {required bool isNew}) =>
    TextPainter(
      text: TextSpan(
        text: hex,
        style: TextStyle(
          fontSize: isNew
              ? RepeaterMarkerStyle.chipFontSizeNew
              : RepeaterMarkerStyle.chipFontSize,
          color: RepeaterMarkerStyle.labelInkFor(RepeaterMarkerStyle.bodyColor),
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

/// Paints a chip's hex label centred in the neutral body.
void paintRepeaterChipLabel(
  Canvas canvas,
  Rect body,
  TextPainter textPainter,
) {
  textPainter.paint(
    canvas,
    Offset(
      body.left + (body.width - textPainter.width) / 2,
      body.top + (body.height - textPainter.height) / 2,
    ),
  );
}

/// Paints the cluster badge disc: neutral body, a ring in the DOMINANT
/// state's colour, and the hairline outside it. The count and the presence
/// dots are drawn over this by their own layers.
///
/// A circle, not a pill: hex ids like 41, CC and FD are real, so a pill
/// reading "23" would be ambiguous with a single repeater.
void paintRepeaterBadge(Canvas canvas, Color ring) {
  const center = Offset(RepeaterMarkerStyle.badgeCanvas / 2,
      RepeaterMarkerStyle.badgeCanvas / 2);

  canvas.drawCircle(
    center.translate(0, RepeaterMarkerStyle.badgeShadowOffsetY),
    RepeaterMarkerStyle.badgeRadius,
    Paint()
      ..color = RepeaterMarkerStyle.badgeShadowColor
      ..maskFilter = const MaskFilter.blur(
          BlurStyle.normal, RepeaterMarkerStyle.badgeShadowBlur),
  );
  canvas.drawCircle(center, RepeaterMarkerStyle.badgeRadius,
      Paint()..color = RepeaterMarkerStyle.bodyColor);
  canvas.drawCircle(
    center,
    RepeaterMarkerStyle.badgeRingRadius,
    Paint()
      ..color = ring
      ..style = PaintingStyle.stroke
      ..strokeWidth = RepeaterMarkerStyle.badgeRingWidth,
  );
  canvas.drawCircle(
    center,
    RepeaterMarkerStyle.badgeHairlineRadius,
    Paint()
      ..color = RepeaterMarkerStyle.hairlineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = RepeaterMarkerStyle.hairlineWidth,
  );
}

/// Paints the badge's presence-dot row: one dot per state PRESENT, all the
/// same size, centred as a row.
///
/// Uniform on purpose. The dots answer "which states are in here"; the badge
/// ring answers "which one dominates". Sizing them by share would blur two
/// separate questions into one ambiguous picture.
void paintRepeaterDots(Canvas canvas, List<Color> dots) {
  if (dots.isEmpty) return;
  const width = RepeaterMarkerStyle.dotStripWidth;
  const height = RepeaterMarkerStyle.dotStripHeight;
  final rowWidth = (dots.length - 1) * RepeaterMarkerStyle.dotPitch;
  final startX = width / 2 - rowWidth / 2;
  for (var i = 0; i < dots.length; i++) {
    canvas.drawCircle(
      Offset(startX + i * RepeaterMarkerStyle.dotPitch, height / 2),
      RepeaterMarkerStyle.dotRadius,
      Paint()..color = dots[i],
    );
  }
}
