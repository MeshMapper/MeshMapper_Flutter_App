// Debug logger with conditional imports for web vs mobile platforms.
//
// Usage:
// ```dart
// import 'package:meshmapper/utils/debug_logger_io.dart';
//
// DebugLogger.initialize();
// debugLog('[TAG] message');
// debugWarn('[TAG] warning');
// debugError('[TAG] error');
// ```

export 'debug_logger_stub.dart' if (dart.library.html) 'debug_logger.dart';
