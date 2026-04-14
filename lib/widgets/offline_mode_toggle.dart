import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';

/// Shared offline mode toggle widget
/// Compact button style — icon + label, tappable to toggle with confirmation
class OfflineModeToggle extends StatelessWidget {
  const OfflineModeToggle({super.key});

  /// Handle offline mode toggle with progress dialog when connected
  static Future<void> handleOfflineModeToggle(
    BuildContext context,
    AppStateProvider appState,
    bool currentOfflineMode,
    bool isConnected,
  ) async {
    final newMode = !currentOfflineMode;

    // Always show confirmation dialog
    final confirmed = await _showConfirmDialog(context, newMode);
    if (confirmed != true || !context.mounted) return;

    // If connected, show progress dialog during mode switch
    if (isConnected) {
      final statusText = newMode
          ? 'Switching to offline mode...'
          : 'Switching to online mode...';

      // Show non-dismissible progress dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  statusText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      );

      // Perform the mode switch
      final result = await appState.setOfflineMode(newMode);

      // Close the progress dialog (check if context is still valid)
      if (context.mounted) {
        Navigator.of(context).pop();
      }

      // Show error dialog if switch failed
      if (!result.success && context.mounted) {
        showDialog(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Mode Switch Failed'),
            content: Text(
              result.error ?? 'An unknown error occurred',
              style: const TextStyle(fontSize: 14),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } else {
      // Not connected - simple toggle without dialog
      await appState.setOfflineMode(newMode);
    }
  }

  /// Show confirmation dialog explaining what the mode does
  static Future<bool?> _showConfirmDialog(
      BuildContext context, bool switchingToOffline) {
    final title =
        switchingToOffline ? 'Enable Offline Mode?' : 'Switch to Online Mode?';
    final icon = switchingToOffline ? Icons.cloud_off : Icons.cloud_done;
    final iconColor = switchingToOffline ? Colors.orange : Colors.green;
    final description = switchingToOffline
        ? 'Wardrive data will be saved locally on your device instead of uploading to MeshMapper.\n\n'
            'This is useful when you have poor cell connectivity or the API is in maintenance.\n\n'
            'You can upload saved data later from the Settings tab.'
        : 'Wardrive data will be uploaded to MeshMapper immediately as you drive.\n\n'
            'This requires an active internet connection.';
    final confirmLabel = switchingToOffline ? 'Go Offline' : 'Go Online';

    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(icon, color: iconColor, size: 22),
            const SizedBox(width: 8),
            Flexible(child: Text(title)),
          ],
        ),
        content: Text(
          description,
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: switchingToOffline
                ? FilledButton.styleFrom(backgroundColor: Colors.orange)
                : null,
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final appState = context.watch<AppStateProvider>();
    final offlineMode = appState.offlineMode;
    final isConnected = appState.isConnected;

    final color = offlineMode
        ? (isDark ? Colors.orange.shade400 : Colors.orange.shade700)
        : (isDark ? Colors.green.shade400 : Colors.green.shade700);
    final bgColor = offlineMode
        ? Colors.orange.withValues(alpha: 0.15)
        : Colors.green.withValues(alpha: 0.15);
    final borderColor = offlineMode
        ? Colors.orange.withValues(alpha: 0.4)
        : Colors.green.withValues(alpha: 0.4);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => handleOfflineModeToggle(
            context, appState, offlineMode, isConnected),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                offlineMode ? Icons.cloud_off : Icons.cloud_queue,
                size: 18,
                color: color,
              ),
              const SizedBox(width: 8),
              Text(
                offlineMode ? 'Go Online' : 'Go Offline',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
