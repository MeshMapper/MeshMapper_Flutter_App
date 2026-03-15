import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../utils/debug_logger_io.dart';

/// Represents an offline wardriving session stored locally
class OfflineSession {
  final String filename;
  final DateTime createdAt;
  final int pingCount;
  final Map<String, dynamic> data;
  final String? devicePublicKey;  // Device public key for auth during upload
  final String? deviceName;       // Device name for display
  final String? contactUri;       // Signed contact URI for registration during upload
  final bool uploaded;            // Track upload status

  OfflineSession({
    required this.filename,
    required this.createdAt,
    required this.pingCount,
    required this.data,
    this.devicePublicKey,
    this.deviceName,
    this.contactUri,
    this.uploaded = false,
  });

  /// Create from stored JSON
  factory OfflineSession.fromJson(Map<String, dynamic> json) {
    return OfflineSession(
      filename: json['filename'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      pingCount: json['pingCount'] as int,
      data: json['data'] as Map<String, dynamic>,
      devicePublicKey: json['devicePublicKey'] as String?,
      deviceName: json['deviceName'] as String?,
      contactUri: json['contactUri'] as String?,
      uploaded: json['uploaded'] as bool? ?? false,
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'filename': filename,
      'createdAt': createdAt.toIso8601String(),
      'pingCount': pingCount,
      'data': data,
      'devicePublicKey': devicePublicKey,
      'deviceName': deviceName,
      'contactUri': contactUri,
      'uploaded': uploaded,
    };
  }

  /// Create a copy with uploaded status changed
  OfflineSession copyWith({bool? uploaded}) {
    return OfflineSession(
      filename: filename,
      createdAt: createdAt,
      pingCount: pingCount,
      data: data,
      devicePublicKey: devicePublicKey,
      deviceName: deviceName,
      contactUri: contactUri,
      uploaded: uploaded ?? this.uploaded,
    );
  }

  /// Display-friendly date
  String get displayDate {
    return '${createdAt.year}-${createdAt.month.toString().padLeft(2, '0')}-${createdAt.day.toString().padLeft(2, '0')} '
        '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';
  }
}

/// Service for managing offline wardriving sessions
/// Stores sessions locally using SharedPreferences
class OfflineSessionService {
  static const String _sessionsKey = 'offline_sessions';

  SharedPreferences? _prefs;
  List<OfflineSession> _sessions = [];

  /// Tracks the filename of the session currently being accumulated via periodic auto-save.
  /// When set, `updateCurrentSession()` updates this session in-place instead of creating a new one.
  String? _currentSessionFilename;

  /// Callback when sessions list changes
  void Function(List<OfflineSession> sessions)? onSessionsUpdated;

  /// Get all stored sessions
  List<OfflineSession> get sessions => List.unmodifiable(_sessions);

  /// Get count of stored sessions
  int get sessionCount => _sessions.length;

  /// Initialize the service
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadSessions();
    debugLog('[OFFLINE] Initialized with ${_sessions.length} stored sessions');
  }

