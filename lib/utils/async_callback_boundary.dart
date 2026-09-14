import 'dart:async';

/// Runs an async callback from a void callback boundary without exposing a
/// rejected Future to the event loop.
void runAsyncCallbackSafely(
  Future<void> Function() operation, {
  required void Function(Object error, StackTrace stackTrace) onError,
}) {
  unawaited(
      Future<void>.sync(operation).catchError((Object error, StackTrace stack) {
    onError(error, stack);
  }));
}
