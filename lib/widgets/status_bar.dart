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
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          // GPS status
          _buildGpsIndicator(context, appState),
          
          const SizedBox(width: 12),
          const VerticalDivider(width: 1),
          const SizedBox(width: 12),
          
          // Connection status
          _buildConnectionIndicator(context, appState),
          
          const Spacer(),
          
          // Queue status
          _buildQueueIndicator(context, appState),
          
          const SizedBox(width: 12),
          
          // Stats summary
          _buildStatsIndicator(context, appState),
        ],
      ),
    );
  }

  Widget _buildGpsIndicator(BuildContext context, AppStateProvider appState) {
    IconData icon;
    Color color;
    String text;

    switch (appState.gpsStatus) {
      case GpsStatus.locked:
        icon = Icons.gps_fixed;
        color = Colors.green;
        text = 'GPS OK';
        break;
      case GpsStatus.searching:
        icon = Icons.gps_not_fixed;
        color = Colors.orange;
        text = 'Searching...';
        break;
      case GpsStatus.outsideGeofence:
        icon = Icons.gps_off;
        color = Colors.red;
        text = 'Outside area';
        break;
      case GpsStatus.disabled:
        icon = Icons.location_disabled;
        color = Colors.grey;
        text = 'GPS disabled';
        break;
      case GpsStatus.permissionDenied:
        icon = Icons.location_disabled;
        color = Colors.red;
        text = 'No permission';
        break;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(fontSize: 12, color: color),
        ),
      ],
    );
  }

  Widget _buildConnectionIndicator(BuildContext context, AppStateProvider appState) {
    final isConnected = appState.isConnected;
    
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
          size: 16,
          color: isConnected ? Colors.green : Colors.grey,
        ),
        const SizedBox(width: 4),
        Text(
          isConnected
              ? appState.deviceModel?.shortName ?? 'Connected'
              : 'Disconnected',
          style: TextStyle(
            fontSize: 12,
            color: isConnected ? Colors.green : Colors.grey,
          ),
        ),
      ],
    );
  }

  Widget _buildQueueIndicator(BuildContext context, AppStateProvider appState) {
    final queueSize = appState.queueSize;
    
    if (queueSize == 0) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_upload,
            size: 14,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: 4),
          Text(
            '$queueSize',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsIndicator(BuildContext context, AppStateProvider appState) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // TX count
        Icon(Icons.arrow_upward, size: 14, color: Colors.green),
        const SizedBox(width: 2),
        Text(
          '${appState.pingStats.txCount}',
          style: const TextStyle(fontSize: 12),
        ),
        
        const SizedBox(width: 8),
        
        // RX count
        Icon(Icons.arrow_downward, size: 14, color: Colors.blue),
        const SizedBox(width: 2),
        Text(
          '${appState.pingStats.rxCount}',
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}
