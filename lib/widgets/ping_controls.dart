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
    final isPendingDisable = appState.isPendingDisable; // Disable pending, waiting for RX window to complete
    final cooldownActive = appState.cooldownTimer.isRunning; // Shared cooldown after disabling Active Mode
    final cooldownRemaining = appState.cooldownTimer.remainingSec;
    final rxWindowActive = appState.rxWindowTimer.isRunning; // RX listening window after ping
    final rxWindowRemaining = appState.rxWindowTimer.remainingSec;
    final isPingSending = appState.isPingSending; // True immediately when manual ping button clicked
    final isPingInProgress = appState.isPingInProgress; // True during entire ping + RX window (includes auto pings)
    final autoPingWaiting = appState.autoPingTimer.isRunning; // Waiting for next auto ping
    final autoPingRemaining = appState.autoPingTimer.remainingSec;
    final discoveryWindowActive = appState.discoveryWindowTimer.isRunning; // Discovery listening window countdown (Passive Mode)
    final discoveryWindowRemaining = appState.discoveryWindowTimer.remainingSec;

    // TX is blocked when offline mode is active and connected
    final txBlockedByOffline = appState.offlineMode && appState.isConnected;

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
            // Send Ping button
            // State flow: "Send Ping" → "Sending..." → "Listening Xs" → "Send Ping"
            // Also shows cooldown countdown when Active Mode is disabled or Passive Mode is listening
            // When Active/Passive Mode is running, just shows "Send Ping" or "Cooldown" (disabled)
            Expanded(
              child: _ActionButton(
                icon: Icons.cell_tower,
                label: txBlockedByOffline
                    ? 'TX Disabled'
                    : isTxRxAutoRunning
                        ? 'Send Ping'  // Just disabled when Active Mode is running
                        : isPingSending
                            ? 'Sending...'
                            : rxWindowActive
                                ? 'Listening ${rxWindowRemaining}s'  // Manual ping listening (works during Passive Mode too)
                                : discoveryWindowActive
                                    ? 'Cooldown ${discoveryWindowRemaining}s'  // Cooldown during Passive Mode listening
                                    : cooldownActive
                                        ? 'Cooldown ${cooldownRemaining}s'  // After Active Mode disabled
                                        : 'Send Ping',
                color: const Color(0xFF0EA5E9), // sky-500
                enabled: canPing && !isTxRxAutoRunning && !cooldownActive && !txBlockedByOffline &&
                         !rxWindowActive && !isPingSending && !discoveryWindowActive && !isPendingDisable,
                isActive: (isPingSending || rxWindowActive) && !isTxRxAutoRunning,  // Only active during manual ping flow
                onPressed: () => _sendPing(context, appState),
                showCooldown: false, // No longer needed - countdown shown in label
                subtitle: txBlockedByOffline ? 'Offline Mode' : ((isPingSending || rxWindowActive || cooldownActive || discoveryWindowActive) ? null : moveSubtitle),
                subtitleColor: txBlockedByOffline ? Colors.orange : Colors.orange.shade600,
              ),
            ),
            const SizedBox(width: 10),

            // Active Mode button (toggle)
            // When ON: shows "Sending..." → "Listening Xs" → "Next ping in Xs" cycle
            // When OFF after being ON: shows "Cooldown Xs" like other buttons
            // During manual ping: shows "Cooldown Xs" (disabled)
            Expanded(
              child: _ActionButton(
                icon: Icons.sensors,
                label: txBlockedByOffline
                    ? 'TX Disabled'
                    : isPendingDisable
                        ? (rxWindowActive
                            ? 'Stopping ${rxWindowRemaining}s'  // Show remaining time until disable completes
                            : 'Stopping...')  // Brief transition state
                        : isTxRxAutoRunning
                            ? (isPingInProgress && !rxWindowActive
                                ? 'Sending...'  // Brief moment while ping is being sent
                                : rxWindowActive
                                    ? 'Listening ${rxWindowRemaining}s'  // During RX window
                                    : autoPingWaiting
                                        ? 'Next ping ${autoPingRemaining}s'  // Waiting for next auto ping
                                        : 'Active Mode')  // Initial state before first ping
                            : rxWindowActive
                                ? 'Cooldown ${rxWindowRemaining}s'  // During manual ping
                                : cooldownActive
                                    ? 'Cooldown ${cooldownRemaining}s'  // After Active Mode disabled
                                    : 'Active Mode',
                color: isPendingDisable
                    ? Colors.orange  // Orange when stopping
                    : isTxRxAutoRunning
                        ? const Color(0xFF22C55E) // green-500
                        : const Color(0xFF6366F1), // indigo-500
                // When pending disable, button is disabled but still shows stopping state
                enabled: !isPendingDisable && ((isTxRxAutoRunning || (canStartAuto && !isRxAutoRunning && !cooldownActive && !isPingSending && !rxWindowActive)) && !txBlockedByOffline),
                isActive: isPendingDisable || (isTxRxAutoRunning && (isPingInProgress || rxWindowActive || autoPingWaiting)),  // Active during stopping or sending/listening/waiting phases
                onPressed: () => _toggleTxRxAuto(context, appState),
                showCooldown: false, // No longer needed - countdown shown in label
                subtitle: txBlockedByOffline ? 'Offline Mode' : (isPendingDisable ? 'Stopping' : null),
                subtitleColor: Colors.orange,
              ),
            ),
            const SizedBox(width: 10),

            // Passive Mode button (toggle)
            // When ON: shows "Listening..." → "Next Disc Xs" cycle
            // When OFF: returns to normal, Active Mode re-enables immediately
            // Disabled during manual ping countdown phases, shows "Cooldown Xs"
            // When Active Mode is running, just shows "Passive Mode" (disabled, no countdown)
            Expanded(
              child: _ActionButton(
                icon: Icons.hearing,
                label: isRxAutoRunning
                    ? (discoveryWindowActive
                        ? 'Listening ${discoveryWindowRemaining}s'  // During discovery listening window
                        : autoPingWaiting
                            ? 'Next Disc ${autoPingRemaining}s'  // Waiting for next discovery
                            : 'Passive Mode')  // Initial state before first discovery
                    : isTxRxAutoRunning || isPendingDisable
                        ? 'Passive Mode'  // Just disabled when Active Mode is running or stopping
                        : rxWindowActive
                            ? 'Cooldown ${rxWindowRemaining}s'  // During manual ping listening
                            : cooldownActive
                                ? 'Cooldown ${cooldownRemaining}s'  // After Active Mode disabled
                                : 'Passive Mode',
                color: isRxAutoRunning
                    ? const Color(0xFF22C55E) // green-500
                    : const Color(0xFF6366F1), // indigo-500
                enabled: isRxAutoRunning || (appState.isConnected && !isTxRxAutoRunning && !isPendingDisable &&
                    !isPingSending && !rxWindowActive && !cooldownActive &&
                    prefs.externalAntennaSet && isPowerSet),
                isActive: isRxAutoRunning && (discoveryWindowActive || autoPingWaiting),  // Active during listening/waiting phases
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
    // Use color when enabled, active (RX listening), or during cooldown
    // This prevents the button from going grey during cooldown
    final showColor = widget.enabled || widget.isActive || widget.showCooldown;
    final effectiveColor = showColor ? widget.color : Colors.grey;
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
                          color: showColor
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
                      color: showColor
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
class _OfflineModeToggle extends StatelessWidget {
  const _OfflineModeToggle();

  // Offline mode is now enabled
  static const bool _isEnabled = true;

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
    final isConnected = appState.isConnected;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          // Cannot change offline mode while connected
          if (isConnected) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Disconnect from device before changing offline mode'),
                duration: Duration(seconds: 3),
              ),
            );
            return;
          }
          appState.setOfflineMode(!offlineMode);
        },
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

