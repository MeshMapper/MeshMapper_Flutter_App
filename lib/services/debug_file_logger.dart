import 'dart:async';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import '../utils/constants.dart';

/// Service for writing debug logs to files on the device.
///
/// Features:
/// - Writes debug logs to timestamped files in app documents directory
/// - Auto-rotates to maintain max 10 log files (deletes oldest)
/// - Provides file listing, viewing, and deletion capabilities
/// - On by default. The stored preference is read before the first file is
///   created: `main.dart` calls [beginCapture] first thing, which holds the
///   startup lines in memory, and only once the preference is known does it
///   call [enable] (the held lines land under the header) or [discardCapture].
///   Opening a file first and closing it when the preference read off left
///   one stub file per launch, and they all surfaced the moment the user
///   turned logging on.
class DebugFileLogger {
  static const int maxLogFiles = 10;

  /// Lines held while capturing (or while a rotation has no sink yet). The
  /// cap is a safety net: nothing normal leaves a capture open for long.
  static const int maxPendingLogs = 500;

  /// Maximum file size for upload (4.5MB, 0.5MB safety margin under 5MB server limit)
  static const int maxUploadSizeBytes = 4718592;
  static File? _currentLogFile;
  static IOSink? _logSink;
  static bool _enabled = false;
  static bool _capturing = false;
  static int _droppedPendingLogs = 0;
  static Future<void>? _enabling;
  static final List<String> _pendingLogs = [];
  static Timer? _flushTimer;

  /// Returns whether file logging is currently enabled
  static bool get isEnabled => _enabled;

  /// Whether a stored `debug_logs_enabled` preference asks for file logging.
  /// Only an explicit `false` turns it off; a missing or malformed value keeps
  /// the default (on). One definition, read by `main.dart` and the provider.
  static bool wantsFileLogging(Object? stored) => stored != false;

  /// Hold every line written from now on in memory, without a file, until
  /// [enable] flushes them into the first file or [discardCapture] drops them.
  /// A no-op while a file is already open.
  static void beginCapture() {
    if (_enabled) return;
    _capturing = true;
  }

  /// End a capture without a file: the preference read off.
  static void discardCapture() {
    _capturing = false;
    _pendingLogs.clear();
    _droppedPendingLogs = 0;
  }

  @visibleForTesting
  static int get pendingLogCount => _pendingLogs.length;

  @visibleForTesting
  static List<String> get pendingLogsForTest => List.unmodifiable(_pendingLogs);

  /// The app build and the device this log came from, resolved once per launch
  /// and written at the top of every log file. A report that blames the app is
  /// often an OEM battery manager or an OS version quirk instead, and the
  /// model plus OS version is the only way to tell that from the log alone.
  /// Deliberately identity-free: no serial, no fingerprint, no device name.
  static String? _environmentLine;

