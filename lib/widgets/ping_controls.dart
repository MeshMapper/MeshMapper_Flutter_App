import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import '../services/ping_service.dart';
import '../utils/debug_logger_io.dart';

/// Modern ping control panel with icon-based buttons and animated status
class PingControls extends StatelessWidget {
  const PingControls({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final validation = appState.pingValidation;
    final manualValidation = appState.manualPingValidation; // Manual ping validation (no distance check)
    final autoValidation = appState.autoModeValidation;
    final canPingManual = manualValidation == PingValidation.valid; // For Send Ping button
    final canStartAuto = autoValidation == PingValidation.valid;
    final isActiveModeRunning = appState.autoPingEnabled && appState.autoMode == AutoMode.active;
    final isPassiveModeRunning = appState.autoPingEnabled && appState.autoMode == AutoMode.passive;
    final isPendingDisable = appState.isPendingDisable; // Disable pending, waiting for RX window to complete
    final cooldownActive = appState.cooldownTimer.isRunning; // Shared cooldown after disabling Active Mode
    final cooldownRemaining = appState.cooldownTimer.remainingSec;
    final manualCooldownActive = appState.manualPingCooldownTimer.isRunning; // Manual ping cooldown (15 seconds)
    final manualCooldownRemaining = appState.manualPingCooldownTimer.remainingSec;
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

    // TX not allowed when API says zone is at TX capacity
    final txNotAllowed = appState.isConnected && !appState.txAllowed;

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
            // State flow: "Send Ping" → "Sending..." → "Listening Xs" → "Cooldown Xs" → "Send Ping"
            // Manual pings use 15-second cooldown, no distance requirement
            // When Active/Passive Mode is running, just shows "Send Ping" (disabled)
            Expanded(
              child: _ActionButton(
                icon: Icons.cell_tower,
                label: txBlockedByOffline
                    ? 'TX Disabled'
                    : txNotAllowed
                        ? 'Zone Full'
                        : isActiveModeRunning
                            ? 'Send Ping'  // Just disabled when Active Mode is running
                            : isPingSending
                                ? 'Sending...'
                                : rxWindowActive
                                    ? 'Listening ${rxWindowRemaining}s'  // Manual ping listening (works during Passive Mode too)
                                    : manualCooldownActive
                                        ? 'Cooldown ${manualCooldownRemaining}s'  // Manual ping 15-second cooldown
                                        : discoveryWindowActive
                                            ? 'Cooldown ${discoveryWindowRemaining}s'  // Cooldown during Passive Mode listening
                                            : cooldownActive
                                                ? 'Cooldown ${cooldownRemaining}s'  // After Active Mode disabled
                                                : 'Send Ping',
                color: const Color(0xFF0EA5E9), // sky-500
                enabled: canPingManual && !isActiveModeRunning && !cooldownActive && !manualCooldownActive && !txBlockedByOffline && !txNotAllowed &&
                         !rxWindowActive && !isPingSending && !discoveryWindowActive && !isPendingDisable,
                isActive: (isPingSending || rxWindowActive) && !isActiveModeRunning,  // Only active during manual ping flow
                onPressed: () => _sendPing(context, appState),
                showCooldown: false, // No longer needed - countdown shown in label
                subtitle: txBlockedByOffline ? 'Offline Mode' : txNotAllowed ? 'Passive Only' : null,  // No "Move Xm" - manual pings have no distance requirement
                subtitleColor: txBlockedByOffline ? Colors.orange : txNotAllowed ? Colors.red : null,
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
                    : txNotAllowed
                        ? 'Zone Full'
                        : isPendingDisable
                            ? (rxWindowActive
                                ? 'Stopping ${rxWindowRemaining}s'  // Show remaining time until disable completes
                                : 'Stopping...')  // Brief transition state
                            : isActiveModeRunning
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
                    : isActiveModeRunning
                        ? const Color(0xFF22C55E) // green-500
                        : const Color(0xFF6366F1), // indigo-500
                // When pending disable, button is disabled but still shows stopping state
                enabled: !isPendingDisable && ((isActiveModeRunning || (canStartAuto && !isPassiveModeRunning && !cooldownActive && !isPingSending && !rxWindowActive)) && !txBlockedByOffline && !txNotAllowed),
                isActive: isPendingDisable || (isActiveModeRunning && (isPingInProgress || rxWindowActive || autoPingWaiting)),  // Active during stopping or sending/listening/waiting phases
                onPressed: () => _toggleTxRxAuto(context, appState),
                showCooldown: false, // No longer needed - countdown shown in label
                subtitle: txBlockedByOffline ? 'Offline Mode' : txNotAllowed ? 'Passive Only' : (isPendingDisable ? 'Stopping' : null),
                subtitleColor: txBlockedByOffline ? Colors.orange : txNotAllowed ? Colors.red : Colors.orange,
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
                label: isPassiveModeRunning
                    ? (discoveryWindowActive
                        ? 'Listening ${discoveryWindowRemaining}s'  // During discovery listening window
                        : autoPingWaiting
                            ? 'Next Disc ${autoPingRemaining}s'  // Waiting for next discovery
                            : 'Passive Mode')  // Initial state before first discovery
                    : isActiveModeRunning || isPendingDisable
                        ? 'Passive Mode'  // Just disabled when Active Mode is running or stopping
                        : rxWindowActive
                            ? 'Cooldown ${rxWindowRemaining}s'  // During manual ping listening
                            : cooldownActive
                                ? 'Cooldown ${cooldownRemaining}s'  // After Active Mode disabled
                                : 'Passive Mode',
                color: isPassiveModeRunning
                    ? const Color(0xFF22C55E) // green-500
                    : const Color(0xFF6366F1), // indigo-500
                enabled: isPassiveModeRunning || (appState.isConnected && !isActiveModeRunning && !isPendingDisable &&
                    !isPingSending && !rxWindowActive && !cooldownActive &&
                    prefs.externalAntennaSet && isPowerSet),
                isActive: isPassiveModeRunning && (discoveryWindowActive || autoPingWaiting),  // Active during listening/waiting phases
                onPressed: () => _toggleRxAuto(context, appState),
              ),
            ),
          ],
        ),

