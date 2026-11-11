/// Counts radio drops that come right after an auto-reconnect succeeded.
///
/// Every drop starts a fresh reconnect budget and every success clears it, so
/// a link that reconnects and then drops again within seconds (a radio on a
/// dying battery, say) looped for as long as the user let it, with no alert.
/// After [maxFlaps] such drops in a row the provider gives up instead. A
/// connection that stays up longer than [window] before it drops resets the
/// count, so ordinary range drops on a long drive never add up.
class ReconnectFlapGuard {
  ReconnectFlapGuard({
    this.window = const Duration(seconds: 30),
    this.maxFlaps = 3,
  });

  /// A drop at most this long after a reconnect success counts as a flap.
  final Duration window;

  /// Flaps in a row that end the reconnecting.
  final int maxFlaps;

  DateTime? _lastSuccessAt;
  int _flaps = 0;

  /// Quick drops counted so far.
  int get flaps => _flaps;

  /// An auto-reconnect reached a connected radio.
  void onReconnectSuccess(DateTime now) => _lastSuccessAt = now;

  /// The radio dropped. True when this drop is the [maxFlaps]th in a row to
  /// follow a reconnect within [window]: stop reconnecting.
  bool onDrop(DateTime now) {
    final last = _lastSuccessAt;
    _lastSuccessAt = null;
    if (last != null && now.difference(last) <= window) {
      _flaps++;
    } else {
      _flaps = 0;
    }
    return _flaps >= maxFlaps;
  }

  /// The radio session ended (a user disconnect or an abandoned reconnect).
  void reset() {
    _flaps = 0;
    _lastSuccessAt = null;
  }
}
