import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_queue_service.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/services/network_state_service.dart';

import 'test_network_state_source.dart';

/// A group handoff releases the old session while the radio stays up, so the
/// queue's own timers must not start a batch under that session in the
/// meantime (the server answers a batch that lands after the close with
/// bad_session, which ends the connection), and an upload already on the
/// wire must be answered before the release goes out.
void main() {
  ({
    ApiQueueService queue,
    ApiService api,
    TestNetworkStateSource network,
    List<DateTime> uploads,
  }) build({Duration uploadDelay = Duration.zero}) {
    final network = TestNetworkStateSource(NetworkState.unconstrained);
    final uploads = <DateTime>[];
    final api = ApiService(
      networkState: network,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth')) {
          return http.Response(
            json.encode({
              'success': true,
              'session_id': 'YOW-20260912-0001',
              'tx_allowed': true,
              'rx_allowed': true,
            }),
            200,
          );
        }
        if (uploadDelay > Duration.zero) {
          await Future<void>.delayed(uploadDelay);
        }
        uploads.add(DateTime.now());
        return http.Response(json.encode({'success': true}), 200);
      }),
    );
    final queue = ApiQueueService(apiService: api, networkState: network);
    return (queue: queue, api: api, network: network, uploads: uploads);
  }

  void connect(FakeAsync async, ApiService api, ApiQueueService queue) {
    api.requestAuth(
      reason: 'connect',
      publicKey: 'AB',
      lat: 45.27,
      lon: -75.78,
    );
    // Starts the periodic batch timer, as the real connect does.
    queue.clearBeforeConnect();
    async.flushMicrotasks();
  }

  void enqueueTx(FakeAsync async, ApiQueueService queue) {
    queue.enqueueTx(
      latitude: 45.27,
      longitude: -75.78,
      heardRepeats: '4e(12.25)',
      timestamp: 1789200000,
      externalAntenna: false,
    );
    async.flushMicrotasks();
  }

  void dispose(
      ({
        ApiQueueService queue,
        ApiService api,
        TestNetworkStateSource network,
        List<DateTime> uploads,
      }) built) {
    built.queue.dispose();
    built.api.dispose();
    built.network.close();
  }

  test('a pause holds the ping flush and the batch timer until the resume',
      () {
    fakeAsync((async) {
      final built = build();
      connect(async, built.api, built.queue);
      enqueueTx(async, built.queue);

      built.queue.pauseScheduledUploads();
      expect(built.queue.scheduledUploadsPaused, isTrue);
      async.elapse(const Duration(seconds: 40));
      expect(built.uploads, isEmpty,
          reason: 'neither the 5 s ping flush nor the 15 s batch timer '
              'may fire while paused');

      built.queue.resumeScheduledUploads();
      expect(built.queue.scheduledUploadsPaused, isFalse);
      async.elapse(const Duration(seconds: 5));
      expect(built.uploads, hasLength(1),
          reason: 'the resume schedules the flush the pause interrupted');

      dispose(built);
    });
  });

  test('an enqueue during the pause is flushed once resumed', () {
    fakeAsync((async) {
      final built = build();
      connect(async, built.api, built.queue);

      built.queue.pauseScheduledUploads();
      enqueueTx(async, built.queue);
      async.elapse(const Duration(seconds: 40));
      expect(built.uploads, isEmpty);

      built.queue.resumeScheduledUploads();
      async.elapse(const Duration(seconds: 5));
      expect(built.uploads, hasLength(1));

      dispose(built);
    });
  });

  test('an explicit upload still runs while paused', () {
    fakeAsync((async) {
      final built = build();
      connect(async, built.api, built.queue);

      built.queue.pauseScheduledUploads();
      enqueueTx(async, built.queue);
      built.queue.forceUploadWithHoldWait();
      async.flushMicrotasks();
      expect(built.uploads, hasLength(1),
          reason: 'the handoff drains the queue while holding the pause');

      dispose(built);
    });
  });

  test('a disconnect during the pause drops it, so the resume restarts nothing',
      () {
    fakeAsync((async) {
      final built = build();
      connect(async, built.api, built.queue);

      built.queue.pauseScheduledUploads();
      built.queue.clearOnDisconnect();
      async.flushMicrotasks();
      expect(built.queue.scheduledUploadsPaused, isFalse);

      built.queue.resumeScheduledUploads();
      async.elapse(const Duration(seconds: 60));
      expect(built.uploads, isEmpty);

      dispose(built);
    });
  });

  test('a repeated pause or resume is a no-op', () {
    fakeAsync((async) {
      final built = build();
      built.queue.resumeScheduledUploads();
      expect(built.queue.scheduledUploadsPaused, isFalse);
      built.queue.pauseScheduledUploads();
      built.queue.pauseScheduledUploads();
      expect(built.queue.scheduledUploadsPaused, isTrue);
      built.queue.resumeScheduledUploads();
      built.queue.resumeScheduledUploads();
      expect(built.queue.scheduledUploadsPaused, isFalse);
      dispose(built);
    });
  });

  test('waiting for an upload answers at once when idle, waits for one on '
      'the wire, and gives up at its bound', () {
    fakeAsync((async) {
      final built = build(uploadDelay: const Duration(seconds: 3));
      connect(async, built.api, built.queue);

      bool? idle;
      built.queue.waitForUploadToFinish().then((v) => idle = v);
      async.flushMicrotasks();
      expect(idle, isTrue, reason: 'nothing in flight');

      enqueueTx(async, built.queue);
      built.queue.forceUploadWithHoldWait();
      async.flushMicrotasks();
      expect(built.queue.isUploading, isTrue);

      bool? bounded;
      built.queue
          .waitForUploadToFinish(limit: const Duration(seconds: 1))
          .then((v) => bounded = v);
      async.elapse(const Duration(seconds: 1));
      expect(bounded, isFalse, reason: 'still on the wire at the bound');
      expect(built.queue.isUploading, isTrue);

      bool? finished;
      built.queue.waitForUploadToFinish().then((v) => finished = v);
      async.elapse(const Duration(seconds: 2));
      expect(finished, isTrue, reason: 'the upload landed inside the bound');
      expect(built.queue.isUploading, isFalse);
      expect(built.uploads, hasLength(1));

      dispose(built);
    });
  });
}
