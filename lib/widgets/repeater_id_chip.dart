import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../models/repeater.dart';
import '../providers/app_state_provider.dart';
import '../services/gps_service.dart';
import '../utils/debug_logger_io.dart';
import '../utils/distance_formatter.dart';

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
    // Scale font size down for longer IDs (4+ chars)
    final effectiveFontSize = repeaterId.length > 2 ? fontSize - 1.0 : fontSize;

    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          repeaterId,
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
  static void showRepeaterPopup(BuildContext context, String repeaterId, {String? fullHexId}) {
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
        final position = appState.currentPosition;

        // Sort by distance (closest first) when GPS is available
        if (position != null) {
          matches.sort((a, b) {
            final distA = GpsService.distanceBetween(
              position.latitude, position.longitude, a.lat, a.lon,
            );
            final distB = GpsService.distanceBetween(
              position.latitude, position.longitude, b.lat, b.lon,
            );
            return distA.compareTo(distB);
          });
        }

        content = Column(
          mainAxisSize: MainAxisSize.min,
          children: matches
              .map((r) => _buildRepeaterRow(context, r, position: position))
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
    Position? position,
  }) {
    final isActive = repeater.isActive;
    final badgeColor = isActive ? Colors.green : Colors.grey;
    final statusText = isActive ? 'Active' : 'Stale';

    // Calculate distance string if GPS is available
    String? distanceText;
    if (position != null) {
      final meters = GpsService.distanceBetween(
        position.latitude, position.longitude, repeater.lat, repeater.lon,
      );
      debugLog('[UI] Distance to ${repeater.name}: '
          'from (${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}) '
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
          // Colored circle badge
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: badgeColor,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              repeater.hexId.length >= 2
                  ? repeater.hexId.substring(0, 2).toUpperCase()
                  : repeater.hexId.toUpperCase(),
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                fontFamily: 'monospace',
              ),
            ),
          ),
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
          // Active/Stale chip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: badgeColor.withValues(alpha: 0.4)),
            ),
            child: Text(
              statusText,
              style: TextStyle(
                fontSize: 11,
                color: badgeColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
