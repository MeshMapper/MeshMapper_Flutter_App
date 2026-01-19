import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/connection_state.dart';
import '../providers/app_state_provider.dart';

/// Status bar showing GPS, connection, and queue status
class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

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

  Widget _buildGpsRegionChip(BuildContext context, AppStateProvider appState) {
    IconData icon;
    Color color;
    String text;

    // Show GPS region (e.g., "YOW") when locked and inside a zone
    switch (appState.gpsStatus) {
      case GpsStatus.locked:
        // Check if we're in a zone and have zone code from API
        if (appState.inZone == true && appState.zoneCode != null) {
          icon = Icons.location_on;
          color = Colors.green;
          text = appState.zoneCode!;
        } else if (appState.inZone == false) {
          // GPS locked but outside any zone
          icon = Icons.location_on;
          color = Colors.orange;
          text = '—';
        } else {
          // GPS locked but zone not checked yet
          icon = Icons.location_on;
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
        icon = Icons.location_off;
        color = Colors.red;
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

    return _buildStatChip(icon: icon, value: text, color: color);
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
        ),

        const SizedBox(width: 8),

        // RX count chip
        _buildStatChip(
          icon: Icons.arrow_downward,
          value: '${appState.pingStats.rxCount}',
          color: Colors.blue,
        ),

        const SizedBox(width: 8),

        // Uploaded count chip
        _buildStatChip(
          icon: Icons.cloud_done,
          value: '${appState.pingStats.successfulUploads}',
          color: Colors.teal[400]!,
        ),
      ],
    );
  }

  Widget _buildStatChip({
    required IconData icon,
    required String value,
    required Color color,
  }) {
    return Container(
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
    );
  }
}
