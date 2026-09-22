import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'debug_logger_io.dart';
import 'ping_colors.dart';

/// Geometry, colour registry and cluster-aggregation expressions for the
/// repeater markers on the map.
///
/// **The one rule underneath the design: the marker's large area is neutral
/// and the state rides its edge.** The body is a constant [bodyColor] in every
/// state and under every colour-vision palette; the state only ever appears in
/// the left bar, the state line and the group ring. That is not a stylistic
/// preference. The old marker fills were darker siblings of the coverage
/// colours painted underneath them (measured on the web at OKLab dE 6.2 for
/// `new` against the no-coverage red, 7.6 for `stale` against the dead-zone
/// grey), so a marker competed with the data it sat on. The neutral body is
/// dE 25.7 from the nearest coverage colour.
///
/// Three more measured constraints live here, and none of them is free to
/// "tidy up":
///
/// * The label ink is **derived** from the body by [labelInkFor], never
///   hardcoded. With a constant body it always resolves to white, but a future
///   palette that darkened or lightened the body would otherwise produce an
///   unreadable label with nothing to catch it.
/// * The edge is two-tone (a state line, then a near-black [hairlineColor]
///   outside it) because no single border colour works on every basemap: white
///   is 16.91:1 on a dark basemap and 1.09:1 on a pale one, and near-black is
///   the exact mirror. This app ships four basemaps, so both halves earn their
///   place.
/// * Backbone gold stays light. `#E8B923` is the same hue as the brown it
///   replaced and only reads as gold above roughly L* 75. There is no dark
///   yellow; darkening it to suit a dark theme turns it back into brown.
///
/// The group marker stays a circle rather than a pill because hex ids like
/// `41`, `CC` and `FD` are real, so a pill reading `23` would be genuinely
/// ambiguous with a single repeater.
class RepeaterMarkerStyle {
  RepeaterMarkerStyle._();

  // ── Shared colours ────────────────────────────────────────────────────────

  /// The constant marker body. Never tinted, in any state or palette.
  static const Color bodyColor = Color(0xFF22303A);

  /// The 1 px near-black line laid outside everything, on both shapes.
  static const Color hairlineColor = Color(0xFF0D1114);

  // ── Chip (single repeater) geometry, logical px ───────────────────────────

  /// Width of the state-coloured bar down the chip's left edge, clipped to the
  /// body's rounded rect.
  static const double barWidth = 8;

  /// The state line laid just outside the body.
  static const double stateLineWidth = 1.5;

  /// The near-black hairline laid just outside the state line.
  static const double hairlineWidth = 1;

  /// How far the body is inset from the marker's outer footprint, so the state
  /// line and hairline are added *inward* and the footprint is unchanged.
  static const double bodyInset = stateLineWidth + hairlineWidth;

  /// Chip height, and the taller variant used for a newly discovered repeater.
  static const double chipHeight = 24;
  static const double chipHeightNew = 28;

  /// Uniform body corner radius for every repeater label length.
  static const double chipCornerRadius = 8;

  /// Label size, and the larger variant for a newly discovered repeater.
  static const double chipFontSize = 12;
  static const double chipFontSizeNew = 13;

  /// Glow blur behind the chip, in the state colour. A new repeater gets a
  /// noticeably wider one: that is the whole emphasis treatment.
  static const double chipGlow = 2;
  static const double chipGlowNew = 6;

  /// Padding either side of the label, inside the space right of the bar.
  static const double chipHorizontalPad = 8;

  // ── Badge (cluster) geometry, logical px ──────────────────────────────────

  /// The badge is drawn into a square canvas of this side, centred.
  static const double badgeCanvas = 48;
  static const double badgeRadius = 19;

  /// The dominant-state ring, centred on [badgeRingRadius] so it spans
  /// 16.5..19.0 and sits *inside* the disc.
  static const double badgeRingWidth = 2.5;
  static const double badgeRingRadius = 17.75;

  /// The hairline, centred on [badgeHairlineRadius] so it spans 19.0..20.0 and
  /// sits just outside the disc.
  static const double badgeHairlineRadius = 19.5;

