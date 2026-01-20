import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import '../services/ping_service.dart';
import '../services/status_message_service.dart';
import '../utils/debug_logger_io.dart';

/// Modern ping control panel with icon-based buttons and animated status
class PingControls extends StatelessWidget {
  const PingControls({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final validation = appState.pingValidation;
    final autoValidation = appState.autoModeValidation;
    final canPing = validation == PingValidation.valid;
    final canStartAuto = autoValidation == PingValidation.valid;
    final isTxRxAutoRunning = appState.autoPingEnabled && appState.autoMode == AutoMode.txRx;
    final isRxAutoRunning = appState.autoPingEnabled && appState.autoMode == AutoMode.rxOnly;
    final cooldownActive = appState.cooldownTimer.isRunning; // Shared cooldown for both TX Ping and TX/RX Auto
    final cooldownRemaining = appState.cooldownTimer.remainingSec;

    // Calculate distance feedback for TX Ping button
    final distanceFromLastPing = appState.distanceFromLastPing;
    final needToMove = validation == PingValidation.tooCloseToLastPing && distanceFromLastPing != null;
    final distanceRemaining = needToMove ? (25.0 - distanceFromLastPing).ceil() : 0;
    final moveSubtitle = needToMove && !cooldownActive ? 'Move ${distanceRemaining}m' : null;

    // Log validation state when buttons are disabled (helps debug "buttons never enable" issues)
    if (!canPing && appState.isConnected && !isTxRxAutoRunning && !isRxAutoRunning) {
      debugLog('[UI] Ping buttons disabled: validation=$validation');
    }

    // Determine blocking reason for status hint (in priority order)
    // Skip antenna hint - the antenna selector already shows this
    String? blockingHint;
    IconData? blockingIcon;
    Color? blockingColor;

    final prefs = appState.preferences;
    final isPowerSet = prefs.autoPowerSet || prefs.powerLevelSet || appState.deviceModel != null;

    if (!appState.isConnected) {
      // Don't show hint when disconnected - buttons are obviously disabled
    } else if (!prefs.externalAntennaSet) {
      blockingHint = 'Select antenna option';
      blockingIcon = Icons.settings_input_antenna;
      blockingColor = Colors.orange;
    } else if (!isPowerSet) {
      blockingHint = 'Select power level in Settings';
      blockingIcon = Icons.bolt;
      blockingColor = Colors.orange;
    } else if (validation == PingValidation.noGpsLock) {
      blockingHint = 'Waiting for GPS lock...';
      blockingIcon = Icons.gps_off;
      blockingColor = Colors.blue;
    } else if (validation == PingValidation.gpsInaccurate) {
      blockingHint = 'GPS accuracy too low';
      blockingIcon = Icons.gps_not_fixed;
      blockingColor = Colors.orange;
    } else if (validation == PingValidation.outsideGeofence) {
      blockingHint = 'Outside service area';
      blockingIcon = Icons.wrong_location;
      blockingColor = Colors.red;
    }
    // Note: cooldown and tooClose are shown on button itself

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Action buttons row
        Row(
          children: [
            // TX Ping button
            Expanded(
              child: _ActionButton(
                icon: Icons.cell_tower,
                label: cooldownActive ? '$cooldownRemaining s' : 'TX Ping',
                color: const Color(0xFF0EA5E9), // sky-500
                enabled: canPing && !isTxRxAutoRunning && !isRxAutoRunning && !cooldownActive,
                onPressed: () => _sendPing(context, appState),
                showCooldown: cooldownActive,
                subtitle: moveSubtitle,
                subtitleColor: Colors.orange.shade600,
              ),
            ),
            const SizedBox(width: 10),

            // TX/RX Auto button
            // Can start even when tooCloseToLastPing - ping will be skipped until user moves
            Expanded(
              child: _ActionButton(
                icon: Icons.sensors,
                label: cooldownActive && !isTxRxAutoRunning
                    ? '$cooldownRemaining s'
                    : 'TX/RX Auto',
                color: isTxRxAutoRunning
                    ? const Color(0xFF22C55E) // green-500
                    : const Color(0xFF6366F1), // indigo-500
                enabled: isTxRxAutoRunning || (canStartAuto && !isRxAutoRunning && !cooldownActive),
                isActive: isTxRxAutoRunning,
                onPressed: () => _toggleTxRxAuto(context, appState),
              ),
            ),
            const SizedBox(width: 10),

            // RX Auto button
            // RX Auto is passive listening - needs connection + antenna + power config, no cooldown/GPS/distance checks
            Expanded(
              child: _ActionButton(
                icon: Icons.hearing,
                label: 'RX Auto',
                color: isRxAutoRunning
                    ? const Color(0xFF22C55E) // green-500
                    : const Color(0xFF6366F1), // indigo-500
                enabled: isRxAutoRunning || (appState.isConnected && !isTxRxAutoRunning &&
                    prefs.externalAntennaSet && isPowerSet),
                isActive: isRxAutoRunning,
                onPressed: () => _toggleRxAuto(context, appState),
              ),
            ),
          ],
        ),

        // Status hint area - fixed height to prevent layout shift
        SizedBox(
          height: 24,
          child: blockingHint != null
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(blockingIcon, size: 14, color: blockingColor),
                    const SizedBox(width: 6),
                    Text(
                      blockingHint,
                      style: TextStyle(
                        fontSize: 12,
                        color: blockingColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                )
              : null,
        ),

        // Offline Mode toggle
        const SizedBox(height: 4),
        const _OfflineModeToggle(),
      ],
    );
  }

