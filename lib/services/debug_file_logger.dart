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

  /// Maximum file size for upload (4.5MB, 0.5MB safety margin under 5MB server limit)
  static const int maxUploadSizeBytes = 4718592;
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
      final logFile = File('${dir.path}/$filename');
      _currentLogFile = logFile;
      final sink = logFile.openWrite(mode: FileMode.append);
      _logSink = sink;
      _enabled = true;

      // Write header to file
      final now = DateTime.now().toIso8601String();
      sink.writeln('=== MeshMapper Debug Log Started: $now ===\n');

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

      final sink = _logSink;
      if (sink != null) {
        final now = DateTime.now().toIso8601String();
        sink.writeln('\n=== MeshMapper Debug Log Stopped: $now ===');
        await sink.flush();
        await sink.close();
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
      _logSink?.writeln(line);
    } catch (e) {
      // Silently fail to avoid recursive logging errors
      // If file writing fails, we don't want to crash the app
    }
  }

  /// Flush pending logs that were captured before the sink was ready
  static void _flushPendingLogs() {
    final sink = _logSink;
    if (_pendingLogs.isEmpty || sink == null) return;
    for (final line in _pendingLogs) {
      try {
        sink.writeln(line);
      } catch (e) {
        // Silently fail - avoid recursive logging errors
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

      final oldSink = _logSink;
      if (oldSink != null) {
        final now = DateTime.now().toIso8601String();
        oldSink.writeln('\n=== Log rotated for upload: $now ===');
        await oldSink.flush();
        await oldSink.close();
      }

      _logSink = null;
      _currentLogFile = null;

      // Start a new log file
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final filename = 'meshmapper-debug-$timestamp.txt';
      final newLogFile = File('${dir.path}/$filename');
      _currentLogFile = newLogFile;
      final newSink = newLogFile.openWrite(mode: FileMode.append);
      _logSink = newSink;

      // Write header to new file
      final nowStr = DateTime.now().toIso8601String();
      newSink.writeln('=== MeshMapper Debug Log Started: $nowStr ===');
      newSink.writeln('=== (Previous log rotated for upload) ===\n');

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

  /// Split a file into chunks that fit within the upload size limit.
  ///
  /// Returns `[file]` if the file is already small enough.
  /// Otherwise, splits at newline boundaries into chunks <= [maxUploadSizeBytes],
  /// writing temp files named `{basename}-part1of3.txt`, etc.
  static Future<List<File>> splitFileIntoChunks(File file) async {
    final fileSize = await file.length();
    if (fileSize <= maxUploadSizeBytes) {
      return [file];
    }

    final content = await file.readAsString();
    final lines = content.split('\n');
    final basename = file.path.split('/').last.replaceAll('.txt', '');
    final tempDir = await getTemporaryDirectory();

    // First pass: determine how many chunks we need
    final List<List<String>> chunkLines = [];
    List<String> currentChunk = [];
    int currentSize = 0;

    for (final line in lines) {
      final lineBytes = line.length + 1; // +1 for newline
      if (currentSize + lineBytes > maxUploadSizeBytes &&
          currentChunk.isNotEmpty) {
        chunkLines.add(currentChunk);
        currentChunk = [];
        currentSize = 0;
      }
      currentChunk.add(line);
      currentSize += lineBytes;
    }
    if (currentChunk.isNotEmpty) {
      chunkLines.add(currentChunk);
    }

    final totalParts = chunkLines.length;
    final List<File> chunkFiles = [];

    for (int i = 0; i < totalParts; i++) {
      final partNum = i + 1;
      final chunkFilename = '$basename-part${partNum}of$totalParts.txt';
      final chunkFile = File('${tempDir.path}/$chunkFilename');
      await chunkFile.writeAsString(chunkLines[i].join('\n'));
      chunkFiles.add(chunkFile);
    }

    return chunkFiles;
  }

  /// Delete temp chunk files created by [splitFileIntoChunks].
  ///
  /// Only deletes files with `-part` in the filename (temp chunks).
  /// Silently ignores errors on individual files.
  static Future<void> cleanupChunkFiles(List<File> files) async {
    for (final file in files) {
      if (file.path.contains('-part')) {
        try {
          if (await file.exists()) {
            await file.delete();
          }
        } catch (e) {
          // Non-critical: temp file cleanup failure
          // Cannot use debugError here (circular dependency with file logger)
        }
      }
    }
  }

  /// Calculate the number of upload parts needed for a file of given size.
  static int estimatePartCount(int fileSizeBytes) {
    if (fileSizeBytes <= maxUploadSizeBytes) return 1;
    return (fileSizeBytes / maxUploadSizeBytes).ceil();
  }
}
