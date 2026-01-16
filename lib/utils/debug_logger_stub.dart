import 'package:flutter/foundation.dart';

/// Debug logging utility stub for non-web platforms.
/// 
/// Logs are only output when DEBUG_ENABLED is true.
/// All log messages should use tagged format: `[TAG] message`
/// 
/// Common tags: [BLE], [GPS], [PING], [API], [RX], [UI], [CONN]
class DebugLogger {
  static bool _debugEnabled = false;
  static bool _initialized = false;

  /// Initialize the debug logger.
  /// On mobile, debug is enabled when running in debug mode.
  static void initialize() {
    if (_initialized) return;
    _initialized = true;

    // On mobile, enable debug logging in debug mode
    _debugEnabled = kDebugMode;
    
    if (_debugEnabled) {
      debugPrint('[DEBUG] Debug logging ENABLED (debug mode)');
    }
  }

  /// Check if debug logging is enabled
  static bool get isEnabled => _debugEnabled;

  /// Manually enable/disable debug logging (for testing)
  static void setEnabled(bool enabled) {
    _debugEnabled = enabled;
  }

  /// Log a general info message to the console.
  /// Use tagged format: debugLog('[BLE] Connected to device');
  static void log(String message, [Object? arg1, Object? arg2, Object? arg3]) {
    if (!_debugEnabled) return;
    
    final args = [message, if (arg1 != null) arg1, if (arg2 != null) arg2, if (arg3 != null) arg3];
    debugPrint(args.join(' '));
  }

  /// Log a warning message to the console.
  /// Use tagged format: debugWarn('[GPS] Position stale, re-acquiring');
  static void warn(String message, [Object? arg1, Object? arg2, Object? arg3]) {
    if (!_debugEnabled) return;
    
    final args = ['⚠️', message, if (arg1 != null) arg1, if (arg2 != null) arg2, if (arg3 != null) arg3];
    debugPrint('WARN: ${args.join(' ')}');
  }

  /// Log an error message to the console.
  /// Use tagged format: debugError('[API] Failed to post queue', error);
  static void error(String message, [Object? arg1, Object? arg2, Object? arg3]) {
    if (!_debugEnabled) return;
    
    final args = ['❌', message, if (arg1 != null) arg1, if (arg2 != null) arg2, if (arg3 != null) arg3];
    debugPrint('ERROR: ${args.join(' ')}');
  }
}

/// Convenience global functions matching MeshMapper_WebClient API
void debugLog(String message, [Object? arg1, Object? arg2, Object? arg3]) {
  DebugLogger.log(message, arg1, arg2, arg3);
}

void debugWarn(String message, [Object? arg1, Object? arg2, Object? arg3]) {
  DebugLogger.warn(message, arg1, arg2, arg3);
}

void debugError(String message, [Object? arg1, Object? arg2, Object? arg3]) {
  DebugLogger.error(message, arg1, arg2, arg3);
}
