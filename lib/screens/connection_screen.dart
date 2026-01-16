import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/connection_state.dart';
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
        title: const Text('Connect Device'),
        actions: [
          if (appState.isConnected)
            TextButton.icon(
              onPressed: () async {
                await appState.disconnect();
              },
              icon: const Icon(Icons.bluetooth_disabled),
              label: const Text('Disconnect'),
            ),
        ],
      ),
      body: _buildBody(context, appState),
      floatingActionButton: !appState.isScanning && !appState.isConnected
          ? FloatingActionButton.extended(
              onPressed: () => appState.startScan(),
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('Scan'),
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
                    Icon(
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
                          if (appState.deviceModel != null)
                            Text(
                              appState.deviceModel!.shortName,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                _buildInfoRow('Manufacturer', appState.manufacturerString ?? 'Unknown'),
                if (appState.deviceModel != null) ...[
                  _buildInfoRow('Platform', appState.deviceModel!.platform),
                  _buildInfoRow('TX Power', '${appState.deviceModel!.txPower} dBm'),
                  _buildInfoRow('Power Level', appState.deviceModel!.power.toString()),
                  if (appState.deviceModel!.isPaAmplifier)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Chip(
                        avatar: const Icon(Icons.warning, size: 18),
                        label: const Text('PA Amplifier'),
                        backgroundColor: Colors.orange.shade100,
                      ),
                    ),
                ],
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

  Widget _buildDeviceList(BuildContext context, AppStateProvider appState) {
    if (appState.isScanning) {
      return Column(
        children: [
          const LinearProgressIndicator(),
          Expanded(child: _buildDeviceListView(context, appState)),
        ],
      );
    }

    if (appState.discoveredDevices.isEmpty) {
      return Center(
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
      );
    }

    return _buildDeviceListView(context, appState);
  }

  Widget _buildDeviceListView(BuildContext context, AppStateProvider appState) {
    return ListView.builder(
      itemCount: appState.discoveredDevices.length,
      itemBuilder: (context, index) {
        final device = appState.discoveredDevices[index];
        return _DeviceListTile(
          device: device,
          onTap: () async {
            await appState.stopScan();
            await appState.connectToDevice(device);
          },
        );
      },
    );
  }
}

class _DeviceListTile extends StatelessWidget {
  final DiscoveredDevice device;
  final VoidCallback onTap;

  const _DeviceListTile({
    required this.device,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const CircleAvatar(
        child: Icon(Icons.bluetooth),
      ),
      title: Text(device.name),
      subtitle: Text(device.id),
      trailing: device.rssi != null
          ? Chip(
              label: Text('${device.rssi} dBm'),
              backgroundColor: _getRssiColor(device.rssi!),
            )
          : null,
      onTap: onTap,
    );
  }

  Color _getRssiColor(int rssi) {
    if (rssi >= -50) return Colors.green.shade100;
    if (rssi >= -70) return Colors.yellow.shade100;
    return Colors.red.shade100;
  }
}
