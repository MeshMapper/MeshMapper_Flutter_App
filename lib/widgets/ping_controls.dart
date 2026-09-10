import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/repeater.dart';
import '../providers/app_state_provider.dart';
import '../services/ping_service.dart';
import '../services/repeater_admin/manage_target.dart';
import '../services/repeater_admin/repeater_admin_models.dart';
import '../services/status/ping_control_labels.dart';
import '../utils/debug_logger_io.dart';
import 'repeater_admin_sheet.dart';
import 'repeater_picker_sheet.dart';

/// The render-only facts every ping-control layout reads: the offline / zone
/// blocks, the Hybrid word, which mode is running, and whether a stop is
/// pending. Everything else a button shows comes from [AppStateProvider.sessionStatus],
/// the one model the glance surfaces read too, so the phone cannot drift from
/// what the watch and the Live Activity say. Timers and countdowns come from
/// that model's per-lane deadlines, not from here.
PingRenderFacts _renderFactsOf(AppStateProvider s) {
  final prefs = s.preferences;
  return (
    txBlockedByOffline: s.offlineMode && s.isConnected,
    txNotAllowed: s.isConnected && !s.txAllowed,
    hybridEnabled: prefs.hybridModeEnabled,
    isTxModeRunning: s.autoPingEnabled &&
        (s.autoMode == AutoMode.active || s.autoMode == AutoMode.hybrid),
    isPassiveModeRunning: s.autoPingEnabled && s.autoMode == AutoMode.passive,
    isTargetedRunning: s.isTargetedModeRunning,
    isPendingDisable: s.isPendingDisable,
  );
}

/// The three flags the blocking hint needs that are not session state: whether
/// the radio is connected and whether the antenna and power are declared. The
/// hint is a projection of the ping validators, which the model deliberately
/// does not carry, so it stays on facts.
PingHintFacts _hintFactsOf(AppStateProvider s) {
  final prefs = s.preferences;
  return (
    isConnected: s.isConnected,
    externalAntennaSet: prefs.externalAntennaSet,
    isPowerSet:
        prefs.autoPowerSet || prefs.powerLevelSet || s.deviceModel != null,
  );
}

/// The icon for a blocking reason. Exhaustive on purpose: a new reason in the
/// shared table cannot be added without this failing to compile.
IconData _hintIcon(StatusHint hint) => switch (hint) {
      StatusHint.antennaRequired => Icons.settings_input_antenna,
      StatusHint.powerRequired => Icons.bolt,
      StatusHint.airborne => Icons.airplanemode_active,
      StatusHint.noGpsLock => Icons.gps_off,
      StatusHint.gpsInaccurate => Icons.gps_not_fixed,
      StatusHint.outsideServiceArea => Icons.wrong_location,
    };

Color _hintColor(StatusHint hint) => switch (hint) {
      StatusHint.antennaRequired => Colors.orange,
      StatusHint.powerRequired => Colors.orange,
      StatusHint.airborne => Colors.red,
      StatusHint.noGpsLock => Colors.blue,
      StatusHint.gpsInaccurate => Colors.orange,
      StatusHint.outsideServiceArea => Colors.red,
    };

/// Fields the ping-control widgets depend on for their enabled/label state.
/// Used with `context.select` so the controls rebuild ONLY when one of these
/// changes — not on every GPS / noise-floor / battery `notifyListeners()`
/// (~1–2 Hz during wardriving). Timer (countdown) values are deliberately
/// excluded; they update via the inner `ListenableBuilder(timerListenable)`
/// in each widget. Keep this in sync with the `appState.*` reads in the build
/// bodies below — a missing field means a button can go stale while idle.
typedef _ControlsDeps = ({
  PingValidation pingValidation,
  PingValidation manualValidation,
  PingValidation autoValidation,
  bool autoPingEnabled,
  AutoMode autoMode,
  bool isTargetedModeRunning,
  bool hybridModeEnabled,
  bool isPendingDisable,
  bool isPingSending,
  bool isAutoPingStarting,
  bool isPingInProgress,
  bool isConnected,
  bool offlineMode,
  bool txAllowed,
  bool externalAntenna,
  bool externalAntennaSet,
  bool isPowerSet,
  bool floodTrafficEnabled,
  bool hasTargetRepeaterId,
  bool isRepeaterAdminActive,
});

_ControlsDeps _controlsDepsOf(AppStateProvider s) {
  final prefs = s.preferences;
  final targetId = s.targetRepeaterId;
  return (
    pingValidation: s.pingValidation,
    manualValidation: s.manualPingValidation,
    autoValidation: s.autoModeValidation,
    autoPingEnabled: s.autoPingEnabled,
    autoMode: s.autoMode,
    isTargetedModeRunning: s.isTargetedModeRunning,
    hybridModeEnabled: prefs.hybridModeEnabled,
    isPendingDisable: s.isPendingDisable,
    isPingSending: s.isPingSending,
    isAutoPingStarting: s.isAutoPingStarting,
    isPingInProgress: s.isPingInProgress,
    isConnected: s.isConnected,
    offlineMode: s.offlineMode,
    txAllowed: s.txAllowed,
    externalAntenna: prefs.externalAntenna,
    externalAntennaSet: prefs.externalAntennaSet,
    isPowerSet:
        prefs.autoPowerSet || prefs.powerLevelSet || s.deviceModel != null,
    floodTrafficEnabled: s.floodTrafficEnabled,
    hasTargetRepeaterId: targetId != null && targetId.isNotEmpty,
    isRepeaterAdminActive: s.isRepeaterAdminActive,
  );
}

/// Subset of provider state the Trace Mode section depends on.
///
/// Every field the Start predicate reads must live here, or the button goes
/// stale: the section rebuilds only when this record changes, so a flipped
/// antenna/power pref or a cleared auto-start flag would not re-enable it.
typedef _TargetedDeps = ({
  bool isTargetedModeRunning,
  int traceHopBytes,
  String? targetRepeaterId,
  bool isConnected,
  bool hasRepeaters,
  bool externalAntennaSet,
  bool isPowerSet,
  bool isAutoPingStarting,
  bool isRepeaterAdminActive,
  bool isPingInProgress,
  bool isPingSending,
  bool isAutoReconnecting,
  int repeaterCount,
  String? firmwareVersionString,
});

