/// MeshMapper Offline Upload Diagnostic Script
///
/// Reproduces server-side session invalidation during offline batch uploads.
/// Runs four scenarios to determine if the server has an item count limit,
/// rate limit, zone mismatch issue, or other constraint.
///
/// Usage:
///   dart run bin/test_offline_upload.dart --key=<API_KEY> --pubkey=<DEVICE_PUB_KEY> [options]
///
/// Required:
///   --key=<value>         MeshMapper API key
///   --pubkey=<value>      Registered device public key (hex)
///
/// Optional:
///   --lat=<value>           Latitude for auth (default: 45.3215)
///   --lon=<value>           Longitude for auth (default: -75.6693)
///   --data-lat=<value>      Latitude for ping data (default: same as --lat)
///   --data-lon=<value>      Longitude for ping data (default: same as --lon)
///   --who=<value>           Device name (default: DIAG-TEST)
///   --scenario=<1|2|3|4|all>  Run specific scenario (default: all)
///   --contact-uri=<value>   Signed contact URI (for unregistered devices)
///
/// Examples:
///   dart run bin/test_offline_upload.dart --key=abc123 --pubkey=deadbeef...
///   dart run bin/test_offline_upload.dart --key=abc123 --pubkey=deadbeef... --scenario=1
library;

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

// ============================================================================
// CONSTANTS
// ============================================================================

const String baseUrl = 'https://meshmapper.net';
const String authEndpoint = '$baseUrl/wardrive-api.php/auth';
const String wardriveEndpoint = '$baseUrl/wardrive-api.php/wardrive';
final String testVersion =
    'APP-${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
const String testModel = 'Offline Upload';

// ============================================================================
// GLOBAL STATE (for Ctrl+C cleanup)
// ============================================================================

String? _activeSessionId;
String? _activeApiKey;
String? _activePubkey;
http.Client? _activeClient;

// ============================================================================
// DATA GENERATION
// ============================================================================

List<Map<String, dynamic>> generateTestItems(
  int count, {
  double baseLat = 45.3215,
  double baseLon = -75.6693,
}) {
  final baseTimestamp = (DateTime.now()
          .subtract(const Duration(hours: 24))
          .millisecondsSinceEpoch ~/
      1000);
  final items = <Map<String, dynamic>>[];

  for (var i = 0; i < count; i++) {
    final timestamp = baseTimestamp + (i * 10);
    final lat = baseLat + (i * 0.00001);
    final lon = baseLon + (i * 0.00001);

    if (i.isEven) {
      items.add({
        'type': 'RX',
        'lat': lat,
        'lon': lon,
        'noisefloor': -100,
        'heard_repeats': 'ff(0.0)',
        'timestamp': timestamp,
        'external_antenna': true,
        'power': '0.3w',
      });
    } else {
      items.add({
        'type': 'DISC',
        'lat': lat,
        'lon': lon,
        'noisefloor': -100,
        'repeater_id': 'ff',
        'node_type': 'REPEATER',
        'local_snr': 0.0,
        'local_rssi': -100,
        'remote_snr': 0.0,
        'public_key':
            '0000000000000000000000000000000000000000000000000000000000000000',
        'timestamp': timestamp,
        'external_antenna': true,
        'power': '0.3w',
      });
    }
  }
  return items;
}

// ============================================================================
// API HELPERS
// ============================================================================

Future<Map<String, dynamic>?> authenticate({
  required http.Client client,
  required String apiKey,
  required String pubkey,
  required double lat,
  required double lon,
  required String who,
  String? contactUri,
}) async {
  final payload = <String, dynamic>{
    'key': apiKey,
    'reason': 'connect',
    'offline_mode': true,
    'who': who,
    'ver': testVersion,
    'power': '0.3w',
    'model': testModel,
    'coords': {
      'lat': lat,
      'lng': lon,
      'accuracy_m': 5.0,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    },
  };

  if (contactUri != null) {
    payload['contact_uri'] = contactUri;
  } else {
    payload['public_key'] = pubkey;
  }

  try {
    final stopwatch = Stopwatch()..start();
    final response = await client
        .post(
          Uri.parse(authEndpoint),
          headers: {'Content-Type': 'application/json'},
          body: json.encode(payload),
        )
        .timeout(const Duration(seconds: 10));
    stopwatch.stop();

    final data = json.decode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      print('    Auth HTTP ${response.statusCode}: ${response.body}');
    }

    return {
      ...data,
      '_http_status': response.statusCode,
      '_elapsed_ms': stopwatch.elapsedMilliseconds,
    };
  } catch (e) {
    print('    Auth exception: $e');
    return null;
  }
}