  static const double badgeShadowBlur = 3;
  static const double badgeShadowOffsetY = 1;
  static const Color badgeShadowColor = Color(0x73000000); // rgba(0,0,0,0.45)

  /// Presence dots. The radius is UNIFORM on purpose: the dots say *which*
  /// states are present, the ring says which one *dominates*. Those are two
  /// different facts, which is why both are drawn. Sizing the dots by share
  /// was considered on the web side and rejected.
  static const double dotRadius = 2.6;
  static const double dotPitch = 4.2;

  /// Centre line of the dot row, relative to the badge centre.
  static const double dotRowCenterY = 9.5;

  /// Centre of the count text, relative to the badge centre.
  static const double countCenterY = -3.5;
  static const double countFontSize = 12;

  /// The dot row is baked into its own canvas and offset down onto the badge,
  /// so only 32 tiny images are needed instead of one per (state, combination).
  static const double dotStripWidth = badgeCanvas;
  static const double dotStripHeight = 16;

  // ── Scale ─────────────────────────────────────────────────────────────────

  /// Every marker bitmap on this map is baked at this device-pixel ratio and
  /// rendered with the matching `iconSize`, so the two grid modes and the
  /// cluster badge stay the same visual size as each other. Before the
  /// redesign Simplified rendered at roughly 39 logical px tall and Detailed at
  /// 26, because they were sized independently.
  ///
  /// **The scale is 1.0 because the geometry above is already final size.**
  /// It was briefly 1.4, carried over from the pre-redesign Simplified marker,
  /// whose 48x28 bitmap held a 40x20 body inside shadow padding and genuinely
  /// needed enlarging. Applying the same multiplier to measurements that are
  /// already the intended size made every marker far too big: on an iPhone 16
  /// Pro Max a 6-character chip measured 84 pt wide against the old 56, and
  /// the cluster badge 56 pt across against the old 40.
  ///
  /// At 1.0 the badge is 40 pt across, the size it has always been, and a chip
  /// is 24 pt tall against the old 28 while growing with the id instead of
  /// being padded to a fixed width. Raising this again means re-measuring
  /// against those numbers, not guessing.
  ///
  /// `addImage` honours the screen scale on both platforms (iOS reads
  /// `UIScreen.main.scale`, Android the decoded bitmap's density), so a 2x
  /// device renders these slightly larger than intended, the same way every
  /// other baked marker in this app already does.
  static const double bakeDevicePixelRatio = 3.0;
  static const double iconScale = 1.0;

  /// Outer footprint of a chip carrying a [labelLength]-character hex.
  ///
  /// The width rule is the spec's: a one- or two-character id gets a fixed 24,
  /// anything longer grows with the label, and the state bar's 8 px is added
  /// on top of either. [measuredLabelWidth] only ever widens the result, for a
  /// font that renders wider than the rule assumed.
  ///
  /// This is the OUTER box. The body is [bodyInset] inside it, so the state
  /// line and hairline are added inward and the footprint is unchanged.
  static Size chipSize(
    int labelLength, {
    required bool isNew,
    double measuredLabelWidth = 0,
  }) {
    final ruleWidth =
        (labelLength <= 2 ? 24.0 : 10.0 + labelLength * 7.0) + barWidth;
    final needed =
        measuredLabelWidth + chipHorizontalPad * 2 + barWidth + bodyInset * 2;
    return Size(
      math.max(ruleWidth, needed),
      isNew ? chipHeightNew : chipHeight,
    );
  }

  /// Width available for the label: the body, less the state bar. The label is
  /// centred in THIS, not in the whole chip, or a short one drifts left and
  /// sits on the bar.
  static double chipLabelWidth(double outerWidth) =>
      outerWidth - bodyInset * 2 - barWidth;

  // ── Status registry ───────────────────────────────────────────────────────

