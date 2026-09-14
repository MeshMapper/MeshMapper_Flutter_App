import 'dart:async';

typedef AsyncOperation = Future<void> Function();

/// Runs one async operation at a time and coalesces re-entrant requests.
///
/// A request received while an operation is active replaces the single
/// pending follow-up with the newest operation. If the active operation fails,
/// the pending follow-up still runs before the failure is reported.
class CoalescedAsyncRunner {
  Future<void>? _active;
  AsyncOperation? _pending;
  bool _running = false;

  bool get isRunning => _running;

  Future<void> run(AsyncOperation operation) {
    if (_running) {
      _pending = operation;
      return _active!;
    }

    _running = true;
    final completion = Completer<void>();
    _active = completion.future;
    _drain(operation, completion);
    return completion.future;
  }

  Future<void> _drain(
    AsyncOperation operation,
    Completer<void> completion,
  ) async {
    Object? firstError;
    StackTrace? firstStack;
    var failed = false;

    try {
      while (true) {
        try {
          await operation();
        } catch (error, stack) {
          if (!failed) {
            failed = true;
            firstError = error;
            firstStack = stack;
          }
        }

        final next = _pending;
        _pending = null;
        if (next == null) break;
        operation = next;
      }

      if (failed) {
        completion.completeError(firstError!, firstStack!);
      } else {
        completion.complete();
      }
    } finally {
      _pending = null;
      _active = null;
      _running = false;
    }
  }
}
