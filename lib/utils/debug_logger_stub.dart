import 'package:flutter/foundation.dart';
import '../services/debug_file_logger.dart';

/// Debug logging utility stub for non-web platforms.
///
/// Logs are only output when DEBUG_ENABLED is true.
/// All log messages should use tagged format: `[TAG] message`
///
/// Common tags: [BLE], [GPS], [PING], [API], [RX], [UI], [CONN]
///
/// When file logging is enabled via DebugFileLogger, all logs are also
/// written to a timestamped file in the app documents directory.
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
    final args = [message, if (arg1 != null) arg1, if (arg2 != null) arg2, if (arg3 != null) arg3];
    final formattedMessage = args.join(' ');

    // Console logging only in debug mode
    if (_debugEnabled) {
      debugPrint(formattedMessage);
    }

    // File logging always (DebugFileLogger.write checks if enabled internally)
    DebugFileLogger.write('LOG', formattedMessage);
  }

  /// Log a warning message to the console.
  /// Use tagged format: debugWarn('[GPS] Position stale, re-acquiring');
  static void warn(String message, [Object? arg1, Object? arg2, Object? arg3]) {
    final args = ['⚠️', message, if (arg1 != null) arg1, if (arg2 != null) arg2, if (arg3 != null) arg3];
    final formattedMessage = args.join(' ');

    // Console logging only in debug mode
    if (_debugEnabled) {
      debugPrint('WARN: $formattedMessage');
    }

    // File logging always (DebugFileLogger.write checks if enabled internally)
    DebugFileLogger.write('WARN', formattedMessage);
  }

  /// Log an error message to the console.
  /// Use tagged format: debugError('[API] Failed to post queue', error);
  static void error(String message, [Object? arg1, Object? arg2, Object? arg3]) {
    final args = ['❌', message, if (arg1 != null) arg1, if (arg2 != null) arg2, if (arg3 != null) arg3];
    final formattedMessage = args.join(' ');

    // Console logging only in debug mode
    if (_debugEnabled) {
      debugPrint('ERROR: $formattedMessage');
    }

    // File logging always (DebugFileLogger.write checks if enabled internally)
    DebugFileLogger.write('ERROR', formattedMessage);
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