/// Compact ping controls for minimized panel view
/// Shows 3 small horizontal pill buttons in a row
/// Active button expands to show context (e.g., "Listening 5s")
class CompactPingControls extends StatefulWidget {
  const CompactPingControls({super.key});

  @override
  State<CompactPingControls> createState() => _CompactPingControlsState();
}

/// Tracks which button should stay expanded during cooldown
enum _LastActiveButton { none, sendPing, activeMode, passiveMode }

class _CompactPingControlsState extends State<CompactPingControls> {
  // Static so it persists across widget rebuilds (e.g., expand/minimize panel)
  static _LastActiveButton _lastActiveButton = _LastActiveButton.none;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final validation = appState.pingValidation;
    final autoValidation = appState.autoModeValidation;
    final canPing = validation == PingValidation.valid;
    final canStartAuto = autoValidation == PingValidation.valid;
    final isTxRxAutoRunning = appState.autoPingEnabled && appState.autoMode == AutoMode.txRx;
    final isRxAutoRunning = appState.autoPingEnabled && appState.autoMode == AutoMode.rxOnly;
    final isPendingDisable = appState.isPendingDisable;
    final cooldownActive = appState.cooldownTimer.isRunning;
    final cooldownRemaining = appState.cooldownTimer.remainingSec;
    final rxWindowActive = appState.rxWindowTimer.isRunning;
    final rxWindowRemaining = appState.rxWindowTimer.remainingSec;
    final isPingSending = appState.isPingSending;
    final isPingInProgress = appState.isPingInProgress;
    final autoPingWaiting = appState.autoPingTimer.isRunning;
    final autoPingRemaining = appState.autoPingTimer.remainingSec;
    final discoveryWindowActive = appState.discoveryWindowTimer.isRunning;
    final discoveryWindowRemaining = appState.discoveryWindowTimer.remainingSec;

