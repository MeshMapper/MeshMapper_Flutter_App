import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/services/network_state_service.dart';

import 'test_network_state_source.dart';

void main() {
  const constrained = NetworkState(isConstrained: true, isSatellite: true);

  ApiService unresponsiveApi(NetworkState state) => ApiService(
        networkState: TestNetworkStateSource(state),
        client: MockClient(
          (_) => Completer<http.Response>().future,
        ),
      );

  test('ordinary network auth times out after ten seconds', () {
    fakeAsync((async) {
      final api = unresponsiveApi(NetworkState.unconstrained);
      var completed = false;
      api
          .requestAuth(
            reason: 'connect',
            publicKey: 'AB',
            lat: 45.27,
            lon: -75.78,
          )
          .whenComplete(() => completed = true);
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 9));
      expect(completed, isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(completed, isTrue);

      api.dispose();
    });
  });

  test('constrained network auth times out after thirty seconds', () {
    fakeAsync((async) {
      final api = unresponsiveApi(constrained);
      var completed = false;
      api
          .requestAuth(
            reason: 'connect',
            publicKey: 'AB',
            lat: 45.27,
            lon: -75.78,
          )
          .whenComplete(() => completed = true);
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 29));
      expect(completed, isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(completed, isTrue);

      api.dispose();
    });
  });
}