_TargetedDeps _targetedDepsOf(AppStateProvider s) {
  final prefs = s.preferences;
  return (
    isTargetedModeRunning: s.isTargetedModeRunning,
    traceHopBytes: s.traceHopBytes,
    targetRepeaterId: s.targetRepeaterId,
    isConnected: s.isConnected,
    hasRepeaters: s.repeaters.isNotEmpty,
    externalAntennaSet: prefs.externalAntennaSet,
    isPowerSet:
        prefs.autoPowerSet || prefs.powerLevelSet || s.deviceModel != null,
    isAutoPingStarting: s.isAutoPingStarting,
    isRepeaterAdminActive: s.isRepeaterAdminActive,
    isPingInProgress: s.isPingInProgress,
    isPingSending: s.isPingSending,
    isAutoReconnecting: s.isAutoReconnecting,
    repeaterCount: s.repeaters.length,
    firmwareVersionString: s.firmwareVersionString,
  );
}

/// Modern ping control panel with icon-based buttons and animated status
class PingControls extends StatelessWidget {
  const PingControls({super.key});

  @override
  Widget build(BuildContext context) {
    // Rebuild only when control-relevant state changes — NOT on every GPS /
    // noise-floor / battery notify. Countdown values update via the inner
    // ListenableBuilder(timerListenable) below, so they're excluded here.
    context.select<AppStateProvider, _ControlsDeps>(_controlsDepsOf);
    final appState = context.read<AppStateProvider>();
    return ListenableBuilder(
      listenable: appState.timerListenable,
      builder: (_, __) {
        final manualValidation = appState
            .manualPingValidation; // Manual ping validation (no distance check)
        final autoValidation = appState.autoModeValidation;
        final canPingManual =
            manualValidation == PingValidation.valid; // For Send Ping button
        final canStartAuto = autoValidation == PingValidation.valid;
        final isActiveModeRunning =
            appState.autoPingEnabled && appState.autoMode == AutoMode.active;
        final isPassiveModeRunning =
            appState.autoPingEnabled && appState.autoMode == AutoMode.passive;
        final isHybridModeRunning =
            appState.autoPingEnabled && appState.autoMode == AutoMode.hybrid;
        final isTxModeRunning = isActiveModeRunning || isHybridModeRunning;
        final isTargetedRunning = appState.isTargetedModeRunning;
        final hybridEnabled = appState.preferences.hybridModeEnabled;
        final isPendingDisable = appState
            .isPendingDisable; // Disable pending, waiting for RX window to complete
        final isAutoStarting = appState
            .isAutoPingStarting; // True while an auto mode is starting (pre-first-notify)
        final cooldownActive = appState.cooldownTimer
            .isRunning; // Shared cooldown after disabling Active Mode
        final manualCooldownActive = appState.manualPingCooldownTimer
            .isRunning; // Manual ping cooldown (15 seconds)
        final rxWindowActive =
            appState.rxWindowTimer.isRunning; // RX listening window after ping
        final isPingSending = appState
            .isPingSending; // True immediately when manual ping button clicked
        final autoPingWaiting =
            appState.autoPingTimer.isRunning; // Waiting for next auto ping
        final discoveryWindowActive = appState.discoveryWindowTimer
            .isRunning; // Discovery listening window countdown (Passive Mode)

        // TX is blocked when offline mode is active and connected
        final txBlockedByOffline = appState.offlineMode && appState.isConnected;

        // TX not allowed when API says zone is at TX capacity
        final txNotAllowed = appState.isConnected && !appState.txAllowed;

        final prefs = appState.preferences;
        final isPowerSet = prefs.autoPowerSet ||
            prefs.powerLevelSet ||
            appState.deviceModel != null;

        // Every word on these buttons comes from the shared table, so the
        // phone cannot drift away from what the watch and the Live Activity
        // say about the same instant.
        final status = appState.sessionStatus;
        final rf = _renderFactsOf(appState);
        // Which button owns a pending stop. Read from the shared table so the
        // colour, the caption and the word can never point at different
        // buttons: stopping Passive lights up Passive, not Active/Hybrid.
        final txStopping = isTxStopping(status, rf);
        final passiveStopping = isPassiveStopping(status, rf);

        final hint = blockingHint(_hintFactsOf(appState), appState.pingValidation);
        final blockingIcon = hint == null ? null : _hintIcon(hint.hint);
        final blockingColor = hint == null ? null : _hintColor(hint.hint);

        final floodTrafficVisible = appState.floodTrafficEnabled;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Action buttons row
            Row(
              children: [
                if (!txNotAllowed && floodTrafficVisible) ...[
                  // Send Ping button
                  // State flow: "Send Ping" → "Sending..." → "Listening Xs" → "Cooldown Xs" → "Send Ping"
                  // Manual pings use 15-second cooldown, no distance requirement
                  // When Active/Passive Mode is running, just shows "Send Ping" (disabled)
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.cell_tower,
                      label: portraitSendPingLabel(status, rf),
                      color: const Color(0xFF0EA5E9), // sky-500
                      enabled: canPingManual &&
                          // Grey Send Ping while an auto mode is starting so the
                          // single-ping icon doesn't show until the first auto ping
                          // fires (matches active/passive gating) (#389)
                          !isAutoStarting &&
                          !isTxModeRunning &&
                          !isTargetedRunning &&
                          !cooldownActive &&
                          !manualCooldownActive &&
                          !txBlockedByOffline &&
                          !txNotAllowed &&
                          !rxWindowActive &&
                          !isPingSending &&
                          !appState.isRepeaterAdminActive &&
                          !discoveryWindowActive &&
                          !isPendingDisable,
                      isActive: (isPingSending || rxWindowActive) &&
                          !isTxModeRunning, // Only active during manual ping flow
                      onPressed: () => _sendPing(context, appState),
                      showCooldown:
                          false, // No longer needed - countdown shown in label
                      subtitle: txBlockedByOffline
                          ? 'Offline Mode'
                          : txNotAllowed
                              ? 'Zone full'
                              : null, // No "Move Xm" - manual pings have no distance requirement
                      subtitleColor: txBlockedByOffline
                          ? Colors.orange
                          : txNotAllowed
                              ? Colors.red
                              : null,
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
                      icon:
                          hybridEnabled ? Icons.compare_arrows : Icons.sensors,
                      label: portraitActiveModeLabel(status, rf),
                      color: txStopping
                          ? Colors.orange
                          : isTxModeRunning
                              ? const Color(0xFF22C55E) // green-500
                              : const Color(0xFF6366F1), // indigo-500
                      enabled: !isPendingDisable &&
                          !isTargetedRunning &&
                          !isAutoStarting &&
                          ((isTxModeRunning ||
                                  (canStartAuto &&
                                      !isPassiveModeRunning &&
                                      !cooldownActive &&
                                      !isPingSending &&
                                      !appState.isRepeaterAdminActive &&
                                      !rxWindowActive)) &&
                              !txBlockedByOffline &&
                              !txNotAllowed),
                      isActive: txStopping || isTxModeRunning,
                      onPressed: () => hybridEnabled
                          ? _toggleHybridAuto(context, appState)
                          : _toggleTxRxAuto(context, appState),
                      showCooldown: false,
                      subtitle: txBlockedByOffline
                          ? 'Offline Mode'
                          : txNotAllowed
                              ? 'Zone full'
                              : (txStopping ? 'Stopping' : null),
                      subtitleColor: txBlockedByOffline
                          ? Colors.orange
                          : txNotAllowed
                              ? Colors.red
                              : Colors.orange,
                    ),
                  ),
                  const SizedBox(width: 10),
                ],

                // Passive Mode button (toggle)
                // When ON: shows "Listening..." then "Next disc Xs" cycle
                // When OFF: returns to normal, Active/Hybrid Mode re-enables immediately
                // Disabled during manual ping countdown phases, shows "Cooldown Xs"
                // When Active/Hybrid Mode is running, just shows "Passive Mode" (disabled, no countdown)
                Expanded(
                  child: _ActionButton(
                    icon: Icons.hearing,
                    label: portraitPassiveModeLabel(status, rf),
                    color: passiveStopping
                        ? Colors.orange
                        : isPassiveModeRunning
                            ? const Color(0xFF22C55E) // green-500
                            : const Color(0xFF6366F1), // indigo-500
                    enabled: !isPendingDisable &&
                        (isPassiveModeRunning ||
                            (appState.isConnected &&
                                !isTxModeRunning &&
                                !isTargetedRunning &&
                                !isAutoStarting &&
                                !isPingSending &&
                                !appState.isRepeaterAdminActive &&
                                !rxWindowActive &&
                                !cooldownActive &&
                                prefs.externalAntennaSet &&
                                isPowerSet)),
                    isActive: passiveStopping ||
                        (isPassiveModeRunning &&
                            (discoveryWindowActive ||
                                autoPingWaiting)), // Active during listening/waiting phases
                    subtitle: passiveStopping ? 'Stopping' : null,
                    subtitleColor: Colors.orange,
                    onPressed: () => _toggleRxAuto(context, appState),
                  ),
                ),
              ],
            ),

            // Status hint area - only show when there's a hint
            if (hint != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(blockingIcon, size: 14, color: blockingColor),
                    const SizedBox(width: 6),
                    Text(
                      hint.text,
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
              isAnyModeRunning: isActiveModeRunning ||
                  isPassiveModeRunning ||
                  isHybridModeRunning,
            ),
          ],
        );
      },
    );
  }

  Future<void> _sendPing(
      BuildContext context, AppStateProvider appState) async {
    HapticFeedback.mediumImpact();

    final success = await appState.sendPing();

    if (success) {
      debugLog('[PING] Manual ping sent successfully');
    }
  }

  Future<void> _toggleTxRxAuto(
      BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.active);
  }

  Future<void> _toggleHybridAuto(
      BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.hybrid);
  }

  Future<void> _toggleRxAuto(
      BuildContext context, AppStateProvider appState) async {
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
  final String? subtitle; // Optional subtitle text (e.g., "Move 5m")
  final Color? subtitleColor; // Optional subtitle color

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

class _ActionButtonState extends State<_ActionButton> {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Use color when enabled, active (RX listening), or during cooldown
    // This prevents the button from going grey during cooldown
    final showColor = widget.enabled || widget.isActive || widget.showCooldown;
    final effectiveColor =
        showColor ? widget.color : colorScheme.onSurfaceVariant;
    final borderOpacity = widget.isActive ? 0.6 : 0.3;
    // Static active-state background opacity. This was a repeating pulse
    // animation, removed because a .repeat() AnimationController kept the GPU
    // rendering at the display refresh rate for the entire wardriving session.
    // The button still reads as "active" via color, the dot, and the text.
    final bgOpacity = widget.isActive ? 0.25 : 0.12;

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
                    // Active indicator dot. Suppressed whenever a subtitle is
                    // showing, for the same reason the caption below prefers
                    // one: a green running dot on an orange "Stopping 5s"
                    // button says the mode is still going.
                    if (widget.isActive && widget.subtitle == null)
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
                  fontWeight:
                      widget.isActive ? FontWeight.w600 : FontWeight.w500,
                  color: showColor
                      ? (widget.isActive
                          ? effectiveColor
                          : colorScheme.onSurface)
                      : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ),
              // Subtitle OR the "Active" status text - always reserve space.
              // The subtitle wins, because it is the more specific word: a
              // button that is stopping is still "active", and captioning it
              // green "Active" under an orange "Stopping 5s" read as a mode
              // that was still running. Nothing else passes a subtitle while
              // it is active (Offline Mode and Zone full both disable the
              // button), so this only changes the stop.
              SizedBox(
                height: 12,
                child: widget.subtitle != null
                    ? Text(
                        widget.subtitle!,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w500,
                          color: widget.subtitleColor ?? Colors.orange.shade600,
                        ),
                      )
                    : widget.isActive
                        ? const Text(
                            'Active',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF22C55E),
                            ),
                          )
                        : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Targeted Ping controls - hex text field + start/stop button