  /// Every state a repeater marker can be in.
  ///
  /// Declaration order is load-bearing twice over: it is the order presence
  /// dots are laid out in, and it is how a tie for the dominant state in a
  /// cluster is broken. It matches the web's badge image id order (a,n,s,x,b).
  ///
  /// [wireKey] keeps the names already baked into this app's image ids and
  /// GeoJSON properties (`dead` rather than `stale`, `dup` rather than
  /// `excluded`) so the redesign does not churn every call site.
  static const List<RepeaterMarkerStatus> statuses = RepeaterMarkerStatus.values;

  /// The accent for [status] under the active colour-vision palette.
  ///
  /// A key with no entry draws in the active colour and logs one warning,
  /// rather than picking up a silent wrong colour. Mirrors the web's registry.
  static Color colorForKey(String key) {
    final status = statusForKey(key);
    if (status == null) {
      _warnUnknownStatus(key);
      return PingColors.repeaterActive;
    }
    return colorFor(status);
  }

  /// The accent for [status] under the active colour-vision palette.
  static Color colorFor(RepeaterMarkerStatus status) => switch (status) {
        RepeaterMarkerStatus.active => PingColors.repeaterActive,
        RepeaterMarkerStatus.fresh => PingColors.repeaterNew,
        RepeaterMarkerStatus.stale => PingColors.repeaterDead,
        RepeaterMarkerStatus.excluded => PingColors.repeaterDuplicate,
        RepeaterMarkerStatus.backbone => PingColors.repeaterBackbone,
      };

  /// The status for a wire key, or null when the key is not registered.
  static RepeaterMarkerStatus? statusForKey(String key) {
    for (final status in RepeaterMarkerStatus.values) {
      if (status.wireKey == key) return status;
    }
    return null;
  }

  static final Set<String> _warnedStatuses = {};

  static void _warnUnknownStatus(String key) {
    if (!_warnedStatuses.add(key)) return;
    debugWarn('[MAP] Repeater status "$key" is not in the colour registry; '
        'drawing it in the active colour');
  }

  /// Clears the "already warned" set. Tests only.
  @visibleForTesting
  static void resetStatusWarnings() => _warnedStatuses.clear();

  // ── Derived label ink ─────────────────────────────────────────────────────

  /// The luminance at which white and black give equal WCAG contrast:
  /// `sqrt(0.0525) - 0.05`.
  static const double inkThreshold = 0.179129;

  /// Ink for a label drawn on [body], derived rather than assumed.
  static Color labelInkFor(Color body) =>
      relativeLuminance(body) <= inkThreshold ? Colors.white : Colors.black;

  /// WCAG 2.x relative luminance of [color], ignoring alpha.
  static double relativeLuminance(Color color) {
    double channel(double v) =>
        v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(color.r) +
        0.7152 * channel(color.g) +
        0.0722 * channel(color.b);
  }

  /// WCAG contrast ratio between two opaque colours, brighter first.
  static double contrastRatio(Color a, Color b) {
    final la = relativeLuminance(a);
    final lb = relativeLuminance(b);
    final hi = math.max(la, lb);
    final lo = math.min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
  }

  // ── Cluster aggregation ───────────────────────────────────────────────────

  /// GeoJSON feature property carrying a point's status wire key. The cluster
  /// properties below are summed from it.
  static const String statusProperty = 'st';

  /// Per-status cluster count property, e.g. `rc_active`.
  static String countProperty(RepeaterMarkerStatus status) =>
      'rc_${status.wireKey}';

  /// Which state dominates a cluster, given per-status counts in
  /// [RepeaterMarkerStatus.values] order.
  ///
  /// Plurality, with a tie broken towards the earlier status. Mirrors
  /// [dominantStatusExpression] exactly; the two are tested against each other.
  static RepeaterMarkerStatus dominantStatus(List<int> counts) {
    assert(counts.length == RepeaterMarkerStatus.values.length);
    var best = 0;
    for (var i = 1; i < counts.length; i++) {
      if (counts[i] > counts[best]) best = i;
    }
    return RepeaterMarkerStatus.values[best];
  }

  /// Which states are present in a cluster, as a bitmask with bit *i* set when
  /// `counts[i] > 0`. Mirrors [presenceMaskExpression].
  static int presenceMask(List<int> counts) {
    assert(counts.length == RepeaterMarkerStatus.values.length);
    var mask = 0;
    for (var i = 0; i < counts.length; i++) {
      if (counts[i] > 0) mask |= 1 << i;
    }
    return mask;
  }

