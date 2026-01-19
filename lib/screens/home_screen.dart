import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import '../services/status_message_service.dart';
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
  bool _showStatusIsland = false; // Default to closed

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
            icon: Icons.signal_cellular_alt,
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

        // Dynamic status island (floating on bottom left - stationary)
        Positioned(
          bottom: 16,
          left: 12,
          child: _showStatusIsland
              ? _DynamicStatusIsland(
                  statusService: appState.statusMessageService,
                  onClose: () => setState(() => _showStatusIsland = false),
                )
              : _StatusIslandToggle(
                  onOpen: () => setState(() => _showStatusIsland = true),
                ),
        ),

        // Control panel overlay
        if (_showControlPanel)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildControlPanel(),
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

/// Floating status island widget
class _DynamicStatusIsland extends StatelessWidget {
  final StatusMessageService statusService;
  final VoidCallback onClose;

  const _DynamicStatusIsland({
    required this.statusService,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<StatusMessage?>(
      stream: statusService.stream,
      initialData: statusService.currentMessage,
      builder: (context, snapshot) {
        final message = snapshot.data;
        final color = message != null ? _getColor(message.color) : Colors.grey.shade400;
        final text = message?.text ?? 'Ready';

        return Container(
          padding: const EdgeInsets.only(left: 14, right: 6, top: 8, bottom: 8),
          decoration: BoxDecoration(
            color: Colors.grey.shade900.withOpacity(0.9),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: color.withOpacity(0.4),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Status indicator dot
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: color.withOpacity(0.5),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // Status text
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade100,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              // Close button
              GestureDetector(
                onTap: onClose,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade800,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    Icons.close,
                    size: 14,
                    color: Colors.grey.shade400,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Color _getColor(StatusColor statusColor) {
    switch (statusColor) {
      case StatusColor.idle:
        return Colors.grey.shade400;
      case StatusColor.info:
        return Colors.blue.shade400;
      case StatusColor.success:
        return Colors.green.shade400;
      case StatusColor.warning:
        return Colors.amber.shade400;
      case StatusColor.error:
        return Colors.red.shade400;
    }
  }
}

/// Small toggle button to re-open the status island
class _StatusIslandToggle extends StatelessWidget {
  final VoidCallback onOpen;

  const _StatusIslandToggle({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onOpen,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.grey.shade900.withOpacity(0.9),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(
          Icons.info_outline,
          size: 18,
          color: Colors.grey.shade300,
        ),
      ),
    );
  }
}
