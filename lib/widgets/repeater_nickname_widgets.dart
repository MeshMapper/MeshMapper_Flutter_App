/// The pieces the repeater nickname UI is drawn from: the repeater's hex ID
/// and the user's own name for it, side by side the way a wardriver keeps
/// them on a paper list ("5007 Mell"), and the sheet's Nickname button.
library;

import 'package:flutter/material.dart';

import '../utils/repeater_marker_style.dart';

/// Fill and border alphas of the app's tinted status pills (the zone and
/// TX/RX counters under the title, `status_bar.dart`), so a nickname tag
/// reads as one of them.
const double _tagFillAlpha = 0.15;
const double _tagBorderAlpha = 0.4;

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

/// The user's nickname for a repeater, as a small sky-tinted pill: the map
/// pill shows it after the repeater's name. Draws nothing when [nickname] is
/// null.
class RepeaterNicknameTag extends StatelessWidget {
  const RepeaterNicknameTag({super.key, required this.nickname});

  final String? nickname;

  @override
  Widget build(BuildContext context) {
    final name = nickname;
    if (name == null) return const SizedBox.shrink();
    final hue = Theme.of(context).colorScheme.secondary;
    // Sky-600 on its own tint is too dim on the dark slate surfaces, so the
    // text is lifted toward white there; the fill and the border stay on the
    // true hue.
    final fg = Theme.of(context).brightness == Brightness.dark
        ? Color.lerp(hue, Colors.white, 0.45)!
        : hue;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: hue.withValues(alpha: _tagFillAlpha),
        borderRadius:
            BorderRadius.circular(RepeaterMarkerStyle.chipCornerRadius),
        border: Border.all(color: hue.withValues(alpha: _tagBorderAlpha)),
      ),
      child: Text(
        name,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}

/// The repeater sheet's Nickname button, beside Manage and the same height
/// and shape. Reads "Nickname" until one is set, then the nickname itself.
class RepeaterNicknameButton extends StatelessWidget {
  const RepeaterNicknameButton({
    super.key,
    required this.nickname,
    required this.onPressed,
  });

  final String? nickname;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final name = nickname;
    // Named for what it does: a bare "Mell, button" would not say the
    // button edits it.
    return Semantics(
      button: true,
      label: name == null ? 'Add nickname' : 'Edit nickname $name',
      onTap: onPressed,
      excludeSemantics: true,
      child: OutlinedButton.icon(
        icon: Icon(name == null ? Icons.add : Icons.label_outline, size: 18),
        label: Text(
          name ?? 'Nickname',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onPressed: onPressed,
      ),
    );
  }
}