  /// Number of distinct masks, i.e. how many dot-row bitmaps exist.
  static const int presenceMaskCount = 1 << 5;

  /// Statuses present in [mask], in dot-row order.
  static List<RepeaterMarkerStatus> statusesInMask(int mask) => [
        for (var i = 0; i < RepeaterMarkerStatus.values.length; i++)
          if (mask & (1 << i) != 0) RepeaterMarkerStatus.values[i],
      ];

  /// `clusterProperties` for the repeater source: one running count per state.
  ///
  /// Only `+` is used as the accumulator. The vendored plugin expands a string
  /// operator into `[op, ["accumulated"], ["get", name]]` on both platforms,
  /// and `+` is the operator both native bridges are exercised with.
  static Map<String, Object> clusterProperties() => {
        for (final status in RepeaterMarkerStatus.values)
          countProperty(status): <Object>[
            '+',
            <Object>[
              'case',
              <Object>[
                '==',
                <Object>['get', statusProperty],
                status.wireKey,
              ],
              1,
              0,
            ],
          ],
      };

  static List<Object> _count(RepeaterMarkerStatus status) =>
      <Object>['get', countProperty(status)];

  /// Picks [imageForStatus] by the cluster's dominant state.
  ///
  /// The first status whose count equals the maximum wins, preserving ties
  /// in declaration order. Keep each `case` binary: iOS translates a multi-arm
  /// case to MLN_IF, which crashes in native literal parsing for icon images.
  /// Comparing with the maximum also avoids iOS folding paired inequalities
  /// into a BETWEEN predicate with different bounds.
  static List<Object> dominantStatusExpression(
    String Function(RepeaterMarkerStatus status) imageForStatus,
  ) {
    const all = RepeaterMarkerStatus.values;
    final maximum = <Object>['max', for (final status in all) _count(status)];
    Object result = imageForStatus(all.last);
    for (var i = all.length - 2; i >= 0; i--) {
      result = <Object>[
        'case',
        <Object>['==', _count(all[i]), maximum],
        imageForStatus(all[i]),
        result,
      ];
    }
    return result as List<Object>;
  }

  /// The cluster's presence bitmask as a MapLibre expression, mirroring
  /// [presenceMask].
  static List<Object> presenceMaskExpression() {
    final expr = <Object>['+'];
    const all = RepeaterMarkerStatus.values;
    for (var i = 0; i < all.length; i++) {
      expr.add(<Object>[
        'case',
        <Object>['>', _count(all[i]), 0],
        1 << i,
        0,
      ]);
    }
    return expr;
  }

  /// Picks [imageForMask] by the cluster's presence bitmask.
  ///
  /// `step` rather than `match`: the mask is a small ascending integer, and
  /// `step` is the expression this map already drives a data-driven property
  /// with on both platforms.
  static List<Object> presenceMaskImageExpression(
    String Function(int mask) imageForMask,
  ) {
    final expr = <Object>[
      'step',
      presenceMaskExpression(),
      imageForMask(0),
    ];
    for (var mask = 1; mask < presenceMaskCount; mask++) {
      expr.add(mask);
      expr.add(imageForMask(mask));
    }
    return expr;
  }
}

/// A repeater marker's state. See [RepeaterMarkerStyle.statuses] for why the
/// declaration order matters.
enum RepeaterMarkerStatus {
  /// Online and adverting.
  active('active'),

  /// Discovered recently. Drawn taller, with a larger label and glow.
  fresh('new'),

  /// No advert inside the region's window.
  stale('dead'),

  /// Its id overlaps another repeater's at the displayed id width.
  excluded('dup'),

  /// Carries part of the region's traffic. Server-decided, never computed
  /// locally, and only ever applied to an otherwise-active repeater.
  backbone('backbone');

  const RepeaterMarkerStatus(this.wireKey);

  /// The key used in image ids and GeoJSON feature properties.
  final String wireKey;
}