Future<Map<String, dynamic>?> registerDevice({
  required http.Client client,
  required String apiKey,
  required String contactUri,
  required double lat,
  required double lon,
  required String who,
}) async {
  return authenticate(
    client: client,
    apiKey: apiKey,
    pubkey: '',
    lat: lat,
    lon: lon,
    who: who,
    contactUri: contactUri,
  );
}

Future<BatchResult> uploadBatch({
  required http.Client client,
  required String apiKey,
  required String sessionId,
  required List<Map<String, dynamic>> items,
  required int batchNum,
  required int cumulativeItems,
}) async {
  final stopwatch = Stopwatch()..start();

  try {
    final payload = {
      'key': apiKey,
      'session_id': sessionId,
      'data': items,
    };

    final response = await client
        .post(
          Uri.parse(wardriveEndpoint),
          headers: {'Content-Type': 'application/json'},
          body: json.encode(payload),
        )
        .timeout(const Duration(seconds: 30));

    stopwatch.stop();

    final data = json.decode(response.body) as Map<String, dynamic>;

    return BatchResult(
      batchNumber: batchNum,
      itemCount: items.length,
      cumulativeItems: cumulativeItems,
      success: data['success'] == true,
      httpStatus: response.statusCode,
      reason: data['reason'] as String?,
      message: data['message'] as String?,
      expiresAt: data['expires_at'] as int?,
      responseTime: stopwatch.elapsed,
    );
  } catch (e) {
    stopwatch.stop();
    return BatchResult(
      batchNumber: batchNum,
      itemCount: items.length,
      cumulativeItems: cumulativeItems,
      success: false,
      httpStatus: 0,
      reason: 'exception',
      message: '$e',
      expiresAt: null,
      responseTime: stopwatch.elapsed,
    );
  }
}

Future<void> disconnectSession({
  required http.Client client,
  required String apiKey,
  required String pubkey,
  required String sessionId,
}) async {
  try {
    final payload = {
      'key': apiKey,
      'reason': 'disconnect',
      'public_key': pubkey,
      'session_id': sessionId,
    };

    await client
        .post(
          Uri.parse(authEndpoint),
          headers: {'Content-Type': 'application/json'},
          body: json.encode(payload),
        )
        .timeout(const Duration(seconds: 10));
  } catch (_) {
    // Best effort
  }
}

// ============================================================================
// RESULT TYPES
// ============================================================================

class BatchResult {
  final int batchNumber;
  final int itemCount;
  final int cumulativeItems;
  final bool success;
  final int httpStatus;
  final String? reason;
  final String? message;
  final int? expiresAt;
  final Duration responseTime;

  BatchResult({
    required this.batchNumber,
    required this.itemCount,
    required this.cumulativeItems,
    required this.success,
    required this.httpStatus,
    this.reason,
    this.message,
    this.expiresAt,
    required this.responseTime,
  });
}

class ScenarioResult {
  final String name;
  final String description;
  final int batchSize;
  final Duration interBatchDelay;
  final List<BatchResult> batches;
  final int? failedAtBatch;
  final int? failedAtCumulativeItems;
  final String? failureReason;
  final bool authFailed;

  ScenarioResult({
    required this.name,
    required this.description,
    required this.batchSize,
    required this.interBatchDelay,
    required this.batches,
    this.failedAtBatch,
    this.failedAtCumulativeItems,
    this.failureReason,
    this.authFailed = false,
  });

  bool get passed => failedAtBatch == null && !authFailed;
  int get totalUploaded =>
      batches.where((b) => b.success).fold(0, (sum, b) => sum + b.itemCount);
}

// ============================================================================
// SCENARIO RUNNER
// ============================================================================

