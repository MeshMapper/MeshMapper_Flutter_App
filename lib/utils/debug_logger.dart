// This file is for web platform only - uses dart:html
// For non-web, see debug_logger_stub.dart
// Export via debug_logger_io.dart for conditional import

// ignore: avoid_web_libraries_in_flutter
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Debug logging utility that mirrors MeshMapper_WebClient debug system.
///
/// Logs are only output when DEBUG_ENABLED is true (set via `?debug=1` URL param).
/// All log messages should use tagged format: `[TAG] message`
///
/// Common tags: [BLE], [GPS], [PING], [API], [RX], [UI], [CONN]
class DebugLogger {
  static bool _debugEnabled = false;
  static bool _initialized = false;

  /// Initialize the debug logger by checking URL parameters.
  /// Call this early in app startup (e.g., in main.dart).
  static void initialize() {
    if (_initialized) return;
    _initialized = true;

    if (kIsWeb) {
      try {
        // Parse URL parameters from browser
        final uri = Uri.base;
        final debugParam = uri.queryParameters['debug'];
        _debugEnabled = debugParam == '1' || debugParam == 'true';

        if (_debugEnabled) {
          _consoleLog('[DEBUG] Debug logging ENABLED via URL param');
        }
      } catch (e) {
        // Fallback - URL parsing failed
        _debugEnabled = false;
      }
    } else {
      // On mobile, check for debug mode compile flag
      _debugEnabled = kDebugMode;
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

    final args = [
      message,
      if (arg1 != null) arg1,
      if (arg2 != null) arg2,
      if (arg3 != null) arg3
    ];

    if (kIsWeb) {
      _consoleLog(args.join(' '));
    } else {
      debugPrint(args.join(' '));
    }
  }

  /// Log a warning message to the console.
  /// Use tagged format: debugWarn('[GPS] Position stale, re-acquiring');
  static void warn(String message, [Object? arg1, Object? arg2, Object? arg3]) {
    if (!_debugEnabled) return;

    final args = [
      '⚠️',
      message,
      if (arg1 != null) arg1,
      if (arg2 != null) arg2,
      if (arg3 != null) arg3
    ];

    if (kIsWeb) {
      _consoleWarn(args.join(' '));
    } else {
      debugPrint('WARN: ${args.join(' ')}');
    }
  }

  /// Log an error message to the console.
  /// Use tagged format: debugError('[API] Failed to post queue', error);
  static void error(String message,
      [Object? arg1, Object? arg2, Object? arg3]) {
    if (!_debugEnabled) return;

    final args = [
      '❌',
      message,
      if (arg1 != null) arg1,
      if (arg2 != null) arg2,
      if (arg3 != null) arg3
    ];

    if (kIsWeb) {
      _consoleError(args.join(' '));
    } else {
      debugPrint('ERROR: ${args.join(' ')}');
    }
  }

  // Web console methods using package:web for proper browser console output
  static void _consoleLog(String message) {
    try {
      web.console.log(message.toJS);
    } catch (e) {
      // Fallback
      // ignore: avoid_print
      print(message);
    }
  }

  static void _consoleWarn(String message) {
    try {
      web.console.warn(message.toJS);
    } catch (e) {
      // ignore: avoid_print
      print('WARN: $message');
    }
  }

  static void _consoleError(String message) {
    try {
      web.console.error(message.toJS);
    } catch (e) {
      // ignore: avoid_print
      print('ERROR: $message');
    }
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
