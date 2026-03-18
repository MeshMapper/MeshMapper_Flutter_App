import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import '../services/ping_service.dart';
import '../utils/debug_logger_io.dart';
import 'repeater_picker_sheet.dart';

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
    final isHybridModeRunning = appState.autoPingEnabled && appState.autoMode == AutoMode.hybrid;
    final isTxModeRunning = isActiveModeRunning || isHybridModeRunning;
    final isTargetedRunning = appState.isTargetedModeRunning;
    final hybridEnabled = appState.preferences.hybridModeEnabled;
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
    final autoPingSkipped = appState.autoPingTimer.skipReason != null; // Last ping was skipped (e.g. distance)
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
                        : isTxModeRunning
                            ? 'Send Ping'  // Just disabled when Active/Hybrid Mode is running
                            : isPingSending
                                ? 'Sending...'
                                : rxWindowActive
                                    ? 'Listening ${rxWindowRemaining}s'  // Manual ping listening (works during Passive Mode too)
                                    : manualCooldownActive
                                        ? 'Cooldown ${manualCooldownRemaining}s'  // Manual ping 15-second cooldown
                                        : discoveryWindowActive
                                            ? 'Cooldown ${discoveryWindowRemaining}s'  // Cooldown during Passive Mode listening
                                            : cooldownActive
                                                ? 'Cooldown ${cooldownRemaining}s'  // After Active/Hybrid Mode disabled
                                                : 'Send Ping',
                color: const Color(0xFF0EA5E9), // sky-500
                enabled: canPingManual && !isTxModeRunning && !isTargetedRunning && !cooldownActive && !manualCooldownActive && !txBlockedByOffline && !txNotAllowed &&
                         !rxWindowActive && !isPingSending && !discoveryWindowActive && !isPendingDisable,
                isActive: (isPingSending || rxWindowActive) && !isTxModeRunning,  // Only active during manual ping flow
                onPressed: () => _sendPing(context, appState),
                showCooldown: false, // No longer needed - countdown shown in label
                subtitle: txBlockedByOffline ? 'Offline Mode' : txNotAllowed ? 'Passive Only' : null,  // No "Move Xm" - manual pings have no distance requirement
                subtitleColor: txBlockedByOffline ? Colors.orange : txNotAllowed ? Colors.red : null,
              ),
            ),
            const SizedBox(width: 10),

            // Active/Hybrid Mode button (toggle)
            // When hybridEnabled: shows as "Hybrid Mode" with compare_arrows icon
            // When ON: shows "Sending..."/"Discovering..." → "Listening Xs" → "Next ping Xs" cycle
            // When OFF after being ON: shows "Cooldown Xs" like other buttons
            // During manual ping: shows "Cooldown Xs" (disabled)
            Expanded(
              child: _ActionButton(
                icon: hybridEnabled ? Icons.compare_arrows : Icons.sensors,
                label: txBlockedByOffline
                    ? 'TX Disabled'
                    : txNotAllowed
                        ? 'Zone Full'
                        : isPendingDisable
                            ? (rxWindowActive
                                ? 'Stopping ${rxWindowRemaining}s'
                                : discoveryWindowActive
                                    ? 'Stopping ${discoveryWindowRemaining}s'
                                    : 'Stopping...')
                            : isTxModeRunning
                                ? (isPingInProgress && !rxWindowActive && !discoveryWindowActive
                                    ? 'Sending...'
                                    : discoveryWindowActive
                                        ? 'Listening ${discoveryWindowRemaining}s'  // Discovery listening window
                                        : rxWindowActive
                                            ? 'Listening ${rxWindowRemaining}s'  // TX RX window
                                            : autoPingWaiting
                                                ? (autoPingSkipped ? 'Skipped ${autoPingRemaining}s' : 'Next ping ${autoPingRemaining}s')
                                                : hybridEnabled ? 'Hybrid Mode' : 'Active Mode')
                                : rxWindowActive
                                    ? 'Cooldown ${rxWindowRemaining}s'
                                    : cooldownActive
                                        ? 'Cooldown ${cooldownRemaining}s'
                                        : hybridEnabled ? 'Hybrid Mode' : 'Active Mode',
                color: isPendingDisable
                    ? Colors.orange
                    : isTxModeRunning
                        ? const Color(0xFF22C55E) // green-500
                        : const Color(0xFF6366F1), // indigo-500
                enabled: !isPendingDisable && !isTargetedRunning && ((isTxModeRunning || (canStartAuto && !isPassiveModeRunning && !cooldownActive && !isPingSending && !rxWindowActive)) && !txBlockedByOffline && !txNotAllowed),
                isActive: isPendingDisable || isTxModeRunning,
                onPressed: () => hybridEnabled ? _toggleHybridAuto(context, appState) : _toggleTxRxAuto(context, appState),
                showCooldown: false,
                subtitle: txBlockedByOffline ? 'Offline Mode' : txNotAllowed ? 'Passive Only' : (isPendingDisable ? 'Stopping' : null),
                subtitleColor: txBlockedByOffline ? Colors.orange : txNotAllowed ? Colors.red : Colors.orange,
              ),
            ),
            const SizedBox(width: 10),

            // Passive Mode button (toggle)
            // When ON: shows "Listening..." → "Next Disc Xs" cycle
            // When OFF: returns to normal, Active/Hybrid Mode re-enables immediately
            // Disabled during manual ping countdown phases, shows "Cooldown Xs"
            // When Active/Hybrid Mode is running, just shows "Passive Mode" (disabled, no countdown)
            Expanded(
              child: _ActionButton(
                icon: Icons.hearing,
                label: isPassiveModeRunning
                    ? (discoveryWindowActive
                        ? 'Listening ${discoveryWindowRemaining}s'  // During discovery listening window
                        : autoPingWaiting
                            ? (autoPingSkipped ? 'Skipped ${autoPingRemaining}s' : 'Next Disc ${autoPingRemaining}s')  // Waiting for next discovery
                            : 'Passive Mode')  // Initial state before first discovery
                    : isTxModeRunning || isPendingDisable
                        ? 'Passive Mode'  // Just disabled when Active/Hybrid Mode is running or stopping
                        : rxWindowActive
                            ? 'Cooldown ${rxWindowRemaining}s'  // During manual ping listening
                            : cooldownActive
                                ? 'Cooldown ${cooldownRemaining}s'  // After Active/Hybrid Mode disabled
                                : 'Passive Mode',
                color: isPassiveModeRunning
                    ? const Color(0xFF22C55E) // green-500
                    : const Color(0xFF6366F1), // indigo-500
                enabled: isPassiveModeRunning || (appState.isConnected && !isTxModeRunning && !isTargetedRunning && !isPendingDisable &&
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

        // Targeted Ping controls
        _TargetedPingSection(
          isAnyModeRunning: isActiveModeRunning || isPassiveModeRunning || isHybridModeRunning,
          cooldownActive: cooldownActive,
          cooldownRemaining: cooldownRemaining,
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

  Future<void> _toggleHybridAuto(BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.hybrid);
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

/// Targeted Ping controls - hex text field + start/stop button
class _TargetedPingSection extends StatefulWidget {
  final bool isAnyModeRunning;
  final bool cooldownActive;
  final int cooldownRemaining;
  final bool compact;

  const _TargetedPingSection({
    required this.isAnyModeRunning,
    required this.cooldownActive,
    required this.cooldownRemaining,
    this.compact = false,
  });

  @override
  State<_TargetedPingSection> createState() => _TargetedPingSectionState();
}

class _TargetedPingSectionState extends State<_TargetedPingSection> {
  final _controller = TextEditingController();
  bool _isStarting = false;

  @override
  void initState() {
    super.initState();
    // Restore any previously set target ID
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final appState = context.read<AppStateProvider>();
      final existing = appState.targetRepeaterId;
      if (existing != null && existing.isNotEmpty && _controller.text != existing) {
        _controller.text = existing;
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _showRepeaterPicker() async {
    final appState = context.read<AppStateProvider>();
    final repeater = await showRepeaterPicker(context);
    if (repeater == null || !mounted) return;

    final maxLen = appState.traceHopBytes * 2;
    final trimmed = repeater.hexId.length >= maxLen
        ? repeater.hexId.substring(0, maxLen).toUpperCase()
        : repeater.hexId.toUpperCase();
    _controller.text = trimmed;
    appState.setTargetRepeaterId(trimmed);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final isTargetedRunning = appState.isTargetedModeRunning;
    final maxLen = appState.traceHopBytes * 2;
    final colorScheme = Theme.of(context).colorScheme;

    // Sync controller when provider clears target (e.g. trace bytes changed)
    if (appState.targetRepeaterId == null && _controller.text.isNotEmpty) {
      _controller.clear();
    }

    // Determine if the start button should be enabled
    final hexText = _controller.text.trim();
    final isValidHex = hexText.isNotEmpty &&
        hexText.length == maxLen &&
        RegExp(r'^[0-9a-fA-F]+$').hasMatch(hexText);
    final canStart = isValidHex &&
        !widget.isAnyModeRunning &&
        !isTargetedRunning &&
        !widget.cooldownActive &&
        appState.isConnected;

    // Status text for when targeted mode is running
    String? statusText;
    if (isTargetedRunning) {
      final discoveryWindowActive = appState.discoveryWindowTimer.isRunning;
      final discoveryRemaining = appState.discoveryWindowTimer.remainingSec;
      final autoPingWaiting = appState.autoPingTimer.isRunning;
      final autoPingRemaining = appState.autoPingTimer.remainingSec;

      if (discoveryWindowActive) {
        statusText = 'Listening ${discoveryRemaining}s';
      } else if (autoPingWaiting) {
        statusText = appState.autoPingTimer.skipReason != null
            ? 'Skipped ${autoPingRemaining}s'
            : 'Next in ${autoPingRemaining}s';
      }
    }

    final isEnabled = (canStart || isTargetedRunning) && !_isStarting;
    final buttonColor = (isTargetedRunning || _isStarting)
        ? const Color(0xFF22C55E) // green-500 when running/starting
        : Colors.cyan;
    final effectiveColor = isEnabled ? buttonColor : colorScheme.onSurfaceVariant;

    return Container(
      decoration: BoxDecoration(
        color: effectiveColor.withValues(alpha: isTargetedRunning ? 0.15 : 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: effectiveColor.withValues(alpha: isTargetedRunning ? 0.5 : 0.25),
          width: isTargetedRunning ? 1.5 : 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          // Targeted button
          Expanded(
            child: GestureDetector(
              onTap: isEnabled
                  ? () async {
                      HapticFeedback.lightImpact();
                      if (!isTargetedRunning) {
                        setState(() => _isStarting = true);
                        appState.setTargetRepeaterId(_controller.text.trim().toUpperCase());
                      }
                      await appState.toggleAutoPing(AutoMode.targeted);
                      if (mounted) setState(() => _isStarting = false);
                    }
                  : null,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  Icon(
                    Icons.route,
                    size: 18,
                    color: effectiveColor,
                  ),
                  if (!widget.compact) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _isStarting
                            ? 'Starting...'
                            : isTargetedRunning
                                ? (statusText ?? 'Stop')
                                : widget.cooldownActive
                                    ? 'Cooldown ${widget.cooldownRemaining}s'
                                    : 'Trace Mode',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isTargetedRunning ? FontWeight.w600 : FontWeight.w500,
                          color: isEnabled ? colorScheme.onSurface : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Hex text field
          SizedBox(
            width: 80,
            child: TextField(
              controller: _controller,
              enabled: !isTargetedRunning,
              maxLength: maxLen,
              textCapitalization: TextCapitalization.characters,
              style: TextStyle(
                fontSize: 14,
                fontFamily: 'monospace',
                color: isTargetedRunning
                    ? colorScheme.onSurfaceVariant
                    : colorScheme.onSurface,
              ),
              decoration: InputDecoration(
                hintText: 'e.g. ${maxLen == 2 ? '4E' : maxLen == 4 ? '4E7A' : maxLen == 8 ? '4E7A3B00' : '4E7A3B'}',
                hintStyle: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                counterText: '',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]')),
                _UpperCaseTextFormatter(),
              ],
              onChanged: (value) {
                appState.setTargetRepeaterId(value.trim().toUpperCase());
                setState(() {});
              },
            ),
          ),
          const SizedBox(width: 6),
          // Choose repeater button
          SizedBox(
            width: 32,
            height: 32,
            child: IconButton(
              icon: Icon(
                Icons.list,
                size: 18,
                color: (!isTargetedRunning && appState.repeaters.isNotEmpty)
                    ? effectiveColor
                    : colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
              ),
              onPressed: (!isTargetedRunning && appState.repeaters.isNotEmpty)
                  ? _showRepeaterPicker
                  : null,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tooltip: 'Choose repeater',
            ),
          ),
        ],
      ),
    );
  }
}

/// Text formatter that converts input to uppercase
class _UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
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
enum _LastActiveButton { none, sendPing, activeMode, passiveMode, targeted }

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
    final isHybridModeRunning = appState.autoPingEnabled && appState.autoMode == AutoMode.hybrid;
    final isTxModeRunning = isActiveModeRunning || isHybridModeRunning;
    final isTargetedRunning = appState.isTargetedModeRunning;
    final hybridEnabled = appState.preferences.hybridModeEnabled;
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
    final autoPingSkipped = appState.autoPingTimer.skipReason != null;
    final discoveryWindowActive = appState.discoveryWindowTimer.isRunning;
    final discoveryWindowRemaining = appState.discoveryWindowTimer.remainingSec;

    // TX is blocked when offline mode is active and connected
    final txBlockedByOffline = appState.offlineMode && appState.isConnected;

    // TX not allowed when API says zone is at TX capacity
    final txNotAllowed = appState.isConnected && !appState.txAllowed;

    final prefs = appState.preferences;
    final isPowerSet = prefs.autoPowerSet || prefs.powerLevelSet || appState.deviceModel != null;

    // Determine which button is currently active (not during cooldown)
    final sendPingCurrentlyActive = (isPingSending || rxWindowActive || manualCooldownActive) && !isTxModeRunning;
    final activeModeCurrentlyActive = isPendingDisable || isTxModeRunning;
    final passiveModeCurrentlyActive = isPassiveModeRunning && (discoveryWindowActive || autoPingWaiting);

    // Track the last active button for cooldown
    if (sendPingCurrentlyActive) {
      _lastActiveButton = _LastActiveButton.sendPing;
    } else if (activeModeCurrentlyActive) {
      _lastActiveButton = _LastActiveButton.activeMode;
    } else if (passiveModeCurrentlyActive) {
      _lastActiveButton = _LastActiveButton.passiveMode;
    } else if (isTargetedRunning) {
      _lastActiveButton = _LastActiveButton.targeted;
    }
    // Reset when no cooldown and no activity
    if (!cooldownActive && !manualCooldownActive && !sendPingCurrentlyActive && !activeModeCurrentlyActive && !passiveModeCurrentlyActive && !isTargetedRunning) {
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
    final sendPingEnabled = canPingManual && !isTxModeRunning && !isTargetedRunning && !cooldownActive && !manualCooldownActive && !txBlockedByOffline && !txNotAllowed &&
                     !rxWindowActive && !isPingSending && !discoveryWindowActive && !isPendingDisable;
    final sendPingActive = (isPingSending || rxWindowActive) && !isTxModeRunning && !cooldownActive && !manualCooldownActive;
    final sendPingShowColor = sendPingEnabled || sendPingActive;

    final activeModeEnabled = !isPendingDisable && !isTargetedRunning && ((isTxModeRunning || (canStartAuto && !isPassiveModeRunning && !cooldownActive && !isPingSending && !rxWindowActive)) && !txBlockedByOffline && !txNotAllowed);
    final activeModeActive = isPendingDisable || isTxModeRunning;
    final activeModeShowColor = activeModeEnabled || activeModeActive;

    final passiveModeEnabled = isPassiveModeRunning || (appState.isConnected && !isTxModeRunning && !isTargetedRunning && !isPendingDisable &&
                !isPingSending && !rxWindowActive && !cooldownActive &&
                prefs.externalAntennaSet && isPowerSet);
    final passiveModeActive = isPassiveModeRunning && (discoveryWindowActive || autoPingWaiting);
    final passiveModeShowColor = passiveModeEnabled || passiveModeActive;

    // Trace Mode (only relevant when a repeater ID has been entered)
    final hasTargetRepeaterId = appState.targetRepeaterId != null && appState.targetRepeaterId!.isNotEmpty;
    final targetedCurrentlyActive = isTargetedRunning;
    final traceModeExpanded = targetedCurrentlyActive ||
        (cooldownActive && _lastActiveButton == _LastActiveButton.targeted);
    final traceModeEnabled = hasTargetRepeaterId && !isTxModeRunning && !isPassiveModeRunning &&
        !isPendingDisable && !isPingSending && !rxWindowActive && !cooldownActive &&
        !manualCooldownActive && appState.isConnected && prefs.externalAntennaSet && isPowerSet;
    final traceModeActive = isTargetedRunning;
    final traceModeShowColor = traceModeEnabled || traceModeActive;

    // Check if any button is actively expanded (showing label)
    final anyExpanded = sendPingExpanded || activeModeExpanded || passiveModeExpanded || traceModeExpanded;
    // Check if all buttons are disabled (no color) - used to split space equally in initial state
    final allDisabled = !sendPingShowColor && !activeModeShowColor && !passiveModeShowColor && (!hasTargetRepeaterId || !traceModeShowColor);

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
      progress: rxWindowActive && !isTxModeRunning
          ? appState.rxWindowTimer.progress
          : manualCooldownActive && _lastActiveButton == _LastActiveButton.sendPing
              ? appState.manualPingCooldownTimer.progress
              : cooldownActive && _lastActiveButton == _LastActiveButton.sendPing
                  ? appState.cooldownTimer.progress
                  : null,
      onPressed: () => _sendPing(context, appState),
    );

    final activeModeButton = _CompactActionButton(
      icon: hybridEnabled ? Icons.compare_arrows : Icons.sensors,
      label: _getActiveModeLabel(
        isActiveModeRunning: isTxModeRunning,
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
        isSkipped: autoPingSkipped,
        discoveryWindowActive: discoveryWindowActive,
        discoveryWindowRemaining: discoveryWindowRemaining,
      ),
      color: isPendingDisable
          ? Colors.orange
          : isTxModeRunning
              ? const Color(0xFF22C55E) // green-500
              : const Color(0xFF6366F1), // indigo-500
      enabled: activeModeEnabled,
      isActive: activeModeActive,
      isExpanded: activeModeExpanded,
      progress: (rxWindowActive || discoveryWindowActive) && isTxModeRunning
          ? (discoveryWindowActive ? appState.discoveryWindowTimer.progress : appState.rxWindowTimer.progress)
          : autoPingWaiting && isTxModeRunning
              ? appState.autoPingTimer.progress
              : cooldownActive && _lastActiveButton == _LastActiveButton.activeMode
                  ? appState.cooldownTimer.progress
                  : null,
      onPressed: () => hybridEnabled ? _toggleHybridAuto(context, appState) : _toggleTxRxAuto(context, appState),
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
        isSkipped: autoPingSkipped,
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

    // Build trace mode button (only used when hasTargetRepeaterId)
    final traceModeButton = _CompactActionButton(
      icon: Icons.route,
      label: _getTraceModeLabel(
        isTargetedRunning: isTargetedRunning,
        discoveryWindowActive: discoveryWindowActive,
        discoveryWindowRemaining: discoveryWindowRemaining,
        autoPingWaiting: autoPingWaiting,
        autoPingRemaining: autoPingRemaining,
        showFullText: traceModeExpanded,
        cooldownActive: cooldownActive,
        cooldownRemaining: cooldownRemaining,
        isExpandedDuringCooldown: traceModeExpanded && cooldownActive,
        isSkipped: autoPingSkipped,
      ),
      color: isTargetedRunning
          ? const Color(0xFF22C55E) // green-500
          : const Color(0xFF06B6D4), // cyan-500
      enabled: traceModeEnabled || isTargetedRunning,
      isActive: traceModeActive,
      isExpanded: traceModeExpanded,
      progress: discoveryWindowActive && isTargetedRunning
          ? appState.discoveryWindowTimer.progress
          : autoPingWaiting && isTargetedRunning
              ? appState.autoPingTimer.progress
              : cooldownActive && _lastActiveButton == _LastActiveButton.targeted
                  ? appState.cooldownTimer.progress
                  : null,
      onPressed: () {
        HapticFeedback.lightImpact();
        appState.toggleAutoPing(AutoMode.targeted);
      },
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

        // Trace Mode (only shown when a repeater ID has been entered)
        if (hasTargetRepeaterId) ...[
          const SizedBox(width: 6),
          if (traceModeExpanded)
            Expanded(child: traceModeButton)
          else if (!anyExpanded && (traceModeShowColor || allDisabled))
            Expanded(child: traceModeButton)
          else
            traceModeButton,
        ],
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

  /// Get label for Active/Hybrid Mode button
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
    required bool isSkipped,
    bool discoveryWindowActive = false,
    int discoveryWindowRemaining = 0,
  }) {
    if (isPendingDisable) {
      if (rxWindowActive) return showFullText ? 'Stopping ${rxWindowRemaining}s' : '${rxWindowRemaining}s';
      if (discoveryWindowActive) return showFullText ? 'Stopping ${discoveryWindowRemaining}s' : '${discoveryWindowRemaining}s';
      return showFullText ? 'Stopping...' : '...';
    }
    if (isActiveModeRunning) {
      if (discoveryWindowActive) return showFullText ? 'Listening ${discoveryWindowRemaining}s' : '${discoveryWindowRemaining}s';
      if (isPingInProgress && !rxWindowActive) return showFullText ? 'Sending...' : '...';
      if (rxWindowActive) return showFullText ? 'Listening ${rxWindowRemaining}s' : '${rxWindowRemaining}s';
      if (autoPingWaiting) return showFullText ? (isSkipped ? 'Skipped ${autoPingRemaining}s' : 'Waiting ${autoPingRemaining}s') : '${autoPingRemaining}s';
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
    required bool isSkipped,
  }) {
    if (isPassiveModeRunning) {
      if (discoveryWindowActive) return showFullText ? 'Listening ${discoveryWindowRemaining}s' : '${discoveryWindowRemaining}s';
      if (autoPingWaiting) return showFullText ? (isSkipped ? 'Skipped ${autoPingRemaining}s' : 'Waiting ${autoPingRemaining}s') : '${autoPingRemaining}s';
    }
    // Show cooldown if this button caused it
    if (cooldownActive && isExpandedDuringCooldown) {
      return showFullText ? 'Cooldown ${cooldownRemaining}s' : '${cooldownRemaining}s';
    }
    return null;
  }

  /// Get label for Trace Mode button
  /// When showFullText is true: "Listening 5s", when false: "5s"
  String? _getTraceModeLabel({
    required bool isTargetedRunning,
    required bool discoveryWindowActive,
    required int discoveryWindowRemaining,
    required bool autoPingWaiting,
    required int autoPingRemaining,
    required bool showFullText,
    required bool cooldownActive,
    required int cooldownRemaining,
    required bool isExpandedDuringCooldown,
    required bool isSkipped,
  }) {
    if (isTargetedRunning) {
      if (discoveryWindowActive) return showFullText ? 'Listening ${discoveryWindowRemaining}s' : '${discoveryWindowRemaining}s';
      if (autoPingWaiting) return showFullText ? (isSkipped ? 'Skipped ${autoPingRemaining}s' : 'Next in ${autoPingRemaining}s') : '${autoPingRemaining}s';
      return showFullText ? 'Stop' : null;
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

  Future<void> _toggleHybridAuto(BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.hybrid);
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
    final isHybridModeRunning = appState.autoPingEnabled && appState.autoMode == AutoMode.hybrid;
    final isTxModeRunning = isActiveModeRunning || isHybridModeRunning;
    final isTargetedRunning = appState.isTargetedModeRunning;
    final hybridEnabled = appState.preferences.hybridModeEnabled;
    final isPendingDisable = appState.isPendingDisable;
    final cooldownActive = appState.cooldownTimer.isRunning;
    final cooldownRemaining = appState.cooldownTimer.remainingSec;
    final manualCooldownActive = appState.manualPingCooldownTimer.isRunning; // Manual ping cooldown (15 seconds)
    final manualCooldownRemaining = appState.manualPingCooldownTimer.remainingSec;
    final rxWindowActive = appState.rxWindowTimer.isRunning;
    final rxWindowRemaining = appState.rxWindowTimer.remainingSec;
    final isPingSending = appState.isPingSending;
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
                enabled: canPingManual && !isTxModeRunning && !isTargetedRunning && !cooldownActive && !manualCooldownActive && !txBlockedByOffline && !txNotAllowed &&
                         !rxWindowActive && !isPingSending && !discoveryWindowActive && !isPendingDisable,
                isActive: (isPingSending || rxWindowActive) && !isTxModeRunning,
                countdown: isPingSending
                    ? null
                    : rxWindowActive && !isTxModeRunning
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

            // Active/Hybrid Mode button
            Expanded(
              child: _LandscapeIconButton(
                icon: hybridEnabled ? Icons.compare_arrows : Icons.sensors,
                tooltip: txNotAllowed ? 'Zone Full (Passive Only)' : (hybridEnabled ? 'Hybrid Mode' : 'Active Mode'),
                color: isPendingDisable
                    ? Colors.orange
                    : isTxModeRunning
                        ? const Color(0xFF22C55E) // green-500
                        : const Color(0xFF6366F1), // indigo-500
                enabled: !isPendingDisable && !isTargetedRunning && ((isTxModeRunning || (canStartAuto && !isPassiveModeRunning && !cooldownActive && !isPingSending && !rxWindowActive)) && !txBlockedByOffline && !txNotAllowed),
                isActive: isPendingDisable || isTxModeRunning,
                countdown: isTxModeRunning
                    ? (discoveryWindowActive
                        ? discoveryWindowRemaining
                        : rxWindowActive
                            ? rxWindowRemaining
                            : autoPingWaiting
                                ? autoPingRemaining
                                : null)
                    : isPendingDisable && (rxWindowActive || discoveryWindowActive)
                        ? (rxWindowActive ? rxWindowRemaining : discoveryWindowRemaining)
                        : null,
                onPressed: () => hybridEnabled ? _toggleHybridAuto(context, appState) : _toggleTxRxAuto(context, appState),
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
                enabled: isPassiveModeRunning || (appState.isConnected && !isTxModeRunning && !isTargetedRunning && !isPendingDisable &&
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

        // Targeted Ping controls (Trace Mode)
        _TargetedPingSection(
          isAnyModeRunning: isActiveModeRunning || isPassiveModeRunning || isHybridModeRunning,
          cooldownActive: cooldownActive,
          cooldownRemaining: cooldownRemaining,
          compact: true,
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

  Future<void> _toggleHybridAuto(BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.hybrid);
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
                  child: const Text(
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
