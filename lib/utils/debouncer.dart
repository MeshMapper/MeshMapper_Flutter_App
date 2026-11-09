import 'dart:async';

/// Runs the latest scheduled action once things have been quiet for [delay].
///
/// Each [schedule] replaces the pending action and restarts the wait, so a
/// burst of changes ends in one call with the newest action. [flush] runs a
/// pending action now (used when the app goes to the background, where the
/// process may be killed before the timer fires); [cancel] drops it.
class Debouncer {
  Debouncer(this.delay);

  final Duration delay;
  Timer? _timer;
  void Function()? _pending;

  /// True while an action is waiting to run.
  bool get isPending => _pending != null;

  void schedule(void Function() action) {
    _pending = action;
    _timer?.cancel();
    _timer = Timer(delay, flush);
  }

  void flush() {
    _timer?.cancel();
    _timer = null;
    final action = _pending;
    _pending = null;
    action?.call();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }
}
