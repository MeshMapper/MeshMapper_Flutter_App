/// The two pieces every repeater nickname surface is drawn from: the
/// repeater's hex ID and the user's own name for it, side by side the way a
/// wardriver keeps them on a paper list ("5007 Mell").
library;

import 'package:flutter/material.dart';

import '../utils/repeater_marker_style.dart';

/// Fill and border alphas of the app's tinted status pills (the zone and
/// TX/RX counters under the title, `status_bar.dart`), so a nickname tag
/// reads as one of them.
const double _tagFillAlpha = 0.15;
const double _tagBorderAlpha = 0.4;

/// The smallest height of a tag that can be tapped.
const double _tagMinTapHeight = 40;

/// A repeater's hex ID as Top Heard shows it, in a hairline box with the map
/// chip's corner radius. No fill, so it sits on any surface.
class RepeaterHexBadge extends StatelessWidget {
  const RepeaterHexBadge(this.hex, {super.key});

  final String hex;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius:
            BorderRadius.circular(RepeaterMarkerStyle.chipCornerRadius),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        hex,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
          fontSize: 13,
          color: scheme.onSurface,
        ),
      ),
    );
  }
}

/// The user's nickname for a repeater, as a sky-tinted pill.
///
/// With no [onTap] it is a small label (the map pill) and draws nothing when
/// [nickname] is null. With [onTap] it is the editable form: larger, with a
/// label icon before the name and an edit icon after it, at least 40 px
/// tall. An editable tag with no [nickname] is the outlined "Add nickname"
/// variant, the same height so nothing moves when one is set.
class RepeaterNicknameTag extends StatelessWidget {
  const RepeaterNicknameTag({super.key, required this.nickname, this.onTap});

  final String? nickname;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(RepeaterMarkerStyle.chipCornerRadius);
    final hue = scheme.secondary;
    // Text and icons only. Sky-600 on its own tint is too dim on the dark
    // slate surfaces, so it is lifted toward white there; the fill and the
    // border stay on the true hue.
    final fg = Theme.of(context).brightness == Brightness.dark
        ? Color.lerp(hue, Colors.white, 0.45)!
        : hue;
    final name = nickname;

    if (onTap == null) {
      if (name == null) return const SizedBox.shrink();
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: hue.withValues(alpha: _tagFillAlpha),
          borderRadius: radius,
          border: Border.all(color: hue.withValues(alpha: _tagBorderAlpha)),
        ),
        child: Text(
          name,
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: fg,
          ),
        ),
      );
    }

    final adding = name == null;
    final color = adding ? scheme.primary : fg;
    // The add variant's border takes the same alpha as a set tag's, so the
    // two read as one tag with and without its fill. At full strength it was
    // the loudest line in the sheet.
    final decoration = adding
        ? BoxDecoration(
            borderRadius: radius,
            border: Border.all(
                color:
                    scheme.outlineVariant.withValues(alpha: _tagBorderAlpha)),
          )
        : BoxDecoration(
            color: hue.withValues(alpha: _tagFillAlpha),
            borderRadius: radius,
            border: Border.all(color: hue.withValues(alpha: _tagBorderAlpha)),
          );

    // One button to a screen reader, named for what it does, rather than a
    // bare nickname. The tap is re-attached here because excluding the
    // children also drops the InkWell's own action.
    return Semantics(
      button: true,
      label: adding ? 'Add nickname' : 'Edit nickname $name',
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Ink(
            decoration: decoration,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(minHeight: _tagMinTapHeight - 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(adding ? Icons.add : Icons.label_outline,
                      size: 14, color: color),
                  const SizedBox(width: 6),
                  Text(
                    adding ? 'Add nickname' : name,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                  if (!adding) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.edit_outlined, size: 14, color: color),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
