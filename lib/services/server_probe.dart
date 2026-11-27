import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'server_config.dart';

/// Asks the dev server's `/status` door who it is, for the Test button on
/// the Developer Tools page, and says the answer in words.
///
/// The request always goes to [ServerConfig.devDomain], with the key GIVEN
/// here, so the key can be tested before the switch is turned on. A typed
/// key can therefore never be sent to live. Neither the key nor the body is
/// logged. Request shape: `docs/APP_API.md` in the Server repo.
Future<String> probeDevServer({
  required http.Client client,
  required String key,
  required double lat,
  required double lon,
  required double accuracyMeters,
  required String appVersion,
  Duration timeout = const Duration(seconds: 10),
}) async {
  const host = ServerConfig.devDomain;
  if (key.trim().isEmpty) return 'Enter the API key first.';

  http.Response response;
  try {
    response = await client
        .post(
          Uri.https(host, '/wardrive-api.php/status'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'lat': lat,
            'lng': lon,
            'accuracy_m': accuracyMeters,
            'ver': appVersion,
            'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            'key': key.trim(),
          }),
        )
        .timeout(timeout);
  } on TimeoutException {
    return 'No answer from $host within ${timeout.inSeconds} seconds. Check '
        'that this phone can reach it.';
  } on HandshakeException {
    return 'The certificate of $host was not accepted.';
  } catch (_) {
    return 'Could not reach $host. Check that this phone can reach it.';
  }

  Map<String, dynamic>? data;
  try {
    final decoded = json.decode(response.body);
    if (decoded is Map<String, dynamic>) data = decoded;
  } catch (_) {}
  if (data == null) {
    return '$host answered (HTTP ${response.statusCode}), but not as a '
        'MeshMapper server.';
  }

  final reason = data['reason'];
  if (response.statusCode == 401 ||
      reason == 'bad_key' ||
      reason == 'invalid_key') {
    return '$host answered, but this key is not valid there.';
  }
  if (data['maintenance'] == true) {
    return '$host answered: it is in maintenance mode.';
  }
  if (data['success'] == false) {
    final message = data['message'];
    final detail = message is String && message.trim().isNotEmpty
        ? message.trim()
        : (reason is String ? reason : 'HTTP ${response.statusCode}');
    return '$host accepted the request but refused it: $detail';
  }
  if (data['in_zone'] == true) {
    final zone = data['zone'];
    final name = zone is Map ? zone['name'] : null;
    final code = zone is Map ? zone['code'] : null;
    final where = [
      if (name is String && name.isNotEmpty) name,
      if (code is String && code.isNotEmpty) '($code)',
    ].join(' ');
    return 'Working. $host accepted the key and places you in '
        '${where.isEmpty ? 'a region' : where}.';
  }
  final nearest = data['nearest_zone'];
  final nearestName = nearest is Map ? nearest['name'] : null;
  final distance = nearest is Map ? nearest['distance_km'] : null;
  final near = nearestName is String && nearestName.isNotEmpty
      ? ' The nearest is $nearestName'
          '${distance is num ? ', ${distance.toStringAsFixed(1)} km away' : ''}.'
      : '';
  return 'Working. $host accepted the key. You are outside every region '
      'there.$near';
}