Future<ScenarioResult> runScenario({
  required http.Client client,
  required String apiKey,
  required String pubkey,
  required double lat,
  required double lon,
  required String who,
  required String name,
  required String description,
  required int batchSize,
  required int maxBatches,
  required Duration interBatchDelay,
  String? contactUri,
  double? dataLat,
  double? dataLon,
}) async {
  // Authenticate
  stdout.write('  Authenticating...');
  final authResult = await authenticate(
    client: client,
    apiKey: apiKey,
    pubkey: pubkey,
    lat: lat,
    lon: lon,
    who: who,
    contactUri: contactUri,
  );

  if (authResult == null || authResult['success'] != true) {
    final reason = authResult?['reason'] as String? ?? 'network error';

    // Try registration if unknown_device and contactUri available
    if (reason == 'unknown_device' && contactUri != null) {
      stdout.write(' unknown device, trying registration...');
      final regResult = await registerDevice(
        client: client,
        apiKey: apiKey,
        contactUri: contactUri,
        lat: lat,
        lon: lon,
        who: who,
      );
      if (regResult == null || regResult['success'] != true) {
        print(' FAILED (registration: ${regResult?['reason'] ?? 'error'})');
        return ScenarioResult(
          name: name,
          description: description,
          batchSize: batchSize,
          interBatchDelay: interBatchDelay,
          batches: [],
          failureReason: 'Registration failed: ${regResult?['reason']}',
          authFailed: true,
        );
      }
      // Use registration session
      final sessionId = regResult['session_id'] as String?;
      if (sessionId == null) {
        print(' FAILED (no session_id after registration)');
        return ScenarioResult(
          name: name,
          description: description,
          batchSize: batchSize,
          interBatchDelay: interBatchDelay,
          batches: [],
          failureReason: 'No session_id after registration',
          authFailed: true,
        );
      }
      print(' OK via registration (session: $sessionId)');
      _activeSessionId = sessionId;
      _activeApiKey = apiKey;
      _activePubkey = pubkey;
      _activeClient = client;
      // Fall through to upload with sessionId
      return _runBatches(
        client: client,
        apiKey: apiKey,
        pubkey: pubkey,
        lat: lat,
        lon: lon,
        dataLat: dataLat,
        dataLon: dataLon,
        sessionId: sessionId,
        name: name,
        description: description,
        batchSize: batchSize,
        maxBatches: maxBatches,
        interBatchDelay: interBatchDelay,
      );
    }

    print(' FAILED ($reason)');
    if (reason == 'unknown_device') {
      print(
          '    Hint: device not registered. Pass --contact-uri=<uri> or use a registered device key.');
    }
    return ScenarioResult(
      name: name,
      description: description,
      batchSize: batchSize,
      interBatchDelay: interBatchDelay,
      batches: [],
      failureReason: 'Auth failed: $reason',
      authFailed: true,
    );
  }

  final sessionId = authResult['session_id'] as String?;
  final expiresAt = authResult['expires_at'] as int?;
  final elapsed = authResult['_elapsed_ms'] as int?;
  if (sessionId == null) {
    print(' FAILED (no session_id)');
    return ScenarioResult(
      name: name,
      description: description,
      batchSize: batchSize,
      interBatchDelay: interBatchDelay,
      batches: [],
      failureReason: 'Auth succeeded but no session_id',
      authFailed: true,
    );
  }

  final ttl = expiresAt != null
      ? expiresAt - (DateTime.now().millisecondsSinceEpoch ~/ 1000)
      : 0;
  print(' OK (session: $sessionId, TTL: ${ttl}s, ${elapsed}ms)');

  _activeSessionId = sessionId;
  _activeApiKey = apiKey;
  _activePubkey = pubkey;
  _activeClient = client;

  return _runBatches(
    client: client,
    apiKey: apiKey,
    pubkey: pubkey,
    lat: lat,
    lon: lon,
    dataLat: dataLat,
    dataLon: dataLon,
    sessionId: sessionId,
    name: name,
    description: description,
    batchSize: batchSize,
    maxBatches: maxBatches,
    interBatchDelay: interBatchDelay,
  );
}

