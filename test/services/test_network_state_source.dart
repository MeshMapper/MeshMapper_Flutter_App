import 'dart:async';

import 'package:mesh_mapper/services/network_state_service.dart';

class TestNetworkStateSource implements NetworkStateSource {
  final StreamController<NetworkState> _controller =
      StreamController<NetworkState>.broadcast(sync: true);

  TestNetworkStateSource([this.current = NetworkState.unconstrained]);

  @override
  NetworkState current;

  @override
  Stream<NetworkState> get stream => _controller.stream;

  void emit(NetworkState state) {
    current = state;
    _controller.add(state);
  }

  Future<void> close() => _controller.close();
}
