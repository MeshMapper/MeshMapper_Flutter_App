import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/repeater.dart';
import '../utils/debug_logger_io.dart';

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

  /// API key (matching wardrive.js)
  static const String apiKey = '59C7754DABDF5C11CA5F5D8368F89';

  /// Heartbeat buffer - schedule heartbeat 1 minute before session expiry
  static const Duration heartbeatBuffer = Duration(minutes: 1);

  final http.Client _client;
  bool _heartbeatEnabled = false;  // Track if heartbeat mode is active
  String? _sessionId;
  bool _txAllowed = false;
  bool _rxAllowed = false;
  int? _sessionExpiresAt;
  Timer? _heartbeatTimer;
  Function? _onSessionExpiring;
  List<String> _channels = [];

  /// Callback to get current GPS coordinates for heartbeat
  /// Returns (lat, lon) or null if GPS is not available
  ({double lat, double lon})? Function()? _gpsProvider;

  /// Regional channels from auth response (e.g., ['public', 'ottawa', 'testing'])
  List<String> get channels => List.unmodifiable(_channels);

  ApiService({http.Client? client}) : _client = client ?? http.Client();

  /// Sanitize payload by removing sensitive fields for logging
  Map<String, dynamic> _sanitizePayload(Map<String, dynamic> payload) {
    final sanitized = Map<String, dynamic>.from(payload);
    sanitized.remove('key');
    sanitized.remove('session_id');
    sanitized.remove('public_key');
    return sanitized;
  }

  /// Check if response indicates maintenance mode, trigger callback if so
  bool _checkMaintenanceMode(Map<String, dynamic> response) {
    if (response['maintenance'] == true) {
      final message = response['maintenance_message'] as String? ?? 'Service is under maintenance';
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
    final durationSec = (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(2);

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
      };

      final response = await _client.post(
        Uri.parse(geoAuthStatusUrl),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(payload),
      ).timeout(const Duration(seconds: 10));

      stopwatch.stop();
      final data = response.statusCode == 200
          ? json.decode(response.body) as Map<String, dynamic>
          : null;

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

  /// Request authentication with MeshMapper geo-auth API
  /// Matches requestAuth() in wardrive.js
  ///
  /// @param reason Either "connect" (acquire session) or "disconnect" (release session)
  /// @param offlineMode Set to true when uploading offline session data
  /// @returns Map with success, session_id, tx_allowed, rx_allowed, expires_at, reason, message
  Future<Map<String, dynamic>?> requestAuth({
    required String reason,
    required String publicKey,
    String? who,
    String? appVersion,
    double? power,
    String? iataCode,
    String? model,
    double? lat,
    double? lon,
    double? accuracyMeters,
    bool offlineMode = false,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final payload = <String, dynamic>{
        'key': apiKey,
        'public_key': publicKey,
        'reason': reason,
      };

      // Add offline_mode flag for offline session uploads
      if (offlineMode) {
        payload['offline_mode'] = true;
      }

      // For connect: add device metadata and GPS coords
      if (reason == 'connect') {
        if (lat == null || lon == null) {
          throw Exception('GPS coordinates required for connect');
        }

        payload['who'] = who ?? 'GOME-WarDriver';
        payload['ver'] = appVersion ?? 'UNKNOWN';
        payload['power'] = '${power ?? 0.3}w';  // Wattage (0.3w, 0.6w, 1.0w, 2.0w)
        if (iataCode != null) payload['iata'] = iataCode;
        payload['model'] = model ?? 'Unknown';
        payload['coords'] = {
          'lat': lat,
          'lng': lon, // Convert lon → lng for API
          'accuracy_m': accuracyMeters ?? 999,
          'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        };
      } else {
        // For disconnect: add session_id
        payload['session_id'] = _sessionId;
      }

      final response = await _client.post(
        Uri.parse(geoAuthUrl),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(payload),
      ).timeout(const Duration(seconds: 10));

      stopwatch.stop();
      final data = json.decode(response.body) as Map<String, dynamic>;

      _logApiCall(
        endpoint: '/wardrive-api.php/auth',
        method: 'POST',
        stopwatch: stopwatch,
        statusCode: response.statusCode,
        request: payload,
        response: data,
      );

      // Store session info on successful connect
      if (reason == 'connect' && data['success'] == true) {
        _sessionId = data['session_id'] as String?;
        _txAllowed = data['tx_allowed'] == true;
        _rxAllowed = data['rx_allowed'] == true;
        _sessionExpiresAt = data['expires_at'] as int?;

        // Parse channels array from auth response
        final channelsData = data['channels'];
        if (channelsData is List) {
          _channels = channelsData.cast<String>().toList();
          debugLog('[API] Regional channels: $_channels');
        } else {
          _channels = [];
        }

        // Note: Heartbeat is enabled by AppStateProvider when auto mode starts
        // (not on initial auth, since heartbeat is only for auto mode)
      } else if (reason == 'disconnect') {
        // Clear session on disconnect
        _clearSession();
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
  Future<Map<String, dynamic>?> submitWardriveData(List<Map<String, dynamic>> entries) async {
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

      final response = await _client.post(
        Uri.parse(wardriveEndpoint),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(payload),
      ).timeout(const Duration(seconds: 30));

      stopwatch.stop();
      final data = json.decode(response.body) as Map<String, dynamic>;

      // Log with data summary including external_antenna values
      final antennaSummary = entries.map((e) =>
        '${e['type']}:external_antenna=${e['external_antenna']}'
      ).join(', ');
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

      final response = await _client.post(
        Uri.parse(wardriveEndpoint),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(payload),
      ).timeout(const Duration(seconds: 30));

      stopwatch.stop();
      final data = json.decode(response.body) as Map<String, dynamic>;

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
      debugError('[API] POST /wardrive-api.php/wardrive (heartbeat) failed: $e');
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
      return (isValid: false, reason: 'no_session', message: 'No active session');
    }

    debugLog('[SESSION] Checking session validity via heartbeat...');
    final result = await sendHeartbeat(lat: lat, lon: lon);

    if (result == null) {
      debugWarn('[SESSION] Session check failed: no response');
      return (isValid: false, reason: 'no_response', message: 'Server did not respond');
    }

    if (result['success'] == true) {
      debugLog('[SESSION] Session is valid (expires_at: ${result['expires_at']})');
      return (isValid: true, reason: null, message: null);
    }

    // Session is invalid - check reason
    final reason = result['reason'] as String?;
    final message = result['message'] as String?;
    debugWarn('[SESSION] Session invalid: $reason - $message');

    // Trigger session error callback for critical errors
    const criticalErrors = {
      'session_expired', 'session_invalid', 'session_revoked', 'bad_session',
      'invalid_key', 'unauthorized', 'bad_key',
      'outside_zone', 'zone_full',
    };
    if (criticalErrors.contains(reason)) {
      _clearSession();
      onSessionError?.call(reason, message);
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
    debugLog('[HEARTBEAT] Heartbeat mode disabled');
  }

  /// Schedule heartbeat to fire before session expires
  /// Matches scheduleHeartbeat() in wardrive.js
  /// @param expiresAt Unix timestamp when session expires
  void scheduleHeartbeat(int expiresAt) {
    // Cancel any existing heartbeat timer
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    if (!_heartbeatEnabled) return;

    // Calculate when to send heartbeat (1 minute before expiry)
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final secondsUntilExpiry = expiresAt - now;
    final secondsUntilHeartbeat = secondsUntilExpiry - heartbeatBuffer.inSeconds;

    if (secondsUntilHeartbeat <= 0) {
      // Session is about to expire or already expired - send heartbeat immediately
      debugWarn('[HEARTBEAT] Session expires in ${secondsUntilExpiry}s, sending immediately');
      _sendScheduledHeartbeat();
      return;
    }

    debugLog('[HEARTBEAT] Scheduling in ${secondsUntilHeartbeat}s (session expires in ${secondsUntilExpiry}s)');

    _heartbeatTimer = Timer(Duration(seconds: secondsUntilHeartbeat), () {
      debugLog('[HEARTBEAT] Timer fired, sending keepalive');
      _sendScheduledHeartbeat();
    });
  }

  /// Send scheduled heartbeat with GPS coordinates
  Future<void> _sendScheduledHeartbeat() async {
    // Get GPS coordinates from provider (matching wardrive.js behavior)
    final coords = _gpsProvider?.call();
    final result = await sendHeartbeat(lat: coords?.lat, lon: coords?.lon);

    if (result?['success'] == true) {
      debugLog('[HEARTBEAT] Heartbeat successful');
      // Next heartbeat will be scheduled when we get new expires_at
    } else {
      debugWarn('[HEARTBEAT] Heartbeat failed: ${result?['message']}');
      _onSessionExpiring?.call();
    }
  }

  /// Clear session data and cancel heartbeat timer
  void _clearSession() {
    _sessionId = null;
    _txAllowed = false;
    _rxAllowed = false;
    _sessionExpiresAt = null;
    _channels = [];
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    debugLog('[API] Session cleared');
  }

  // ---- Legacy compatibility methods (TODO: remove after migration) ----

  /// Legacy: Set device ID (no-op, kept for compatibility)
  void setDeviceId(String deviceId) {
    // No-op: device ID is now the public key in geo-auth system
  }

  /// Legacy: Acquire API slot (no-op, kept for compatibility)
  /// Real auth happens via requestAuth() during connection
  Future<bool> acquireSlot() async {
    // No-op: slot acquisition is now part of requestAuth('connect')
    return true;
  }

  /// Legacy: Check if we have a slot (compatibility with old code)
  bool get hasSlot => hasSession;

  /// Callback for session errors (session_expired, bad_session, outside_zone)
  /// Set by AppStateProvider to handle auto-disconnect
  Future<void> Function(String? reason, String? message)? onSessionError;

  /// Callback for maintenance mode detection (while connected)
  void Function(String message, String? url)? onMaintenanceMode;

  /// Legacy: Upload batch (wrapper for submitWardriveData)
  /// Returns true on success, false on failure
  /// Triggers onSessionError callback for session-related errors
  Future<bool> uploadBatch(List<Map<String, dynamic>> pings) async {
    if (pings.isEmpty) return true;

    try {
      final result = await submitWardriveData(pings);

      if (result == null) {
        debugError('[API] Upload batch failed: no response');
        return false;
      }

      // Check for maintenance mode first
      if (_checkMaintenanceMode(result)) {
        return false;
      }

      if (result['success'] == true) {
        debugLog('[API] Upload batch SUCCESS: ${pings.length} items');
        return true;
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
        'outside_zone', 'zone_full',
      };

      if (criticalErrors.contains(reason)) {
        debugError('[API] Upload batch session error: $reason');
        final message = result['message'] as String?;
        // Clear session locally since it's invalid on server
        _clearSession();
        // Notify listener for auto-disconnect
        onSessionError?.call(reason, message);
      }

      return false;
    } catch (e) {
      debugError('[API] Upload batch exception: $e');
      return false;
    }
  }

  /// Fetch repeaters for a zone from the MeshMapper API
  /// Returns a list of enabled repeaters for the given IATA zone code
  Future<List<Repeater>> fetchRepeaters(String iata) async {
    final stopwatch = Stopwatch()..start();
    const endpoint = '/repeaters.json';
    try {
      final url = 'https://${iata.toLowerCase()}.meshmapper.net$endpoint';

      final response = await _client.get(
        Uri.parse(url),
      ).timeout(const Duration(seconds: 15));

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

      final List<dynamic> jsonList = json.decode(response.body) as List<dynamic>;
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

  /// Dispose of resources
  void dispose() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _client.close();
  }
}
