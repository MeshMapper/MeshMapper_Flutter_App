import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/connection_state.dart';
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

  /// Landscape mode: map controls expanded state (mutually exclusive with control panel)
  bool _mapControlsExpanded = false;

  /// Landscape side panel width (220px gives more room for controls)
  static const double _landscapePanelWidth = 220.0;

  /// Toggle control panel in landscape mode (closes map controls if open)
  void _toggleControlPanel() {
    setState(() {
      if (_showControlPanel) {
        // Closing control panel
        _showControlPanel = false;
      } else {
        // Opening control panel - close map controls first
        _mapControlsExpanded = false;
        _showControlPanel = true;
      }
    });
  }

  /// Toggle map controls in landscape mode (closes control panel if open)
  void _toggleMapControls() {
    setState(() {
      if (_mapControlsExpanded) {
        // Closing map controls
        _mapControlsExpanded = false;
      } else {
        // Opening map controls - close control panel first
        _showControlPanel = false;
        _mapControlsExpanded = true;
      }
    });
  }

  /// Calculate the current control panel height for map centering offset (portrait mode)
  double _getControlPanelHeight() {
    // In landscape, panel is on the side, not bottom
    if (MediaQuery.of(context).orientation == Orientation.landscape) {
      return 0;
    }
    if (!_showControlPanel) return 0;
    // Approximate heights including Card margins (8px * 2 = 16px)
    // Minimized: Row padding (12) + content (~32) + margin (16) = ~60px
    // Expanded: ListTile (56) + Divider (1) + ConnectionPanel (~100) + PingControls (~140) + margin (16) = ~320px
    return _isControlsMinimized ? 60 : 320;
  }


  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    // In landscape: no AppBar, everything on map overlays
    if (isLandscape) {
      return Scaffold(
        body: _buildLayout(appState),
      );
    }

    // Portrait: standard AppBar
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: _buildPortraitAppBarTitle(appState),
        actions: [
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

  /// Portrait AppBar title (just MeshMapper + device name)
  Widget _buildPortraitAppBarTitle(AppStateProvider appState) {
    return Column(
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
    );
  }

  /// Stats row for AppBar/floating status bar (matches StatusBar exactly)
  Widget _buildAppBarStats(AppStateProvider appState, {bool withTapHandlers = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // TX count
        _buildAppBarStatChip(
          Icons.arrow_upward,
          appState.pingStats.txCount,
          Colors.green,
          onTap: withTapHandlers ? () => _showInfoPopup('tx', appState) : null,
        ),
        const SizedBox(width: 8),
        // RX count
        _buildAppBarStatChip(
          Icons.arrow_downward,
          appState.pingStats.rxCount,
          Colors.blue,
          onTap: withTapHandlers ? () => _showInfoPopup('rx', appState) : null,
        ),
        const SizedBox(width: 8),
        // DISC count
        _buildAppBarStatChip(
          Icons.radar,
          appState.pingStats.discCount,
          const Color(0xFF7B68EE),
          onTap: withTapHandlers ? () => _showInfoPopup('disc', appState) : null,
        ),
        const SizedBox(width: 8),
        // Upload count
        _buildAppBarStatChip(
          Icons.cloud_done,
          appState.pingStats.successfulUploads,
          Colors.teal.shade400,
          onTap: withTapHandlers ? () => _showInfoPopup('upload', appState) : null,
        ),
      ],
    );
  }

  /// Stat chip for AppBar (same style as StatusBar)
  Widget _buildAppBarStatChip(IconData icon, int value, Color color, {VoidCallback? onTap}) {
    final chip = Container(
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
            '$value',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: chip);
    }
    return chip;
  }

  /// Show info popup as bottom sheet (same as StatusBar)
  void _showInfoPopup(String id, AppStateProvider appState) {
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

  /// Unified layout: orientation-aware with bottom panel (portrait) or side panel (landscape)
  Widget _buildLayout(AppStateProvider appState) {
    return OrientationBuilder(
      builder: (context, orientation) {
        final isLandscape = orientation == Orientation.landscape;

        if (isLandscape) {
          return _buildLandscapeLayout(appState);
        } else {
          return _buildPortraitLayout(appState);
        }
      },
    );
  }

  /// Portrait layout: StatusBar on top, map below, bottom control panel
  Widget _buildPortraitLayout(AppStateProvider appState) {
    return Stack(
      children: [
        // Map fills entire screen
        Column(
          children: [
            const StatusBar(),
            Expanded(child: MapWidget(bottomPaddingPixels: _getControlPanelHeight())),
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

  /// Landscape layout: No AppBar, floating overlays for status and controls
  Widget _buildLandscapeLayout(AppStateProvider appState) {
    // Get safe area padding for dynamic island/notch
    final safePadding = MediaQuery.of(context).padding;
    final leftInset = safePadding.left + 8; // Dynamic island + margin

    return Stack(
      children: [
        // Map takes full screen - pass map controls state for mutual exclusivity
        MapWidget(
          mapControlsExpanded: _mapControlsExpanded,
          onMapControlsToggle: _toggleMapControls,
        ),

        // Floating status bar at top center
        Positioned(
          top: 16,
          left: leftInset + 72, // Leave space for GPS info on left
          right: 60, // Leave space for map controls toggle on right
          child: Center(
            child: _buildFloatingStatusBar(appState),
          ),
        ),

        // Floating control panel on left side, near bottom
        if (_showControlPanel)
          Positioned(
            bottom: 16,
            left: leftInset,
            child: _buildLandscapeControlPanel(appState),
          ),

        // FAB to open control panel when closed (left side)
        if (!_showControlPanel)
          Positioned(
            bottom: 16,
            left: leftInset,
            child: FloatingActionButton.small(
              onPressed: _toggleControlPanel,
              child: const Icon(Icons.tune),
            ),
          ),
      ],
    );
  }

  /// Floating status bar for landscape mode (replaces AppBar)
  Widget _buildFloatingStatusBar(AppStateProvider appState) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Device name
          Text(
            appState.displayDeviceName ?? 'Disconnected',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: appState.connectedDeviceName != null
                  ? Colors.white
                  : Colors.grey.shade400,
            ),
          ),
          const SizedBox(width: 12),

          // Zone chip (tappable)
          GestureDetector(
            onTap: () => _showInfoPopup('gps', appState),
            child: _buildZoneChip(appState),
          ),
          const SizedBox(width: 8),

          // Stats (with tap handlers in landscape)
          _buildAppBarStats(appState, withTapHandlers: true),
          const SizedBox(width: 12),

          // Noise floor
          _buildFloatingStatIndicator(
            icon: Icons.volume_up,
            value: appState.currentNoiseFloor != null
                ? '${appState.currentNoiseFloor}'
                : '--',
            color: appState.currentNoiseFloor != null
                ? _getNoiseFloorColor(appState.currentNoiseFloor!)
                : Colors.grey,
          ),
          const SizedBox(width: 8),

          // Battery
          _buildFloatingStatIndicator(
            icon: appState.currentBatteryPercent != null
                ? _getBatteryIcon(appState.currentBatteryPercent!)
                : Icons.battery_unknown,
            value: appState.currentBatteryPercent != null
                ? '${appState.currentBatteryPercent}%'
                : '--%',
            color: appState.currentBatteryPercent != null
                ? _getBatteryColor(appState.currentBatteryPercent!)
                : Colors.grey,
          ),
        ],
      ),
    );
  }

  /// Compact stat indicator for floating status bar
  Widget _buildFloatingStatIndicator({
    required IconData icon,
    required String value,
    required Color color,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: color,
          ),
        ),
      ],
    );
  }

  /// Landscape floating control panel (compact, top-right corner)
  Widget _buildLandscapeControlPanel(AppStateProvider appState) {
    return Container(
      width: _landscapePanelWidth,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header with help and close buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            child: Row(
              children: [
                Text(
                  'Controls',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: Colors.grey.shade300,
                  ),
                ),
                const Spacer(),
                // Help button - larger touch target
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _showControlsHelp(context),
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.help_outline, size: 22, color: Colors.grey.shade400),
                    ),
                  ),
                ),
                // Close button - larger touch target
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => setState(() => _showControlPanel = false),
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.close, size: 22, color: Colors.grey.shade400),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: Colors.grey.withValues(alpha: 0.2)),

          // Controls (no scroll needed, sized to content)
          Padding(
            padding: const EdgeInsets.all(10),
            child: LandscapePingControls(
              onShowHelp: () => _showControlsHelp(context),
            ),
          ),
        ],
      ),
    );
  }

  /// Compact zone chip for landscape panel
  Widget _buildZoneChip(AppStateProvider appState) {
    IconData icon;
    Color color;
    String text;

    // Offline mode: show greyed out with "-"
    if (appState.offlineMode) {
      icon = Icons.flight;
      color = Colors.grey;
      text = '-';
    } else {
      // Show GPS region (e.g., "YOW") when locked and inside a zone
      switch (appState.gpsStatus) {
        case GpsStatus.locked:
          if (appState.inZone == true && appState.zoneCode != null) {
            icon = Icons.flight;
            color = Colors.green;
            text = appState.zoneCode!;
          } else if (appState.inZone == false) {
            icon = Icons.flight;
            color = Colors.orange;
            text = '—';
          } else {
            icon = Icons.flight;
            color = Colors.green;
            text = '...';
          }
          break;
        case GpsStatus.searching:
          icon = Icons.gps_not_fixed;
          color = Colors.orange;
          text = '...';
          break;
        case GpsStatus.outsideGeofence:
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
    }

    // Same styling as stat chips for consistent height
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
          Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
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
            padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: ConnectionPanel(compact: true),
          ),

          // Ping controls
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: PingControls(),
          ),
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
        initialChildSize: 0.85,
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

              // Sound toggle
              _buildHelpItem(
                icon: Icons.volume_up,
                color: Colors.blue,
                title: 'Sound',
                description: 'Sonar tone when sending TX/Discovery pings. Message tone when receiving valid RX packets, heard repeaters, or discovery responses.',
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
  /// Uses displayDeviceName which prefers SelfInfo name over BLE advertisement name
  String _buildSubtitle(AppStateProvider appState) {
    return appState.displayDeviceName ?? 'Unknown';
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