Future<ScenarioResult> _runBatches({
  required http.Client client,
  required String apiKey,
  required String pubkey,
  required double lat,
  required double lon,
  double? dataLat,
  double? dataLon,
  required String sessionId,
  required String name,
  required String description,
  required int batchSize,
  required int maxBatches,
  required Duration interBatchDelay,
}) async {
  final batches = <BatchResult>[];
  int? failedAtBatch;
  int? failedAtCumulative;
  String? failureReason;

  // Wait for session propagation
  print('  Waiting 4s for session propagation...');
  await Future.delayed(const Duration(seconds: 4));

  // Generate all test items up front (use data coords if provided, else auth coords)
  final totalItems = batchSize * maxBatches;
  final allItems = generateTestItems(totalItems,
      baseLat: dataLat ?? lat, baseLon: dataLon ?? lon);

  // Upload batches
  var cumulativeItems = 0;
  for (var i = 0; i < maxBatches; i++) {
    final batchNum = i + 1;
    final start = i * batchSize;
    final end = (start + batchSize).clamp(0, allItems.length);
    final batch = allItems.sublist(start, end);
    cumulativeItems += batch.length;

    stdout.write(
        '  Batch $batchNum/$maxBatches (${batch.length} items, total: $cumulativeItems)...');

    final result = await uploadBatch(
      client: client,
      apiKey: apiKey,
      sessionId: sessionId,
      items: batch,
      batchNum: batchNum,
      cumulativeItems: cumulativeItems,
    );
    batches.add(result);

    if (result.success) {
      final elapsed =
          '${(result.responseTime.inMilliseconds / 1000).toStringAsFixed(2)}s';
      print(' OK ($elapsed)');
    } else {
      final elapsed =
          '${(result.responseTime.inMilliseconds / 1000).toStringAsFixed(2)}s';
      print(
          ' FAIL ${result.httpStatus} ${result.reason ?? 'unknown'} ($elapsed)');
      if (result.message != null) {
        print('    "${result.message}"');
      }
      failedAtBatch = batchNum;
      failedAtCumulative = cumulativeItems;
      failureReason = result.reason;
      break;
    }

    // Inter-batch delay
    if (interBatchDelay.inMilliseconds > 0 && i < maxBatches - 1) {
      stdout.write(
          '  (waiting ${interBatchDelay.inSeconds}s before next batch...)\n');
      await Future.delayed(interBatchDelay);
    }
  }

  // Disconnect
  stdout.write('  Disconnecting...');
  await disconnectSession(
    client: client,
    apiKey: apiKey,
    pubkey: pubkey,
    sessionId: sessionId,
  );
  print(' OK');

  _activeSessionId = null;
  _activeApiKey = null;
  _activePubkey = null;
  _activeClient = null;

  return ScenarioResult(
    name: name,
    description: description,
    batchSize: batchSize,
    interBatchDelay: interBatchDelay,
    batches: batches,
    failedAtBatch: failedAtBatch,
    failedAtCumulativeItems: failedAtCumulative,
    failureReason: failureReason,
  );
}

// ============================================================================
// OUTPUT
// ============================================================================

void printHeader(String apiKey, String pubkey, double lat, double lon,
    double? dataLat, double? dataLon, String who, String scenarios) {
  print('');
  print('=' * 60);
  print('     MESHMAPPER OFFLINE UPLOAD DIAGNOSTIC');
  print('=' * 60);
  print('');
  print('  Config:');
  print(
      '    API Key:    ${apiKey.length > 8 ? '${apiKey.substring(0, 4)}...${apiKey.substring(apiKey.length - 4)}' : '****'}');
  print(
      '    Public Key: ${pubkey.length > 16 ? '${pubkey.substring(0, 8)}...${pubkey.substring(pubkey.length - 8)}' : pubkey}');
  print('    Device:     $who');
  print('    Auth Coords:  $lat, $lon');
  if (dataLat != null || dataLon != null) {
    print('    Data Coords:  ${dataLat ?? lat}, ${dataLon ?? lon}');
  }
  print('    Scenarios:  $scenarios');
  print('');
}

void printScenarioHeader(String name, String description) {
  print('=' * 60);
  print('  SCENARIO: $name');
  print('  $description');
  print('=' * 60);
  print('');
}

