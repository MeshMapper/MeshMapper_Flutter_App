import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/user_preferences.dart';
import '../utils/debug_logger_io.dart';

/// Service for forwarding wardrive ping payloads to a user-configured
/// third-party API endpoint. Fire-and-forget: never blocks MeshMapper uploads.
///
/// Payload sent to custom endpoint:
/// ```json
/// { "data": [ ...same ping objects as MeshMapper... ] }
/// ```
///
/// MeshMapper API key and session_id are NOT included.
/// Custom API key is sent as X-API-Key header.
class CustomApiService {
  final http.Client _client;
  final UserPreferences Function() _prefsGetter;

  /// Throttle map: error type → last time logged to user-facing error tab
  final Map<String, DateTime> _errorThrottle = {};
  static const Duration _throttleWindow = Duration(minutes: 1);
  static const Duration _requestTimeout = Duration(seconds: 10);

  /// Callback for user-facing error logging (wired to AppStateProvider.logError)
  void Function(String message)? onError;

  /// Returns the 8-char public key prefix of the connected device, or null
  String? Function()? contactGetter;

  /// Returns the current IATA zone code, or null if not in a zone
  String? Function()? iataGetter;

  CustomApiService({
    required UserPreferences Function() prefsGetter,
    http.Client? client,
  })  : _prefsGetter = prefsGetter,
        _client = client ?? http.Client();

  /// Fire-and-forget: forward pings to the custom endpoint.
  /// Called after successful MeshMapper upload. Never throws.
  void forwardPings(List<Map<String, dynamic>> pings) {
    final prefs = _prefsGetter();
    if (!prefs.customApiEnabled) return;
    if (prefs.customApiUrl == null || prefs.customApiUrl!.isEmpty) return;
    if (prefs.customApiKey == null || prefs.customApiKey!.isEmpty) return;

    // Enrich with contact and iata (custom API only — never sent to MeshMapper)
    final contact =
        prefs.customApiIncludeContact ? contactGetter?.call() : null;
    final iata = iataGetter?.call();

    final enriched = pings.map((ping) {
      final enrichedPing = Map<String, dynamic>.from(ping);
      if (contact != null) enrichedPing['contact'] = contact;
      if (iata != null) enrichedPing['iata'] = iata;
      return enrichedPing;
    }).toList();

    // Fire and forget — do not await
    _doForward(prefs.customApiUrl!, prefs.customApiKey!, enriched);
  }

  Future<void> _doForward(
    String url,
    String apiKey,
    List<Map<String, dynamic>> pings,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      final payload = json.encode({'data': pings});

      final response = await _client
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'X-API-Key': apiKey,
            },
            body: payload,
          )
          .timeout(_requestTimeout);

      stopwatch.stop();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        debugLog(
            '[CUSTOM API] Forward SUCCESS: ${pings.length} items in ${stopwatch.elapsedMilliseconds}ms');
      } else {
        final errorType = 'http_${response.statusCode}';
        debugError(
            '[CUSTOM API] Forward failed: HTTP ${response.statusCode} (${stopwatch.elapsedMilliseconds}ms)');
        debugError(
            '[CUSTOM API]   Body: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}');
        _throttledError(
            errorType, 'Custom API returned HTTP ${response.statusCode}');
      }
    } on TimeoutException {
      stopwatch.stop();
      debugError(
          '[CUSTOM API] Forward timed out after ${_requestTimeout.inSeconds}s');
      _throttledError('timeout', 'Custom API request timed out');
    } catch (e) {
      stopwatch.stop();
      debugError('[CUSTOM API] Forward exception: $e');
      // Extract a concise, user-friendly message from the exception chain
      final description = _describeError(e);
      _throttledError('network_error', 'Custom API: $description');
    }
  }

  /// Log error to user-facing error tab, throttled to one per error type per minute.
  /// Debug logs (debugError) are always emitted unthrottled.
  void _throttledError(String errorType, String message) {
    final now = DateTime.now();
    final lastLog = _errorThrottle[errorType];
    if (lastLog != null && now.difference(lastLog) < _throttleWindow) {
      return; // Suppressed — same error type logged within 1 minute
    }
    _errorThrottle[errorType] = now;
    onError?.call(message);
  }

  /// Extract a concise error description from an exception.
  /// The http package wraps SocketException inside ClientException —
  /// drill into the chain to surface the actionable detail (e.g. host lookup failure).
  String _describeError(Object e) {
    final full = e.toString();
    // Look for SocketException detail (e.g. "Failed host lookup: 'blah.blah'")
    final socketMatch =
        RegExp(r'SocketException: (.+?)(?:,|\()').firstMatch(full);
    if (socketMatch != null) return socketMatch.group(1)!.trim();
    // Look for OS-level message
    final osMatch = RegExp(r'OS Error: (.+?)(?:,|\))').firstMatch(full);
    if (osMatch != null) return osMatch.group(1)!.trim();
    // Fallback: use the exception type
    return e.runtimeType.toString();
  }

  void dispose() {
    _errorThrottle.clear();
  }
}
