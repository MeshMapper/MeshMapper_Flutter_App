import 'package:flutter/material.dart';

import 'repeater_marker_style.dart';

/// Draws the repeater markers. Split out of the map widget so the drawing can
/// be probed pixel by pixel in a test: the whole design turns on WHERE the
/// state colour appears, and "the code compiles" says nothing about that.
///
/// [RepeaterMarkerStyle] holds the measurements and the reasoning; this file
/// only puts paint on a canvas. MapLibre plumbing (encoding these to PNG and
/// registering them by name) stays in the map widget.

/// Margin left around every baked chip so the state-coloured glow has room.
/// Uniform across states, so a chip's body stays centred in its bitmap however
/// wide its glow is and the symbol's centre anchor lands on the body's centre.
const double repeaterChipGlowMargin = RepeaterMarkerStyle.chipGlowNew + 2;

/// Paints one repeater chip into [outer] and returns the body rect, so a
/// caller that also draws a label knows where the label may go.
///
/// The body is neutral in every state. The state appears only in the left bar,
/// the line just outside the body and the glow behind it, which is what keeps
/// the marker from competing with the coverage carpet drawn underneath. See
/// [RepeaterMarkerStyle] for the measurements behind that.
Rect paintRepeaterChip(
  Canvas canvas,
  Rect outer,
  Color accent,
  double bodyRadius, {
  required bool isNew,
}) {
  final body = outer.deflate(RepeaterMarkerStyle.bodyInset);
  final bodyRRect =
      RRect.fromRectAndRadius(body, Radius.circular(bodyRadius));

  // Glow in the state colour, behind everything. A new repeater's is wide
  // enough to read as emphasis on its own.
  canvas.drawRRect(
    bodyRRect,
    Paint()
      ..color = accent.withValues(alpha: isNew ? 0.85 : 0.55)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        isNew ? RepeaterMarkerStyle.chipGlowNew : RepeaterMarkerStyle.chipGlow,
      ),
  );

  // The neutral body.
  canvas.drawRRect(bodyRRect, Paint()..color = RepeaterMarkerStyle.bodyColor);

  // State bar down the left edge, clipped to the body so it picks up the
  // rounded corners instead of squaring them off.
  canvas.save();
  canvas.clipRRect(bodyRRect);
  canvas.drawRect(
    Rect.fromLTWH(
        body.left, body.top, RepeaterMarkerStyle.barWidth, body.height),
    Paint()..color = accent,
  );
  canvas.restore();

  // State line laid just outside the body...
  const halfLine = RepeaterMarkerStyle.stateLineWidth / 2;
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      body.inflate(halfLine),
      Radius.circular(bodyRadius + halfLine),
    ),
    Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = RepeaterMarkerStyle.stateLineWidth,
  );

  // ...and the near-black hairline just outside that, whose outer edge lands
  // exactly on [outer]. Two tones because no single border colour survives
  // both a dark and a pale basemap.
  const hairOffset = RepeaterMarkerStyle.stateLineWidth +
      RepeaterMarkerStyle.hairlineWidth / 2;
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      body.inflate(hairOffset),
      Radius.circular(bodyRadius + hairOffset),
    ),
    Paint()
      ..color = RepeaterMarkerStyle.hairlineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = RepeaterMarkerStyle.hairlineWidth,
  );

  return body;
}

/// Lays out a chip's hex label. Bold, sized by state, and inked from the body
/// rather than hardcoded white. See [RepeaterMarkerStyle.labelInkFor].
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

/// Paints a chip's hex label centred in the space right of the state bar.
void paintRepeaterChipLabel(
  Canvas canvas,
  Rect body,
  TextPainter textPainter,
) {
  final labelLeft = body.left + RepeaterMarkerStyle.barWidth;
  final labelWidth = body.width - RepeaterMarkerStyle.barWidth;
  textPainter.paint(
    canvas,
    Offset(
      labelLeft + (labelWidth - textPainter.width) / 2,
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
