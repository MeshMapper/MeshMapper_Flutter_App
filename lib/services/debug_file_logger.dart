import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Service for writing debug logs to files on the device.
///
/// Features:
/// - Writes debug logs to timestamped files in app documents directory
/// - Auto-rotates to maintain max 10 log files (deletes oldest)
/// - Provides file listing, viewing, and deletion capabilities
/// - Non-persistent (always starts disabled on app launch)
class DebugFileLogger {
  static const int maxLogFiles = 10;
  static File? _currentLogFile;
  static IOSink? _logSink;
  static bool _enabled = false;
  static final List<String> _pendingLogs = [];
  static Timer? _flushTimer;

  /// Returns whether file logging is currently enabled
  static bool get isEnabled => _enabled;

  /// Enable debug file logging and create a new log file
  ///
  /// Creates a new file with format: meshmapper-debug-{unix_timestamp}.txt
  /// Auto-rotates old files if limit exceeded
  static Future<void> enable() async {
    if (_enabled) return;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final filename = 'meshmapper-debug-$timestamp.txt';
      _currentLogFile = File('${dir.path}/$filename');
      _logSink = _currentLogFile!.openWrite(mode: FileMode.append);
      _enabled = true;

      // Write header to file
      final now = DateTime.now().toIso8601String();
      _logSink!.writeln('=== MeshMapper Debug Log Started: $now ===\n');

      // Flush any logs that were captured before the sink was ready
      _flushPendingLogs();

      // Start periodic flush timer (every 5 seconds) to ensure logs persist
      // This is important on iOS where background suspension can lose buffered data
      _flushTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _logSink?.flush();
      });

      // Clean up old files if needed
      await _rotateOldFiles(dir);
    } catch (e) {
      _enabled = false;
      _logSink = null;
      _currentLogFile = null;
      rethrow;
    }
  }

  /// Disable debug file logging and close current file
  ///
  /// Flushes and closes the file handle but does NOT delete the file
  static Future<void> disable() async {
    if (!_enabled) return;

    try {
      // Cancel flush timer
      _flushTimer?.cancel();
      _flushTimer = null;

      if (_logSink != null) {
        final now = DateTime.now().toIso8601String();
        _logSink!.writeln('\n=== MeshMapper Debug Log Stopped: $now ===');
        await _logSink!.flush();
        await _logSink!.close();
      }
    } finally {
      _logSink = null;
      _currentLogFile = null;
      _enabled = false;
    }
  }

  /// Write a log entry to the current file
  ///
  /// Called by debug_logger_stub.dart for each log message
  /// Format: [ISO8601_timestamp] LEVEL: message
  ///
  /// If the log sink isn't ready yet (race condition during init), logs are
  /// buffered and flushed when the sink becomes available.
  static void write(String level, String message) {
    if (!_enabled) return;

    final timestamp = DateTime.now().toIso8601String();
    final line = '[$timestamp] $level: $message';

    if (_logSink == null) {
      // Buffer logs until sink is ready (race condition during initialization)
      _pendingLogs.add(line);
      return;
    }

    // Flush any pending logs first
    _flushPendingLogs();

    try {
      _logSink!.writeln(line);
    } catch (e) {
      // Silently fail to avoid recursive logging errors
      // If file writing fails, we don't want to crash the app
    }
  }

  /// Flush pending logs that were captured before the sink was ready
  static void _flushPendingLogs() {
    if (_pendingLogs.isEmpty || _logSink == null) return;
    for (final line in _pendingLogs) {
      try {
        _logSink!.writeln(line);
      } catch (e) {
        // Silently fail
      }
    }
    _pendingLogs.clear();
  }

  /// List all debug log files in the app documents directory
  ///
  /// Returns files sorted newest first (by filename timestamp)
  static Future<List<File>> listLogFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('meshmapper-debug-'))
          .toList();

      // Sort by filename (contains timestamp) - newest first
      files.sort((a, b) => b.path.compareTo(a.path));
      return files;
    } catch (e) {
      return [];
    }
  }

  /// Delete oldest log files to maintain the maximum file limit
  ///
  /// Keeps the newest [maxLogFiles] files and deletes the rest
  static Future<void> _rotateOldFiles(Directory dir) async {
    try {
      final files = await listLogFiles();
      if (files.length > maxLogFiles) {
        for (var i = maxLogFiles; i < files.length; i++) {
          await files[i].delete();
        }
      }
    } catch (e) {
      // Silently fail - rotation is not critical
    }
  }

  /// Delete all debug log files
  ///
  /// Removes all files matching the meshmapper-debug-* pattern
  /// Closes current log file if one is active
  static Future<void> deleteAll() async {
    try {
      // Close current log if active
      if (_enabled) {
        await disable();
      }

      final files = await listLogFiles();
      for (var file in files) {
        await file.delete();
      }
    } catch (e) {
      rethrow;
    }
  }

  /// Delete a specific log file
  ///
  /// If the file is currently being written to, closes it first
  static Future<void> deleteFile(File file) async {
    try {
      // If this is the current log file, disable logging first
      if (_currentLogFile?.path == file.path) {
        await disable();
      }
      await file.delete();
    } catch (e) {
      rethrow;
    }
  }

  /// Get the current log file path (if logging is enabled)
  static String? get currentLogPath => _currentLogFile?.path;

  /// Rotate the current log file - closes it and starts a new one
  ///
  /// This is useful before uploading logs to ensure the files being
  /// uploaded are complete and not being actively written to.
  static Future<void> rotateLogFile() async {
    if (!_enabled) return;

    try {
      // Close current log file
      _flushTimer?.cancel();
      _flushTimer = null;

      if (_logSink != null) {
        final now = DateTime.now().toIso8601String();
        _logSink!.writeln('\n=== Log rotated for upload: $now ===');
        await _logSink!.flush();
        await _logSink!.close();
      }

      _logSink = null;
      _currentLogFile = null;

      // Start a new log file
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final filename = 'meshmapper-debug-$timestamp.txt';
      _currentLogFile = File('${dir.path}/$filename');
      _logSink = _currentLogFile!.openWrite(mode: FileMode.append);

      // Write header to new file
      final nowStr = DateTime.now().toIso8601String();
      _logSink!.writeln('=== MeshMapper Debug Log Started: $nowStr ===');
      _logSink!.writeln('=== (Previous log rotated for upload) ===\n');

      // Restart flush timer
      _flushTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _logSink?.flush();
      });

      // Clean up old files if needed
      await _rotateOldFiles(dir);
    } catch (e) {
      // If rotation fails, try to continue with existing state
      rethrow;
    }
  }

  /// List log files that are safe to upload (excludes currently active file)
  ///
  /// Returns files sorted newest first, excluding the file currently being written to
  static Future<List<File>> listUploadableLogFiles() async {
    final allFiles = await listLogFiles();
    final currentPath = _currentLogFile?.path;

    if (currentPath == null) {
      return allFiles;
    }

    // Filter out the current log file
    return allFiles.where((f) => f.path != currentPath).toList();
  }
}
