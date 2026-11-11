import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state_provider.dart';

/// Close App row on the Settings tab (Android only; the caller gates it).
///
/// Lives on the tab itself rather than in General so it is one tap away.
class CloseAppTile extends StatelessWidget {
  const CloseAppTile({super.key});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.power_settings_new, color: Colors.red),
      title: const Text('Close App'),
      subtitle: const Text('Exit the app completely'),
      onTap: () => _showCloseAppConfirmation(context),
    );
  }

  void _showCloseAppConfirmation(BuildContext context) {
    final appState = context.read<AppStateProvider>();
    final isConnected = appState.isConnected;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close App'),
        content: Text(
          isConnected
              ? 'This will disconnect from the device and close the app. Continue?'
              : 'This will close the app. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              appState.exitApp();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Close App'),
          ),
        ],
      ),
    );
  }
}
