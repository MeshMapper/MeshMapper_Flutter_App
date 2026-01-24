import 'dart:async';

import 'package:flutter/foundation.dart' show protected, VoidCallback;

import '../utils/debug_logger_io.dart';
import 'status_message_service.dart';

/// Countdown timer result with message and optional color
class CountdownResult {
  final String message;
  final StatusColor color;

  CountdownResult(this.message, [this.color = StatusColor.idle]);
}

/// Countdown timer for cooldown, auto-ping, and RX window
/// Reference: createCountdownTimer() in wardrive.js
///
/// Features:
/// - 1-second update interval
/// - First update respects minimum visibility
/// - Subsequent updates are immediate for smooth countdown
/// - Auto-stops when countdown reaches zero
class CountdownTimerService {
  Timer? _timer;
  DateTime? _endTime;
  bool _isFirstUpdate = true;
  @protected
  final StatusMessageService statusService;
  final CountdownResult Function(int remainingSec)? _getStatusMessage;
  final VoidCallback? onUpdate;  // Callback for UI refresh on each timer tick

  CountdownTimerService(
    this.statusService, {
    CountdownResult Function(int remainingSec)? getStatusMessage,
    this.onUpdate,
  }) : _getStatusMessage = getStatusMessage;

  /// Check if timer is running
  bool get isRunning => _timer != null;

  /// Get remaining milliseconds
  int get remainingMs {
    if (_endTime == null) return 0;
    final now = DateTime.now();
    final remaining = _endTime!.difference(now).inMilliseconds;
    return remaining > 0 ? remaining : 0;
  }

  /// Get remaining seconds (rounded up)
  int get remainingSec => (remainingMs / 1000).ceil();

  /// Start countdown timer
  /// @param durationMs - Duration in milliseconds
  void start(int durationMs) {
    stop();
    _endTime = DateTime.now().add(Duration(milliseconds: durationMs));
    _isFirstUpdate = true;

    // Start 1-second update timer
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _update());

    // Trigger immediate update
    _update();
  }

  /// Update countdown display
  void _update() {
    if (_endTime == null) return;

    final remainingMs = this.remainingMs;

    // Stop when countdown reaches zero
    if (remainingMs == 0) {
      stop();
      return;
    }

    final remainingSec = (remainingMs / 1000).ceil();

    // Get status message from callback (if provided)
    if (_getStatusMessage != null) {
      final result = _getStatusMessage(remainingSec);

      // First update respects minimum visibility of previous message
      // Subsequent updates are immediate for smooth 1-second countdown intervals
      final immediate = !_isFirstUpdate;
      statusService.setDynamicStatus(result.message, result.color, immediate: immediate);

      // Mark first update as complete
      _isFirstUpdate = false;
    }

    // Trigger UI refresh callback after each update
    onUpdate?.call();
  }

  /// Stop countdown timer
  void stop() {
    _timer?.cancel();
    _timer = null;
    _endTime = null;
    _isFirstUpdate = true;
  }

  /// Dispose resources
  void dispose() {
    stop();
  }
}

/// Specialized countdown timer for ping cooldown
/// Reference: wardrive.js state.cooldownEndTime and cooldownUpdateTimer
class CooldownTimer extends CountdownTimerService {
  CooldownTimer(StatusMessageService statusService, {VoidCallback? onUpdate})
      : super(
          statusService,
          onUpdate: onUpdate,
          getStatusMessage: (remainingSec) => CountdownResult(
            'Cooldown ($remainingSec s)',
            StatusColor.idle,
          ),
        );

  @override
  void stop() {
    final wasRunning = isRunning;
    super.stop();
    // Clear the "Cooldown (Xs)" status message when timer completes naturally
    // Use clearDynamicStatus to remove our message without forcing a new one
    if (wasRunning) {
      debugLog('[TIMER] Cooldown timer stopped, clearing countdown status');
      statusService.clearDynamicStatus();
    }
  }
}

/// Specialized countdown timer for auto-ping interval
/// Reference: wardrive.js state.nextAutoPingTime and autoCountdownTimer
class AutoPingTimer extends CountdownTimerService {
  String? _skipReason;

  AutoPingTimer(StatusMessageService statusService, {VoidCallback? onUpdate})
      : super(
          statusService,
          getStatusMessage: null, // Custom logic in override
          onUpdate: onUpdate,
        );

  /// Set skip reason (e.g., "too close", "gps too old")
  set skipReason(String? reason) {
    _skipReason = reason;
  }

  /// Override update to handle skip reason
  void _updateWithSkipReason() {
    if (_endTime == null) return;

    final remainingMs = this.remainingMs;

    // Stop when countdown reaches zero
    if (remainingMs == 0) {
      stop();
      return;
    }

    final remainingSec = (remainingMs / 1000).ceil();

    // Build status message
    CountdownResult result;
    if (remainingSec == 0) {
      result = CountdownResult('Sending auto ping', StatusColor.info);
    } else if (_skipReason == 'too close') {
      result = CountdownResult(
        'Ping skipped, too close to last ping, waiting for next ping (${remainingSec}s)',
        StatusColor.warning,
      );
    } else if (_skipReason == 'gps too old') {
      result = CountdownResult(
        'Ping skipped, GPS too old, waiting for fresh GPS (${remainingSec}s)',
        StatusColor.warning,
      );
    } else {
      result = CountdownResult('Next ping in ${remainingSec}s');
    }

    // First update respects minimum visibility, subsequent updates are immediate
    final immediate = !_isFirstUpdate;
    statusService.setDynamicStatus(result.message, result.color, immediate: immediate);

    // Mark first update as complete
    _isFirstUpdate = false;

    // Trigger UI refresh callback after each update
    onUpdate?.call();
  }

  @override
  void start(int durationMs) {
    stop();
    _endTime = DateTime.now().add(Duration(milliseconds: durationMs));
    _isFirstUpdate = true;

    // Start 1-second update timer with custom update logic
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateWithSkipReason());

    // Trigger immediate update
    _updateWithSkipReason();
  }

  /// Start countdown with optional skip reason
  /// Reference: startAutoCountdown() in wardrive.js with state.skipReason
  void startWithSkipReason(int durationMs, String? reason) {
    _skipReason = reason;
    start(durationMs);
  }
}

/// Specialized countdown timer for RX listening window
/// Reference: wardrive.js state.rxListeningEndTime
class RxWindowTimer extends CountdownTimerService {
  RxWindowTimer(StatusMessageService statusService, {VoidCallback? onUpdate})
      : super(
          statusService,
          getStatusMessage: (remainingSec) => CountdownResult(
            'Listening for responses (${remainingSec}s)',
            StatusColor.info,
          ),
          onUpdate: onUpdate,
        );
}

/// Specialized countdown timer for discovery listening window (Passive Mode)
class DiscoveryWindowTimer extends CountdownTimerService {
  DiscoveryWindowTimer(StatusMessageService statusService, {VoidCallback? onUpdate})
      : super(
          statusService,
          getStatusMessage: (remainingSec) => CountdownResult(
            'Listening for nodes (${remainingSec}s)',
            StatusColor.info,
          ),
          onUpdate: onUpdate,
        );
}
