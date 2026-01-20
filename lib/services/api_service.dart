import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

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

  /// Heartbeat interval (send 5 minutes before expiry)
  static const Duration heartbeatLeadTime = Duration(minutes: 5);

  final http.Client _client;
  String? _sessionId;
  bool _txAllowed = false;
  bool _rxAllowed = false;
  int? _sessionExpiresAt;
  Timer? _heartbeatTimer;
  Function? _onSessionExpiring;

  ApiService({http.Client? client}) : _client = client ?? http.Client();

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

      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      // Return null on error
    }
    return null;
  }

  /// Request authentication with MeshMapper geo-auth API
  /// Matches requestAuth() in wardrive.js
  /// 
  /// @param reason Either "connect" (acquire session) or "disconnect" (release session)
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
  }) async {
    try {
      final payload = <String, dynamic>{
        'key': apiKey,
        'public_key': publicKey,
        'reason': reason,
      };

      // For connect: add device metadata and GPS coords
      if (reason == 'connect') {
        if (lat == null || lon == null) {
          throw Exception('GPS coordinates required for connect');
        }

        payload['who'] = who ?? 'GOME-WarDriver';
        payload['ver'] = appVersion ?? 'UNKNOWN';
        payload['power'] = power ?? 0.3;  // Wattage (0.3, 0.6, 1.0, 2.0)
        payload['iata'] = iataCode ?? 'YOW';
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

      final data = json.decode(response.body) as Map<String, dynamic>;

      // Store session info on successful connect
      if (reason == 'connect' && data['success'] == true) {
        _sessionId = data['session_id'] as String?;
        _txAllowed = data['tx_allowed'] == true;
        _rxAllowed = data['rx_allowed'] == true;
        _sessionExpiresAt = data['expires_at'] as int?;

        // Start heartbeat timer if we have an expiry time
        _scheduleHeartbeat();
      } else if (reason == 'disconnect') {
        // Clear session on disconnect
        _clearSession();
      }

      return data;
    } catch (e) {
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

      final data = json.decode(response.body) as Map<String, dynamic>;

      // Update expires_at if provided and reschedule heartbeat
      if (data['success'] == true && data['expires_at'] != null) {
        _sessionExpiresAt = data['expires_at'] as int;
        _scheduleHeartbeat();
      }

      return data;
    } catch (e) {
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
      return null;
    }

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

      final data = json.decode(response.body) as Map<String, dynamic>;

      // Update expires_at if provided and reschedule heartbeat
      if (data['success'] == true && data['expires_at'] != null) {
        _sessionExpiresAt = data['expires_at'] as int;
        _scheduleHeartbeat();
      }

      return data;
    } catch (e) {
      return null;
    }
  }

  /// Schedule heartbeat timer to fire 5 minutes before session expires
  /// Reference: sendHeartbeat() in wardrive.js
  void _scheduleHeartbeat() {
    // Cancel existing timer
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    if (_sessionExpiresAt == null) {
      debugLog('[API] No expiry time, skipping heartbeat schedule');
      return;
    }

    final expiryTime = DateTime.fromMillisecondsSinceEpoch(_sessionExpiresAt! * 1000);
    final heartbeatTime = expiryTime.subtract(heartbeatLeadTime);
    final now = DateTime.now();

    if (heartbeatTime.isBefore(now)) {
      // Already expired or expiring very soon - notify immediately
      debugWarn('[API] Session expires soon, notifying immediately');
      _onSessionExpiring?.call();
      return;
    }

    final delay = heartbeatTime.difference(now);
    debugLog('[API] Scheduling heartbeat in ${delay.inSeconds}s (${heartbeatTime})');

    _heartbeatTimer = Timer(delay, () async {
      debugLog('[API] Heartbeat timer fired, sending heartbeat');
      try {
        final result = await sendHeartbeat();
        if (result?['success'] == true) {
          debugLog('[API] Heartbeat successful, session extended');
        } else {
          debugWarn('[API] Heartbeat failed: ${result?['message'] ?? 'unknown'}');
          _onSessionExpiring?.call();
        }
      } catch (e) {
        debugError('[API] Heartbeat error: $e');
        _onSessionExpiring?.call();
      }
    });
  }

  /// Clear session data and cancel heartbeat timer
  void _clearSession() {
    _sessionId = null;
    _txAllowed = false;
    _rxAllowed = false;
    _sessionExpiresAt = null;
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

      if (result['success'] == true) {
        debugLog('[API] Upload batch SUCCESS: ${pings.length} items');
        return true;
      }

      // Check for session errors that require disconnect
      final reason = result['reason'] as String?;
      if (reason == 'session_expired' || reason == 'bad_session' || reason == 'outside_zone') {
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

  /// Dispose of resources
  void dispose() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _client.close();
  }
}
