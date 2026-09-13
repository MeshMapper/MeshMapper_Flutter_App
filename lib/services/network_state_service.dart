import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../utils/debug_logger_io.dart';

/// Snapshot of the device's active default network as reported by Android's
/// constrained-networks API. On non-Android platforms (and on Android below
/// API 36, which predates the API) this is always "not constrained".
class NetworkState {
  final bool isConstrained;
  final bool isSatellite;

  const NetworkState({required this.isConstrained, required this.isSatellite});

  static const unconstrained =
      NetworkState(isConstrained: false, isSatellite: false);

  @override
  String toString() =>
      'NetworkState(isConstrained: $isConstrained, isSatellite: $isSatellite)';
}

/// Read-only network state used by services that adapt request pacing.
abstract interface class NetworkStateSource {
  NetworkState get current;
  Stream<NetworkState> get stream;
}

/// Surfaces Android's bandwidth-constrained/satellite network signal to Dart.
///
/// Routed through an EventChannel on `meshmapper/network_state`, backed by
/// MeshMapperNetworkService.kt (registers a ConnectivityManager network
/// callback and reports whether NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED is
/// absent or TRANSPORT_SATELLITE is present):
/// https://developer.android.com/develop/connectivity/satellite/constrained-networks
///
/// Callers that want to adapt heavy network usage (batch uploads, large
/// downloads) should watch [stream] or check [current].
class NetworkStateService implements NetworkStateSource {
  static const _channel = EventChannel('meshmapper/network_state');

  final _controller = StreamController<NetworkState>.broadcast();

  NetworkState _current = NetworkState.unconstrained;

  NetworkStateService._() {
    if (Platform.isAndroid) _startListening();
  }
  static final NetworkStateService instance = NetworkStateService._();

  /// Most recently reported network state. Defaults to "not constrained"
  /// until the first native event arrives, and stays there on non-Android
  /// platforms (this API is Android-only).
  @override
  NetworkState get current => _current;

  /// Broadcast stream of network state changes. Never emits on platforms
  /// other than Android.
  @override
  Stream<NetworkState> get stream => _controller.stream;

  void _startListening() {
    _channel.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        final state = NetworkState(
          isConstrained: event['constrained'] as bool? ?? false,
          isSatellite: event['satellite'] as bool? ?? false,
        );
        _current = state;
        _controller.add(state);
        if (state.isConstrained) {
          debugLog('[NETWORK] Constrained network detected: $state');
        }
      },
      onError: (e) => debugWarn('[NETWORK] State stream error: $e'),
    );
  }
}
