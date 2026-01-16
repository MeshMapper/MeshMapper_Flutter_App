import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';

/// Settings screen for user preferences and API configuration
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          // Device Info section
          _buildSectionHeader(context, 'Device'),
          ListTile(
            leading: const Icon(Icons.perm_identity),
            title: const Text('Device ID'),
            subtitle: Text(appState.deviceId),
          ),
          
          const Divider(),
          
          // Queue section
          _buildSectionHeader(context, 'API Queue'),
          ListTile(
            leading: const Icon(Icons.cloud_queue),
            title: const Text('Queued Pings'),
            subtitle: Text('${appState.queueSize} items waiting'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.cloud_upload),
                  onPressed: appState.queueSize > 0
                      ? () => appState.forceUploadQueue()
                      : null,
                  tooltip: 'Force upload',
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: appState.queueSize > 0
                      ? () => _confirmClearQueue(context, appState)
                      : null,
                  tooltip: 'Clear queue',
                ),
              ],
            ),
          ),
          
          const Divider(),
          
          // Statistics section
          _buildSectionHeader(context, 'Statistics'),
          ListTile(
            leading: const Icon(Icons.send),
            title: const Text('TX Pings'),
            trailing: Text(
              '${appState.pingStats.txCount}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.call_received),
            title: const Text('RX Pings'),
            trailing: Text(
              '${appState.pingStats.rxCount}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.check_circle),
            title: const Text('Successful Uploads'),
            trailing: Text(
              '${appState.pingStats.successfulUploads}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever),
            title: const Text('Clear Map Markers'),
            onTap: () => _confirmClearPings(context, appState),
          ),
          
          const Divider(),
          
          // About section
          _buildSectionHeader(context, 'About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('MeshMapper'),
            subtitle: const Text('Version 1.0.0'),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('Source Code'),
            subtitle: const Text('github.com/MeshMapper/MeshMapper_Flutter_App'),
          ),
          ListTile(
            leading: const Icon(Icons.book),
            title: const Text('Documentation'),
            subtitle: const Text('MeshCore wardriving app'),
          ),
          
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }

  void _confirmClearQueue(BuildContext context, AppStateProvider appState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Queue?'),
        content: Text(
          'This will permanently delete ${appState.queueSize} queued pings that haven\'t been uploaded yet.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              appState.clearQueue();
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  void _confirmClearPings(BuildContext context, AppStateProvider appState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Map Markers?'),
        content: const Text(
          'This will remove all TX/RX markers from the map. This won\'t affect uploaded data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              appState.clearPings();
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}
