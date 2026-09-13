import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_queue_service.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/services/network_state_service.dart';

import 'test_network_state_source.dart';

void main() {
  const constrained = NetworkState(isConstrained: true, isSatellite: true);

  ({
    ApiQueueService queue,
    ApiService api,
    TestNetworkStateSource network,
    List<DateTime> uploads,
  }) build(NetworkState initial) {
    final network = TestNetworkStateSource(initial);
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
        uploads.add(DateTime.now());
        return http.Response(json.encode({'success': true}), 200);
      }),
    );
    final queue = ApiQueueService(
      apiService: api,
      networkState: network,
    );
    return (queue: queue, api: api, network: network, uploads: uploads);
  }

  void connect(FakeAsync async, ApiService api) {
    api.requestAuth(
      reason: 'connect',
      publicKey: 'AB',
      lat: 45.27,
      lon: -75.78,
    );
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

  void enqueueOtherRoutineItems(FakeAsync async, ApiQueueService queue) {
    queue.enqueueDisc(
      latitude: 45.27,
      longitude: -75.78,
      repeaterId: '4e',
      nodeType: 'repeater',
      localSnr: 12.25,
      localRssi: -95,
      remoteSnr: 8.5,
      pubkeyFull: 'AB',
      timestamp: 1789200001,
      externalAntenna: false,
    );
    queue.enqueueTrace(
      latitude: 45.27,
      longitude: -75.78,
      repeaterId: '4e',
      localSnr: 12.25,
      localRssi: -95,
      remoteSnr: 8.5,
      timestamp: 1789200002,
      externalAntenna: false,
    );
    queue.enqueueDiscDrop(
      latitude: 45.27,
      longitude: -75.78,
      timestamp: 1789200003,
      externalAntenna: false,
    );
    queue.enqueueDefer(
      latitude: 45.27,
      longitude: -75.78,
      timestamp: 1789200004,
      held: 'tx',
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

  test('ordinary network uploads five seconds after a ping', () {
    fakeAsync((async) {
      final built = build(NetworkState.unconstrained);
      connect(async, built.api);
      enqueueTx(async, built.queue);

      async.elapse(const Duration(seconds: 4));
      expect(built.uploads, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(built.uploads, hasLength(1));

      dispose(built);
    });
  });

  test('constrained network paces every routine item at sixty seconds', () {
    fakeAsync((async) {
      final built = build(constrained);
      connect(async, built.api);
      enqueueTx(async, built.queue);
      enqueueOtherRoutineItems(async, built.queue);

      async.elapse(const Duration(seconds: 59));
      expect(built.uploads, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(built.uploads, hasLength(1));

      dispose(built);
    });
  });

  test('becoming constrained postpones a pending ping upload', () {
    fakeAsync((async) {
      final built = build(NetworkState.unconstrained);
      connect(async, built.api);
      enqueueTx(async, built.queue);

      async.elapse(const Duration(seconds: 2));
      built.network.emit(constrained);
      async.elapse(const Duration(seconds: 59));
      expect(built.uploads, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(built.uploads, hasLength(1));

      dispose(built);
    });
  });

  test('leaving a constrained network advances a pending ping upload', () {
    fakeAsync((async) {
      final built = build(constrained);
      connect(async, built.api);
      enqueueTx(async, built.queue);

      async.elapse(const Duration(seconds: 10));
      built.network.emit(NetworkState.unconstrained);
      async.elapse(const Duration(seconds: 4));
      expect(built.uploads, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(built.uploads, hasLength(1));

      dispose(built);
    });
  });

  test('duplicate constrained state does not postpone a pending upload', () {
    fakeAsync((async) {
      final built = build(constrained);
      connect(async, built.api);
      enqueueTx(async, built.queue);

      async.elapse(const Duration(seconds: 30));
      built.network.emit(constrained);
      async.elapse(const Duration(seconds: 29));
      expect(built.uploads, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(built.uploads, hasLength(1));

      dispose(built);
    });
  });
}
