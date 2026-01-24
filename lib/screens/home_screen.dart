import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import '../widgets/connection_panel.dart';
import '../widgets/map_widget.dart';
import '../widgets/ping_controls.dart';
import '../widgets/status_bar.dart';

/// Main wardrive interface
/// Single unified layout with full-screen map and collapsible bottom control panel
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _showControlPanel = true;
  bool _isControlsMinimized = false;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'MeshMapper',
              style: TextStyle(fontSize: 18),
            ),
              Text(
                appState.connectedDeviceName != null
                    ? _buildSubtitle(appState)
                    : 'Disconnected',
                style: TextStyle(
                  fontSize: 12,
                  color: appState.connectedDeviceName != null
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Colors.grey,
                ),
            ),
          ],
        ),
        actions: [
          // Noise floor indicator (always visible, greyed when disconnected)
          _buildStatIndicator(
            icon: Icons.volume_up,
            value: appState.currentNoiseFloor != null
                ? '${appState.currentNoiseFloor}'
                : '--',
            unit: 'dBm',
            color: appState.currentNoiseFloor != null
                ? _getNoiseFloorColor(appState.currentNoiseFloor!)
                : Colors.grey,
          ),

          // Battery indicator (always visible, greyed when disconnected)
          _buildStatIndicator(
            icon: appState.currentBatteryPercent != null
                ? _getBatteryIcon(appState.currentBatteryPercent!)
                : Icons.battery_unknown,
            value: appState.currentBatteryPercent != null
                ? '${appState.currentBatteryPercent}'
                : '--',
            unit: '%',
            color: appState.currentBatteryPercent != null
                ? _getBatteryColor(appState.currentBatteryPercent!)
                : Colors.grey,
          ),

          const SizedBox(width: 8),
        ],
      ),
      body: _buildLayout(appState),
      floatingActionButton: !_showControlPanel
          ? FloatingActionButton.extended(
              onPressed: () => setState(() => _showControlPanel = true),
              icon: const Icon(Icons.tune),
              label: const Text('Controls'),
            )
          : null,
    );
  }

  /// Unified layout: full-screen map with collapsible bottom control panel
  Widget _buildLayout(AppStateProvider appState) {
    return Stack(
      children: [
        // Map fills entire screen
        const Column(
          children: [
            StatusBar(),
            Expanded(child: MapWidget()),
          ],
        ),

        // Control panel overlay
        if (_showControlPanel)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _isControlsMinimized
                ? _buildCompactControlPanel()
                : _buildControlPanel(),
          ),
      ],
    );
  }

  Widget _buildControlPanel() {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header with help, minimize, and close buttons
          ListTile(
            title: const Text('Controls', style: TextStyle(fontWeight: FontWeight.bold)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.help_outline),
                  onPressed: () => _showControlsHelp(context),
                  tooltip: 'Help',
                ),
                IconButton(
                  icon: const Icon(Icons.close_fullscreen),
                  onPressed: () => setState(() => _isControlsMinimized = true),
                  tooltip: 'Minimize',
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _showControlPanel = false),
                  tooltip: 'Close',
                ),
              ],
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

  /// Build compact minimized control panel
  Widget _buildCompactControlPanel() {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            // Compact controls (expands to fill available space)
            const Expanded(
              child: CompactPingControls(),
            ),
            // Vertical divider
            Container(
              height: 24,
              width: 1,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              color: Colors.grey.withValues(alpha: 0.3),
            ),
            // Expand button
            GestureDetector(
              onTap: () => setState(() => _isControlsMinimized = false),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(
                  Icons.open_in_full,
                  size: 20,
                  color: Colors.grey.shade500,
                ),
              ),
            ),
            // Close button
            GestureDetector(
              onTap: () => setState(() => _showControlPanel = false),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(
                  Icons.close,
                  size: 20,
                  color: Colors.grey.shade500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Show help bottom sheet explaining each control
  void _showControlsHelp(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.help_outline, color: Colors.blue),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Controls Help',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Divider(height: 24),

              // External Antenna
              _buildHelpItem(
                icon: Icons.settings_input_antenna,
                color: Colors.orange,
                title: 'External Antenna',
                description: 'Enable if using an external antenna (ex: mag mount on roof of car). We store this along with pings as external antennas can make a big difference in reception.',
              ),

              // Send Ping button
              _buildHelpItem(
                icon: Icons.cell_tower,
                color: const Color(0xFF0EA5E9),
                title: 'Send Ping',
                description: 'Send a single ping to #wardriving and track which repeaters heard it.',
              ),

              // Active Mode button
              _buildHelpItem(
                icon: Icons.sensors,
                color: const Color(0xFF6366F1),
                title: 'Active Mode',
                description: 'Auto-pings #wardriving at your set interval, tracks repeaters from pings and received mesh traffic.',
              ),

              // Passive Mode button
              _buildHelpItem(
                icon: Icons.hearing,
                color: const Color(0xFF6366F1),
                title: 'Passive Mode',
                description: 'Sends zero-hop discovery pings every 30s, tracks nearby repeaters and received mesh traffic.',
              ),

              // Offline mode toggle
              _buildHelpItem(
                icon: Icons.cloud_off,
                color: Colors.orange,
                title: 'Offline Mode',
                description: 'Save pings locally instead of uploading immediately. Useful when you have poor connectivity. Upload saved sessions later from the Settings tab.',
              ),

              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// Build a single help item
  Widget _buildHelpItem({
    required IconData icon,
    required Color color,
    required String title,
    required String description,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build subtitle with device name only
  String _buildSubtitle(AppStateProvider appState) {
    return appState.connectedDeviceName!.replaceFirst('MeshCore-', '');
  }

  /// Build compact stat indicator for app bar
  Widget _buildStatIndicator({
    required IconData icon,
    required String value,
    required String unit,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          Text(
            unit,
            style: TextStyle(
              fontSize: 10,
              color: color.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  /// Get color based on noise floor value (lower is better)
  Color _getNoiseFloorColor(int noiseFloor) {
    if (noiseFloor <= -100) return Colors.green;   // -100 to -120: great
    if (noiseFloor <= -90) return Colors.orange;   // -90 to -100: okay
    return Colors.red;                              // 0 to -90: bad
  }

  /// Get battery icon based on percentage
  IconData _getBatteryIcon(int percent) {
    if (percent >= 90) return Icons.battery_full;
    if (percent >= 70) return Icons.battery_6_bar;
    if (percent >= 50) return Icons.battery_5_bar;
    if (percent >= 30) return Icons.battery_3_bar;
    if (percent >= 15) return Icons.battery_2_bar;
    return Icons.battery_1_bar;
  }

  /// Get battery color based on percentage
  Color _getBatteryColor(int percent) {
    if (percent >= 50) return Colors.green;
    if (percent >= 20) return Colors.orange;
    return Colors.red;
  }
}