  /// Load sessions from storage
  Future<void> _loadSessions() async {
    final sessionsJson = _prefs?.getStringList(_sessionsKey) ?? [];
    _sessions = sessionsJson.map((json) {
      try {
        return OfflineSession.fromJson(jsonDecode(json) as Map<String, dynamic>);
      } catch (e) {
        debugError('[OFFLINE] Failed to parse session: $e');
        return null;
      }
    }).whereType<OfflineSession>().toList();

    // Sort by date, newest first
    _sessions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Save sessions to storage
  Future<void> _saveSessions() async {
    final sessionsJson = _sessions.map((s) => jsonEncode(s.toJson())).toList();
    await _prefs?.setStringList(_sessionsKey, sessionsJson);
    onSessionsUpdated?.call(_sessions);
  }

  /// Generate filename for new session
  String _generateFilename() {
    final now = DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    // Check if we already have sessions for today
    final todaySessions = _sessions.where((s) => s.filename.startsWith(dateStr)).length;

    if (todaySessions == 0) {
      return '$dateStr.json';
    } else {
      return '$dateStr-${todaySessions + 1}.json';
    }
  }

  /// Save a new offline session
  ///
  /// @param pings List of ping data to save
  /// @param devicePublicKey Optional device public key for auth during upload
  /// @param deviceName Optional device name for display
  Future<void> saveSession(
    List<Map<String, dynamic>> pings, {
    String? devicePublicKey,
    String? deviceName,
    String? contactUri,
  }) async {
    if (pings.isEmpty) {
      debugLog('[OFFLINE] No pings to save, skipping session creation');
      return;
    }

    final filename = _generateFilename();
    final now = DateTime.now();

    // Create session data with offline flag at root
    final sessionData = <String, dynamic>{
      'offline': true,
      'created_at': now.toIso8601String(),
      'ping_count': pings.length,
      'pings': pings,
      if (devicePublicKey != null) 'device_public_key': devicePublicKey,
      if (deviceName != null) 'device_name': deviceName,
    };

    final session = OfflineSession(
      filename: filename,
      createdAt: now,
      pingCount: pings.length,
      data: sessionData,
      devicePublicKey: devicePublicKey,
      deviceName: deviceName,
      contactUri: contactUri,
    );

    _sessions.insert(0, session); // Add at beginning (newest first)
    await _saveSessions();

    debugLog('[OFFLINE] Saved session: $filename with ${pings.length} pings (device: ${deviceName ?? "unknown"})');
  }

  /// Update the current in-progress session with the latest pings snapshot.
  /// If no current session exists, creates a new one and tracks it.
  /// This allows periodic saves to update the same file instead of creating duplicates.
  Future<void> updateCurrentSession(
    List<Map<String, dynamic>> pings, {
    String? devicePublicKey,
    String? deviceName,
    String? contactUri,
  }) async {
    if (pings.isEmpty) {
      debugLog('[OFFLINE] No pings to auto-save, skipping');
      return;
    }

    // If we have a tracked session, update it in-place
    if (_currentSessionFilename != null) {
      final index = _sessions.indexWhere((s) => s.filename == _currentSessionFilename);
      if (index != -1) {
        final existing = _sessions[index];
        final updatedData = Map<String, dynamic>.from(existing.data);
        updatedData['pings'] = pings;
        updatedData['ping_count'] = pings.length;

        _sessions[index] = OfflineSession(
          filename: existing.filename,
          createdAt: existing.createdAt,
          pingCount: pings.length,
          data: updatedData,
          devicePublicKey: devicePublicKey ?? existing.devicePublicKey,
          deviceName: deviceName ?? existing.deviceName,
          contactUri: contactUri ?? existing.contactUri,
        );
        await _saveSessions();
        debugLog('[OFFLINE] Updated session: ${existing.filename} with ${pings.length} pings');
        return;
      }
      // Session was deleted externally — fall through to create new
      debugWarn('[OFFLINE] Tracked session $_currentSessionFilename not found, creating new');
      _currentSessionFilename = null;
    }

    // No current session — create a new one and track it
    await saveSession(
      pings,
      devicePublicKey: devicePublicKey,
      deviceName: deviceName,
      contactUri: contactUri,
    );
    // saveSession inserts at index 0 (newest first)
    if (_sessions.isNotEmpty) {
      _currentSessionFilename = _sessions.first.filename;
      debugLog('[OFFLINE] Tracking new auto-save session: $_currentSessionFilename');
    }
  }

  /// Clear the current session tracker so the next save creates a fresh session file.
  /// Called after final saves (mode switch, disconnect) to create a clean break.
  void finalizeCurrentSession() {
    if (_currentSessionFilename != null) {
      debugLog('[OFFLINE] Finalized session: $_currentSessionFilename');
      _currentSessionFilename = null;
    }
  }

  /// Mark a session as uploaded without deleting it
  Future<void> markAsUploaded(String filename) async {
    final index = _sessions.indexWhere((s) => s.filename == filename);
    if (index == -1) {
      debugLog('[OFFLINE] Session not found for marking uploaded: $filename');
      return;
    }

    _sessions[index] = _sessions[index].copyWith(uploaded: true);
    await _saveSessions();
    debugLog('[OFFLINE] Marked session as uploaded: $filename');
  }

  /// Get a session by filename
  OfflineSession? getSession(String filename) {
    try {
      return _sessions.firstWhere((s) => s.filename == filename);
    } catch (e) {
      return null;
    }
  }

  /// Delete a session
  Future<void> deleteSession(String filename) async {
    _sessions.removeWhere((s) => s.filename == filename);
    await _saveSessions();
    debugLog('[OFFLINE] Deleted session: $filename');
  }

  /// Get session data for upload
  Map<String, dynamic>? getSessionData(String filename) {
    try {
      return _sessions.firstWhere((s) => s.filename == filename).data;
    } catch (e) {
      return null;
    }
  }

  /// Clear all sessions
  Future<void> clearAll() async {
    _sessions.clear();
    await _saveSessions();
    debugLog('[OFFLINE] Cleared all sessions');
  }

  void dispose() {
    // Nothing to dispose
  }
}
