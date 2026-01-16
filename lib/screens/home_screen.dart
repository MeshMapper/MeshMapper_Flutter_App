import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import '../widgets/connection_panel.dart';
import '../widgets/map_widget.dart';
import '../widgets/ping_controls.dart';
import '../widgets/status_bar.dart';
import '../widgets/stats_panel.dart';
import 'connection_screen.dart';
import 'settings_screen.dart';

/// Main wardrive interface
/// Responsive layout: desktop/tablet shows side panel, mobile uses bottom sheet
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _showControlPanel = true;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final isWideScreen = MediaQuery.of(context).size.width > 800;

    return Scaffold(
      appBar: AppBar(
        title: const Text('MeshMapper'),
        actions: [
          // Queue indicator
          if (appState.queueSize > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Chip(
                avatar: const Icon(Icons.cloud_upload, size: 18),
                label: Text('${appState.queueSize}'),
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              ),
            ),
          
          // Connection status indicator
          IconButton(
            icon: Icon(
              appState.isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
              color: appState.isConnected ? Colors.green : null,
            ),
            onPressed: () => _navigateToConnection(context),
            tooltip: appState.isConnected ? 'Connected' : 'Connect device',
          ),
          
          // Settings
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _navigateToSettings(context),
            tooltip: 'Settings',
          ),
        ],
      ),
      body: isWideScreen ? _buildWideLayout(appState) : _buildNarrowLayout(appState),
      floatingActionButton: !isWideScreen && !_showControlPanel
          ? FloatingActionButton.extended(
              onPressed: () => setState(() => _showControlPanel = true),
              icon: const Icon(Icons.tune),
              label: const Text('Controls'),
            )
          : null,
    );
  }

  /// Wide screen layout (tablet/desktop): side-by-side
  Widget _buildWideLayout(AppStateProvider appState) {
    return Row(
      children: [
        // Map takes most space
        Expanded(
          flex: 3,
          child: Column(
            children: [
              const StatusBar(),
              const Expanded(child: MapWidget()),
            ],
          ),
        ),
        
        // Control panel on right
        SizedBox(
          width: 320,
          child: Card(
            margin: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(),
            child: Column(
              children: [
                const ConnectionPanel(),
                const Divider(),
                const PingControls(),
                const Divider(),
                const Expanded(child: StatsPanel()),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Narrow screen layout (mobile): stacked with collapsible panel
  Widget _buildNarrowLayout(AppStateProvider appState) {
    return Stack(
      children: [
        // Map fills entire screen
        Column(
          children: [
            const StatusBar(),
            const Expanded(child: MapWidget()),
          ],
        ),
        
        // Control panel overlay
        if (_showControlPanel)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildMobileControlPanel(),
          ),
      ],
    );
  }

  Widget _buildMobileControlPanel() {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header with close button
          ListTile(
            title: const Text('Controls', style: TextStyle(fontWeight: FontWeight.bold)),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _showControlPanel = false),
            ),
          ),
          const Divider(height: 1),
          
          // Compact connection info
          const Padding(
            padding: EdgeInsets.all(12),
            child: ConnectionPanel(compact: true),
          ),
          
          // Ping controls
          const Padding(
            padding: EdgeInsets.all(12),
            child: PingControls(),
          ),
          
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  void _navigateToConnection(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ConnectionScreen()),
    );
  }

  void _navigateToSettings(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SettingsScreen()),
    );
  }
}