  static Future<String> _environmentHeader() async {
    final cached = _environmentLine;
    if (cached != null) return cached;

    final parts = <String>['App ${AppConstants.appVersion}'];
    const flutterVersion = String.fromEnvironment('FLUTTER_VERSION');
    const engineRevision = String.fromEnvironment('FLUTTER_ENGINE_REVISION');
    if (flutterVersion.isNotEmpty) parts.add('Flutter $flutterVersion');
    if (engineRevision.isNotEmpty) parts.add('Engine $engineRevision');
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        parts.add('Android ${a.version.release} (SDK ${a.version.sdkInt})');
        parts.add('${a.manufacturer} ${a.model}');
        parts
            .add('OS build ${a.id}, security patch ${a.version.securityPatch}');
      } else if (Platform.isIOS) {
        final i = await info.iosInfo;
        parts.add('iOS ${i.systemVersion}');
        parts.add('${i.modelName} (${i.utsname.machine})');
      } else {
        parts.add(Platform.operatingSystem);
        parts.add(Platform.operatingSystemVersion);
      }
    } catch (e) {
      // The header is diagnostics: a plugin that cannot answer must never stop
      // the log from being written.
      parts.add('${Platform.operatingSystem} (device info unavailable: $e)');
    }

    final line = '=== ${parts.join(' | ')} ===';
    _environmentLine = line;
    return line;
  }

  /// Enable debug file logging and create a new log file
  ///
  /// Creates a new file with format: meshmapper-debug-{unix_timestamp}.txt
  /// Auto-rotates old files if limit exceeded
  static Future<void> enable() {
    if (_enabled) return Future.value();
    // The flag only flips after two awaits, so a second caller landing in
    // that window would open a second file. Hand it the same future instead.
    return _enabling ??= _enable().whenComplete(() => _enabling = null);
  }

  static Future<void> _enable() async {
    try {
      // Resolved before the sink exists: an await between opening it and
      // writing the header would let a concurrent debugLog land above the
      // header.
      final environment = await _environmentHeader();

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
      sink.writeln('=== MeshMapper Debug Log Started: $now ===');
      sink.writeln('$environment\n');

      // Flush any logs that were captured before the sink was ready
      _flushPendingLogs();
      _capturing = false;

      // Start periodic flush timer (every 5 seconds) to ensure logs persist
      // This is important on iOS where background suspension can lose buffered data
      _flushTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _logSink?.flush();
      });

      // Clean up old files if needed
      await _rotateOldFiles(dir);
    } catch (e) {
      _enabled = false;
      _capturing = false;
      _pendingLogs.clear();
      _droppedPendingLogs = 0;
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
      _capturing = false;
      _pendingLogs.clear();
      _droppedPendingLogs = 0;
    }
  }

  /// Credential shapes stripped from every line written to a log FILE.
  static final RegExp _bearerPattern =
      RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]{8,}');
  static final RegExp _tokenFieldPattern =
      RegExp(r'"token"\s*:\s*"[0-9a-zA-Z._~+/=-]{8,}"');
  static final RegExp _codeParamPattern = RegExp(
      r'\b(code|code_verifier|code_challenge|token)=[A-Za-z0-9._~%+/=-]{20,}');

  /// The loose shapes the two patterns above miss: an UNQUOTED value, a `:`
  /// separator, or a header name. `Map.toString()` renders a decoded body as
  /// `{ok: true, token: fff…}` — no quotes, no `=` — and that is exactly what
  /// `debug_submit_service.dart` writes on a failed upload. Case-insensitive so
  /// the `X-MM-App-Token:` header is covered too. The 20-char floor keeps
  /// `token: abc` and `code=7` intact.
  static final RegExp _looseTokenPattern = RegExp(
      r'''(\btoken['"]?\s*[:=]\s*)['"]?[A-Za-z0-9._~%+/=-]{20,}''',
      caseSensitive: false);

  /// Repeater admin passwords. The app never logs one on purpose; this is
  /// the belt-and-braces rule for any `password=…`, `password: …` or
  /// `"password":"…"` shape that reaches a log FILE.
  static final RegExp _passwordPattern = RegExp(
      r'''(\bpassword['"]?\s*[:=]\s*)['"]?[^\s,}'"]+['"]?''',
      caseSensitive: false);

  /// Strip credential shapes out of a log line.
  ///
  /// Log files are uploaded verbatim with bug reports and debug logging stays
  /// on in release builds, so this is the last line of defence behind
  /// "never log a secret". Public so it can be unit-tested.
  static String scrubSecrets(String message) {
    var out = message.replaceAll(_bearerPattern, 'Bearer <redacted>');
    // Quoted JSON first, so the canonical `"token":"<redacted>"` shape is
    // preserved rather than being half-eaten by the loose pattern.
    out = out.replaceAll(_tokenFieldPattern, '"token":"<redacted>"');
    out = out.replaceAllMapped(
        _codeParamPattern, (match) => '${match.group(1)}=<redacted>');
    out = out.replaceAllMapped(
        _looseTokenPattern, (match) => '${match.group(1)}<redacted>');
    out = out.replaceAllMapped(_passwordPattern, (match) {
      final head = match.group(1)!;
      final whole = match.group(0)!;
      // Keep a JSON value quoted so the line still parses by eye.
      final quoted = whole.endsWith('"') && whole[head.length] == '"';
      return quoted ? '$head"<redacted>"' : '$head<redacted>';
    });
    return out;
  }

  /// Write a log entry to the current file
  ///
  /// Called by debug_logger_stub.dart for each log message
  /// Format: [ISO8601_timestamp] LEVEL: message
  ///
  /// While capturing, or while the sink isn't ready yet (a rotation in
  /// flight), lines are held in memory and written once a sink exists, up to
  /// [maxPendingLogs]; past the cap the newest lines are dropped and counted.
  static void write(String level, String message) {
    if (!_enabled && !_capturing) return;

    final timestamp = DateTime.now().toIso8601String();
    final line = '[$timestamp] $level: ${scrubSecrets(message)}';

    if (_logSink == null) {
      if (_pendingLogs.length >= maxPendingLogs) {
        _droppedPendingLogs++;
        return;
      }
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
    if (_droppedPendingLogs > 0) {
      try {
        sink.writeln('=== $_droppedPendingLogs lines dropped while the log '
            'had no file ===');
      } catch (e) {
        // Silently fail - avoid recursive logging errors
      }
      _droppedPendingLogs = 0;
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

  /// The line the old startup path wrote right before closing the file it had
  /// just opened: every file containing it is a stub by construction. The
  /// provider's wording changed with the fix, so no new file can match.
  static const String legacyStartupStubLine =
      '[INIT] Debug logs disabled by user preference, turning off';

  /// Only files this small are ever read by [deleteStartupStubs].
  static const int maxStartupStubBytes = 16 * 1024;

  /// Whether a log file's content is a stub left by the old startup path.
  static bool isStartupStubContent(String content) =>
      content.contains(legacyStartupStubLine);

  /// Delete the stub files the old startup path left behind, once per launch
  /// and best effort: at most [maxLogFiles] stats, and only a small file that
  /// is not the current one is read.
  static Future<int> deleteStartupStubs() async {
    var deleted = 0;
    try {
      final currentPath = _currentLogFile?.path;
      for (final file in await listLogFiles()) {
        if (file.path == currentPath) continue;
        try {
          if (await file.length() > maxStartupStubBytes) continue;
          if (!isStartupStubContent(await file.readAsString())) continue;
          await file.delete();
          deleted++;
        } catch (e) {
          // Best effort: a file that cannot be read or deleted stays.
        }
      }
    } catch (e) {
      // Best effort: the cleanup is never allowed to fail startup.
    }
    return deleted;
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
      // A submission usually carries rotated files too, and the one worth
      // reading is rarely the first, so every file repeats the header.
      final environment = await _environmentHeader();

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
      newSink.writeln(environment);
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
