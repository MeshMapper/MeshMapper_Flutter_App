import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/repeater.dart';
import '../providers/app_state_provider.dart';
import '../services/gps_service.dart';
import '../utils/debug_logger_io.dart';
import '../utils/distance_formatter.dart';
import '../utils/ping_colors.dart';

/// A styled repeater ID text with a dotted underline hint that it's tappable.
///
/// Displays the hex repeater ID (2/4/6 chars) in monospace style. Use together
/// with [RepeaterIdChip.showRepeaterPopup] on the parent row's `InkWell` so
/// the entire row is the tap target.
class RepeaterIdChip extends StatelessWidget {
  /// The hex repeater ID (e.g., "4E", "4F5D", "4F5D82")
  final String repeaterId;

  /// Font size for the ID text (11 for log screens, 13 for map popups)
  final double fontSize;

  /// Optional SizedBox width constraint (e.g., 50 or 60)
  final double? width;

  const RepeaterIdChip({
    super.key,
    required this.repeaterId,
    this.fontSize = 11,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    // Scale font size down for longer IDs
    final effectiveFontSize = repeaterId.length > 4
        ? fontSize - 2.0  // 6-char IDs (3-byte)
        : repeaterId.length > 2
            ? fontSize - 1.0  // 4-char IDs (2-byte)
            : fontSize;        // 2-char IDs (1-byte)

    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          repeaterId,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: TextStyle(
            fontSize: effectiveFontSize,
            fontWeight: FontWeight.w600,
            fontFamily: 'monospace',
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(width: 2),
        Icon(
          Icons.info_outline,
          size: fontSize - 1,
          color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
        ),
      ],
    );

    if (width != null) {
      return SizedBox(width: width, child: child);
    }
    return child;
  }

  /// Show a dialog with matching repeater names for the given [repeaterId].
  ///
  /// Call this from the parent row's `InkWell.onTap` so the entire row is
  /// tappable, not just the tiny ID text.
  ///
  /// For DISC pings, pass [fullHexId] (the full public key hex) to enable
  /// exact 4-byte matching against the repeater database instead of the
  /// ambiguous 1-byte prefix match used for TX/RX pings.
  /// Show a dialog with matching repeater names for the given [repeaterId].
  ///
  /// When [fromLatLng] is provided, distances are measured from that point
  /// (e.g. the ping's GPS location) instead of the user's current position.
  static void showRepeaterPopup(BuildContext context, String repeaterId, {String? fullHexId, ({double lat, double lon})? fromLatLng}) {
    final appState = Provider.of<AppStateProvider>(context, listen: false);
    final repeaters = appState.repeaters;

    final Widget content;

    if (repeaters.isEmpty) {
      content = Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Repeater data not available',
          style: TextStyle(
            fontStyle: FontStyle.italic,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 13,
          ),
        ),
      );
    } else {
      // DISC pings provide the full public key — match first 8 hex chars
      // (4 bytes) against repeater hexId for exact identification.
      // TX/RX pings only have 1-byte IDs so fall back to prefix matching.
      final matchKey = fullHexId != null && fullHexId.length >= 8
          ? fullHexId.substring(0, 8)
          : repeaterId;
      final matches = repeaters
          .where((r) => r.hexId.toLowerCase().startsWith(matchKey.toLowerCase()))
          .toList();

      if (matches.isEmpty) {
        content = Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'Unknown repeater',
            style: TextStyle(
              fontStyle: FontStyle.italic,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 13,
            ),
          ),
        );
      } else {
        // Use explicit origin point if provided, otherwise fall back to current GPS
        final position = appState.currentPosition;
        final refLat = fromLatLng?.lat ?? position?.latitude;
        final refLon = fromLatLng?.lon ?? position?.longitude;

        // Sort by distance (closest first) when a reference point is available
        if (refLat != null && refLon != null) {
          matches.sort((a, b) {
            final distA = GpsService.distanceBetween(refLat, refLon, a.lat, a.lon);
            final distB = GpsService.distanceBetween(refLat, refLon, b.lat, b.lon);
            return distA.compareTo(distB);
          });
        }

        final regionOverride = appState.enforceHopBytes ? appState.effectiveHopBytes : null;
        content = Column(
          mainAxisSize: MainAxisSize.min,
          children: matches
              .map((r) => _buildRepeaterRow(context, r, refLat: refLat, refLon: refLon, regionHopBytesOverride: regionOverride))
              .toList(),
        );
      }
    }

    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Icon(
                      Icons.cell_tower,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Node ${repeaterId.toUpperCase()}',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace',
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Divider(height: 1, color: Theme.of(context).dividerColor),
                const SizedBox(height: 12),
                // Content
                content,
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Widget _buildRepeaterRow(
    BuildContext context,
    Repeater repeater, {
    double? refLat,
    double? refLon,
    int? regionHopBytesOverride,
  }) {
    final isActive = repeater.isActive;
    final badgeColor = isActive ? PingColors.repeaterActive : PingColors.repeaterDead;
    final statusText = isActive ? 'Active' : 'Stale';
    final statusIcon = isActive ? Icons.circle : Icons.circle_outlined;

    // Calculate distance string if a reference point is available
    String? distanceText;
    if (refLat != null && refLon != null) {
      final meters = GpsService.distanceBetween(
        refLat, refLon, repeater.lat, repeater.lon,
      );
      debugLog('[UI] Distance to ${repeater.name}: '
          'from (${refLat.toStringAsFixed(5)}, ${refLon.toStringAsFixed(5)}) '
          'to (${repeater.lat.toStringAsFixed(5)}, ${repeater.lon.toStringAsFixed(5)}) '
          '= ${meters.toStringAsFixed(0)}m');
      final isImperial = Provider.of<AppStateProvider>(context, listen: false)
          .preferences
          .isImperial;
      if (meters < 1000) {
        distanceText = formatMeters(meters, isImperial: isImperial);
      } else {
        distanceText =
            formatKilometers(meters / 1000, isImperial: isImperial);
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          // Colored badge — circle for short IDs, pill for longer
          _buildHexBadge(repeater.displayHexId(overrideHopBytes: regionHopBytesOverride), badgeColor),
          const SizedBox(width: 12),
          // Repeater name + distance subtitle
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  repeater.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (distanceText != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.near_me,
                          size: 10,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          distanceText,
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Active/Stale chip (icon + text for colorblind accessibility)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: badgeColor.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(statusIcon, size: 8, color: badgeColor),
                const SizedBox(width: 4),
                Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 11,
                    color: badgeColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build a hex ID badge — circle for 2-char, pill for longer IDs
  static Widget _buildHexBadge(String displayId, Color color) {
    final isLong = displayId.length > 2;

    return Container(
      constraints: const BoxConstraints(minWidth: 28),
      height: 28,
      padding: isLong
          ? const EdgeInsets.symmetric(horizontal: 5)
          : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      child: Text(
        displayId,
        style: TextStyle(
          fontSize: displayId.length > 4 ? 8 : 10,
          fontWeight: FontWeight.bold,
          color: Colors.white,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}
