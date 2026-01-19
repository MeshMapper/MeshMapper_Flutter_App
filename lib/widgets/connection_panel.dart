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

  Widget _buildAntennaSelector(BuildContext context, AppStateProvider appState, prefs) {
    final isSet = prefs.externalAntennaSet;
    final hasExternal = prefs.externalAntenna;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isSet
            ? Colors.grey.withOpacity(0.06)
            : Colors.orange.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSet
              ? Colors.grey.withOpacity(0.15)
              : Colors.orange.withOpacity(0.3),
        ),
      ),
      child: Row(
        children: [
          // Icon
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isSet
                  ? Colors.grey.withOpacity(0.1)
                  : Colors.orange.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.settings_input_antenna,
              size: 20,
              color: isSet ? Colors.grey.shade600 : Colors.orange.shade700,
            ),
          ),
          const SizedBox(width: 12),
          // Label
          Expanded(
            child: Text(
              'External Antenna',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Colors.grey.shade800,
              ),
            ),
          ),
          // Segmented toggle
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF334155), // slate-700
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.all(3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildSegmentButton(
                  context,
                  label: 'No',
                  isSelected: isSet && !hasExternal,
                  onTap: () {
                    debugLog('[UI] External antenna button pressed: No');
                    appState.updatePreferences(
                      prefs.copyWith(externalAntenna: false, externalAntennaSet: true),
                    );
                  },
                ),
                _buildSegmentButton(
                  context,
                  label: 'Yes',
                  isSelected: isSet && hasExternal,
                  onTap: () {
                    debugLog('[UI] External antenna button pressed: Yes');
                    appState.updatePreferences(
                      prefs.copyWith(externalAntenna: true, externalAntennaSet: true),
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

  Widget _buildSegmentButton(
    BuildContext context, {
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF475569) // slate-600
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            color: isSelected
                ? Colors.white
                : const Color(0xFF94A3B8), // slate-400
          ),
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
