import 'package:flutter/material.dart';

import 'repeater_id_chip.dart';

/// Compact arrow-chain renderer for an RX packet's hop path.
///
/// Renders `[hop] → [hop] → [hop] (heard)` with each hop as a tappable
/// [RepeaterIdChip]. Long paths wrap to multiple lines via [Wrap].
class RxPathChain extends StatelessWidget {
  /// Hop list ordered origin → ... → us. Already CARpeater-stripped.
  final List<String> hops;

  /// Source GPS coordinates passed through to the repeater info popup so
  /// distances are measured from the ping location, not the user's current
  /// position.
  final ({double lat, double lon})? fromLatLng;

  /// Font size for hop chips (11 for log screens, 13 for map popups).
  final double fontSize;

  const RxPathChain({
    super.key,
    required this.hops,
    this.fromLatLng,
    this.fontSize = 12,
  });

  @override
  Widget build(BuildContext context) {
    if (hops.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final arrow = Icon(
      Icons.arrow_forward,
      size: fontSize,
      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
    );

    final children = <Widget>[];
    for (var i = 0; i < hops.length; i++) {
      if (i > 0) children.add(arrow);
      children.add(
        InkWell(
          onTap: () => RepeaterIdChip.showRepeaterPopup(
            context,
            hops[i],
            fromLatLng: fromLatLng,
          ),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: RepeaterIdChip(repeaterId: hops[i], fontSize: fontSize),
          ),
        ),
      );
    }
    children.add(
      Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Text(
          '(heard)',
          style: TextStyle(
            fontSize: fontSize - 2,
            fontStyle: FontStyle.italic,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 2,
      runSpacing: 4,
      children: children,
    );
  }
}
