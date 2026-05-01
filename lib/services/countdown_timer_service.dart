import 'dart:async';

import 'package:flutter/foundation.dart';

import '../utils/debug_logger_io.dart';

/// Countdown timer for cooldown, auto-ping, and RX window.
/// Reference: createCountdownTimer() in wardrive.js
///
/// Extends ChangeNotifier so that only widgets listening to this specific timer
/// rebuild on each tick. Previously, every tick called
/// AppStateProvider.notifyListeners(), which rebuilt the entire widget tree
/// (including the expensive MapWidget) 2× per second per active timer.
class CountdownTimerService extends ChangeNotifier {
  Timer? _timer;
  DateTime? _endTime;
  int? _durationMs;

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
    _cancelTimer();
    _durationMs = durationMs;
    _endTime = DateTime.now().add(Duration(milliseconds: durationMs));

    // Start 500ms update timer for responsive countdown
    _timer =
        Timer.periodic(const Duration(milliseconds: 500), (_) => _update());

    // Trigger immediate update
    notifyListeners();
  }

  /// Update countdown display
  void _update() {
    if (_endTime == null) return;

    final remainingMs = this.remainingMs;

    // Stop when countdown reaches zero
    if (remainingMs == 0) {
      _cancelTimer();
      _endTime = null;
      _durationMs = null;
      notifyListeners();
      return;
    }

    notifyListeners();
  }

  /// Stop countdown timer
  void stop() {
    if (_timer == null) return;
    _cancelTimer();
    _endTime = null;
    _durationMs = null;
    notifyListeners();
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// Dispose resources
  @override
  void dispose() {
    _cancelTimer();
    _endTime = null;
    _durationMs = null;
    super.dispose();
  }
}

/// Specialized countdown timer for ping cooldown
/// Reference: wardrive.js state.cooldownEndTime and cooldownUpdateTimer
class CooldownTimer extends CountdownTimerService {
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

  /// Start countdown with optional skip reason
  /// Reference: startAutoCountdown() in wardrive.js with state.skipReason
  void startWithSkipReason(int durationMs, String? reason) {
    skipReason = reason;
    start(durationMs);
  }
}

/// Specialized countdown timer for RX listening window
/// Reference: wardrive.js state.rxListeningEndTime
class RxWindowTimer extends CountdownTimerService {}

/// Specialized countdown timer for discovery listening window (Passive Mode)
class DiscoveryWindowTimer extends CountdownTimerService {}

/// Specialized countdown timer for manual ping cooldown (15 seconds)
class ManualPingCooldownTimer extends CountdownTimerService {
  @override
  void stop() {
    final wasRunning = isRunning;
    final remaining = remainingMs;
    super.stop();
    if (wasRunning) {
      debugLog(
          '[TIMER] Manual ping cooldown timer stopped (was ${remaining}ms remaining)');
    }
  }
}
