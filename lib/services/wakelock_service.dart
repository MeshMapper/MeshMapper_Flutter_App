import 'package:wakelock_plus/wakelock_plus.dart';

import '../utils/debug_logger_io.dart';

/// Wake lock service to keep screen on during auto-ping mode
/// Reference: acquireWakeLock() and releaseWakeLock() in wardrive.js
class WakelockService {
  bool _isEnabled = false;

  /// Check if wake lock is currently enabled
  bool get isEnabled => _isEnabled;

  /// Enable wake lock (keep screen on)
  /// Called when auto-ping mode starts
  Future<void> enable() async {
    if (_isEnabled) return;

    try {
      await WakelockPlus.enable();
      _isEnabled = true;
      debugLog('[WAKELOCK] Screen wake lock enabled');
    } catch (e) {
      debugError('[WAKELOCK] Failed to enable wake lock: $e');
    }
  }

  /// Disable wake lock (allow screen to sleep)
  /// Called when auto-ping mode stops or on disconnect
  Future<void> disable() async {
    if (!_isEnabled) return;

    try {
      await WakelockPlus.disable();
      _isEnabled = false;
      debugLog('[WAKELOCK] Screen wake lock disabled');
    } catch (e) {
      debugError('[WAKELOCK] Failed to disable wake lock: $e');
    }
  }

  /// Dispose resources
  Future<void> dispose() async {
    await disable();
  }
}
