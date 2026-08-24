import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/repeater.dart';
import '../utils/debug_logger_io.dart';

/// Result of a batch upload attempt
enum UploadResult { success, retryable, sessionError, nonRetryable }

/// MeshMapper API service
/// Handles communication with the MeshMapper backend
///
/// API Endpoints (matching wardrive.js):
/// - POST /wardrive-api.php/status - Check zone status (geo-auth)
/// - POST /wardrive-api.php/auth - Acquire/release session (geo-auth)
/// - POST /wardrive-api.php/wardrive - Submit wardrive data + heartbeat
class ApiService {
  /// Base URL for MeshMapper API
  static const String baseUrl = 'https://meshmapper.net';

  /// Wardrive API endpoints
  static const String wardriveEndpoint = '$baseUrl/wardrive-api.php/wardrive';
  static const String geoAuthStatusUrl = '$baseUrl/wardrive-api.php/status';
  static const String geoAuthUrl = '$baseUrl/wardrive-api.php/auth';
  static const String borderUrl = '$baseUrl/wardrive-api.php/border';

  /// API key — injected at build time via --dart-define=API_KEY=...
  static const String apiKey = String.fromEnvironment('API_KEY');

  /// Heartbeat buffer - schedule heartbeat 1 minute before session expiry
  static const Duration heartbeatBuffer = Duration(minutes: 1);

  final http.Client _client;
  bool _heartbeatEnabled = false; // Track if heartbeat mode is active
  String? _sessionId;
  bool _txAllowed = false;
  bool _rxAllowed = false;
  int? _sessionExpiresAt;
  String? _wireKey; // TX wire-tag secret from /auth (null = un-keyed fallback)
  int _pingCounter =
      0; // per-session TX counter; resets on fresh /auth, not on heartbeat
  Timer? _heartbeatTimer;
  Timer? _heartbeatRetryTimer;

  int _heartbeatRetryCount = 0;
  static const int _maxHeartbeatRetries = 5;
  Function? _onSessionExpiring;
  List<String> _channels = [];
  List<String> _scopes = [];
  bool _enforceHybrid = false;
  bool _enforceDiscDrop = false;
  bool _floodDisabled = false;
  int _minModeInterval = 15;
  int _apiHopBytes = 1;

  /// Callback to get current GPS coordinates for heartbeat
  /// Returns (lat, lon) or null if GPS is not available
  ({double lat, double lon})? Function()? _gpsProvider;

  /// Regional channels from auth response (e.g., ['public', 'ottawa', 'testing'])
  List<String> get channels => List.unmodifiable(_channels);

  /// Regional scopes from auth response (e.g., ['ottawa'])
  List<String> get scopes => List.unmodifiable(_scopes);

  /// Whether hybrid mode is enforced by regional admin
  bool get enforceHybrid => _enforceHybrid;

  /// Whether discovery drop is enforced by regional admin
  bool get enforceDiscDrop => _enforceDiscDrop;

  /// Whether flood traffic (Active/Hybrid modes) is disabled by regional admin
  bool get floodDisabled => _floodDisabled;

  /// Minimum auto-ping interval enforced by regional admin (seconds)
  int get minModeInterval => _minModeInterval;

  /// Path hop bytes enforced by regional admin (1, 2, or 3)
  int get apiHopBytes => _apiHopBytes;

  /// Whether hop bytes are enforced by regional admin (only 2 or 3 enforces)
  bool get enforceHopBytes => _apiHopBytes > 1;

  ApiService({http.Client? client}) : _client = client ?? http.Client();

  /// Sanitize payload by removing sensitive fields for logging
  Map<String, dynamic> _sanitizePayload(Map<String, dynamic> payload) {
    final sanitized = Map<String, dynamic>.from(payload);
    sanitized.remove('key');
    sanitized.remove('session_id');
    sanitized.remove('public_key');
    sanitized.remove('contact_uri');
    return sanitized;
  }

  /// Check if response indicates maintenance mode, trigger callback if so
  bool _checkMaintenanceMode(Map<String, dynamic> response) {
    if (response['maintenance'] == true) {
      final message = response['maintenance_message'] as String? ??
          'Service is under maintenance';
      final url = response['maintenance_url'] as String?;
      debugLog('[MAINTENANCE] Maintenance mode detected: $message');
      onMaintenanceMode?.call(message, url);
      return true;
    }
    return false;
  }

