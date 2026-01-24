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

  /// Heartbeat idle timeout (send keepalive after 3 minutes of no API activity)
  static const Duration heartbeatIdleTimeout = Duration(minutes: 3);

  final http.Client _client;
  bool _heartbeatEnabled = false;  // Track if heartbeat mode is active
  String? _sessionId;
  bool _txAllowed = false;
  bool _rxAllowed = false;
  int? _sessionExpiresAt;
  Timer? _heartbeatTimer;
  Function? _onSessionExpiring;
  List<String> _channels = [];

  /// Regional channels from auth response (e.g., ['public', 'ottawa', 'testing'])
  List<String> get channels => List.unmodifiable(_channels);

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

      // Update expires_at if provided and reset heartbeat idle timer
      if (data['success'] == true) {
        if (data['expires_at'] != null) {
          _sessionExpiresAt = data['expires_at'] as int;
        }
        _resetHeartbeatTimer();  // Resets 3-min idle timer on each successful upload
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

      // Update expires_at if provided (timer reset handled by _resetHeartbeatTimer in caller)
      if (data['success'] == true && data['expires_at'] != null) {
        _sessionExpiresAt = data['expires_at'] as int;
      }

      return data;
    } catch (e) {
      return null;
    }
  }

  /// Enable heartbeat mode (called when auto mode starts)
  /// Heartbeat fires after 3 minutes of API inactivity to keep session alive
  void enableHeartbeat() {
    _heartbeatEnabled = true;
    _resetHeartbeatTimer();
    debugLog('[API] Heartbeat mode enabled (3 min idle timeout)');
  }

  /// Disable heartbeat mode (called when auto mode stops)
  void disableHeartbeat() {
    _heartbeatEnabled = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    debugLog('[API] Heartbeat mode disabled');
  }

  /// Reset the heartbeat timer (call after any API activity)
  /// Timer fires 3 minutes after last API post to send keepalive
  void _resetHeartbeatTimer() {
    if (!_heartbeatEnabled) return;

    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer(heartbeatIdleTimeout, () async {
      debugLog('[API] Heartbeat timer fired (3 min idle), sending keepalive');
      final result = await sendHeartbeat();
      if (result?['success'] == true) {
        debugLog('[API] Heartbeat successful');
        _resetHeartbeatTimer();  // Schedule next heartbeat
      } else {
        debugWarn('[API] Heartbeat failed: ${result?['message']}');
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
    try {
      final url = 'https://${iata.toLowerCase()}.meshmapper.net/repeaters.json';
      debugLog('[API] Fetching repeaters from: $url');

      final response = await _client.get(
        Uri.parse(url),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugError('[API] Failed to fetch repeaters: HTTP ${response.statusCode}');
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

      debugLog('[API] Fetched ${repeaters.length} enabled repeaters');
      return repeaters;
    } catch (e) {
      debugError('[API] Error fetching repeaters: $e');
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
