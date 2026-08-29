import 'dart:async';

/// Runs queued async tasks strictly one at a time, in submission order.
///
/// MapLibre style mutations (add/remove source and layer) are multi-await
/// sequences guarded by Dart-side "ready" flags. Two flows interleaving
/// between a flag check and the final await double-add or half-remove native
/// objects: the zone-transfer overlay rebuild racing the post-upload patch
/// refresh produced `CannotAddSourceException: Source meshmapper-coverage-patch
/// already exists` at a region boundary (#495). Funnelling every mutating flow
/// through one gate makes each flow atomic with respect to the others.
///
/// A task's error propagates to its own submitter only; the queue keeps
/// draining behind it. Do NOT await a nested [run] from inside a running task:
/// it is queued after the current task and awaiting it would deadlock.
class SerialTaskGate {
  Future<void> _tail = Future.value();

  /// Queue [task] behind everything already submitted and return its result.
  Future<T> run<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}