  /// Log API request/response with timing
  void _logApiCall({
    required String endpoint,
    required String method,
    required Stopwatch stopwatch,
    required int statusCode,
    Map<String, dynamic>? request,
    dynamic response,
  }) {
    final durationSec =
        (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(2);

    String reqSummary;
    if (request != null) {
      reqSummary = json.encode(_sanitizePayload(request));
    } else {
      reqSummary = 'none';
    }

    String resSummary;
    if (response is Map<String, dynamic>) {
      resSummary = json.encode(_sanitizePayload(response));
    } else if (response is List) {
      resSummary = '[${response.length} items]';
    } else if (response != null) {
      resSummary = response.toString();
    } else {
      resSummary = 'none';
    }

    debugLog('[API] $method $endpoint');
    debugLog('[API]   Request: $reqSummary');
    debugLog('[API]   Response ($statusCode) in ${durationSec}s: $resSummary');
  }

  /// Check if we have a valid session
  bool get hasSession => _sessionId != null;

  /// Check if TX is allowed
  bool get txAllowed => _txAllowed;

  /// Check if RX is allowed
  bool get rxAllowed => _rxAllowed;

  /// Get session ID
  String? get sessionId => _sessionId;

  /// TX wire-tag secret delivered by /auth (null when the server didn't send one).
  String? get wireKey => _wireKey;

  /// Current per-session TX ping counter (peek without incrementing).
  int get pingCounter => _pingCounter;

  /// Increment and return the next per-session TX ping counter (1-based).
  /// Hard-capped at 2047 (the wire tag's 11-bit counter field) so the packed
  /// token can never overflow into the session#/region bits. Reaching the cap
  /// needs an ~8.5h continuous session at 15s; a fresh /auth resets it.
  int nextPingCounter() => _pingCounter >= 2047 ? 2047 : ++_pingCounter;

  /// Get session expiry timestamp
  int? get sessionExpiresAt => _sessionExpiresAt;

  /// Set callback for session expiring notification
  set onSessionExpiring(Function callback) {
    _onSessionExpiring = callback;
  }

  /// Check zone status via geo-auth API
  /// Matches checkZoneStatus() in wardrive.js
  Future<Map<String, dynamic>?> checkZoneStatus({
    required double lat,
    required double lon,
    required double accuracyMeters,
    required String appVersion,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final payload = {
        'lat': lat,
        'lng': lon, // API expects lng, not lon
        'accuracy_m': accuracyMeters,
        'ver': appVersion,
        'timestamp': timestamp,
        'key': apiKey,
      };

      final response = await _client
          .post(
            Uri.parse(geoAuthStatusUrl),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(payload),
          )
          .timeout(const Duration(seconds: 10));

      stopwatch.stop();

      if (response.statusCode != 200) {
        debugError(
            '[API] /wardrive-api.php/status returned HTTP ${response.statusCode}');
        debugError(
            '[API]   Response body: ${response.body.isEmpty ? '(empty)' : response.body}');
        debugError('[API]   Response headers: ${response.headers}');
      }

      Map<String, dynamic>? data;
      try {
        data = json.decode(response.body) as Map<String, dynamic>;
      } on FormatException {
        // CDN/proxy can return HTML error pages with HTTP 200
        debugError(
            '[API] Non-JSON response from /status (HTTP ${response.statusCode}): '
            '${response.body.length > 200 ? response.body.substring(0, 200) : response.body}');
      }

      _logApiCall(
        endpoint: '/wardrive-api.php/status',
        method: 'POST',
        stopwatch: stopwatch,
        statusCode: response.statusCode,
        request: payload,
        response: data,
      );

      return data;
    } catch (e) {
      stopwatch.stop();
      debugError('[API] POST /wardrive-api.php/status failed: $e');
      return null;
    }
  }

  /// Fetch regional boundary polygons from the MeshMapper API.
  ///
  /// Returns a list of `{code, polygon}` maps where `polygon` is a list of
  /// `[lat, lon]` pairs (as sent by the server). Returns `null` on failure
  /// or maintenance mode.
  Future<List<Map<String, dynamic>>?> fetchBorderPolygons({
    required double lat,
    required double lon,
    required String appVersion,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final payload = {
        'lat': lat,
        'lng': lon,
        'ver': appVersion,
        'timestamp': timestamp,
        'key': apiKey,
      };

      final response = await _client
          .post(
            Uri.parse(borderUrl),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(payload),
          )
          .timeout(const Duration(seconds: 10));

      stopwatch.stop();

      if (response.statusCode != 200) {
        debugError(
            '[BORDER] /wardrive-api.php/border returned HTTP ${response.statusCode}');
        debugError(
            '[BORDER]   Response body: ${response.body.isEmpty ? '(empty)' : response.body}');
      }

      Map<String, dynamic>? data;
      try {
        data = json.decode(response.body) as Map<String, dynamic>;
      } on FormatException {
        debugError(
            '[BORDER] Non-JSON response from /border (HTTP ${response.statusCode}): '
            '${response.body.length > 200 ? response.body.substring(0, 200) : response.body}');
      }

      _logApiCall(
        endpoint: '/wardrive-api.php/border',
        method: 'POST',
        stopwatch: stopwatch,
        statusCode: response.statusCode,
        request: payload,
        response: data,
      );

      if (data == null) return null;
      if (_checkMaintenanceMode(data)) return null;

      final polygons = data['polygons'];
      if (polygons is! List) return null;

      return polygons
          .whereType<Map>()
          .map((p) => Map<String, dynamic>.from(p))
          .toList();
    } catch (e) {
      stopwatch.stop();
      debugError('[BORDER] POST /wardrive-api.php/border failed: $e');
      return null;
    }
  }

  /// Request authentication with MeshMapper geo-auth API
  /// Matches requestAuth() in wardrive.js
  ///
  /// @param reason Either "connect" (acquire session), "register" (new device), or "disconnect" (release session)
  /// @param publicKey Device public key (for existing auth flow)
  /// @param contactUri Signed contact URI (for registration flow)
  /// @param offlineMode Set to true when uploading offline session data
  /// @param skipSessionStore When true, does not write to shared _sessionId/_txAllowed/etc. Caller manages session locally.
  /// @param sessionId Explicit session ID for disconnect. When provided, disconnect uses this instead of _sessionId and skips _clearSession().
  /// @returns Map with success, session_id, tx_allowed, rx_allowed, expires_at, reason, message
  Future<Map<String, dynamic>?> requestAuth({
    required String reason,
    String? publicKey, // Now optional - either publicKey or contactUri required
    String? contactUri, // NEW: for registration flow
    String? who,
    String? appVersion,
    double? power,
    String? iataCode,
    String? model,
    String? radioFreq,
    double? lat,
    double? lon,
    double? accuracyMeters,
    bool offlineMode = false,
    bool skipSessionStore = false,
    String? sessionId,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final payload = <String, dynamic>{
        'key': apiKey,
        'reason': reason,
      };

      // Prefer contact_uri (signed) over public_key (unsigned)
      if (contactUri != null) {
        payload['contact_uri'] = contactUri;
      } else if (publicKey != null) {
        payload['public_key'] = publicKey;
      } else if (reason != 'disconnect') {
        throw Exception('Either contactUri or publicKey must be provided');
      }

      // Add offline_mode flag for offline session uploads
      if (offlineMode) {
        payload['offline_mode'] = true;
      }

      // For connect/register: add device metadata and GPS coords
      if (reason == 'connect' || reason == 'register') {
        if (lat == null || lon == null) {
          throw Exception('GPS coordinates required for $reason');
        }

        if (who != null) payload['who'] = who;
        payload['ver'] = appVersion ?? 'UNKNOWN';
        if (power != null) {
          payload['power'] = '${power}w'; // Wattage (0.3w, 0.6w, 1.0w, 2.0w)
        }
        if (iataCode != null) payload['iata'] = iataCode;
        if (model != null) payload['model'] = model;
        if (radioFreq != null) payload['radio_freq'] = radioFreq;
        payload['coords'] = {
          'lat': lat,
          'lng': lon, // Convert lon → lng for API
          'accuracy_m': accuracyMeters ?? 999,
          'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        };
      } else {
        // For disconnect: use explicit sessionId if provided, otherwise shared _sessionId
        payload['session_id'] = sessionId ?? _sessionId;
      }

      final response = await _client
          .post(
            Uri.parse(geoAuthUrl),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(payload),
          )
          .timeout(const Duration(seconds: 10));

      stopwatch.stop();

      if (response.statusCode != 200) {
        debugError(
            '[API] /wardrive-api.php/auth returned HTTP ${response.statusCode}');
        debugError(
            '[API]   Response body: ${response.body.isEmpty ? '(empty)' : response.body}');
      }

      Map<String, dynamic> data;
      try {
        data = json.decode(response.body) as Map<String, dynamic>;
      } on FormatException {
        debugError(
            '[API] Non-JSON response from /auth (HTTP ${response.statusCode}): '
            '${response.body.length > 500 ? response.body.substring(0, 500) : response.body}');
        rethrow;
      }

      _logApiCall(
        endpoint: '/wardrive-api.php/auth',
        method: 'POST',
        stopwatch: stopwatch,
        statusCode: response.statusCode,
        request: payload,
        response: data,
      );

      // Store session info on successful connect or register
      // Note: 'register' now returns full auth response directly (no retry needed)
      if ((reason == 'connect' || reason == 'register') &&
          data['success'] == true) {
        if (!skipSessionStore) {
          // A wire tag only re-derives under the session that minted it. When
          // the server hands back a DIFFERENT session id (it reuses one only
          // while status=1 and unexpired), anything still sitting in the queue
          // was tagged under the old session and would be silently dropped on
          // upload, so tell the listener to drop those pings.
          final previousSessionId = _sessionId;
          _sessionId = data['session_id'] as String?;
          if (previousSessionId != null &&
              _sessionId != null &&
              previousSessionId != _sessionId) {
            debugLog(
                '[SESSION] New session id issued (was $previousSessionId, now $_sessionId). '
                'Queued wire tags are stale');
            onSessionIdChanged?.call();
          }
          _txAllowed = data['tx_allowed'] == true;
          _rxAllowed = data['rx_allowed'] == true;
          _sessionExpiresAt = data['expires_at'] as int?;

          // TX wire-tag key + per-session ping counter. The counter RESUMES from the server's
          // resume_counter when our session was reused (force-close + reconnect): resetting to 0
          // here would re-mint wire-tags identical to the pre-restart pings, which the subscriber
          // + coverage dedup then silently drop. Absent (new session / old server) -> 0, the
          // original behaviour. Log only receipt + length — NEVER the raw key (uploadable logs).
          _wireKey = data['wire_key'] as String?;
          final resumeCounter = (data['resume_counter'] as num?)?.toInt() ?? 0;
          _pingCounter = resumeCounter;
          if (resumeCounter > 0) {
            debugLog(
                '[AUTH] resumed ping counter at $resumeCounter (reused session)');
          }
          if (_wireKey != null) {
            debugLog('[AUTH] wire-tag key received (len=${_wireKey!.length})');
          } else {
            debugLog('[AUTH] no wire-tag key in auth response (un-keyed tag)');
          }

          // Parse channels array from auth response
          final channelsData = data['channels'];
          if (channelsData is List) {
            _channels = channelsData.cast<String>().toList();
            debugLog('[API] Regional channels: $_channels');
          } else {
            _channels = [];
          }

          // Parse scopes array from auth response
          final scopesData = data['scopes'];
          if (scopesData is List && scopesData.isNotEmpty) {
            _scopes = scopesData.cast<String>().toList();
            debugLog('[API] Regional scopes: $_scopes');
          } else {
            _scopes = [];
          }

          // Parse enforce_hybrid flag from auth response
          _enforceHybrid = data['enforce_hybrid'] == true;
          if (_enforceHybrid) {
            debugLog('[API] Regional admin enforces hybrid mode');
          }

          // Parse disc_drop flag from auth response
          _enforceDiscDrop = data['disc_drop'] == true;
          if (_enforceDiscDrop) {
            debugLog('[API] Regional admin enforces discovery drop');
          }

          // Parse flood_disabled flag from auth response
          _floodDisabled = data['flood_disabled'] == true;
          if (_floodDisabled) {
            debugLog('[API] Regional admin has disabled flood traffic');
          }

          // Parse min_mode_interval from auth response
          final minInterval = data['min_mode_interval'];
          if (minInterval is int && minInterval > 0) {
            _minModeInterval = minInterval;
            debugLog('[API] Regional admin min interval: ${_minModeInterval}s');
          } else {
            _minModeInterval = 15;
          }

          // Parse hop_bytes from auth response
          final hopBytes = data['hop_bytes'];
          if (hopBytes is int && hopBytes >= 1 && hopBytes <= 3) {
            _apiHopBytes = hopBytes;
            if (_apiHopBytes > 1) {
              debugLog(
                  '[API] Regional admin enforces $_apiHopBytes-byte paths');
            }
          } else {
            _apiHopBytes = 1;
          }

          // Note: Heartbeat is enabled by AppStateProvider when auto mode starts
          // (not on initial auth, since heartbeat is only for auto mode)
        }
      } else if (reason == 'disconnect') {
        // Only clear shared session when no explicit sessionId was provided
        // (explicit sessionId means caller manages its own session lifecycle)
        if (sessionId == null) {
          _clearSession();
        }
      }

      return data;
    } catch (e) {
      stopwatch.stop();
      debugError('[API] POST /wardrive-api.php/auth failed: $e');
      return null;
    }
  }

  /// Submit wardrive data batch to API
  /// Matches submitWardriveData() in wardrive.js
  ///
  /// @param entries List of wardrive entries (TX/RX)
  /// @returns Map with success, expires_at, reason, message
  Future<Map<String, dynamic>?> submitWardriveData(
      List<Map<String, dynamic>> entries) async {
    if (_sessionId == null) {
      throw Exception('Cannot submit: no session_id');
    }

    final stopwatch = Stopwatch()..start();
    try {
      final payload = {
        'key': apiKey,
        'session_id': _sessionId,
        'data': entries,
      };

      final response = await _client
          .post(
            Uri.parse(wardriveEndpoint),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(payload),
          )
          .timeout(const Duration(seconds: 30));

      stopwatch.stop();

      if (response.statusCode != 200) {
        debugError(
            '[API] /wardrive-api.php/wardrive returned HTTP ${response.statusCode}');
        debugError(
            '[API]   Response body: ${response.body.isEmpty ? '(empty)' : response.body}');
      }

      Map<String, dynamic> data;
      try {
        data = json.decode(response.body) as Map<String, dynamic>;
      } on FormatException {
        debugError(
            '[API] Non-JSON response from /wardrive (HTTP ${response.statusCode}): '
            '${response.body.length > 500 ? response.body.substring(0, 500) : response.body}');
        rethrow;
      }

      // Log with data summary including external_antenna values
      final antennaSummary = entries
          .map((e) => '${e['type']}:external_antenna=${e['external_antenna']}')
          .join(', ');
      _logApiCall(
        endpoint: '/wardrive-api.php/wardrive',
        method: 'POST',
        stopwatch: stopwatch,
        statusCode: response.statusCode,
        request: {'data': '${entries.length} items', 'items': antennaSummary},
        response: data,
      );

      // Update expires_at and schedule heartbeat if provided
      if (data['success'] == true && data['expires_at'] != null) {
        _sessionExpiresAt = data['expires_at'] as int;
        scheduleHeartbeat(_sessionExpiresAt!);
      }

      return data;
    } catch (e) {
      stopwatch.stop();
      debugError('[API] POST /wardrive-api.php/wardrive failed: $e');
      return null;
    }
  }

  /// Send heartbeat to keep session alive
  /// Matches sendHeartbeat() in wardrive.js
  Future<Map<String, dynamic>?> sendHeartbeat({
    double? lat,
    double? lon,
  }) async {
    if (_sessionId == null) {
      debugLog('[HEARTBEAT] Cannot send heartbeat: no session_id');
      return null;
    }

    final stopwatch = Stopwatch()..start();
    try {
      final payload = <String, dynamic>{
        'key': apiKey,
        'session_id': _sessionId,
        'heartbeat': true,
      };

      if (lat != null && lon != null) {
        payload['coords'] = {
          'lat': lat,
          'lon': lon,
          'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        };
      }

      final response = await _client
          .post(
            Uri.parse(wardriveEndpoint),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(payload),
          )
          .timeout(const Duration(seconds: 30));

      stopwatch.stop();

      if (response.statusCode != 200) {
        debugError(
            '[API] /wardrive-api.php/wardrive (heartbeat) returned HTTP ${response.statusCode}');
        debugError(
            '[API]   Response body: ${response.body.isEmpty ? '(empty)' : response.body}');
      }

      Map<String, dynamic> data;
      try {
        data = json.decode(response.body) as Map<String, dynamic>;
      } on FormatException {
        debugError(
            '[API] Non-JSON response from /wardrive heartbeat (HTTP ${response.statusCode}): '
            '${response.body.length > 500 ? response.body.substring(0, 500) : response.body}');
        rethrow;
      }

      // Log heartbeat with coords info but not sensitive data
      final hasCoords = lat != null && lon != null;
      _logApiCall(
        endpoint: '/wardrive-api.php/wardrive',
        method: 'POST',
        stopwatch: stopwatch,
        statusCode: response.statusCode,
        request: {'heartbeat': true, 'has_coords': hasCoords},
        response: data,
      );

      // Check for maintenance mode
      if (_checkMaintenanceMode(data)) {
        return data;
      }

      // Update expires_at and schedule next heartbeat if provided
      if (data['success'] == true && data['expires_at'] != null) {
        _sessionExpiresAt = data['expires_at'] as int;
        scheduleHeartbeat(_sessionExpiresAt!);
      }

      return data;
    } catch (e) {
      stopwatch.stop();
      debugError(
          '[API] POST /wardrive-api.php/wardrive (heartbeat) failed: $e');
      return null;
    }
  }

  /// Check if session is still valid by sending a heartbeat
  /// Use this before starting any wardrive action (Send Ping, Active Mode, Passive Mode)
  /// Returns (isValid, errorReason, errorMessage)
  Future<({bool isValid, String? reason, String? message})> checkSessionValid({
    double? lat,
    double? lon,
  }) async {
    if (_sessionId == null) {
      debugWarn('[SESSION] No session to validate');
      return (
        isValid: false,
        reason: 'no_session',
        message: 'No active session'
      );
    }

    debugLog('[SESSION] Checking session validity via heartbeat...');
    final result = await sendHeartbeat(lat: lat, lon: lon);

    if (result == null) {
      debugWarn('[SESSION] Session check failed: no response');
      return (
        isValid: false,
        reason: 'no_response',
        message: 'Server did not respond'
      );
    }

    if (result['success'] == true) {
      debugLog(
          '[SESSION] Session is valid (expires_at: ${result['expires_at']})');
      return (isValid: true, reason: null, message: null);
    }

    // Session is invalid - check reason
    final reason = result['reason'] as String?;
    final message = result['message'] as String?;
    debugWarn('[SESSION] Session invalid: $reason - $message');

    // Trigger session error callback for critical errors
    const criticalErrors = {
      'session_expired',
      'session_invalid',
      'session_revoked',
      'bad_session',
      'invalid_key',
      'unauthorized',
      'bad_key',
      'zone_full',
      'zone_disabled',
    };
    if (criticalErrors.contains(reason)) {
      _clearSession();
      await onSessionError?.call(reason, message);
    }

    // outside_zone: notify listener but preserve session (backend auto-transfers on zone re-entry)
    if (reason == 'outside_zone') {
      await onSessionError?.call(reason, message);
    }

    return (isValid: false, reason: reason, message: message);
  }

  /// Enable heartbeat mode (called when auto mode starts)
  /// Heartbeat is scheduled based on expires_at from API responses
  /// @param gpsProvider Callback to get current GPS coordinates for heartbeat
  void enableHeartbeat({({double lat, double lon})? Function()? gpsProvider}) {
    _heartbeatEnabled = true;
    _gpsProvider = gpsProvider;
    // Schedule initial heartbeat if we have an expiry time
    if (_sessionExpiresAt != null) {
      scheduleHeartbeat(_sessionExpiresAt!);
    }
    debugLog('[HEARTBEAT] Heartbeat mode enabled');
  }

  /// Disable heartbeat mode (called when auto mode stops)
  void disableHeartbeat() {
    _heartbeatEnabled = false;
    _gpsProvider = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatRetryTimer?.cancel();
    _heartbeatRetryTimer = null;
    _heartbeatRetryCount = 0;
    debugLog('[HEARTBEAT] Heartbeat mode disabled');
  }

  /// Schedule heartbeat to fire before session expires
  /// Matches scheduleHeartbeat() in wardrive.js
  /// @param expiresAt Unix timestamp when session expires
  void scheduleHeartbeat(int expiresAt) {
    // Cancel any existing heartbeat timer and reset retry state
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatRetryTimer?.cancel();
    _heartbeatRetryTimer = null;
    _heartbeatRetryCount = 0;

    if (!_heartbeatEnabled) return;

    // Calculate when to send heartbeat (1 minute before expiry)
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final secondsUntilExpiry = expiresAt - now;
    final secondsUntilHeartbeat =
        secondsUntilExpiry - heartbeatBuffer.inSeconds;

    if (secondsUntilHeartbeat <= 0) {
      // Session is about to expire or already expired - send heartbeat immediately
      debugWarn(
          '[HEARTBEAT] Session expires in ${secondsUntilExpiry}s, sending immediately');
      _sendScheduledHeartbeat();
    } else {
      debugLog(
          '[HEARTBEAT] Scheduling in ${secondsUntilHeartbeat}s (session expires in ${secondsUntilExpiry}s)');

      _heartbeatTimer = Timer(Duration(seconds: secondsUntilHeartbeat), () {
        debugLog('[HEARTBEAT] Timer fired, sending keepalive');
        _sendScheduledHeartbeat();
      });
    }
  }

  /// Send scheduled heartbeat with GPS coordinates
  Future<void> _sendScheduledHeartbeat() async {
    // Get GPS coordinates from provider (matching wardrive.js behavior)
    final coords = _gpsProvider?.call();
    final result = await sendHeartbeat(lat: coords?.lat, lon: coords?.lon);

    if (result?['success'] == true) {
      debugLog('[HEARTBEAT] Heartbeat successful');
      // Reset retry state on success
      _heartbeatRetryCount = 0;
      _heartbeatRetryTimer?.cancel();
      _heartbeatRetryTimer = null;
      // Next heartbeat will be scheduled when we get new expires_at
    } else if (result == null) {
      // Network error — schedule retry with exponential backoff
      if (_heartbeatRetryCount < _maxHeartbeatRetries) {
        final delay = min(30 * pow(2, _heartbeatRetryCount).toInt(), 120);
        _heartbeatRetryCount++;
        debugWarn(
            '[HEARTBEAT] Network error, scheduling retry $_heartbeatRetryCount/$_maxHeartbeatRetries in ${delay}s');
        _heartbeatRetryTimer?.cancel();
        _heartbeatRetryTimer =
            Timer(Duration(seconds: delay), _sendScheduledHeartbeat);
      } else {
        debugError(
            '[HEARTBEAT] Network error, all $_maxHeartbeatRetries retries exhausted');
      }
      _onSessionExpiring?.call();
    } else {
      // Server returned an error — check if critical
      final reason = result['reason'] as String?;
      final message = result['message'] as String?;
      debugWarn('[HEARTBEAT] Heartbeat failed: $reason - $message');

      const criticalErrors = {
        'session_expired',
        'session_invalid',
        'session_revoked',
        'bad_session',
        'invalid_key',
        'unauthorized',
        'bad_key',
        'zone_full',
        'zone_disabled',
      };

      if (criticalErrors.contains(reason)) {
        _clearSession();
        await onSessionError?.call(reason, message);
      } else if (reason == 'outside_zone') {
        // Preserve session — backend auto-transfers on zone re-entry
        await onSessionError?.call(reason, message);
      } else {
        _onSessionExpiring?.call();
      }
    }
  }

  /// Clear session data and cancel all timers
  void _clearSession() {
    _sessionId = null;
    _wireKey = null;
    _pingCounter = 0;
    _txAllowed = false;
    _rxAllowed = false;
    _sessionExpiresAt = null;
    _channels = [];
    _scopes = [];
    _enforceHybrid = false;
    _enforceDiscDrop = false;
    _floodDisabled = false;
    _minModeInterval = 15;
    _apiHopBytes = 1;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatRetryTimer?.cancel();
    _heartbeatRetryTimer = null;
    _heartbeatRetryCount = 0;
    debugLog('[API] Session cleared');
  }

  /// Legacy: Check if we have a slot (compatibility with old code)
  bool get hasSlot => hasSession;

  /// Callback for session errors (session_expired, bad_session, outside_zone)
  /// Set by AppStateProvider to handle auto-disconnect
  ///
  /// [subReason] carries the server's `sub_reason` where it narrows the reason
  /// enough to change what the app does. Only the upload path passes it today:
  /// a stationary revoke can only be raised by an upload, never a heartbeat.
  Future<void> Function(String? reason, String? message, {String? subReason})?
      onSessionError;

  /// Callback for maintenance mode detection (while connected)
  void Function(String message, String? url)? onMaintenanceMode;

  /// Fired when /auth returns a session id different from the one we held.
  /// Wired to ApiQueueService.dropStaleTaggedItems(). See that method for why.
  void Function()? onSessionIdChanged;

  /// Force-rebuild one vector coverage tile on the region server
  /// (`vector_tile.php?...&fresh=1`, see VECTOR_TILES.md). Used by the
  /// post-wardrive live refresh: it keeps the server cache hot AND hands the
  /// fresh tile bytes back so the caller can patch the user's own cells onto
  /// the map without touching the rest of the overlay.
  ///
  /// `changed`: true/false from the X-Tile-Changed header; null on network
  /// failure, non-2xx, or a server that doesn't implement fresh=1 yet.
  /// `body`: the uncompressed MVT bytes on a 200, null otherwise (204 = tile
  /// is empty; package:http has already gunzipped the response).
  Future<({bool? changed, Uint8List? body})> freshenVectorTile({
    required String zone,
    required int z,
    required int x,
    required int y,
    int gsize = 300,
  }) async {
    final url =
        Uri.parse('https://${zone.toLowerCase()}.meshmapper.net/vector_tile.php'
            '?z=$z&x=$x&y=$y&gsize=$gsize&fresh=1');
    final sw = Stopwatch()..start();
    debugLog(
        '[API] GET /vector_tile.php?z=$z&x=$x&y=$y&gsize=$gsize&fresh=1 (zone ${zone.toLowerCase()})');
    try {
      final response =
          await _client.get(url).timeout(const Duration(seconds: 8));
      final changed = response.headers['x-tile-changed'];
      debugLog(
          '[API]   Tile $z/$x/$y response (${response.statusCode}) in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s: '
          '${response.bodyBytes.length}B, X-Tile-Changed=${changed ?? 'absent'}');
      if (response.statusCode != 200 && response.statusCode != 204) {
        return (changed: null, body: null);
      }
      final body = response.statusCode == 200 ? response.bodyBytes : null;
      return (
        changed: changed == null ? null : changed == '1',
        body: body,
      );
    } catch (e) {
      debugWarn(
          '[API]   Tile $z/$x/$y fresh fetch failed in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s: $e');
      return (changed: null, body: null);
    }
  }

  /// Upload batch of wardrive data
  /// Returns UploadResult indicating success, retryable failure, or non-retryable failure
  /// Triggers onSessionError callback for session-related errors
  Future<UploadResult> uploadBatch(List<Map<String, dynamic>> pings) async {
    if (pings.isEmpty) return UploadResult.success;

    try {
      final result = await submitWardriveData(pings);

      if (result == null) {
        debugError('[API] Upload batch failed: no response');
        return UploadResult.retryable;
      }

      // Check for maintenance mode first
      if (_checkMaintenanceMode(result)) {
        return UploadResult.retryable;
      }

      if (result['success'] == true) {
        debugLog('[API] Upload batch SUCCESS: ${pings.length} items');
        return UploadResult.success;
      }

      // Check for session errors that require disconnect
      final reason = result['reason'] as String?;

      // All errors that require session invalidation and disconnect
      const criticalErrors = {
        // Session errors
        'session_expired', 'session_invalid', 'session_revoked', 'bad_session',
        // Auth errors
        'invalid_key', 'unauthorized', 'bad_key',
        // Zone errors
        'zone_full', 'zone_disabled',
      };

      if (criticalErrors.contains(reason)) {
        final subReason = result['sub_reason'] as String?;
        debugError('[API] Upload batch session error: $reason'
            '${subReason != null ? ' ($subReason)' : ''}');
        final message = result['message'] as String?;
        // Clear session locally since it's invalid on server
        _clearSession();
        // Notify listener for auto-disconnect. MUST be awaited: the handler
        // snapshots the queue to offline storage, and returning nonRetryable
        // makes the caller DISCARD that same batch. Fired bare, the snapshot's
        // first real suspension (a non-empty RX buffer flushing to Hive) let
        // the discard land first, so the preserved pings came back short.
        await onSessionError?.call(reason, message, subReason: subReason);
        return UploadResult.nonRetryable;
      }

      // outside_zone: preserve session (backend auto-transfers on zone re-entry),
      // but discard this batch (gap-GPS coords would be rejected again)
      if (reason == 'outside_zone') {
        debugWarn(
            '[API] Upload batch outside_zone — discarding batch, preserving session');
        final message = result['message'] as String?;
        await onSessionError?.call(reason, message);
        return UploadResult.nonRetryable;
      }

      // Errors where the batch data itself is invalid — retrying won't help
      const nonRetryableErrors = {
        'gps_inaccurate',
        'gps_stale',
        'invalid_request',
        'zone_disabled',
        'outofdate',
      };
      if (nonRetryableErrors.contains(reason)) {
        debugWarn(
            '[API] Upload batch non-retryable error: $reason - discarding batch');
        return UploadResult.nonRetryable;
      }

      return UploadResult.retryable;
    } catch (e) {
      debugError('[API] Upload batch exception: $e');
      return UploadResult.retryable;
    }
  }

  /// Fetch repeaters for a zone from the MeshMapper API
  /// Returns a list of enabled repeaters for the given IATA zone code
  Future<List<Repeater>> fetchRepeaters(String iata) async {
    final stopwatch = Stopwatch()..start();
    const endpoint = '/get_repeaters.php';
    try {
      final url = 'https://${iata.toLowerCase()}.meshmapper.net$endpoint';

      final response = await _client
          .get(
            Uri.parse(url),
          )
          .timeout(const Duration(seconds: 15));

      stopwatch.stop();

      if (response.statusCode != 200) {
        _logApiCall(
          endpoint: endpoint,
          method: 'GET',
          stopwatch: stopwatch,
          statusCode: response.statusCode,
          response: 'error',
        );
        return [];
      }

      final List<dynamic> jsonList =
          json.decode(response.body) as List<dynamic>;
      final repeaters = <Repeater>[];

      for (final item in jsonList) {
        try {
          final repeater = Repeater.fromJson(item as Map<String, dynamic>);
          // Only include enabled repeaters
          if (repeater.isEnabled) {
            repeaters.add(repeater);
          }
        } catch (e) {
          debugError('[API] Failed to parse repeater: $e');
        }
      }

      _logApiCall(
        endpoint: endpoint,
        method: 'GET',
        stopwatch: stopwatch,
        statusCode: response.statusCode,
        response: '${repeaters.length} repeaters',
      );

      return repeaters;
    } catch (e) {
      stopwatch.stop();
      debugError('[API] GET $endpoint failed: $e');
      return [];
    }
  }

  /// Fetch raw coverage points for a clicked map cell, for the tap-to-inspect
  /// GRID SUMMARY. Posts to the region's app-facing endpoint
  /// (`app_coverage.php` → `api.php` `map_data`); the app aggregates the points
  /// client-side (see `coverage_summary.dart`). Returns `[]` on any failure.
  ///
  /// NOTE: unlike [fetchRepeaterCoverage] this still collapses a failed request
  /// into `[]`. The cell summary has no "couldn't load" state yet
  /// (MeshMapper_Server#109 covers the repeater sheet only) and its tap flow
  /// chains straight into `filterWithinBlob`. Give the cell sheet that state
  /// before propagating the null here.
  Future<List<Map<String, dynamic>>> fetchMapData({
    required String zone,
    required double lat,
    required double lon,
    required double radiusMeters,
  }) async {
    final points = await _fetchCoveragePoints(
      zone: zone,
      label: 'map_data',
      body: {
        'request': 'map_data',
        'lat': lat,
        'lon': lon,
        'radius': radiusMeters,
      },
    );
    return points ?? const <Map<String, dynamic>>[];
  }

  /// Fetch the coverage points referencing a repeater (a hex-prefix superset),
  /// for the repeater detail sheet's BIDIR/TX/RX/DISC/DEAD totals + max range.
  /// Posts to `app_coverage.php` → `api.php` `repeater_coverage`.
  ///
  /// Returns `null` when the request could not be answered, and `[]` when the
  /// zone genuinely has nothing for this prefix. The sheet renders those
  /// differently (MeshMapper_Server#109).
  Future<List<Map<String, dynamic>>?> fetchRepeaterCoverage({
    required String zone,
    required String prefix,
  }) {
    return _fetchCoveragePoints(
      zone: zone,
      label: 'repeater_coverage',
      body: {
        'request': 'repeater_coverage',
        'prefix': prefix,
      },
    );
  }

  /// Shared POST to `https://<zone>.meshmapper.net/app_coverage.php` with the app
  /// key in the JSON body.
  ///
  /// Returns the point maps on success, which may legitimately be an EMPTY list
  /// meaning the server has no coverage for this query, or `null` when the
  /// request could not be answered at all. Callers MUST keep those apart:
  /// collapsing them into `[]` was MeshMapper_Server#109, where a failed fetch
  /// rendered as a repeater that had heard nothing.
  Future<List<Map<String, dynamic>>?> _fetchCoveragePoints({
    required String zone,
    required String label,
    required Map<String, dynamic> body,
  }) async {
    final z = zone.toLowerCase();
    final url = Uri.parse('https://$z.meshmapper.net/app_coverage.php');
    final sw = Stopwatch()..start();
    debugLog('[COVERAGE] POST /app_coverage.php ($label, zone $z)');
    try {
      final response = await _client
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'key': apiKey, ...body}),
          )
          .timeout(const Duration(seconds: 15));
      final secs = (sw.elapsedMilliseconds / 1000).toStringAsFixed(2);

      if (response.statusCode != 200) {
        final snippet = response.body.isEmpty
            ? '(empty)'
            : (response.body.length > 200
                ? response.body.substring(0, 200)
                : response.body);
        debugWarn(
            '[COVERAGE]   $label HTTP ${response.statusCode} in ${secs}s: $snippet');
        return null;
      }

      final decoded = json.decode(response.body);
      if (decoded is! List) {
        debugWarn('[COVERAGE]   $label: unexpected response (not a JSON list)');
        return null;
      }
      final points = decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      debugLog('[COVERAGE]   $label OK in ${secs}s: ${points.length} points');
      return points;
    } catch (e) {
      debugWarn(
          '[COVERAGE]   $label POST failed in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s: $e');
      return null;
    }
  }