        // Status hint area - only show when there's a hint
        if (blockingHint != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Row(
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
            ),
          )
        else
          const SizedBox(height: 8),

        // Offline Mode and Sound toggles row
        const Row(
          children: [
            // Offline Mode toggle (expanded)
            Expanded(child: _OfflineModeToggle()),
            SizedBox(width: 8),
            // Sound toggle (compact, right side)
            _SoundToggle(),
          ],
        ),
      ],
    );
  }

  Future<void> _sendPing(BuildContext context, AppStateProvider appState) async {
    HapticFeedback.mediumImpact();

    final success = await appState.sendPing();

    if (success) {
      debugLog('[PING] Manual ping sent successfully');
    }
  }

  Future<void> _toggleTxRxAuto(BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.active);
  }

  Future<void> _toggleRxAuto(BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.passive);
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
    final colorScheme = Theme.of(context).colorScheme;
    // Use color when enabled, active (RX listening), or during cooldown
    // This prevents the button from going grey during cooldown
    final showColor = widget.enabled || widget.isActive || widget.showCooldown;
    final effectiveColor = showColor ? widget.color : colorScheme.onSurfaceVariant;
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
                              : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
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
                                  color: colorScheme.surface,
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
                          ? (widget.isActive ? effectiveColor : colorScheme.onSurface)
                          : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
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