void printSummary(List<ScenarioResult> results) {
  print('');
  print('=' * 60);
  print('                  DIAGNOSTIC SUMMARY');
  print('=' * 60);
  print('');

  for (final result in results) {
    final icon = result.passed ? '[+]' : '[X]';
    final delayStr = result.interBatchDelay.inSeconds > 0
        ? '${result.interBatchDelay.inSeconds}s delay'
        : 'no delay';

    if (result.authFailed) {
      print('  $icon ${result.name} (batch=${result.batchSize}, $delayStr)');
      print('     Auth failed: ${result.failureReason}');
    } else if (result.passed) {
      print('  $icon ${result.name} (batch=${result.batchSize}, $delayStr)');
      print(
          '     PASSED ${result.totalUploaded} items across ${result.batches.length} batches');
    } else {
      print('  $icon ${result.name} (batch=${result.batchSize}, $delayStr)');
      print(
          '     FAILED at batch ${result.failedAtBatch} (${result.failedAtCumulativeItems} cumulative items)');
      print('     Reason: ${result.failureReason}');
      print(
          '     Successfully uploaded: ${result.totalUploaded} items before failure');
    }
    print('');
  }

  // Analysis
  final validResults = results.where((r) => !r.authFailed).toList();
  if (validResults.isEmpty) {
    print('  FINDINGS:');
    print('  - All scenarios failed to authenticate.');
    print(
        '  - Check your API key and device public key, or provide --contact-uri');
  } else {
    print('  FINDINGS:');

    final rapidFire = validResults
        .where((r) => r.interBatchDelay.inSeconds == 0 && r.batchSize == 50)
        .toList();
    final throttled = validResults
        .where((r) => r.interBatchDelay.inSeconds > 0 && r.batchSize == 50)
        .toList();
    final batchSweep = validResults
        .where((r) => r.interBatchDelay.inSeconds == 0 && r.batchSize != 50)
        .toList();

    // Check if rapid fire failed but throttled passed
    if (rapidFire.isNotEmpty &&
        throttled.isNotEmpty &&
        !rapidFire.first.passed &&
        throttled.first.passed) {
      print(
          '  - Rapid-fire batches fail at ~${rapidFire.first.totalUploaded} items, but throttled batches pass.');
      print('  - CONCLUSION: Server-side RATE LIMIT (not item count limit).');
      print(
          '  - The server rejects rapid consecutive POSTs to the same session.');
      print(
          '  - Workaround: add a delay between batch uploads (${throttled.first.interBatchDelay.inSeconds}s worked).');
    } else if (rapidFire.isNotEmpty &&
        throttled.isNotEmpty &&
        !rapidFire.first.passed &&
        !throttled.first.passed) {
      final rapidItems = rapidFire.first.totalUploaded;
      final throttledItems = throttled.first.totalUploaded;
      if ((rapidItems - throttledItems).abs() < 60) {
        print('  - Both rapid and throttled fail at ~$rapidItems items.');
        print(
            '  - CONCLUSION: Server-side ITEM COUNT LIMIT (~$rapidItems per session).');
        print(
            '  - Workaround: re-authenticate after every ~${(rapidItems * 0.8).round()} items.');
      } else {
        print(
            '  - Rapid: failed at $rapidItems items. Throttled: failed at $throttledItems items.');
        print(
            '  - CONCLUSION: Mixed behavior — may be a combination of rate + count limits.');
      }
    } else if (validResults.every((r) => r.passed)) {
      print('  - All scenarios passed!');
      print('  - Could not reproduce the session invalidation in this run.');
      print(
          '  - The issue may depend on server load, time of day, or specific session state.');
    }

    // Batch size analysis
    if (batchSweep.length >= 2) {
      print('');
      print('  Batch size analysis:');
      for (final r in batchSweep) {
        final status = r.passed ? 'PASSED' : 'FAILED at ${r.totalUploaded}';
        print('    batch=${r.batchSize}: $status');
      }
    }

    // Out-of-zone analysis
    final oozResults =
        validResults.where((r) => r.name == 'Out-of-Zone Data').toList();
    if (oozResults.isNotEmpty) {
      print('');
      print('  Out-of-zone data analysis:');
      final ooz = oozResults.first;
      if (ooz.passed) {
        print(
            '    PASSED — server accepted ${ooz.totalUploaded} items with out-of-zone coordinates.');
        print(
            '    Zone mismatch between auth and ping data does NOT cause session invalidation.');
      } else {
        print(
            '    FAILED at batch ${ooz.failedAtBatch} (${ooz.failedAtCumulativeItems} cumulative items).');
        print('    Reason: ${ooz.failureReason}');
        if (ooz.failureReason == 'bad_session' ||
            ooz.failureReason == 'session_expired') {
          print(
              '    CONCLUSION: Server MAY invalidate sessions when ping coords are outside auth zone.');
        }
      }
    }
  }

  print('');
  print('=' * 60);
  print('  NOTE: Test data uses who="DIAG-TEST" and past timestamps.');
  print('  Ask the backend team to purge DIAG-TEST data after review.');
  print('=' * 60);
  print('');
}