    // TX is blocked when offline mode is active and connected
    final txBlockedByOffline = appState.offlineMode && appState.isConnected;

    final prefs = appState.preferences;
    final isPowerSet = prefs.autoPowerSet || prefs.powerLevelSet || appState.deviceModel != null;

    // Determine which button is currently active (not during cooldown)
    final sendPingCurrentlyActive = (isPingSending || rxWindowActive) && !isTxRxAutoRunning;
    final activeModeCurrentlyActive = isPendingDisable || (isTxRxAutoRunning && (isPingInProgress || rxWindowActive || autoPingWaiting));
    final passiveModeCurrentlyActive = isRxAutoRunning && (discoveryWindowActive || autoPingWaiting);

    // Track the last active button for cooldown
    if (sendPingCurrentlyActive) {
      _lastActiveButton = _LastActiveButton.sendPing;
    } else if (activeModeCurrentlyActive) {
      _lastActiveButton = _LastActiveButton.activeMode;
    } else if (passiveModeCurrentlyActive) {
      _lastActiveButton = _LastActiveButton.passiveMode;
    }
    // Reset when no cooldown and no activity
    if (!cooldownActive && !sendPingCurrentlyActive && !activeModeCurrentlyActive && !passiveModeCurrentlyActive) {
      _lastActiveButton = _LastActiveButton.none;
    }

    // Determine which button should be expanded
    // During cooldown, the last active button stays expanded
    final sendPingExpanded = sendPingCurrentlyActive ||
        (cooldownActive && _lastActiveButton == _LastActiveButton.sendPing);
    final activeModeExpanded = activeModeCurrentlyActive ||
        (cooldownActive && _lastActiveButton == _LastActiveButton.activeMode);
    final passiveModeExpanded = passiveModeCurrentlyActive ||
        (cooldownActive && _lastActiveButton == _LastActiveButton.passiveMode);

    // Determine which buttons are colored (enabled or active)
    final sendPingEnabled = canPing && !isTxRxAutoRunning && !cooldownActive && !txBlockedByOffline &&
                     !rxWindowActive && !isPingSending && !discoveryWindowActive && !isPendingDisable;
    final sendPingActive = (isPingSending || rxWindowActive) && !isTxRxAutoRunning && !cooldownActive;
    final sendPingShowColor = sendPingEnabled || sendPingActive;

    final activeModeEnabled = !isPendingDisable && ((isTxRxAutoRunning || (canStartAuto && !isRxAutoRunning && !cooldownActive && !isPingSending && !rxWindowActive)) && !txBlockedByOffline);
    final activeModeActive = isPendingDisable || (isTxRxAutoRunning && (isPingInProgress || rxWindowActive || autoPingWaiting));
    final activeModeShowColor = activeModeEnabled || activeModeActive;

    final passiveModeEnabled = isRxAutoRunning || (appState.isConnected && !isTxRxAutoRunning && !isPendingDisable &&
                !isPingSending && !rxWindowActive && !cooldownActive &&
                prefs.externalAntennaSet && isPowerSet);
    final passiveModeActive = isRxAutoRunning && (discoveryWindowActive || autoPingWaiting);
    final passiveModeShowColor = passiveModeEnabled || passiveModeActive;

    // Check if any button is actively expanded (showing label)
    final anyExpanded = sendPingExpanded || activeModeExpanded || passiveModeExpanded;
    // Check if all buttons are disabled (no color) - used to split space equally in initial state
    final allDisabled = !sendPingShowColor && !activeModeShowColor && !passiveModeShowColor;

