import 'dart:convert';

import 'package:http/http.dart' as http;

/// MeshMapper API service
/// Handles communication with the MeshMapper backend
class ApiService {
  /// Base URL for MeshMapper API
  static const String baseUrl = 'https://meshmapper.caldr.ca/api';

  final http.Client _client;
  String? _deviceId;
  bool _hasSlot = false;

  ApiService({http.Client? client}) : _client = client ?? http.Client();

  /// Set device ID for API requests
  void setDeviceId(String deviceId) {
    _deviceId = deviceId;
  }

  /// Check if we have a valid API slot
  bool get hasSlot => _hasSlot;

  /// Acquire API slot for this device
  /// Reference: /api/addslot?user_id={DEVICE_ID}
  Future<bool> acquireSlot() async {
    if (_deviceId == null) {
      throw Exception('Device ID not set');
    }

    try {
      final response = await _client.get(
        Uri.parse('$baseUrl/addslot?user_id=$_deviceId'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        _hasSlot = true;
        return true;
      } else {
        _hasSlot = false;
        return false;
      }
    } catch (e) {
      _hasSlot = false;
      return false;
    }
  }

  /// Upload a batch of pings to the API
  /// Reference: batchUpload() in wardrive.js
  Future<bool> uploadBatch(List<Map<String, dynamic>> pings) async {
    if (pings.isEmpty) return true;

    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/batch'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(pings),
      ).timeout(const Duration(seconds: 30));

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Upload a single TX ping
  Future<bool> uploadTxPing({
    required double latitude,
    required double longitude,
    required int power,
    required String deviceId,
  }) async {
    final ping = {
      'type': 'TX',
      'lat': latitude,
      'lon': longitude,
      'power': power,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'device_id': deviceId,
    };

    return uploadBatch([ping]);
  }

  /// Upload a single RX ping
  Future<bool> uploadRxPing({
    required double latitude,
    required double longitude,
    required String repeaterId,
    required double snr,
    required int rssi,
    required String deviceId,
  }) async {
    final ping = {
      'type': 'RX',
      'lat': latitude,
      'lon': longitude,
      'repeater_id': repeaterId,
      'snr': snr,
      'rssi': rssi,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'device_id': deviceId,
    };

    return uploadBatch([ping]);
  }

  /// Get leaderboard data
  Future<List<Map<String, dynamic>>?> getLeaderboard() async {
    try {
      final response = await _client.get(
        Uri.parse('$baseUrl/leaderboard'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return List<Map<String, dynamic>>.from(data);
      }
    } catch (e) {
      // Ignore errors
    }
    return null;
  }

  /// Dispose of resources
  void dispose() {
    _client.close();
  }
}
