import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/connection_state.dart';
import '../providers/app_state_provider.dart';

/// Connection panel showing device info and status
class ConnectionPanel extends StatelessWidget {
  final bool compact;

  const ConnectionPanel({
    super.key,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();

    if (compact) {
      return _buildCompact(context, appState);
    }

    return _buildFull(context, appState);
  }

  Widget _buildCompact(BuildContext context, AppStateProvider appState) {
    return Row(
      children: [
        // Connection status icon
        Icon(
          appState.isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
          color: appState.isConnected ? Colors.green : Colors.grey,
        ),
        const SizedBox(width: 8),
        
        // Status text
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                appState.isConnected
                    ? appState.deviceModel?.shortName ?? 'Connected'
                    : 'Not connected',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              if (appState.isConnected && appState.deviceModel != null)
                Text(
                  '${appState.deviceModel!.txPower} dBm',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFull(BuildContext context, AppStateProvider appState) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(
                appState.isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                color: appState.isConnected ? Colors.green : Colors.grey,
              ),
              const SizedBox(width: 8),
              Text(
                'Connection',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Connection step progress (when connecting)
          if (appState.connectionStep != ConnectionStep.disconnected &&
              appState.connectionStep != ConnectionStep.connected &&
              appState.connectionStep != ConnectionStep.error) ...[
            Text(appState.connectionStep.description),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: appState.connectionStep.stepNumber /
                  ConnectionStepExtension.totalSteps,
            ),
          ],

          // Connected state
          if (appState.isConnected) ...[
            _buildInfoRow('Device', appState.deviceModel?.shortName ?? 'Unknown'),
            _buildInfoRow('Platform', appState.deviceModel?.platform ?? 'Unknown'),
            _buildInfoRow('TX Power', '${appState.deviceModel?.txPower ?? 0} dBm'),
            
            if (appState.deviceModel?.isPaAmplifier ?? false)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(Icons.warning, color: Colors.orange, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      'PA Amplifier Mode',
                      style: TextStyle(color: Colors.orange),
                    ),
                  ],
                ),
              ),
          ],

          // Disconnected state
          if (appState.connectionStep == ConnectionStep.disconnected)
            Text(
              'No device connected',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey,
                  ),
            ),

          // Error state
          if (appState.connectionStep == ConnectionStep.error)
            Text(
              appState.connectionError ?? 'Connection error',
              style: TextStyle(color: Colors.red),
            ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(color: Colors.grey),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
