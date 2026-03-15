import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';

/// Shared offline mode toggle widget
/// Extracted from ping_controls.dart for use on both connection screen and ping controls
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final appState = context.watch<AppStateProvider>();
    final offlineMode = appState.offlineMode;
    final offlinePingCount = appState.offlinePingCount;
    final isConnected = appState.isConnected;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => handleOfflineModeToggle(context, appState, offlineMode, isConnected),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: offlineMode
                ? Colors.orange.withValues(alpha: 0.15)
                : colorScheme.onSurface.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: offlineMode
                  ? Colors.orange.withValues(alpha: 0.4)
                  : colorScheme.outline.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            children: [
              // Icon
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: offlineMode
                      ? Colors.orange.withValues(alpha: 0.2)
                      : colorScheme.onSurface.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  offlineMode ? Icons.cloud_off : Icons.cloud_queue,
                  size: 18,
                  color: offlineMode
                      ? (isDark ? Colors.orange.shade400 : Colors.orange.shade700)
                      : colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              // Label and count
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Offline Mode',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: offlineMode
                            ? (isDark ? Colors.orange.shade300 : Colors.orange.shade800)
                            : colorScheme.onSurface,
                      ),
                    ),
                    if (offlineMode && offlinePingCount > 0)
                      Text(
                        '$offlinePingCount pings saved locally',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.orange.shade400 : Colors.orange.shade600,
                        ),
                      )
                    else
                      Text(
                        offlineMode
                            ? 'Data saved locally'
                            : 'Uploads immediately',
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              // Toggle indicator
              Container(
                width: 44,
                height: 26,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  color: offlineMode
                      ? (isDark ? Colors.orange.shade600 : Colors.orange.shade500)
                      : (isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1)),
                ),
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  alignment: offlineMode
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    width: 22,
                    height: 22,
                    margin: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
