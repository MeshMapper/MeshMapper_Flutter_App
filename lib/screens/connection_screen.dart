import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/connection_state.dart';
import '../models/remembered_device.dart';
import '../providers/app_state_provider.dart';
import '../services/bluetooth/bluetooth_service.dart';

/// BLE device selection and connection screen
class ConnectionScreen extends StatelessWidget {
  const ConnectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection'),
        automaticallyImplyLeading: false,
      ),
      body: _buildBody(context, appState),
      floatingActionButton: !appState.isScanning && !appState.isConnected
          ? FloatingActionButton.extended(
              onPressed: appState.inZone == true ? () => appState.startScan() : null,
              icon: const Icon(Icons.bluetooth_searching),
              label: Text(appState.inZone == true ? 'Scan' : 'Outside Zone'),
              backgroundColor: appState.inZone == true ? null : Colors.grey,
            )
          : null,
    );
  }

  Widget _buildBody(BuildContext context, AppStateProvider appState) {
    // Show connection progress
    if (appState.connectionStep != ConnectionStep.disconnected &&
        appState.connectionStep != ConnectionStep.connected &&
        appState.connectionStep != ConnectionStep.error) {
      return _buildConnectionProgress(context, appState);
    }

    // Show connected state
    if (appState.isConnected) {
      return _buildConnectedInfo(context, appState);
    }

    // Show error
    if (appState.connectionError != null) {
      return _buildError(context, appState);
    }

    // Show device list
    return _buildDeviceList(context, appState);
  }

  Widget _buildConnectionProgress(BuildContext context, AppStateProvider appState) {
    final step = appState.connectionStep;
    final totalSteps = ConnectionStepExtension.totalSteps;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              step.description,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: step.stepNumber / totalSteps,
            ),
            const SizedBox(height: 8),
            Text(
              'Step ${step.stepNumber} of $totalSteps',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectedInfo(BuildContext context, AppStateProvider appState) {
    // Get device name like we show in the app bar subtitle
    final deviceName = appState.connectedDeviceName?.replaceFirst('MeshCore-', '') ?? 'Unknown';

    // Parse version from manufacturer string and use shortName from device model for hardware
    // Format examples:
    // - "MeshCore (Heltec V3) v1.10.0"
    // - "Ikoka Stick-E22-30dBm (Xiao_nrf52)      nightly-e31c46f"
    String? version;
    final manufacturerString = appState.manufacturerString;
    if (manufacturerString != null) {
      // Use regex to find version pattern directly instead of splitting
      // Match: v followed by digits/dots, OR nightly- followed by hex, OR just digits.digits
      final versionRegex = RegExp(r'(v[\d.]+|nightly-[a-f0-9]+|\d+\.\d+\.\d+)');
      final match = versionRegex.firstMatch(manufacturerString);
      if (match != null) {
        version = match.group(1);
      }
    }

    // Use shortName from device model if available, otherwise fall back to manufacturer string
    final hardware = appState.deviceModel?.shortName ?? manufacturerString ?? 'Unknown';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.bluetooth_connected,
                      color: Colors.green,
                      size: 32,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Connected',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  color: Colors.green,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          Text(
                            deviceName,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                _buildInfoRow('Hardware', hardware),
                _buildInfoRow('Version', version ?? 'Unknown'),
                if (appState.deviceModel != null) ...[
                  _buildInfoRow('Platform', appState.deviceModel!.platform),
                  _buildInfoRow('Power', '${appState.deviceModel!.power} W'),
                ],
                if (appState.devicePublicKey != null)
                  _buildPublicKeyRow(context, appState.devicePublicKey!),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: () async {
            await appState.disconnect();
          },
          icon: const Icon(Icons.bluetooth_disabled),
          label: const Text('Disconnect'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _buildPublicKeyRow(BuildContext context, String publicKey) {
    // Show truncated key for display (first 8 + ... + last 8)
    final displayKey = publicKey.length > 16
        ? '${publicKey.substring(0, 8)}...${publicKey.substring(publicKey.length - 8)}'
        : publicKey;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const SizedBox(
            width: 120,
            child: Row(
              children: [
                Text(
                  'Public Key',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                SizedBox(width: 4),
                Tooltip(
                  message: 'Used for geo-auth API authentication',
                  child: Icon(Icons.info_outline, size: 14, color: Colors.grey),
                ),
              ],
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: publicKey));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Public key copied to clipboard'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayKey,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.copy,
                      size: 14,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context, AppStateProvider appState) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: Colors.red,
            ),
            const SizedBox(height: 16),
            Text(
              'Connection Failed',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              appState.connectionError ?? 'Unknown error',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => appState.startScan(),
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }

  /// Builds a compact zone status bar matching StatusBar design
  Widget _buildZoneStatusBar(BuildContext context, AppStateProvider appState) {
    final theme = Theme.of(context);

    // Determine zone status
    IconData locationIcon;
    String locationText;
    String? iataCode;
    Color locationColor;

    // Only show "Checking..." on initial load when we don't have zone info yet
    // After that, keep showing current state while checking happens in background
    if (appState.isCheckingZone && appState.inZone == null) {
      locationIcon = Icons.location_searching;
      locationText = 'Checking...';
      locationColor = Colors.blue;
    } else if (appState.inZone == true) {
      locationIcon = Icons.location_on;
      locationText = appState.zoneName ?? 'Unknown';
      iataCode = appState.zoneCode;
      locationColor = Colors.green;
    } else if (appState.inZone == false) {
      locationIcon = Icons.location_off;
      locationText = 'Outside Zone';
      locationColor = Colors.orange;
    } else {
      locationIcon = Icons.gps_not_fixed;
      locationText = 'GPS...';
      locationColor = Colors.grey;
    }

    // Slots info
    final slotsAvailable = appState.zoneSlotsAvailable;
    final slotsMax = appState.zoneSlotsMax;
    final hasSlots = slotsAvailable != null && slotsMax != null;

    // Slots color based on availability
    Color slotsColor;
    if (!hasSlots) {
      slotsColor = Colors.grey;
    } else if (slotsAvailable == 0) {
      slotsColor = Colors.red;
    } else if (slotsAvailable <= 2) {
      slotsColor = Colors.orange;
    } else {
      slotsColor = Colors.green;
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            // Location chip (city name)
            _buildChip(
              icon: locationIcon,
              text: locationText,
              color: locationColor,
            ),

            // IATA code chip (only when in zone)
            if (iataCode != null) ...[
              const SizedBox(width: 8),
              _buildChip(
                icon: Icons.flight,
                text: iataCode,
                color: Colors.blue,
              ),
            ],

            const Spacer(),

            // Slots chip
            _buildChip(
              icon: Icons.people_outline,
              text: hasSlots ? '$slotsAvailable/$slotsMax' : '--',
              color: slotsColor,
            ),
          ],
        ),
      ),
    );
  }

  /// Builds a chip matching StatusBar design
  Widget _buildChip({
    required IconData icon,
    required String text,
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
            text,
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

  Widget _buildDeviceList(BuildContext context, AppStateProvider appState) {
    // Check if Connect should be disabled (outside zone)
    final canConnect = appState.inZone == true;

    // Show onboarding message when outside zone
    if (appState.inZone == false) {
      return Column(
        children: [
          _buildZoneStatusBar(context, appState),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.public_off,
                      size: 64,
                      color: Colors.orange.withValues(alpha: 0.7),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Region Not Available',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Your geo zone is not on-boarded into MeshMapper.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                          ),
                    ),
                    const SizedBox(height: 24),
                    OutlinedButton.icon(
                      onPressed: () => _launchOnboardingUrl(),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Request Region Onboarding'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (appState.isScanning) {
      return Column(
        children: [
          _buildZoneStatusBar(context, appState),
          const LinearProgressIndicator(),
          Expanded(child: _buildDeviceListView(context, appState, canConnect: canConnect)),
        ],
      );
    }

    if (appState.discoveredDevices.isEmpty) {
      // Show remembered device option if available (mobile only)
      final remembered = appState.rememberedDevice;
      if (!kIsWeb && remembered != null) {
        return Column(
          children: [
            _buildZoneStatusBar(context, appState),
            Expanded(child: _buildRememberedDeviceView(context, appState, remembered, canConnect: canConnect)),
          ],
        );
      }

      return Column(
        children: [
          _buildZoneStatusBar(context, appState),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.bluetooth_searching,
                    size: 64,
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No devices found',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap Scan to search for MeshCore devices',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        _buildZoneStatusBar(context, appState),
        Expanded(child: _buildDeviceListView(context, appState, canConnect: canConnect)),
      ],
    );
  }

  void _launchOnboardingUrl() async {
    final uri = Uri.parse('https://meshmapper.net/?onboarding');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Widget _buildRememberedDeviceView(
    BuildContext context,
    AppStateProvider appState,
    RememberedDevice remembered, {
    bool canConnect = true,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bluetooth,
              size: 64,
              color: canConnect
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey,
            ),
            const SizedBox(height: 16),
            Text(
              'Last Connected Device',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              remembered.displayName,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: canConnect ? () => appState.reconnectToRememberedDevice() : null,
              icon: const Icon(Icons.bluetooth_connected),
              label: Text(canConnect ? 'Reconnect' : 'Outside Zone'),
              style: ElevatedButton.styleFrom(
                backgroundColor: canConnect
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton.icon(
                  onPressed: () => appState.startScan(),
                  icon: const Icon(Icons.bluetooth_searching, size: 18),
                  label: const Text('Scan for Others'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () => appState.clearRememberedDevice(),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Forget'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.grey,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceListView(BuildContext context, AppStateProvider appState, {bool canConnect = true}) {
    return ListView.builder(
      itemCount: appState.discoveredDevices.length,
      itemBuilder: (context, index) {
        final device = appState.discoveredDevices[index];
        return _DeviceListTile(
          device: device,
          enabled: canConnect,
          onTap: canConnect
              ? () async {
                  await appState.stopScan();
                  await appState.connectToDevice(device);
                }
              : null,
        );
      },
    );
  }
}

class _DeviceListTile extends StatelessWidget {
  final DiscoveredDevice device;
  final VoidCallback? onTap;
  final bool enabled;

  const _DeviceListTile({
    required this.device,
    this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    // Strip MeshCore- prefix from device name for cleaner display
    final displayName = device.name.replaceFirst('MeshCore-', '');

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: enabled ? null : Colors.grey.shade300,
        child: Icon(
          Icons.bluetooth,
          color: enabled ? null : Colors.grey,
        ),
      ),
      title: Text(
        displayName,
        style: TextStyle(color: enabled ? null : Colors.grey),
      ),
      subtitle: Text(
        device.id,
        style: TextStyle(color: enabled ? null : Colors.grey),
      ),
      trailing: device.rssi != null
          ? Chip(
              label: Text('${device.rssi} dBm'),
              backgroundColor: enabled ? _getRssiColor(device.rssi!) : Colors.grey.shade200,
            )
          : null,
      enabled: enabled,
      onTap: onTap,
    );
  }

  Color _getRssiColor(int rssi) {
    if (rssi >= -50) return Colors.green.shade100;
    if (rssi >= -70) return Colors.yellow.shade100;
    return Colors.red.shade100;
  }
}
