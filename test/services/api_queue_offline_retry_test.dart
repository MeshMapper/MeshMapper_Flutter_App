import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_queue_service.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// Regression tests for #437: driving without cell coverage loses samples.
///
/// A phone with no signal fails the POST at the socket, so the queue can't
/// tell "the server rejected this" from "I couldn't reach the server". Both
/// come back as UploadResult.retryable and both burn a slot on the 5-attempt
/// retry ladder. Once an item hits _maxRetries it is filtered out of every
/// future batch, nothing ever resets the counter, and `failedItems` (the only
/// thing that can still see it) has no callers, so the ping is stranded in
/// Hive for good.
void main() {
  /// An ApiService holding a live session whose /wardrive posts all fail the
  /// way an out-of-coverage phone fails: the socket never connects.
  Future<({ApiService api, List<String> wardrivePosts})> offlineApi() async {
    final wardrivePosts = <String>[];
    final api = ApiService(client: MockClient((request) async {
      if (request.url.path.endsWith('/auth')) {
        return http.Response(
          json.encode({
            'success': true,
            'session_id': 'yow-20260824-0001',
            'tx_allowed': true,
            'rx_allowed': true,
            'expires_at': DateTime.now()
                .add(const Duration(hours: 1))
                .toUtc()
                .toIso8601String(),
          }),
          200,
        );
      }
      wardrivePosts.add(request.url.path);
      throw const SocketException('Network is unreachable');
    }));

    await api.requestAuth(
      reason: 'connect',
      publicKey: 'ab' * 32,
      lat: 45.26974,
      lon: -75.77746,
      accuracyMeters: 5,
    );

    return (api: api, wardrivePosts: wardrivePosts);
  }

  Future<void> enqueueRx(ApiQueueService queue) => queue.enqueueRx(
        latitude: 45.26974,
        longitude: -75.77746,
        heardRepeats: '4e(12.25)',
        timestamp: 1750000000,
        repeaterId: '4e',
        externalAntenna: false,
      );

  // Both of these fail today. They describe the behaviour #437 needs, and are
  // skipped so the suite stays green until that fix lands. Un-skip with it.
  const openBug = 'unfixed: #437';

  test('an unreachable network must not consume the retry ladder', () async {
    final harness = await offlineApi();
    // No init(), so Hive stays closed and the service uses its in-memory
    // queue. Same enqueue/upload code paths, no Hive box needed.
    final queue = ApiQueueService(apiService: harness.api);
    await enqueueRx(queue);

    await queue.flushQueue();
    await queue.flushQueue();

    expect(
      harness.wardrivePosts, hasLength(2),
      reason: 'both flushes should have tried the network. If the second was '
          'skipped, the first failure started the backoff ladder, which means '
          'a dead socket is being counted as a server rejection',
    );
  }, skip: openBug);

  test('a ping is stranded by a 30 second outage', () async {
    final harness = await offlineApi();
    final queue = ApiQueueService(apiService: harness.api);
    await enqueueRx(queue);

    // Walk the real backoff ladder: 1s, 2s, 4s, 8s, 16s. Real time, because
    // isReadyForRetry reads DateTime.now() directly.
    for (var i = 0; i < 6; i++) {
      await queue.flushQueue();
      await Future<void>.delayed(Duration(seconds: 1 << i));
    }

    expect(queue.queueSize, 1, reason: 'the sample is still held in the queue');
    expect(
      queue.failedItems, isEmpty,
      reason: 'nothing in the app ever reads failedItems or resets retryCount, '
          'so an item that lands here is coverage the user will never get',
    );
  }, timeout: const Timeout(Duration(minutes: 2)), skip: openBug);
}
