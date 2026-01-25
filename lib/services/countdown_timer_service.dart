import 'dart:async';

import 'package:flutter/foundation.dart' show VoidCallback;

import '../utils/debug_logger_io.dart';

/// Countdown timer for cooldown, auto-ping, and RX window
/// Reference: createCountdownTimer() in wardrive.js
///
/// Features:
/// - 500ms update interval for responsive countdown display
/// - Auto-stops when countdown reaches zero
class CountdownTimerService {
  Timer? _timer;
  DateTime? _endTime;
  int? _durationMs;  // Original duration for progress calculation
  final VoidCallback? onUpdate;  // Callback for UI refresh on each timer tick

  CountdownTimerService({this.onUpdate});

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

  /// Get progress as 0.0 to 1.0 (1.0 = full, 0.0 = complete)
  double get progress {
    if (_durationMs == null || _durationMs == 0) return 0.0;
    return remainingMs / _durationMs!;
  }

  /// Start countdown timer
  /// @param durationMs - Duration in milliseconds
  void start(int durationMs) {
    stop();
    _durationMs = durationMs;  // Track original duration for progress
    _endTime = DateTime.now().add(Duration(milliseconds: durationMs));

    // Start 500ms update timer for responsive countdown
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _update());

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

    // Trigger UI refresh callback after each update
    onUpdate?.call();
  }

  /// Stop countdown timer
  void stop() {
    _timer?.cancel();
    _timer = null;
    _endTime = null;
    _durationMs = null;
  }

  /// Dispose resources
  void dispose() {
    stop();
  }
}

/// Specialized countdown timer for ping cooldown
/// Reference: wardrive.js state.cooldownEndTime and cooldownUpdateTimer
class CooldownTimer extends CountdownTimerService {
  CooldownTimer({super.onUpdate});

  @override
  void stop() {
    final wasRunning = isRunning;
    super.stop();
    if (wasRunning) {
      debugLog('[TIMER] Cooldown timer stopped');
    }
  }
}

/// Specialized countdown timer for auto-ping interval
/// Reference: wardrive.js state.nextAutoPingTime and autoCountdownTimer
class AutoPingTimer extends CountdownTimerService {
  /// Skip reason (e.g., "too close", "gps too old")
  String? skipReason;

  AutoPingTimer({super.onUpdate});

  /// Start countdown with optional skip reason
  /// Reference: startAutoCountdown() in wardrive.js with state.skipReason
  void startWithSkipReason(int durationMs, String? reason) {
    skipReason = reason;
    start(durationMs);
  }
}

/// Specialized countdown timer for RX listening window
/// Reference: wardrive.js state.rxListeningEndTime
class RxWindowTimer extends CountdownTimerService {
  RxWindowTimer({super.onUpdate});
}

/// Specialized countdown timer for discovery listening window (Passive Mode)
class DiscoveryWindowTimer extends CountdownTimerService {
  DiscoveryWindowTimer({super.onUpdate});
}