// ============================================================================
// MAIN
// ============================================================================

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.contains('--help')) {
    printUsage();
    return;
  }

  // Parse arguments
  String? apiKey;
  String? pubkey;
  String? contactUri;
  double lat = 45.3215;
  double lon = -75.6693;
  double? dataLat;
  double? dataLon;
  String who = 'DIAG-TEST';
  String scenario = 'all';

  for (final arg in arguments) {
    if (arg.startsWith('--key=')) {
      apiKey = arg.substring(6);
    } else if (arg.startsWith('--pubkey=')) {
      pubkey = arg.substring(9);
    } else if (arg.startsWith('--contact-uri=')) {
      contactUri = arg.substring(14);
    } else if (arg.startsWith('--lat=')) {
      lat = double.parse(arg.substring(6));
    } else if (arg.startsWith('--lon=')) {
      lon = double.parse(arg.substring(6));
    } else if (arg.startsWith('--data-lat=')) {
      dataLat = double.parse(arg.substring(11));
    } else if (arg.startsWith('--data-lon=')) {
      dataLon = double.parse(arg.substring(11));
    } else if (arg.startsWith('--who=')) {
      who = arg.substring(6);
    } else if (arg.startsWith('--scenario=')) {
      scenario = arg.substring(11);
    }
  }

  if (apiKey == null) {
    print('Error: --key=<API_KEY> is required');
    printUsage();
    exit(1);
  }
  if (pubkey == null && contactUri == null) {
    print(
        'Error: --pubkey=<DEVICE_PUB_KEY> or --contact-uri=<URI> is required');
    printUsage();
    exit(1);
  }

  pubkey ??= '';

  // Setup signal handler for Ctrl+C
  ProcessSignal.sigint.watch().listen((_) async {
    print('\n\n  [CTRL+C] Cleaning up...');
    if (_activeSessionId != null && _activeClient != null) {
      await disconnectSession(
        client: _activeClient!,
        apiKey: _activeApiKey!,
        pubkey: _activePubkey!,
        sessionId: _activeSessionId!,
      );
      print('  Session disconnected.');
    }
    _activeClient?.close();
    exit(1);
  });

  final client = http.Client();
  final results = <ScenarioResult>[];

  printHeader(apiKey, pubkey, lat, lon, dataLat, dataLon, who, scenario);

  // Scenario 1: Rapid fire (reproduce the bug)
  if (scenario == 'all' || scenario == '1') {
    printScenarioHeader(
      '1 - Rapid Fire',
      'Batch=50, no delay. Should reproduce failure at ~batch 4.',
    );
    results.add(await runScenario(
      client: client,
      apiKey: apiKey,
      pubkey: pubkey,
      lat: lat,
      lon: lon,
      dataLat: dataLat,
      dataLon: dataLon,
      who: who,
      contactUri: contactUri,
      name: 'Rapid Fire',
      description: 'batch=50, no delay',
      batchSize: 50,
      maxBatches: 10,
      interBatchDelay: Duration.zero,
    ));
    print('');
  }

  // Scenario 2: Throttled (test rate limit hypothesis)
  if (scenario == 'all' || scenario == '2') {
    printScenarioHeader(
      '2 - Throttled',
      'Batch=50, 3s delay between batches. Tests rate limit hypothesis.',
    );
    results.add(await runScenario(
      client: client,
      apiKey: apiKey,
      pubkey: pubkey,
      lat: lat,
      lon: lon,
      dataLat: dataLat,
      dataLon: dataLon,
      who: who,
      contactUri: contactUri,
      name: 'Throttled',
      description: 'batch=50, 3s delay',
      batchSize: 50,
      maxBatches: 10,
      interBatchDelay: const Duration(seconds: 3),
    ));
    print('');
  }

  // Scenario 3: Batch size sweep
  if (scenario == 'all' || scenario == '3') {
    for (final size in [10, 25, 100]) {
      final maxBatches = (200 / size).ceil();
      printScenarioHeader(
        '3 - Batch Size $size',
        'Batch=$size, no delay, up to $maxBatches batches (${size * maxBatches} items).',
      );
      results.add(await runScenario(
        client: client,
        apiKey: apiKey,
        pubkey: pubkey,
        lat: lat,
        lon: lon,
        dataLat: dataLat,
        dataLon: dataLon,
        who: who,
        contactUri: contactUri,
        name: 'Batch Size $size',
        description: 'batch=$size, no delay',
        batchSize: size,
        maxBatches: maxBatches,
        interBatchDelay: Duration.zero,
      ));
      print('');
    }
  }

  // Scenario 4: Out-of-zone ping data
  if (scenario == 'all' || scenario == '4') {
    // Auth from in-zone coords, but ping data from far outside any zone
    const oozLat = 50.0;
    const oozLon = -90.0;
    printScenarioHeader(
      '4 - Out-of-Zone Data',
      'Auth at ($lat, $lon) but ping coords at ($oozLat, $oozLon). Tests zone mismatch.',
    );
    results.add(await runScenario(
      client: client,
      apiKey: apiKey,
      pubkey: pubkey,
      lat: lat,
      lon: lon,
      dataLat: dataLat ?? oozLat,
      dataLon: dataLon ?? oozLon,
      who: who,
      contactUri: contactUri,
      name: 'Out-of-Zone Data',
      description: 'auth in-zone, data out-of-zone',
      batchSize: 50,
      maxBatches: 3,
      interBatchDelay: Duration.zero,
    ));
    print('');
  }

  printSummary(results);
  client.close();
}

