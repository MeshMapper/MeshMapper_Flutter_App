import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/connection_state.dart';
import '../providers/app_state_provider.dart';

/// Status bar showing GPS, connection, and queue status
class StatusBar extends StatefulWidget {
  const StatusBar({super.key});

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // GPS region indicator (chip style)
          _buildGpsRegionChip(context, appState),

          const Spacer(),

          // Stats summary
          _buildStatsIndicator(context, appState),
        ],
      ),
    );
  }

  /// Show info popup as bottom sheet
  void _showInfoPopup(BuildContext context, String id) {
    final appState = context.read<AppStateProvider>();
    final (title, description, icon, color) = _getPopupContent(id, appState);

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Content
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 24, color: color),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: color,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        description,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade600,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// Get content for the popup based on ID
  (String, String, IconData, Color) _getPopupContent(String id, AppStateProvider appState) {
    switch (id) {
      case 'gps':
        if (appState.offlineMode) {
          return ('Offline Mode Active', 'Pings are saved locally. Zone detection is paused until you go back online.', Icons.flight, Colors.grey);
        }
        if (appState.inZone == true && appState.zoneCode != null) {
          return ('${appState.zoneName ?? appState.zoneCode} Zone',
            'You\'re in an active zone with ${appState.zoneSlotsAvailable ?? "?"} TX slots available. Ready to wardrive!',
            Icons.flight, Colors.green);
        }
        if (appState.inZone == false) {
          final nearest = appState.nearestZoneName ?? 'Unknown';
          final dist = appState.nearestZoneDistanceKm?.toStringAsFixed(1) ?? '?';
          return ('Outside Coverage Area', 'Nearest zone is $nearest, ${dist}km away. Enter a zone to start wardriving.', Icons.flight, Colors.orange);
        }
        return ('Locating...', 'Acquiring GPS signal and checking your zone status.', Icons.gps_not_fixed, Colors.blue);

      case 'tx':
        return ('TX Packets', 'TX packets that have been sent out. These are messages to the #wardriving channel.', Icons.arrow_upward, Colors.green);

      case 'rx':
        return ('RX Packets', 'RX packets that we have heard from the mesh. These were not initiated by us.', Icons.arrow_downward, Colors.blue);

      case 'disc':
        return ('Discovery Requests', 'Discovery request packets we have sent out.', Icons.radar, const Color(0xFF7B68EE));

      case 'upload':
        return ('Uploaded', 'Pings sent to MeshMapper servers. Your data helps build the community coverage map!', Icons.cloud_done, Colors.teal);

      default:
        return ('Info', '', Icons.info, Colors.grey);
    }
  }

  Widget _buildGpsRegionChip(BuildContext context, AppStateProvider appState) {
    IconData icon;
    Color color;
    String text;

    // Offline mode: show greyed out with "-"
    if (appState.offlineMode) {
      icon = Icons.flight;
      color = Colors.grey;
      text = '-';
      return _buildStatChip(icon: icon, value: text, color: color, onTap: () => _showInfoPopup(context, 'gps'));
    }

    // Show GPS region (e.g., "YOW") when locked and inside a zone
    switch (appState.gpsStatus) {
      case GpsStatus.locked:
        // Check if we're in a zone and have zone code from API
        if (appState.inZone == true && appState.zoneCode != null) {
          icon = Icons.flight;
          color = Colors.green;
          text = appState.zoneCode!;
        } else if (appState.inZone == false) {
          // GPS locked but outside any zone
          icon = Icons.flight;
          color = Colors.orange;
          text = '—';
        } else {
          // GPS locked but zone not checked yet
          icon = Icons.flight;
          color = Colors.green;
          text = '...';
        }
        break;
      case GpsStatus.searching:
        icon = Icons.gps_not_fixed;
        color = Colors.orange;
        text = 'GPS...';
        break;
      case GpsStatus.outsideGeofence:
        // Note: This state is no longer set - zone validation is handled by API
        // Falls through to same display as locked outside zone
        icon = Icons.flight;
        color = Colors.orange;
        text = '—';
        break;
      case GpsStatus.disabled:
        icon = Icons.location_disabled;
        color = Colors.grey;
        text = 'OFF';
        break;
      case GpsStatus.permissionDenied:
        icon = Icons.location_disabled;
        color = Colors.red;
        text = '!';
        break;
    }

    return _buildStatChip(icon: icon, value: text, color: color, onTap: () => _showInfoPopup(context, 'gps'));
  }

  Widget _buildStatsIndicator(BuildContext context, AppStateProvider appState) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // TX count chip
        _buildStatChip(
          icon: Icons.arrow_upward,
          value: '${appState.pingStats.txCount}',
          color: Colors.green,
          onTap: () => _showInfoPopup(context, 'tx'),
        ),

        const SizedBox(width: 8),

        // RX count chip
        _buildStatChip(
          icon: Icons.arrow_downward,
          value: '${appState.pingStats.rxCount}',
          color: Colors.blue,
          onTap: () => _showInfoPopup(context, 'rx'),
        ),

        const SizedBox(width: 8),

        // DISC count chip
        _buildStatChip(
          icon: Icons.radar,
          value: '${appState.pingStats.discCount}',
          color: const Color(0xFF7B68EE),  // DISC purple
          onTap: () => _showInfoPopup(context, 'disc'),
        ),

        const SizedBox(width: 8),

        // Uploaded count chip
        _buildStatChip(
          icon: Icons.cloud_done,
          value: '${appState.pingStats.successfulUploads}',
          color: Colors.teal[400]!,
          onTap: () => _showInfoPopup(context, 'upload'),
        ),
      ],
    );
  }

  Widget _buildStatChip({
    required IconData icon,
    required String value,
    required Color color,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              value,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