  /// Submit wardrive data using an explicit session ID (for offline uploads)
  /// Does NOT read/write shared _sessionId, _sessionExpiresAt, or heartbeat state
  Future<Map<String, dynamic>?> submitWardriveDataWithSessionId(
    List<Map<String, dynamic>> entries,
    String sessionId,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      final payload = {
        'key': apiKey,
        'session_id': sessionId,
        'data': entries,
      };

      final response = await _client
          .post(
            Uri.parse(wardriveEndpoint),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(payload),
          )
          .timeout(const Duration(seconds: 30));

      stopwatch.stop();

      if (response.statusCode != 200) {
        debugError(
            '[API] /wardrive-api.php/wardrive (offline) returned HTTP ${response.statusCode}');
        debugError(
            '[API]   Response body: ${response.body.isEmpty ? '(empty)' : response.body}');
      }

      Map<String, dynamic> data;
      try {
        data = json.decode(response.body) as Map<String, dynamic>;
      } on FormatException {
        debugError(
            '[API] Non-JSON response from /wardrive offline (HTTP ${response.statusCode}): '
            '${response.body.length > 500 ? response.body.substring(0, 500) : response.body}');
        rethrow;
      }

      final antennaSummary = entries
          .map((e) => '${e['type']}:external_antenna=${e['external_antenna']}')
          .join(', ');
      _logApiCall(
        endpoint: '/wardrive-api.php/wardrive (offline)',
        method: 'POST',
        stopwatch: stopwatch,
        statusCode: response.statusCode,
        request: {'data': '${entries.length} items', 'items': antennaSummary},
        response: data,
      );

      // Do NOT update shared _sessionExpiresAt or schedule heartbeat
      return data;
    } catch (e) {
      stopwatch.stop();
      debugError('[API] POST /wardrive-api.php/wardrive (offline) failed: $e');
      return null;
    }
  }

  /// Upload batch using explicit session ID (for offline uploads)
  /// Returns UploadResult only — does NOT call _clearSession(), onSessionError, or onMaintenanceMode
  Future<UploadResult> uploadBatchWithSessionId(
    List<Map<String, dynamic>> pings,
    String sessionId, {
    void Function(Map<String, dynamic> response)? onResponse,
  }) async {
    if (pings.isEmpty) return UploadResult.success;

    try {
      final result = await submitWardriveDataWithSessionId(pings, sessionId);

      if (result == null) {
        debugError('[API] Offline upload batch failed: no response');
        return UploadResult.retryable;
      }

      if (result['success'] == true) {
        // Surface the server's per-batch placement_counts / too_far_region
        // (offline routing) so the caller can accumulate an upload summary.
        onResponse?.call(result);
        debugLog('[API] Offline upload batch SUCCESS: ${pings.length} items');
        return UploadResult.success;
      }

      final reason = result['reason'] as String?;

      // Session timing errors: session not yet propagated or expired.
      // The pings are fine — retrying with a delay may succeed.
      const sessionTimingErrors = {
        'bad_session',
        'session_expired',
        'session_invalid',
        'session_revoked',
      };
      if (sessionTimingErrors.contains(reason)) {
        debugError('[API] Offline upload batch session timing error: $reason');
        return UploadResult.sessionError;
      }

      // Permanent auth/zone errors: session will never work, abort upload.
      const permanentSessionErrors = {
        'invalid_key',
        'unauthorized',
        'bad_key',
        'outside_zone',
        'zone_full',
        'zone_disabled',
      };
      if (permanentSessionErrors.contains(reason)) {
        debugError('[API] Offline upload batch permanent error: $reason');
        return UploadResult.nonRetryable;
      }

      const nonRetryableErrors = {
        'gps_inaccurate',
        'gps_stale',
        'invalid_request',
        'zone_disabled',
        'outofdate',
      };
      if (nonRetryableErrors.contains(reason)) {
        debugWarn(
            '[API] Offline upload batch non-retryable error: $reason - stopping upload, pings preserved');
        return UploadResult.nonRetryable;
      }

      return UploadResult.retryable;
    } catch (e) {
      debugError('[API] Offline upload batch exception: $e');
      return UploadResult.retryable;
    }
  }

  /// Dispose of resources
  void dispose() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatRetryTimer?.cancel();
    _heartbeatRetryTimer = null;
    _client.close();
  }
}