void printUsage() {
  print('''
MeshMapper Offline Upload Diagnostic

Reproduces server-side session invalidation during offline batch uploads.
Runs four scenarios to determine if the server has an item count limit,
rate limit, zone mismatch issue, or other constraint.

Usage:
  dart run bin/test_offline_upload.dart --key=<API_KEY> --pubkey=<DEVICE_PUB_KEY> [options]

Required:
  --key=<value>           MeshMapper API key
  --pubkey=<value>        Registered device public key (hex)

Optional:
  --contact-uri=<value>   Signed contact URI (if device not yet registered)
  --lat=<value>           Auth latitude (default: 45.3215)
  --lon=<value>           Auth longitude (default: -75.6693)
  --data-lat=<value>      Ping data latitude (default: same as --lat)
  --data-lon=<value>      Ping data longitude (default: same as --lon)
  --who=<value>           Device name (default: DIAG-TEST)
  --scenario=<1|2|3|4|all>  Run specific scenario (default: all)

Scenarios:
  1  Rapid fire       Batch=50, no delay, 10 batches. Reproduces the bug.
  2  Throttled        Batch=50, 3s delay, 10 batches. Tests rate limit.
  3  Batch sweep      Batch=10/25/100, no delay. Tests per-batch vs cumulative limit.
  4  Out-of-zone data Auth in-zone, ping coords out-of-zone. Tests zone mismatch.

Examples:
  dart run bin/test_offline_upload.dart --key=abc123 --pubkey=deadbeef01234567
  dart run bin/test_offline_upload.dart --key=abc123 --pubkey=deadbeef01234567 --scenario=1
  dart run bin/test_offline_upload.dart --key=abc123 --contact-uri="meshcore://..." --scenario=2
  dart run bin/test_offline_upload.dart --key=abc123 --pubkey=deadbeef01234567 --scenario=4 --data-lat=50.0 --data-lon=-90.0
''');
}
