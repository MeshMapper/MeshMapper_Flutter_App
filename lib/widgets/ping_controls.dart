import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';

/// Ping control buttons matching MeshMapper_WebClient layout:
/// - TX Ping (sky blue) - Manual single ping
/// - TX/RX Auto (indigo) - Auto mode with TX and RX listening
/// - RX Auto (indigo) - Passive RX listening only
class PingControls extends StatelessWidget {
  const PingControls({super.key});

  // Colors matching the original web app
  static const Color _txPingColor = Color(0xFF0284C7); // sky-600
  static const Color _txPingHover = Color(0xFF0EA5E9); // sky-500
  static const Color _autoColor = Color(0xFF4F46E5); // indigo-600
  static const Color _autoHover = Color(0xFF6366F1); // indigo-500
  static const Color _stopColor = Color(0xFFDC2626); // red-600
  static const Color _disabledColor = Color(0xFF6B7280); // gray-500

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final validation = appState.pingValidation;
    final canPing = validation == PingValidation.valid;
    final isTxRxAutoRunning = appState.autoPingEnabled && appState.autoMode == AutoMode.txRx;
    final isRxAutoRunning = appState.autoPingEnabled && appState.autoMode == AutoMode.rxOnly;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Three button row matching web layout
        Row(
          children: [
            // TX Ping button (sky blue)
            Expanded(
              child: _PingButton(
                label: 'TX Ping',
                color: _txPingColor,
                hoverColor: _txPingHover,
                enabled: canPing && !isTxRxAutoRunning && !isRxAutoRunning,
                onPressed: () => _sendPing(context, appState),
              ),
            ),
            const SizedBox(width: 8),
            
            // TX/RX Auto button (indigo, or red when active)
            Expanded(
              child: _PingButton(
                label: isTxRxAutoRunning ? 'Stop' : 'TX/RX Auto',
                color: isTxRxAutoRunning ? _stopColor : _autoColor,
                hoverColor: isTxRxAutoRunning ? _stopColor : _autoHover,
                enabled: appState.isConnected && appState.hasGpsLock,
                onPressed: () => _toggleTxRxAuto(appState),
              ),
            ),
            const SizedBox(width: 8),
            
            // RX Auto button (indigo, or red when active)
            Expanded(
              child: _PingButton(
                label: isRxAutoRunning ? 'Stop' : 'RX Auto',
                color: isRxAutoRunning ? _stopColor : _autoColor,
                hoverColor: isRxAutoRunning ? _stopColor : _autoHover,
                enabled: appState.isConnected,
                onPressed: () => _toggleRxAuto(appState),
              ),
            ),
          ],
        ),
        
        // Validation message
        if (!canPing && appState.isConnected)
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

        // Auto-ping status info
        if (isTxRxAutoRunning || isRxAutoRunning)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              isTxRxAutoRunning 
                  ? 'TX/RX Auto: Pinging on movement, listening for responses'
                  : 'RX Auto: Listening for repeater signals only',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.green,
                    fontWeight: FontWeight.w500,
                  ),
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }

  Future<void> _sendPing(BuildContext context, AppStateProvider appState) async {
    HapticFeedback.mediumImpact();
    
    final success = await appState.sendPing();
    
    if (success && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ping sent!'),
          duration: Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _toggleTxRxAuto(AppStateProvider appState) {
    HapticFeedback.lightImpact();
    appState.toggleAutoPing(AutoMode.txRx);
  }

  void _toggleRxAuto(AppStateProvider appState) {
    HapticFeedback.lightImpact();
    appState.toggleAutoPing(AutoMode.rxOnly);
  }
}

/// Individual ping button styled to match web app
class _PingButton extends StatelessWidget {
  final String label;
  final Color color;
  final Color hoverColor;
  final bool enabled;
  final VoidCallback onPressed;

  const _PingButton({
    required this.label,
    required this.color,
    required this.hoverColor,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ElevatedButton(
        onPressed: enabled ? onPressed : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          disabledBackgroundColor: PingControls._disabledColor.withOpacity(0.4),
          disabledForegroundColor: Colors.white.withOpacity(0.6),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

