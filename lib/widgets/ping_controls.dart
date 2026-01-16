import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import '../services/ping_service.dart';

/// Ping control buttons (manual/auto ping)
class PingControls extends StatelessWidget {
  const PingControls({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final validation = appState.pingValidation;
    final canPing = validation == PingValidation.valid;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Manual ping button
        SizedBox(
          height: 56,
          child: ElevatedButton.icon(
            onPressed: canPing ? () => _sendPing(context, appState) : null,
            icon: const Icon(Icons.send, size: 24),
            label: const Text(
              'PING',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.grey.shade300,
            ),
          ),
        ),
        
        // Validation message
        if (!canPing)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              validation.message,
              style: TextStyle(
                color: Colors.orange.shade700,
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ),

        const SizedBox(height: 12),

        // Auto-ping toggle
        Row(
          children: [
            Expanded(
              child: Text(
                'Auto Ping',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Switch.adaptive(
              value: appState.autoPingEnabled,
              onChanged: appState.isConnected && appState.hasGpsLock
                  ? (_) => appState.toggleAutoPing()
                  : null,
            ),
          ],
        ),

        // Auto-ping info
        if (appState.autoPingEnabled)
          Text(
            'Automatically pings every 25m of movement',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey,
                ),
          ),
      ],
    );
  }

  Future<void> _sendPing(BuildContext context, AppStateProvider appState) async {
    // Haptic feedback
    HapticFeedback.mediumImpact();
    
    final success = await appState.sendPing();
    
    if (success && context.mounted) {
      // Show brief success feedback
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ping sent!'),
          duration: Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}