    // Build the buttons
    final sendPingButton = _CompactActionButton(
      icon: Icons.cell_tower,
      label: _getSendPingLabel(
        isPingSending: isPingSending,
        rxWindowActive: rxWindowActive,
        rxWindowRemaining: rxWindowRemaining,
        discoveryWindowActive: discoveryWindowActive,
        discoveryWindowRemaining: discoveryWindowRemaining,
        cooldownActive: cooldownActive,
        cooldownRemaining: cooldownRemaining,
        showFullText: sendPingExpanded,
      ),
      color: const Color(0xFF0EA5E9), // sky-500
      enabled: sendPingEnabled,
      isActive: sendPingActive,
      isExpanded: sendPingExpanded,
      onPressed: () => _sendPing(context, appState),
    );

    final activeModeButton = _CompactActionButton(
      icon: Icons.sensors,
      label: _getActiveModeLabel(
        isTxRxAutoRunning: isTxRxAutoRunning,
        isPingInProgress: isPingInProgress,
        rxWindowActive: rxWindowActive,
        rxWindowRemaining: rxWindowRemaining,
        autoPingWaiting: autoPingWaiting,
        autoPingRemaining: autoPingRemaining,
        isPendingDisable: isPendingDisable,
        showFullText: activeModeExpanded,
        cooldownActive: cooldownActive,
        cooldownRemaining: cooldownRemaining,
        isExpandedDuringCooldown: activeModeExpanded && cooldownActive,
      ),
      color: isPendingDisable
          ? Colors.orange
          : isTxRxAutoRunning
              ? const Color(0xFF22C55E) // green-500
              : const Color(0xFF6366F1), // indigo-500
      enabled: activeModeEnabled,
      isActive: activeModeActive,
      isExpanded: activeModeExpanded,
      onPressed: () => _toggleTxRxAuto(context, appState),
    );

    final passiveModeButton = _CompactActionButton(
      icon: Icons.hearing,
      label: _getPassiveModeLabel(
        isRxAutoRunning: isRxAutoRunning,
        discoveryWindowActive: discoveryWindowActive,
        discoveryWindowRemaining: discoveryWindowRemaining,
        autoPingWaiting: autoPingWaiting,
        autoPingRemaining: autoPingRemaining,
        showFullText: passiveModeExpanded,
        cooldownActive: cooldownActive,
        cooldownRemaining: cooldownRemaining,
        isExpandedDuringCooldown: passiveModeExpanded && cooldownActive,
      ),
      color: isRxAutoRunning
          ? const Color(0xFF22C55E) // green-500
          : const Color(0xFF6366F1), // indigo-500
      enabled: passiveModeEnabled,
      isActive: passiveModeActive,
      isExpanded: passiveModeExpanded,
      onPressed: () => _toggleRxAuto(context, appState),
    );