  Future<void> _sendPing(BuildContext context, AppStateProvider appState) async {
    HapticFeedback.mediumImpact();

    final success = await appState.sendPing();

    if (success) {
      appState.statusMessageService.setDynamicStatus(
        'Ping sent!',
        StatusColor.success,
      );
    }
  }

  Future<void> _toggleTxRxAuto(BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.txRx);
  }

  Future<void> _toggleRxAuto(BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.rxOnly);
  }
}

/// Icon-based action button with animated active state
class _ActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool enabled;
  final bool isActive;
  final bool showCooldown;
  final VoidCallback onPressed;
  final String? subtitle;  // Optional subtitle text (e.g., "Move 5m")
  final Color? subtitleColor;  // Optional subtitle color

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.enabled,
    required this.onPressed,
    this.isActive = false,
    this.showCooldown = false,
    this.subtitle,
    this.subtitleColor,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    // Pulse opacity from 0.3 to 0.6 for a subtle glow effect
    _pulseAnimation = Tween<double>(begin: 0.15, end: 0.35).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (widget.isActive) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_ActionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _pulseController.repeat(reverse: true);
    } else if (!widget.isActive && oldWidget.isActive) {
      _pulseController.stop();
      _pulseController.reset();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveColor = widget.enabled ? widget.color : Colors.grey;
    final borderOpacity = widget.isActive ? 0.6 : 0.3;

    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        // Use animated opacity for active state background
        final bgOpacity = widget.isActive ? _pulseAnimation.value : 0.12;

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.enabled ? widget.onPressed : null,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: effectiveColor.withValues(alpha: bgOpacity),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: effectiveColor.withValues(alpha: borderOpacity),
                  width: widget.isActive ? 2 : 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Icon with indicator dot
                  SizedBox(
                    height: 30,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        // Main icon
                        Icon(
                          widget.icon,
                          size: 26,
                          color: widget.enabled
                              ? effectiveColor
                              : Colors.grey.shade400,
                        ),
                        // Active indicator dot
                        if (widget.isActive)
                          Positioned(
                            top: 0,
                            right: -6,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: const Color(0xFF22C55E),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Label - always same height
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: widget.isActive ? FontWeight.w600 : FontWeight.w500,
                      color: widget.enabled
                          ? (widget.isActive ? effectiveColor : Colors.grey.shade700)
                          : Colors.grey.shade400,
                    ),
                  ),
                  // Active status text OR subtitle - always reserve space
                  SizedBox(
                    height: 12,
                    child: widget.isActive
                        ? const Text(
                            'Active',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF22C55E),
                            ),
                          )
                        : widget.subtitle != null
                            ? Text(
                                widget.subtitle!,
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w500,
                                  color: widget.subtitleColor ?? Colors.orange.shade600,
                                ),
                              )
                            : null,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Compact offline mode toggle matching app design language
/// Currently disabled - feature coming soon
class _OfflineModeToggle extends StatelessWidget {
  const _OfflineModeToggle();

  // TODO: Set to true when offline mode is fully implemented
  static const bool _isEnabled = false;

  @override
  Widget build(BuildContext context) {
    // When disabled, always show as "off" state
    if (!_isEnabled) {
      return Opacity(
        opacity: 0.5,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.grey.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: Colors.grey.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            children: [
              // Icon
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  Icons.cloud_queue,
                  size: 18,
                  color: Colors.grey.shade500,
                ),
              ),
              const SizedBox(width: 12),
              // Label and "Coming soon"
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Offline Mode',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    Text(
                      'Coming soon',
                      style: TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              ),
              // Toggle indicator (always off)
              Container(
                width: 44,
                height: 26,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  color: Colors.grey.shade300,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
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
      );
    }

    // Original implementation when enabled
    final appState = context.watch<AppStateProvider>();
    final offlineMode = appState.offlineMode;
    final offlinePingCount = appState.offlinePingCount;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => appState.setOfflineMode(!offlineMode),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: offlineMode
                ? Colors.orange.withValues(alpha: 0.15)
                : Colors.grey.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: offlineMode
                  ? Colors.orange.withValues(alpha: 0.4)
                  : Colors.grey.withValues(alpha: 0.2),
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
                      : Colors.grey.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  offlineMode ? Icons.cloud_off : Icons.cloud_queue,
                  size: 18,
                  color: offlineMode ? Colors.orange.shade700 : Colors.grey.shade500,
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
                            ? Colors.orange.shade800
                            : Colors.grey.shade700,
                      ),
                    ),
                    if (offlineMode && offlinePingCount > 0)
                      Text(
                        '$offlinePingCount pings saved locally',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange.shade600,
                        ),
                      )
                    else
                      Text(
                        offlineMode
                            ? 'Data saved locally'
                            : 'Uploads immediately',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade500,
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
                      ? Colors.orange.shade600
                      : Colors.grey.shade300,
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