class _TargetedPingSection extends StatefulWidget {
  final bool isAnyModeRunning;
  final bool compact;

  const _TargetedPingSection({
    required this.isAnyModeRunning,
    this.compact = false,
  });

  @override
  State<_TargetedPingSection> createState() => _TargetedPingSectionState();
}

class _TargetedPingSectionState extends State<_TargetedPingSection> {
  final _controller = TextEditingController();
  bool _isStarting = false;

  /// The repeater the user picked from the list, kept so Manage has a full
  /// public key even when the typed ID is only its first few characters.
  Repeater? _pickedRepeater;

  @override
  void initState() {
    super.initState();
    // Restore any previously set target ID
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final appState = context.read<AppStateProvider>();
      final existing = appState.targetRepeaterId;
      if (existing != null &&
          existing.isNotEmpty &&
          _controller.text != existing) {
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
    _pickedRepeater = repeater;
    appState.setTargetRepeaterId(trimmed);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild only when Trace-relevant state changes (not on GPS/noise/battery).
    context.select<AppStateProvider, _TargetedDeps>(_targetedDepsOf);
    final appState = context.read<AppStateProvider>();
    final colorScheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: appState.timerListenable,
      builder: (_, __) {
        final status = appState.sessionStatus;
        final rf = _renderFactsOf(appState);
        // A pending stop belongs to the button of the mode being stopped.
        final traceStopping = isTraceStopping(status, rf);
        final isTargetedRunning = appState.isTargetedModeRunning;
        final maxLen = appState.traceHopBytes * 2;

        // Sync controller when provider clears target (e.g. trace bytes changed)
        if (appState.targetRepeaterId == null && _controller.text.isNotEmpty) {
          _controller.clear();
        }

        // Determine if the start button should be enabled
        final prefs = appState.preferences;
        final isPowerSet = prefs.autoPowerSet ||
            prefs.powerLevelSet ||
            appState.deviceModel != null;
        final hexText = _controller.text.trim();
        final isValidHex = hexText.isNotEmpty &&
            hexText.length == maxLen &&
            RegExp(r'^[0-9a-fA-F]+$').hasMatch(hexText);
        final canStart = isValidHex &&
            !widget.isAnyModeRunning &&
            !isTargetedRunning &&
            !appState.isRepeaterAdminActive &&
            !appState.cooldownTimer.isRunning &&
            !appState.isAutoPingStarting &&
            appState.isConnected &&
            prefs.externalAntennaSet &&
            isPowerSet;

        // Which repeater Manage would open, and why it may not open now. The
        // inputs match the provider's own refusal, plus the Trace lane this
        // row owns.
        final manageTarget = resolveManageTarget(
          typedId: hexText,
          picked: _pickedRepeater,
          repeaters: appState.repeaters,
        );
        final manageBlock = manageBlockReason(
          isConnected: appState.isConnected,
          isAnyModeRunning: widget.isAnyModeRunning || isTargetedRunning,
          isPingInProgress: appState.isPingInProgress,
          isPingSending: appState.isPingSending,
          isRepeaterAdminActive: appState.isRepeaterAdminActive,
          isAutoReconnecting: appState.isAutoReconnecting,
          companionFirmwareSupported: companionFirmwareAtLeast(
              appState.firmwareVersionString,
              major: kCompanionFloorMajor,
              minor: kCompanionFloorMinor,
              patch: kCompanionFloorPatch),
        );
        final manageHint = manageBlock ??
            (manageTarget == null ? kChooseFromListHint : 'Manage repeater');
        final canManage =
            manageBlock == null && manageTarget != null && !_isStarting;

        // `isTargetedRunning` stays true through a pending stop, so without
        // the guard this section kept taking taps while its own stop was
        // draining, which re-entered the disable and parked it until the 12s
        // backstop. The Active/Hybrid button has always led with this check.
        final isEnabled = (canStart || isTargetedRunning) &&
            !_isStarting &&
            !rf.isPendingDisable;
        final buttonColor = traceStopping
            ? Colors.orange
            : (isTargetedRunning || _isStarting)
                ? const Color(0xFF22C55E) // green-500 when running/starting
                : Colors.cyan;
        // `|| traceStopping` is the `showColor = enabled || isActive` idiom the
        // other three buttons use. Without it this section, which greys itself
        // while its own stop drains, could never show the stop: portrait dimmed
        // it to 50% and landscape (which renders no label at all) showed
        // nothing whatsoever.
        final effectiveColor = isEnabled || traceStopping
            ? buttonColor
            : colorScheme.onSurfaceVariant;

        return Container(
          decoration: BoxDecoration(
            color: effectiveColor.withValues(
                alpha: isTargetedRunning ? 0.15 : 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: effectiveColor.withValues(
                  alpha: isTargetedRunning ? 0.5 : 0.25),
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
                            appState.setTargetRepeaterId(
                                _controller.text.trim().toUpperCase());
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
                            traceSectionLabel(status, rf, isStarting: _isStarting),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isTargetedRunning
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              // Same `|| traceStopping` as effectiveColor above:
                              // the icon, border and fill went orange for the
                              // stop while the words stayed disabled grey.
                              color: isEnabled || traceStopping
                                  ? colorScheme.onSurface
                                  : colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.5),
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
                    hintText:
                        'e.g. ${maxLen == 2 ? '4E' : maxLen == 4 ? '4E7A' : maxLen == 8 ? '4E7A3B00' : '4E7A3B'}',
                    hintStyle: TextStyle(
                      fontSize: 12,
                      color:
                          colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                    counterText: '',
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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
                    // The picked repeater stops being the selection as soon as
                    // the typed text no longer prefixes its key.
                    final typed = value.trim().toUpperCase();
                    if (_pickedRepeater != null &&
                        !_pickedRepeater!.hexId.toUpperCase().startsWith(typed)) {
                      _pickedRepeater = null;
                    }
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
                  onPressed:
                      (!isTargetedRunning && appState.repeaters.isNotEmpty)
                          ? _showRepeaterPicker
                          : null,
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Choose repeater',
                ),
              ),
              if (!widget.compact) ...[
                const SizedBox(width: 6),
                // Manage repeater button (repeater administrators)
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    icon: Icon(
                      Icons.admin_panel_settings_outlined,
                      size: 18,
                      color: canManage
                          ? effectiveColor
                          : colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                    ),
                    onPressed: canManage
                        ? () {
                            HapticFeedback.lightImpact();
                            showRepeaterAdminSheet(context,
                                RepeaterTarget.fromRepeater(manageTarget));
                          }
                        : null,
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    tooltip: manageHint,
                  ),
                ),
              ],
            ],
          ),
        );
      },
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
    // Rebuild only when control-relevant state changes (not on GPS/noise/battery).
    context.select<AppStateProvider, _ControlsDeps>(_controlsDepsOf);
    final appState = context.read<AppStateProvider>();
    return ListenableBuilder(
      listenable: appState.timerListenable,
      builder: (_, __) {
        final status = appState.sessionStatus;
        final rf = _renderFactsOf(appState);
        // Which button owns a pending stop. Read from the shared table so the
        // colour, the caption and the word can never point at different
        // buttons: stopping Passive lights up Passive, not Active/Hybrid.
        final txStopping = isTxStopping(status, rf);
        final passiveStopping = isPassiveStopping(status, rf);
        final traceStopping = isTraceStopping(status, rf);
        final manualValidation = appState
            .manualPingValidation; // Manual ping validation (no distance check)
        final autoValidation = appState.autoModeValidation;
        final canPingManual =
            manualValidation == PingValidation.valid; // For Send Ping button
        final canStartAuto = autoValidation == PingValidation.valid;
        final isActiveModeRunning =
            appState.autoPingEnabled && appState.autoMode == AutoMode.active;
        final isPassiveModeRunning =
            appState.autoPingEnabled && appState.autoMode == AutoMode.passive;
        final isHybridModeRunning =
            appState.autoPingEnabled && appState.autoMode == AutoMode.hybrid;
        final isTxModeRunning = isActiveModeRunning || isHybridModeRunning;
        final isTargetedRunning = appState.isTargetedModeRunning;
        final hybridEnabled = appState.preferences.hybridModeEnabled;
        final isPendingDisable = appState.isPendingDisable;
        final isAutoStarting = appState.isAutoPingStarting;
        final cooldownActive = appState.cooldownTimer.isRunning;
        final manualCooldownActive = appState.manualPingCooldownTimer
            .isRunning; // Manual ping cooldown (15 seconds)
        final rxWindowActive = appState.rxWindowTimer.isRunning;
        final isPingSending = appState.isPingSending;
        final autoPingWaiting = appState.autoPingTimer.isRunning;
        final discoveryWindowActive = appState.discoveryWindowTimer.isRunning;

        // TX is blocked when offline mode is active and connected
        final txBlockedByOffline = appState.offlineMode && appState.isConnected;

        // TX not allowed when API says zone is at TX capacity
        final txNotAllowed = appState.isConnected && !appState.txAllowed;

        final prefs = appState.preferences;
        final isPowerSet = prefs.autoPowerSet ||
            prefs.powerLevelSet ||
            appState.deviceModel != null;

        // Determine which button is currently active (not during cooldown)
        final sendPingCurrentlyActive =
            (isPingSending || rxWindowActive || manualCooldownActive) &&
                !isTxModeRunning;
        final activeModeCurrentlyActive = txStopping || isTxModeRunning;
        final passiveModeCurrentlyActive = passiveStopping ||
            (isPassiveModeRunning &&
                (discoveryWindowActive || autoPingWaiting));

        // Track the last active button for cooldown
        if (sendPingCurrentlyActive) {
          _lastActiveButton = _LastActiveButton.sendPing;
        } else if (activeModeCurrentlyActive) {
          _lastActiveButton = _LastActiveButton.activeMode;
        } else if (passiveModeCurrentlyActive) {
          _lastActiveButton = _LastActiveButton.passiveMode;
        } else if (traceStopping || isTargetedRunning) {
          _lastActiveButton = _LastActiveButton.targeted;
        }
        // Reset when no cooldown and no activity
        if (!cooldownActive &&
            !manualCooldownActive &&
            !sendPingCurrentlyActive &&
            !activeModeCurrentlyActive &&
            !passiveModeCurrentlyActive &&
            !traceStopping &&
            !isTargetedRunning) {
          _lastActiveButton = _LastActiveButton.none;
        }

        // Determine which button should be expanded
        // During cooldown, the last active button stays expanded
        final sendPingExpanded = sendPingCurrentlyActive ||
            (manualCooldownActive &&
                _lastActiveButton == _LastActiveButton.sendPing) ||
            (cooldownActive && _lastActiveButton == _LastActiveButton.sendPing);
        final activeModeExpanded = activeModeCurrentlyActive ||
            (cooldownActive &&
                _lastActiveButton == _LastActiveButton.activeMode);
        final passiveModeExpanded = passiveModeCurrentlyActive ||
            (cooldownActive &&
                _lastActiveButton == _LastActiveButton.passiveMode);

        // Determine which buttons are colored (enabled or active)
        final sendPingEnabled = canPingManual &&
            // Grey Send Ping while an auto mode is starting so the single-ping icon
            // doesn't show until the first auto ping fires (matches active/passive
            // gating) (#389)
            !isAutoStarting &&
            !isTxModeRunning &&
            !isTargetedRunning &&
            !cooldownActive &&
            !manualCooldownActive &&
            !txBlockedByOffline &&
            !txNotAllowed &&
            !rxWindowActive &&
            !isPingSending &&
            !appState.isRepeaterAdminActive &&
            !discoveryWindowActive &&
            !isPendingDisable;
        final sendPingActive = (isPingSending || rxWindowActive) &&
            !isTxModeRunning &&
            !cooldownActive &&
            !manualCooldownActive;
        final sendPingShowColor = sendPingEnabled || sendPingActive;

        final activeModeEnabled = !isPendingDisable &&
            !isTargetedRunning &&
            !isAutoStarting &&
            ((isTxModeRunning ||
                    (canStartAuto &&
                        !isPassiveModeRunning &&
                        !cooldownActive &&
                        !isPingSending &&
                        !appState.isRepeaterAdminActive &&
                        !rxWindowActive)) &&
                !txBlockedByOffline &&
                !txNotAllowed);
        final activeModeActive = txStopping || isTxModeRunning;
        final activeModeShowColor = activeModeEnabled || activeModeActive;

        final passiveModeEnabled = !isPendingDisable &&
            (isPassiveModeRunning ||
                (appState.isConnected &&
                    !isTxModeRunning &&
                    !isTargetedRunning &&
                    !isAutoStarting &&
                    !isPingSending &&
                    !appState.isRepeaterAdminActive &&
                    !rxWindowActive &&
                    !cooldownActive &&
                    prefs.externalAntennaSet &&
                    isPowerSet));
        final passiveModeActive = passiveStopping ||
            (isPassiveModeRunning &&
                (discoveryWindowActive || autoPingWaiting));
        final passiveModeShowColor = passiveModeEnabled || passiveModeActive;

        // Trace Mode (only relevant when a repeater ID has been entered)
        final hasTargetRepeaterId = appState.targetRepeaterId != null &&
            appState.targetRepeaterId!.isNotEmpty;
        final targetedCurrentlyActive = traceStopping || isTargetedRunning;
        final traceModeExpanded = targetedCurrentlyActive ||
            (cooldownActive && _lastActiveButton == _LastActiveButton.targeted);
        final traceModeEnabled = hasTargetRepeaterId &&
            !isTxModeRunning &&
            !isPassiveModeRunning &&
            !isPendingDisable &&
            !isAutoStarting &&
            !isPingSending &&
            !appState.isRepeaterAdminActive &&
            !rxWindowActive &&
            !cooldownActive &&
            !manualCooldownActive &&
            appState.isConnected &&
            prefs.externalAntennaSet &&
            isPowerSet;
        final traceModeActive = traceStopping || isTargetedRunning;
        final traceModeShowColor = traceModeEnabled || traceModeActive;

        // Check if any button is actively expanded (showing label)
        final anyExpanded = sendPingExpanded ||
            activeModeExpanded ||
            passiveModeExpanded ||
            traceModeExpanded;
        // Check if all buttons are disabled (no color) - used to split space equally in initial state
        final allDisabled = !sendPingShowColor &&
            !activeModeShowColor &&
            !passiveModeShowColor &&
            (!hasTargetRepeaterId || !traceModeShowColor);

        // Build the buttons
        final sendPingButton = _CompactActionButton(
          icon: Icons.cell_tower,
          label: compactSendPingLabel(status, rf, showFullText: sendPingExpanded),
          color: const Color(0xFF0EA5E9), // sky-500
          enabled: sendPingEnabled,
          isActive: sendPingActive,
          isExpanded: sendPingExpanded,
          progress: rxWindowActive && !isTxModeRunning
              ? appState.rxWindowTimer.progress
              : manualCooldownActive &&
                      _lastActiveButton == _LastActiveButton.sendPing
                  ? appState.manualPingCooldownTimer.progress
                  : cooldownActive &&
                          _lastActiveButton == _LastActiveButton.sendPing
                      ? appState.cooldownTimer.progress
                      : null,
          onPressed: () => _sendPing(context, appState),
        );

        final activeModeButton = _CompactActionButton(
          icon: hybridEnabled ? Icons.compare_arrows : Icons.sensors,
          label: compactActiveModeLabel(status, rf,
              showFullText: activeModeExpanded,
              isExpandedDuringCooldown: activeModeExpanded && cooldownActive),
          color: txStopping
              ? Colors.orange
              : isTxModeRunning
                  ? const Color(0xFF22C55E) // green-500
                  : const Color(0xFF6366F1), // indigo-500
          enabled: activeModeEnabled,
          isActive: activeModeActive,
          isExpanded: activeModeExpanded,
          progress: (rxWindowActive || discoveryWindowActive) && isTxModeRunning
              ? (discoveryWindowActive
                  ? appState.discoveryWindowTimer.progress
                  : appState.rxWindowTimer.progress)
              : autoPingWaiting && isTxModeRunning
                  ? appState.autoPingTimer.progress
                  : cooldownActive &&
                          _lastActiveButton == _LastActiveButton.activeMode
                      ? appState.cooldownTimer.progress
                      : null,
          onPressed: () => hybridEnabled
              ? _toggleHybridAuto(context, appState)
              : _toggleTxRxAuto(context, appState),
        );

        final passiveModeButton = _CompactActionButton(
          icon: Icons.hearing,
          label: compactPassiveModeLabel(status, rf,
              showFullText: passiveModeExpanded,
              isExpandedDuringCooldown: passiveModeExpanded && cooldownActive),
          color: passiveStopping
              ? Colors.orange
              : isPassiveModeRunning
                  ? const Color(0xFF22C55E) // green-500
                  : const Color(0xFF6366F1), // indigo-500
          enabled: passiveModeEnabled,
          isActive: passiveModeActive,
          isExpanded: passiveModeExpanded,
          // While its own stop drains, the bar follows the window the label
          // counts, not the interval timer that is still running underneath.
          progress: passiveStopping
              ? (discoveryWindowActive
                  ? appState.discoveryWindowTimer.progress
                  : rxWindowActive
                      ? appState.rxWindowTimer.progress
                      : null)
              : discoveryWindowActive && isPassiveModeRunning
                  ? appState.discoveryWindowTimer.progress
                  : autoPingWaiting && isPassiveModeRunning
                      ? appState.autoPingTimer.progress
                      : cooldownActive &&
                              _lastActiveButton == _LastActiveButton.passiveMode
                          ? appState.cooldownTimer.progress
                          : null,
          onPressed: () => _toggleRxAuto(context, appState),
        );

        // Build trace mode button (only used when hasTargetRepeaterId)
        final traceModeButton = _CompactActionButton(
          icon: Icons.route,
          label: compactTraceModeLabel(status, rf,
              showFullText: traceModeExpanded,
              isExpandedDuringCooldown: traceModeExpanded && cooldownActive),
          color: traceStopping
              ? Colors.orange
              : isTargetedRunning
                  ? const Color(0xFF22C55E) // green-500
                  : const Color(0xFF06B6D4), // cyan-500
          enabled: !isPendingDisable && (traceModeEnabled || isTargetedRunning),
          isActive: traceModeActive,
          isExpanded: traceModeExpanded,
          progress: discoveryWindowActive && isTargetedRunning
              ? appState.discoveryWindowTimer.progress
              : autoPingWaiting && isTargetedRunning
                  ? appState.autoPingTimer.progress
                  : cooldownActive &&
                          _lastActiveButton == _LastActiveButton.targeted
                      ? appState.cooldownTimer.progress
                      : null,
          onPressed: () {
            HapticFeedback.lightImpact();
            appState.toggleAutoPing(AutoMode.targeted);
          },
        );

        final floodTrafficVisible = appState.floodTrafficEnabled;

        // Layout logic:
        // - If button is expanded (including during cooldown): stays big
        // - If no button is expanded: all colored buttons share space equally
        // - Grey non-expanded buttons are icon-only
        return Row(
          children: [
            if (!txNotAllowed && floodTrafficVisible) ...[
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
            ],

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
      },
    );
  }

  Future<void> _sendPing(
      BuildContext context, AppStateProvider appState) async {
    HapticFeedback.mediumImpact();

    final success = await appState.sendPing();

    if (success) {
      debugLog('[PING] Compact ping sent successfully');
    }
  }

  Future<void> _toggleTxRxAuto(
      BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.active);
  }

  Future<void> _toggleHybridAuto(
      BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.hybrid);
  }

  Future<void> _toggleRxAuto(
      BuildContext context, AppStateProvider appState) async {
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
    // Rebuild only when control-relevant state changes (not on GPS/noise/battery).
    context.select<AppStateProvider, _ControlsDeps>(_controlsDepsOf);
    final appState = context.read<AppStateProvider>();
    return ListenableBuilder(
      listenable: appState.timerListenable,
      builder: (_, __) {
        final status = appState.sessionStatus;
        final rf = _renderFactsOf(appState);
        // Which button owns a pending stop. Read from the shared table so the
        // colour, the caption and the word can never point at different
        // buttons: stopping Passive lights up Passive, not Active/Hybrid.
        final txStopping = isTxStopping(status, rf);
        final passiveStopping = isPassiveStopping(status, rf);
        final manualValidation = appState
            .manualPingValidation; // Manual ping validation (no distance check)
        final autoValidation = appState.autoModeValidation;
        final canPingManual =
            manualValidation == PingValidation.valid; // For Send Ping button
        final canStartAuto = autoValidation == PingValidation.valid;
        final isActiveModeRunning =
            appState.autoPingEnabled && appState.autoMode == AutoMode.active;
        final isPassiveModeRunning =
            appState.autoPingEnabled && appState.autoMode == AutoMode.passive;
        final isHybridModeRunning =
            appState.autoPingEnabled && appState.autoMode == AutoMode.hybrid;
        final isTxModeRunning = isActiveModeRunning || isHybridModeRunning;
        final isTargetedRunning = appState.isTargetedModeRunning;
        final hybridEnabled = appState.preferences.hybridModeEnabled;
        final isPendingDisable = appState.isPendingDisable;
        final isAutoStarting = appState.isAutoPingStarting;
        final cooldownActive = appState.cooldownTimer.isRunning;
        final manualCooldownActive = appState.manualPingCooldownTimer
            .isRunning; // Manual ping cooldown (15 seconds)
        final rxWindowActive = appState.rxWindowTimer.isRunning;
        final isPingSending = appState.isPingSending;
        final autoPingWaiting = appState.autoPingTimer.isRunning;
        final discoveryWindowActive = appState.discoveryWindowTimer.isRunning;

        // TX is blocked when offline mode is active and connected
        final txBlockedByOffline = appState.offlineMode && appState.isConnected;

        // TX not allowed when API says zone is at TX capacity
        final txNotAllowed = appState.isConnected && !appState.txAllowed;

        final prefs = appState.preferences;
        final isPowerSet = prefs.autoPowerSet ||
            prefs.powerLevelSet ||
            appState.deviceModel != null;

        final floodTrafficVisible = appState.floodTrafficEnabled;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Antenna selector (compact)
            _LandscapeAntennaSelector(
              externalAntenna: prefs.externalAntenna,
              externalAntennaSet: prefs.externalAntennaSet,
              onChanged: (value) => appState.updatePreferences(
                prefs.copyWith(
                    externalAntenna: value, externalAntennaSet: true),
              ),
            ),
            const SizedBox(height: 10),

            // Action buttons row (icon-only)
            Row(
              children: [
                if (!txNotAllowed && floodTrafficVisible) ...[
                  // TX Ping button
                  Expanded(
                    child: _LandscapeIconButton(
                      icon: Icons.cell_tower,
                      tooltip: txNotAllowed
                          ? 'Passive only (zone full)'
                          : 'Send Ping',
                      color: const Color(0xFF0EA5E9), // sky-500
                      enabled: canPingManual &&
                          // Grey Send Ping while an auto mode is starting so the
                          // single-ping icon doesn't show until the first auto ping
                          // fires (matches active/passive gating) (#389)
                          !isAutoStarting &&
                          !isTxModeRunning &&
                          !isTargetedRunning &&
                          !cooldownActive &&
                          !manualCooldownActive &&
                          !txBlockedByOffline &&
                          !txNotAllowed &&
                          !rxWindowActive &&
                          !isPingSending &&
                          !appState.isRepeaterAdminActive &&
                          !discoveryWindowActive &&
                          !isPendingDisable,
                      isActive:
                          (isPingSending || rxWindowActive) && !isTxModeRunning,
                      countdown: landscapeSendPingCountdown(status, rf),
                      onPressed: () => _sendPing(context, appState),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Active/Hybrid Mode button
                  Expanded(
                    child: _LandscapeIconButton(
                      icon:
                          hybridEnabled ? Icons.compare_arrows : Icons.sensors,
                      tooltip: txNotAllowed
                          ? 'Passive only (zone full)'
                          : (hybridEnabled ? 'Hybrid Mode' : 'Active Mode'),
                      color: txStopping
                          ? Colors.orange
                          : isTxModeRunning
                              ? const Color(0xFF22C55E) // green-500
                              : const Color(0xFF6366F1), // indigo-500
                      enabled: !isPendingDisable &&
                          !isTargetedRunning &&
                          !isAutoStarting &&
                          ((isTxModeRunning ||
                                  (canStartAuto &&
                                      !isPassiveModeRunning &&
                                      !cooldownActive &&
                                      !isPingSending &&
                                      !appState.isRepeaterAdminActive &&
                                      !rxWindowActive)) &&
                              !txBlockedByOffline &&
                              !txNotAllowed),
                      isActive: txStopping || isTxModeRunning,
                      stopping: txStopping,
                      countdown: landscapeActiveModeCountdown(status, rf),
                      onPressed: () => hybridEnabled
                          ? _toggleHybridAuto(context, appState)
                          : _toggleTxRxAuto(context, appState),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],

                // Passive Mode button
                Expanded(
                  child: _LandscapeIconButton(
                    icon: Icons.hearing,
                    tooltip: 'Passive Mode',
                    color: passiveStopping
                        ? Colors.orange
                        : isPassiveModeRunning
                            ? const Color(0xFF22C55E) // green-500
                            : const Color(0xFF6366F1), // indigo-500
                    enabled: !isPendingDisable &&
                        (isPassiveModeRunning ||
                            (appState.isConnected &&
                                !isTxModeRunning &&
                                !isTargetedRunning &&
                                !isAutoStarting &&
                                !isPingSending &&
                                !appState.isRepeaterAdminActive &&
                                !rxWindowActive &&
                                !cooldownActive &&
                                prefs.externalAntennaSet &&
                                isPowerSet)),
                    isActive: passiveStopping ||
                        (isPassiveModeRunning &&
                            (discoveryWindowActive || autoPingWaiting)),
                    stopping: passiveStopping,
                    countdown: landscapePassiveModeCountdown(status, rf),
                    onPressed: () => _toggleRxAuto(context, appState),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Targeted Ping controls (Trace Mode)
            _TargetedPingSection(
              isAnyModeRunning: isActiveModeRunning ||
                  isPassiveModeRunning ||
                  isHybridModeRunning,
              compact: true,
            ),
          ],
        );
      },
    );
  }

  Future<void> _sendPing(
      BuildContext context, AppStateProvider appState) async {
    HapticFeedback.mediumImpact();
    await appState.sendPing();
  }

  Future<void> _toggleTxRxAuto(
      BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.active);
  }

  Future<void> _toggleHybridAuto(
      BuildContext context, AppStateProvider appState) async {
    HapticFeedback.lightImpact();
    await appState.toggleAutoPing(AutoMode.hybrid);
  }

  Future<void> _toggleRxAuto(
      BuildContext context, AppStateProvider appState) async {
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
                  color: externalAntennaSet
                      ? colorScheme.onSurfaceVariant
                      : notSetColor,
                ),
              ),
              if (!externalAntennaSet) ...[
                const SizedBox(width: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: notSetColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'Required',
                    style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w600,
                        color: notSetColor),
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
            border:
                Border.all(color: colorScheme.outline.withValues(alpha: 0.2)),
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
                      borderRadius: const BorderRadius.horizontal(
                          left: Radius.circular(7)),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'Internal',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: (!externalAntenna && externalAntennaSet)
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: (!externalAntenna && externalAntennaSet)
                            ? Colors.orange
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
              // Divider
              Container(
                  width: 1,
                  height: 18,
                  color: colorScheme.outline.withValues(alpha: 0.3)),
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
                      borderRadius: const BorderRadius.horizontal(
                          right: Radius.circular(7)),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'External',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: (externalAntenna && externalAntennaSet)
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: (externalAntenna && externalAntennaSet)
                            ? Colors.orange
                            : colorScheme.onSurfaceVariant,
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
  // A stop is draining on this button. Portrait suppresses the running dot
  // whenever a subtitle ("Stopping") is showing; this widget has no subtitle,
  // so the caller says so directly.
  final bool stopping;
  final VoidCallback onPressed;

  const _LandscapeIconButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.enabled,
    required this.onPressed,
    this.isActive = false,
    this.countdown,
    this.stopping = false,
  });

  @override
  State<_LandscapeIconButton> createState() => _LandscapeIconButtonState();
}

class _LandscapeIconButtonState extends State<_LandscapeIconButton> {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Keep the button's color (not grey) whenever the countdown badge is shown,
    // mirroring portrait's `_ActionButton` showCooldown handling. Otherwise the
    // badge renders white text on grey (onSurfaceVariant) during cooldown.
    final showColor =
        widget.enabled || widget.isActive || widget.countdown != null;
    final effectiveColor =
        showColor ? widget.color : colorScheme.onSurfaceVariant;
    // Static active-state opacity (continuous pulse animation removed — see
    // _ActionButton; it kept the GPU rendering all session).
    final bgOpacity = widget.isActive ? 0.25 : 0.10;

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
                color: effectiveColor.withValues(
                    alpha: widget.isActive ? 0.5 : 0.25),
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
                  color: showColor
                      ? effectiveColor
                      : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                // Countdown badge (bottom right)
                if (widget.countdown != null)
                  Positioned(
                    bottom: 4,
                    right: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
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
                // Active indicator dot (top right). Hidden during a stop for
                // the same reason portrait hides it: a green running dot on an
                // orange Stopping button says the mode is still going, and
                // with no countdown running (a stop parked during the GPS
                // fetch) nothing else would suppress it.
                if (widget.isActive &&
                    widget.countdown == null &&
                    !widget.stopping)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: const Color(0xFF22C55E),
                        shape: BoxShape.circle,
                        border:
                            Border.all(color: colorScheme.surface, width: 1.5),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
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
  final double?
      progress; // 0.0 to 1.0 for progress bar fill, null = no progress bar

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

class _CompactActionButtonState extends State<_CompactActionButton> {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final showColor = widget.enabled || widget.isActive;
    final effectiveColor =
        showColor ? widget.color : colorScheme.onSurfaceVariant;
    // Show label if colored OR if expanded (shows countdown on grey button during cooldown)
    final hasLabel = widget.label != null && (showColor || widget.isExpanded);
    // Static active-state opacity (continuous pulse animation removed — see
    // _ActionButton; it kept the GPU rendering all session).
    final bgOpacity = widget.isActive ? 0.25 : 0.12;

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
              color:
                  effectiveColor.withValues(alpha: widget.isActive ? 0.5 : 0.3),
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
                          color: showColor
                              ? effectiveColor
                              : colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.5),
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
                                        fontWeight: widget.isActive
                                            ? FontWeight.w600
                                            : FontWeight.w500,
                                        color: showColor
                                            ? effectiveColor
                                            : colorScheme.onSurfaceVariant
                                                .withValues(alpha: 0.5),
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
  }
}