    // Layout logic:
    // - If button is expanded (including during cooldown): stays big
    // - If no button is expanded: all colored buttons share space equally
    // - Grey non-expanded buttons are icon-only
    return Row(
      children: [
        // Send Ping - expanded buttons stay big even when grey (cooldown)
        if (sendPingExpanded)
          Expanded(child: sendPingButton)
        else if (!anyExpanded && (sendPingShowColor || allDisabled))
          Expanded(child: sendPingButton)
        else
          sendPingButton,
        const SizedBox(width: 6),

        // Active Mode
        if (activeModeExpanded)
          Expanded(child: activeModeButton)
        else if (!anyExpanded && (activeModeShowColor || allDisabled))
          Expanded(child: activeModeButton)
        else
          activeModeButton,
        const SizedBox(width: 6),

        // Passive Mode
        if (passiveModeExpanded)
          Expanded(child: passiveModeButton)
        else if (!anyExpanded && (passiveModeShowColor || allDisabled))
          Expanded(child: passiveModeButton)
        else
          passiveModeButton,
      ],
    );
  }

  /// Get label for Send Ping button
  /// When showFullText is true: "Listening 5s", when false: "5s"
  String? _getSendPingLabel({
    required bool isPingSending,
    required bool rxWindowActive,
    required int rxWindowRemaining,
    required bool discoveryWindowActive,
    required int discoveryWindowRemaining,
    required bool cooldownActive,
    required int cooldownRemaining,
    required bool showFullText,
  }) {
    if (isPingSending) return showFullText ? 'Sending...' : '...';
    if (rxWindowActive) return showFullText ? 'Listening ${rxWindowRemaining}s' : '${rxWindowRemaining}s';
    if (discoveryWindowActive) return showFullText ? 'Cooldown ${discoveryWindowRemaining}s' : '${discoveryWindowRemaining}s';
    if (cooldownActive) return showFullText ? 'Cooldown ${cooldownRemaining}s' : '${cooldownRemaining}s';
    return null;
  }

  /// Get label for Active Mode button
  /// When showFullText is true: "Listening 5s", when false: "5s"
  String? _getActiveModeLabel({
    required bool isTxRxAutoRunning,
    required bool isPingInProgress,
    required bool rxWindowActive,
    required int rxWindowRemaining,
    required bool autoPingWaiting,
    required int autoPingRemaining,
    required bool isPendingDisable,
    required bool showFullText,
    required bool cooldownActive,
    required int cooldownRemaining,
    required bool isExpandedDuringCooldown,
  }) {
    if (isPendingDisable) {
      if (rxWindowActive) return showFullText ? 'Stopping ${rxWindowRemaining}s' : '${rxWindowRemaining}s';
      return showFullText ? 'Stopping...' : '...';
    }
    if (isTxRxAutoRunning) {
      if (isPingInProgress && !rxWindowActive) return showFullText ? 'Sending...' : '...';
      if (rxWindowActive) return showFullText ? 'Listening ${rxWindowRemaining}s' : '${rxWindowRemaining}s';
      if (autoPingWaiting) return showFullText ? 'Waiting ${autoPingRemaining}s' : '${autoPingRemaining}s';
    }
    // Show cooldown if this button caused it
    if (cooldownActive && isExpandedDuringCooldown) {
      return showFullText ? 'Cooldown ${cooldownRemaining}s' : '${cooldownRemaining}s';
    }
    return null;
  }

  /// Get label for Passive Mode button
  /// When showFullText is true: "Listening 5s", when false: "5s"
  String? _getPassiveModeLabel({
    required bool isRxAutoRunning,
    required bool discoveryWindowActive,
    required int discoveryWindowRemaining,
    required bool autoPingWaiting,
    required int autoPingRemaining,
    required bool showFullText,
    required bool cooldownActive,
    required int cooldownRemaining,
    required bool isExpandedDuringCooldown,
  }) {
    if (isRxAutoRunning) {
      if (discoveryWindowActive) return showFullText ? 'Listening ${discoveryWindowRemaining}s' : '${discoveryWindowRemaining}s';
      if (autoPingWaiting) return showFullText ? 'Waiting ${autoPingRemaining}s' : '${autoPingRemaining}s';
    }
    // Show cooldown if this button caused it
    if (cooldownActive && isExpandedDuringCooldown) {
      return showFullText ? 'Cooldown ${cooldownRemaining}s' : '${cooldownRemaining}s';
    }
    return null;
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

/// Compact action button for minimized panel - horizontal pill layout
/// Supports expanding to show label when active
class _CompactActionButton extends StatefulWidget {
  final IconData icon;
  final String? label; // Label text (shown when expanded)
  final Color color;
  final bool enabled;
  final bool isActive;
  final bool isExpanded; // When true, show icon + label with wider width
  final VoidCallback onPressed;

  const _CompactActionButton({
    required this.icon,
    this.label,
    required this.color,
    required this.enabled,
    required this.onPressed,
    this.isActive = false,
    this.isExpanded = false,
  });

  @override
  State<_CompactActionButton> createState() => _CompactActionButtonState();
}

class _CompactActionButtonState extends State<_CompactActionButton>
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
    _pulseAnimation = Tween<double>(begin: 0.15, end: 0.35).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (widget.isActive) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_CompactActionButton oldWidget) {
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
    final showColor = widget.enabled || widget.isActive;
    final effectiveColor = showColor ? widget.color : Colors.grey;
    // Show label if colored OR if expanded (shows countdown on grey button during cooldown)
    final hasLabel = widget.label != null && (showColor || widget.isExpanded);

    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        final bgOpacity = widget.isActive ? _pulseAnimation.value : 0.12;

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.enabled ? widget.onPressed : null,
            borderRadius: BorderRadius.circular(14),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              height: 32,
              padding: EdgeInsets.symmetric(
                horizontal: hasLabel ? 10 : 8,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: effectiveColor.withValues(alpha: bgOpacity),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: effectiveColor.withValues(alpha: widget.isActive ? 0.5 : 0.3),
                  width: widget.isActive ? 1.5 : 1,
                ),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      widget.icon,
                      size: 18,
                      color: showColor ? effectiveColor : Colors.grey.shade400,
                    ),
                    // Animated label - show when label is provided
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      child: hasLabel
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(width: 5),
                                Text(
                                  widget.label!,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: widget.isActive ? FontWeight.w600 : FontWeight.w500,
                                    color: showColor ? effectiveColor : Colors.grey.shade400,
                                  ),
                                ),
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
