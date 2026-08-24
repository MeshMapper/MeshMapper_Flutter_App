import 'package:flutter_test/flutter_test.dart';

import 'package:mesh_mapper/services/api_queue_service.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// Regression tests for the silently-dropped TX pings behind server issues
/// #108 and #123.
///
/// A TX wire tag is `wireTagEncode(session_id, ping_counter, key)`. The server
/// recomputes it from the session the batch is POSTed under and skips the entry
/// outright on a mismatch (`wardrive-api.php`, action=wire_tag_mismatch) while
/// still returning success, so the app prunes the item as uploaded and the
/// ping is gone with no error anywhere.
///
/// That means a tag is only ever valid under the session that minted it. Two
/// app paths carried a tag across a session boundary; prod access.log for
/// 2026-08-23 shows 102 of 111 mismatches on `offline-*` sessions (the first
/// case) and 9 on live ones (the second).
///
/// Such an item is now DROPPED, not un-tagged. It is ~0.2% of TX pings, and
/// every alternative is worse: keeping the tag is a silent loss plus a warn,
/// and stripping it sends the ping down the server coords path where, with no
/// status-4 WAIT row left to join, it inserts as DEAD(3) and paints a grey
/// "dead" cell on the map for a ping that was actually heard.
void main() {
  ApiQueueService newQueue() =>
      // No init(), so Hive stays closed and _safeWrite falls back to the
      // in-memory queue. That exercises the same enqueue/extract code paths
      // without needing a Hive box in the test harness.
      ApiQueueService(apiService: ApiService());

  Future<void> enqueueTaggedTx(ApiQueueService queue) => queue.enqueueTx(
        latitude: 45.26974,
        longitude: -75.77746,
        heardRepeats: '4e(12.25)',
        timestamp: 1750000000,
        externalAntenna: false,
        pingCounter: 13,
        wireTag: 'MM:YVNPAr5OIw',
      );

  Future<void> enqueueRx(ApiQueueService queue) => queue.enqueueRx(
        latitude: 45.26974,
        longitude: -75.77746,
        heardRepeats: '4e(12.25)',
        timestamp: 1750000000,
        repeaterId: '4e',
        externalAntenna: false,
      );

  group('tagged pings never outlive the session that minted them', () {
    test('offline preservation drops them (#108, 92% of prod mismatches)',
        () async {
      final queue = newQueue();
      await enqueueTaggedTx(queue);
      await enqueueRx(queue);

      // handleSessionError() snapshots the queue here and hands it to
      // OfflineSessionService, which re-uploads it later under a brand new
      // `offline-YYYYMMDD-NNNN` session id.
      final preserved = await queue.extractAllAsJson();

      expect(preserved, hasLength(1),
          reason: 'the tagged TX ping is undeliverable under any offline '
              'session, so it must not be preserved at all');
      expect(preserved.single['type'], 'RX',
          reason: 'untagged observations still preserve exactly as before');
      expect(preserved.any((p) => p['wire_tag'] != null), isFalse);
      expect(preserved.any((p) => p['ping_counter'] != null), isFalse);
    });

    test('a new session id drops what is already queued (#123, live sessions)',
        () async {
      final queue = newQueue();
      await enqueueTaggedTx(queue);
      await enqueueRx(queue);

      // Auto-reconnect deliberately preserves the queue, but /auth only reuses
      // a session while it is status=1 and unexpired. Otherwise a new
      // session_id comes back and everything already queued is stale.
      await queue.dropStaleTaggedItems();

      final pending = await queue.extractAllAsJson();
      expect(pending, hasLength(1));
      expect(pending.single['type'], 'RX',
          reason: 'RX carries no tag, so a new session does not invalidate it');
    });

    test('an untagged queue is left completely alone', () async {
      final queue = newQueue();
      await enqueueRx(queue);

      await queue.dropStaleTaggedItems();

      final pending = await queue.extractAllAsJson();
      expect(pending, hasLength(1));
      expect(pending.single['type'], 'RX');
      expect(pending.single['heard_repeats'], '4e(12.25)');
    });
  });
}
