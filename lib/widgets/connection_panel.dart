import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import '../utils/debug_logger_io.dart';

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
    final prefs = appState.preferences;

    // Just show external antenna selector
    return _buildAntennaSelector(context, appState, prefs);
  }

  Widget _buildAntennaSelector(
      BuildContext context, AppStateProvider appState, prefs) {
    final isSet = prefs.externalAntennaSet;
    final hasExternal = prefs.externalAntenna;
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isSet
            ? colorScheme.onSurface.withValues(alpha: 0.04)
            : Colors.orange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSet
              ? colorScheme.outline.withValues(alpha: 0.3)
              : Colors.orange.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          // Icon
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isSet
                  ? colorScheme.onSurface.withValues(alpha: 0.08)
                  : Colors.orange.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.settings_input_antenna,
              size: 20,
              color:
                  isSet ? colorScheme.onSurfaceVariant : Colors.orange.shade700,
            ),
          ),
          const SizedBox(width: 12),
          // Label
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Antenna',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurface,
                  ),
                ),
                if (appState.antennaRestoredFromDevice)
                  Text(
                    'Remembered for ${appState.displayDeviceName}',
                    style: TextStyle(
                        fontSize: 11, color: colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          // Segmented toggle
          Container(
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF334155) // slate-700 for dark
                  : const Color(0xFFE2E8F0), // slate-200 for light
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.all(3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildSegmentButton(
                  context,
                  label: 'Internal',
                  icon: Icons.directions_car,
                  isSelected: isSet && !hasExternal,
                  onTap: () {
                    debugLog('[UI] Antenna button pressed: Internal');
                    appState.updatePreferences(
                      prefs.copyWith(
                          externalAntenna: false, externalAntennaSet: true),
                    );
                  },
                ),
                _buildSegmentButton(
                  context,
                  label: 'External',
                  icon: Icons.cell_tower,
                  isSelected: isSet && hasExternal,
                  onTap: () {
                    debugLog('[UI] Antenna button pressed: External');
                    appState.updatePreferences(
                      prefs.copyWith(
                          externalAntenna: true, externalAntennaSet: true),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One antenna choice. [icon] matches the quick guide's picture of it.
  Widget _buildSegmentButton(
    BuildContext context, {
    required String label,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isSelected
        ? (isDark
            ? Colors.white
            : const Color(0xFF1E293B)) // slate-800 for light
        : (isDark
            ? const Color(0xFF94A3B8)
            : const Color(0xFF64748B)); // slate-400/500

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        // Tighter than the old 16 so the icon costs no width: the label
        // column beside the toggle has to keep "Remembered for <radio>".
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark
                  ? const Color(0xFF475569) // slate-600 for dark
                  : const Color(0xFFFFFFFF)) // white for light
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          boxShadow: isSelected && !isDark
              ? [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 2,
                      offset: const Offset(0, 1))
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFull(BuildContext context, AppStateProvider appState) {
    final prefs = appState.preferences;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // External Antenna toggle
          _buildAntennaSelector(context, appState, prefs),
        ],
      ),
    );
  }
}