/// Compact sound notification toggle - matches height of _OfflineModeToggle
class _SoundToggle extends StatelessWidget {
  const _SoundToggle();

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final soundEnabled = appState.isSoundEnabled;
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => appState.toggleSoundEnabled(),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          // Match _OfflineModeToggle: padding 10v + icon container (6+18+6) + text adds more height
          // _OfflineModeToggle content: icon 30px, text column ~34px, toggle 26px
          // Use same padding and let IntrinsicHeight from Row handle matching
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: soundEnabled
                ? Colors.blue.withValues(alpha: 0.15)
                : colorScheme.onSurface.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: soundEnabled
                  ? Colors.blue.withValues(alpha: 0.4)
                  : colorScheme.outline.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: soundEnabled
                      ? Colors.blue.withValues(alpha: 0.2)
                      : colorScheme.onSurface.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  soundEnabled ? Icons.volume_up : Icons.volume_off,
                  size: 18,
                  color: soundEnabled
                      ? (isDark ? Colors.blue.shade400 : Colors.blue.shade700)
                      : colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              // Add text column to match offline mode toggle height
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sound',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: soundEnabled
                          ? (isDark ? Colors.blue.shade300 : Colors.blue.shade800)
                          : colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    soundEnabled ? 'On' : 'Off',
                    style: TextStyle(
                      fontSize: 11,
                      color: soundEnabled
                          ? (isDark ? Colors.blue.shade400 : Colors.blue.shade600)
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact offline mode toggle matching app design language
class _OfflineModeToggle extends StatelessWidget {
  const _OfflineModeToggle();

  // Offline mode is now enabled
  static const bool _isEnabled = true;

  /// Handle offline mode toggle with progress dialog when connected
  static Future<void> _handleOfflineModeToggle(
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

    // When disabled, always show as "off" state
    if (!_isEnabled) {
      return Opacity(
        opacity: 0.5,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: colorScheme.onSurface.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: colorScheme.outline.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            children: [
              // Icon
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: colorScheme.onSurface.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  Icons.cloud_queue,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
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
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      'Coming soon',
                      style: TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: colorScheme.onSurfaceVariant,
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
                  color: isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1), // slate-600/300
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
        onTap: () => _handleOfflineModeToggle(context, appState, offlineMode, isConnected),
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
                      : (isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1)), // slate-600/300
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
    final manualValidation = appState.manualPingValidation; // Manual ping validation (no distance check)
    final autoValidation = appState.autoModeValidation;
    final canPingManual = manualValidation == PingValidation.valid; // For Send Ping button
    final canStartAuto = autoValidation == PingValidation.valid;
    final isActiveModeRunning = appState.autoPingEnabled && appState.autoMode == AutoMode.active;
    final isPassiveModeRunning = appState.autoPingEnabled && appState.autoMode == AutoMode.passive;
    final isPendingDisable = appState.isPendingDisable;
    final cooldownActive = appState.cooldownTimer.isRunning;
    final cooldownRemaining = appState.cooldownTimer.remainingSec;
    final manualCooldownActive = appState.manualPingCooldownTimer.isRunning; // Manual ping cooldown (15 seconds)
    final manualCooldownRemaining = appState.manualPingCooldownTimer.remainingSec;
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

    // TX not allowed when API says zone is at TX capacity
    final txNotAllowed = appState.isConnected && !appState.txAllowed;

    final prefs = appState.preferences;
    final isPowerSet = prefs.autoPowerSet || prefs.powerLevelSet || appState.deviceModel != null;

    // Determine which button is currently active (not during cooldown)
    final sendPingCurrentlyActive = (isPingSending || rxWindowActive || manualCooldownActive) && !isActiveModeRunning;
    final activeModeCurrentlyActive = isPendingDisable || (isActiveModeRunning && (isPingInProgress || rxWindowActive || autoPingWaiting));
    final passiveModeCurrentlyActive = isPassiveModeRunning && (discoveryWindowActive || autoPingWaiting);

    // Track the last active button for cooldown
    if (sendPingCurrentlyActive) {
      _lastActiveButton = _LastActiveButton.sendPing;
    } else if (activeModeCurrentlyActive) {
      _lastActiveButton = _LastActiveButton.activeMode;
    } else if (passiveModeCurrentlyActive) {
      _lastActiveButton = _LastActiveButton.passiveMode;
    }
    // Reset when no cooldown and no activity
    if (!cooldownActive && !manualCooldownActive && !sendPingCurrentlyActive && !activeModeCurrentlyActive && !passiveModeCurrentlyActive) {
      _lastActiveButton = _LastActiveButton.none;
    }

    // Determine which button should be expanded
    // During cooldown, the last active button stays expanded
    final sendPingExpanded = sendPingCurrentlyActive ||
        (manualCooldownActive && _lastActiveButton == _LastActiveButton.sendPing) ||
        (cooldownActive && _lastActiveButton == _LastActiveButton.sendPing);
    final activeModeExpanded = activeModeCurrentlyActive ||
        (cooldownActive && _lastActiveButton == _LastActiveButton.activeMode);
    final passiveModeExpanded = passiveModeCurrentlyActive ||
        (cooldownActive && _lastActiveButton == _LastActiveButton.passiveMode);

    // Determine which buttons are colored (enabled or active)
    final sendPingEnabled = canPingManual && !isActiveModeRunning && !cooldownActive && !manualCooldownActive && !txBlockedByOffline && !txNotAllowed &&
                     !rxWindowActive && !isPingSending && !discoveryWindowActive && !isPendingDisable;
    final sendPingActive = (isPingSending || rxWindowActive) && !isActiveModeRunning && !cooldownActive && !manualCooldownActive;
    final sendPingShowColor = sendPingEnabled || sendPingActive;

    final activeModeEnabled = !isPendingDisable && ((isActiveModeRunning || (canStartAuto && !isPassiveModeRunning && !cooldownActive && !isPingSending && !rxWindowActive)) && !txBlockedByOffline && !txNotAllowed);
    final activeModeActive = isPendingDisable || (isActiveModeRunning && (isPingInProgress || rxWindowActive || autoPingWaiting));
    final activeModeShowColor = activeModeEnabled || activeModeActive;

    final passiveModeEnabled = isPassiveModeRunning || (appState.isConnected && !isActiveModeRunning && !isPendingDisable &&
                !isPingSending && !rxWindowActive && !cooldownActive &&
                prefs.externalAntennaSet && isPowerSet);
    final passiveModeActive = isPassiveModeRunning && (discoveryWindowActive || autoPingWaiting);
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
        manualCooldownActive: manualCooldownActive,
        manualCooldownRemaining: manualCooldownRemaining,
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
      progress: rxWindowActive && !isActiveModeRunning
          ? appState.rxWindowTimer.progress
          : manualCooldownActive && _lastActiveButton == _LastActiveButton.sendPing
              ? appState.manualPingCooldownTimer.progress
              : cooldownActive && _lastActiveButton == _LastActiveButton.sendPing
                  ? appState.cooldownTimer.progress
                  : null,
      onPressed: () => _sendPing(context, appState),
    );

    final activeModeButton = _CompactActionButton(
      icon: Icons.sensors,
      label: _getActiveModeLabel(
        isActiveModeRunning: isActiveModeRunning,
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
          : isActiveModeRunning
              ? const Color(0xFF22C55E) // green-500
              : const Color(0xFF6366F1), // indigo-500
      enabled: activeModeEnabled,
      isActive: activeModeActive,
      isExpanded: activeModeExpanded,
      progress: rxWindowActive && isActiveModeRunning
          ? appState.rxWindowTimer.progress
          : autoPingWaiting && isActiveModeRunning
              ? appState.autoPingTimer.progress
              : cooldownActive && _lastActiveButton == _LastActiveButton.activeMode
                  ? appState.cooldownTimer.progress
                  : null,
      onPressed: () => _toggleTxRxAuto(context, appState),
    );

    final passiveModeButton = _CompactActionButton(
      icon: Icons.hearing,
      label: _getPassiveModeLabel(
        isPassiveModeRunning: isPassiveModeRunning,
        discoveryWindowActive: discoveryWindowActive,
        discoveryWindowRemaining: discoveryWindowRemaining,
        autoPingWaiting: autoPingWaiting,
        autoPingRemaining: autoPingRemaining,
        showFullText: passiveModeExpanded,
        cooldownActive: cooldownActive,
        cooldownRemaining: cooldownRemaining,
        isExpandedDuringCooldown: passiveModeExpanded && cooldownActive,
      ),
      color: isPassiveModeRunning
          ? const Color(0xFF22C55E) // green-500
          : const Color(0xFF6366F1), // indigo-500
      enabled: passiveModeEnabled,
      isActive: passiveModeActive,
      isExpanded: passiveModeExpanded,
      progress: discoveryWindowActive && isPassiveModeRunning
          ? appState.discoveryWindowTimer.progress
          : autoPingWaiting && isPassiveModeRunning
              ? appState.autoPingTimer.progress
              : cooldownActive && _lastActiveButton == _LastActiveButton.passiveMode
                  ? appState.cooldownTimer.progress
                  : null,
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
    required bool manualCooldownActive,
    required int manualCooldownRemaining,
    required bool discoveryWindowActive,
    required int discoveryWindowRemaining,
    required bool cooldownActive,
    required int cooldownRemaining,
    required bool showFullText,
  }) {
    if (isPingSending) return showFullText ? 'Sending...' : '...';
    if (rxWindowActive) return showFullText ? 'Listening ${rxWindowRemaining}s' : '${rxWindowRemaining}s';
    if (manualCooldownActive) return showFullText ? 'Cooldown ${manualCooldownRemaining}s' : '${manualCooldownRemaining}s';
    if (discoveryWindowActive) return showFullText ? 'Cooldown ${discoveryWindowRemaining}s' : '${discoveryWindowRemaining}s';
    if (cooldownActive) return showFullText ? 'Cooldown ${cooldownRemaining}s' : '${cooldownRemaining}s';
    return null;
  }

  /// Get label for Active Mode button
  /// When showFullText is true: "Listening 5s", when false: "5s"
  String? _getActiveModeLabel({
    required bool isActiveModeRunning,
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
    if (isActiveModeRunning) {
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
    required bool isPassiveModeRunning,
    required bool discoveryWindowActive,
    required int discoveryWindowRemaining,
    required bool autoPingWaiting,
    required int autoPingRemaining,
    required bool showFullText,
    required bool cooldownActive,
    required int cooldownRemaining,
    required bool isExpandedDuringCooldown,
  }) {
    if (isPassiveModeRunning) {
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
      debugLog('[PING] Compact ping sent successfully');
    }
  }

  Future<void> _toggleTxRxAuto(BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.active);
  }

  Future<void> _toggleRxAuto(BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.passive);
  }
}

/// Ping controls optimized for landscape side panel
/// Vertical stack of compact buttons
class LandscapePingControls extends StatelessWidget {
  final VoidCallback? onShowHelp;

  const LandscapePingControls({super.key, this.onShowHelp});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final manualValidation = appState.manualPingValidation; // Manual ping validation (no distance check)
    final autoValidation = appState.autoModeValidation;
    final canPingManual = manualValidation == PingValidation.valid; // For Send Ping button
    final canStartAuto = autoValidation == PingValidation.valid;
    final isActiveModeRunning = appState.autoPingEnabled && appState.autoMode == AutoMode.active;
    final isPassiveModeRunning = appState.autoPingEnabled && appState.autoMode == AutoMode.passive;
    final isPendingDisable = appState.isPendingDisable;
    final cooldownActive = appState.cooldownTimer.isRunning;
    final cooldownRemaining = appState.cooldownTimer.remainingSec;
    final manualCooldownActive = appState.manualPingCooldownTimer.isRunning; // Manual ping cooldown (15 seconds)
    final manualCooldownRemaining = appState.manualPingCooldownTimer.remainingSec;
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

    // TX not allowed when API says zone is at TX capacity
    final txNotAllowed = appState.isConnected && !appState.txAllowed;

    final prefs = appState.preferences;
    final isPowerSet = prefs.autoPowerSet || prefs.powerLevelSet || appState.deviceModel != null;

    // Antenna selector
    final soundEnabled = appState.isSoundEnabled;
    final offlineMode = appState.offlineMode;
    final isConnected = appState.isConnected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Antenna selector (compact)
        _LandscapeAntennaSelector(
          externalAntenna: prefs.externalAntenna,
          externalAntennaSet: prefs.externalAntennaSet,
          onChanged: (value) => appState.updatePreferences(
            prefs.copyWith(externalAntenna: value, externalAntennaSet: true),
          ),
        ),
        const SizedBox(height: 10),

        // Action buttons row (icon-only)
        Row(
          children: [
            // TX Ping button
            Expanded(
              child: _LandscapeIconButton(
                icon: Icons.cell_tower,
                tooltip: txNotAllowed ? 'Zone Full (Passive Only)' : 'Send Ping',
                color: const Color(0xFF0EA5E9), // sky-500
                enabled: canPingManual && !isActiveModeRunning && !cooldownActive && !manualCooldownActive && !txBlockedByOffline && !txNotAllowed &&
                         !rxWindowActive && !isPingSending && !discoveryWindowActive && !isPendingDisable,
                isActive: (isPingSending || rxWindowActive) && !isActiveModeRunning,
                countdown: isPingSending
                    ? null
                    : rxWindowActive && !isActiveModeRunning
                        ? rxWindowRemaining
                        : manualCooldownActive
                            ? manualCooldownRemaining
                            : discoveryWindowActive
                                ? discoveryWindowRemaining
                                : cooldownActive
                                    ? cooldownRemaining
                                    : null,
                onPressed: () => _sendPing(context, appState),
              ),
            ),
            const SizedBox(width: 8),

            // Active Mode button
            Expanded(
              child: _LandscapeIconButton(
                icon: Icons.sensors,
                tooltip: txNotAllowed ? 'Zone Full (Passive Only)' : 'Active Mode',
                color: isPendingDisable
                    ? Colors.orange
                    : isActiveModeRunning
                        ? const Color(0xFF22C55E) // green-500
                        : const Color(0xFF6366F1), // indigo-500
                enabled: !isPendingDisable && ((isActiveModeRunning || (canStartAuto && !isPassiveModeRunning && !cooldownActive && !isPingSending && !rxWindowActive)) && !txBlockedByOffline && !txNotAllowed),
                isActive: isPendingDisable || (isActiveModeRunning && (isPingInProgress || rxWindowActive || autoPingWaiting)),
                countdown: isActiveModeRunning
                    ? (rxWindowActive
                        ? rxWindowRemaining
                        : autoPingWaiting
                            ? autoPingRemaining
                            : null)
                    : isPendingDisable && rxWindowActive
                        ? rxWindowRemaining
                        : null,
                onPressed: () => _toggleTxRxAuto(context, appState),
              ),
            ),
            const SizedBox(width: 8),

            // Passive Mode button
            Expanded(
              child: _LandscapeIconButton(
                icon: Icons.hearing,
                tooltip: 'Passive Mode',
                color: isPassiveModeRunning
                    ? const Color(0xFF22C55E) // green-500
                    : const Color(0xFF6366F1), // indigo-500
                enabled: isPassiveModeRunning || (appState.isConnected && !isActiveModeRunning && !isPendingDisable &&
                    !isPingSending && !rxWindowActive && !cooldownActive &&
                    prefs.externalAntennaSet && isPowerSet),
                isActive: isPassiveModeRunning && (discoveryWindowActive || autoPingWaiting),
                countdown: isPassiveModeRunning
                    ? (discoveryWindowActive
                        ? discoveryWindowRemaining
                        : autoPingWaiting
                            ? autoPingRemaining
                            : null)
                    : null,
                onPressed: () => _toggleRxAuto(context, appState),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Compact row for toggles
        Row(
          children: [
            Expanded(
              child: _LandscapeToggle(
                icon: offlineMode ? Icons.cloud_off : Icons.cloud_queue,
                label: 'Offline',
                isOn: offlineMode,
                color: Colors.orange,
                onTap: () => _OfflineModeToggle._handleOfflineModeToggle(
                  context,
                  appState,
                  offlineMode,
                  isConnected,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _LandscapeToggle(
                icon: soundEnabled ? Icons.volume_up : Icons.volume_off,
                label: 'Sound',
                isOn: soundEnabled,
                color: Colors.blue,
                onTap: () => appState.toggleSoundEnabled(),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _sendPing(BuildContext context, AppStateProvider appState) async {
    HapticFeedback.mediumImpact();
    await appState.sendPing();
  }

  Future<void> _toggleTxRxAuto(BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.active);
  }

  Future<void> _toggleRxAuto(BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.passive);
  }
}

/// Compact antenna selector for landscape panel
class _LandscapeAntennaSelector extends StatelessWidget {
  final bool externalAntenna;
  final bool externalAntennaSet;
  final ValueChanged<bool> onChanged;

  const _LandscapeAntennaSelector({
    required this.externalAntenna,
    required this.externalAntennaSet,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    const notSetColor = Colors.orange;
    final colorScheme = Theme.of(context).colorScheme;
    final setColor = colorScheme.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label row
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 4),
          child: Row(
            children: [
              Icon(
                Icons.settings_input_antenna,
                size: 12,
                color: externalAntennaSet ? setColor : notSetColor,
              ),
              const SizedBox(width: 4),
              Text(
                'Antenna',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: externalAntennaSet ? colorScheme.onSurfaceVariant : notSetColor,
                ),
              ),
              if (!externalAntennaSet) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: notSetColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Required',
                    style: TextStyle(fontSize: 8, fontWeight: FontWeight.w600, color: notSetColor),
                  ),
                ),
              ],
            ],
          ),
        ),
        // Toggle buttons
        Container(
          height: 32,
          decoration: BoxDecoration(
            color: colorScheme.onSurface.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colorScheme.outline.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              // Internal option
              Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(false),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    decoration: BoxDecoration(
                      color: (!externalAntenna && externalAntennaSet)
                          ? Colors.orange.withValues(alpha: 0.25)
                          : Colors.transparent,
                      borderRadius: const BorderRadius.horizontal(left: Radius.circular(7)),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'Internal',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: (!externalAntenna && externalAntennaSet) ? FontWeight.w600 : FontWeight.w500,
                        color: (!externalAntenna && externalAntennaSet) ? Colors.orange : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
              // Divider
              Container(width: 1, height: 18, color: colorScheme.outline.withValues(alpha: 0.3)),
              // External option
              Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(true),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    decoration: BoxDecoration(
                      color: (externalAntenna && externalAntennaSet)
                          ? Colors.orange.withValues(alpha: 0.25)
                          : Colors.transparent,
                      borderRadius: const BorderRadius.horizontal(right: Radius.circular(7)),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'External',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: (externalAntenna && externalAntennaSet) ? FontWeight.w600 : FontWeight.w500,
                        color: (externalAntenna && externalAntennaSet) ? Colors.orange : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Icon-only action button for landscape panel
class _LandscapeIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final bool enabled;
  final bool isActive;
  final int? countdown; // Optional countdown number to display
  final VoidCallback onPressed;

  const _LandscapeIconButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.enabled,
    required this.onPressed,
    this.isActive = false,
    this.countdown,
  });

  @override
  State<_LandscapeIconButton> createState() => _LandscapeIconButtonState();
}

class _LandscapeIconButtonState extends State<_LandscapeIconButton>
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
  void didUpdateWidget(_LandscapeIconButton oldWidget) {
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
    final colorScheme = Theme.of(context).colorScheme;
    final showColor = widget.enabled || widget.isActive;
    final effectiveColor = showColor ? widget.color : colorScheme.onSurfaceVariant;

    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        final bgOpacity = widget.isActive ? _pulseAnimation.value : 0.10;

        return Tooltip(
          message: widget.tooltip,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.enabled ? widget.onPressed : null,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                height: 48,
                decoration: BoxDecoration(
                  color: effectiveColor.withValues(alpha: bgOpacity),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: effectiveColor.withValues(alpha: widget.isActive ? 0.5 : 0.25),
                    width: widget.isActive ? 1.5 : 1,
                  ),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Main icon
                    Icon(
                      widget.icon,
                      size: 24,
                      color: showColor ? effectiveColor : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                    // Countdown badge (bottom right)
                    if (widget.countdown != null)
                      Positioned(
                        bottom: 4,
                        right: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: effectiveColor,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '${widget.countdown}',
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    // Active indicator dot (top right)
                    if (widget.isActive && widget.countdown == null)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: const Color(0xFF22C55E),
                            shape: BoxShape.circle,
                            border: Border.all(color: colorScheme.surface, width: 1.5),
                          ),
                        ),
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

/// Compact toggle button for landscape panel
class _LandscapeToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isOn;
  final Color color;
  final VoidCallback onTap;

  const _LandscapeToggle({
    required this.icon,
    required this.label,
    required this.isOn,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final activeColor = isOn ? color : colorScheme.onSurfaceVariant;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: isOn
                ? activeColor.withValues(alpha: 0.12)
                : colorScheme.onSurface.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isOn
                  ? activeColor.withValues(alpha: 0.35)
                  : colorScheme.outline.withValues(alpha: 0.15),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: isOn ? activeColor : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isOn ? FontWeight.w600 : FontWeight.w500,
                  color: isOn ? activeColor : colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
  final double? progress; // 0.0 to 1.0 for progress bar fill, null = no progress bar

  const _CompactActionButton({
    required this.icon,
    this.label,
    required this.color,
    required this.enabled,
    required this.onPressed,
    this.isActive = false,
    this.isExpanded = false,
    this.progress,
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
    final colorScheme = Theme.of(context).colorScheme;
    final showColor = widget.enabled || widget.isActive;
    final effectiveColor = showColor ? widget.color : colorScheme.onSurfaceVariant;
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
              decoration: BoxDecoration(
                color: effectiveColor.withValues(alpha: bgOpacity),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: effectiveColor.withValues(alpha: widget.isActive ? 0.5 : 0.3),
                  width: widget.isActive ? 1.5 : 1,
                ),
              ),
              child: Stack(
                children: [
                  // Progress fill (behind content)
                  if (widget.progress != null && widget.progress! > 0)
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(15),
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: widget.progress!,
                          child: Container(
                            color: effectiveColor.withValues(alpha: 0.3),
                          ),
                        ),
                      ),
                    ),
                  // Existing button content
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: hasLabel ? 10 : 8,
                      vertical: 6,
                    ),
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              widget.icon,
                              size: 18,
                              color: showColor ? effectiveColor : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
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
                                            color: showColor ? effectiveColor : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
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
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
