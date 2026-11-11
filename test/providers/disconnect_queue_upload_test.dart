import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';

/// The bound on the queue upload a Disconnect or Close App tap makes before
/// it releases the session. The tap used to clear the queue without sending
/// it, so a TX still in its 5 s upload wait or an RX batch inside its 15 s
/// window was lost on almost every drive that ended with Stop and then
/// Disconnect. The upload must never hold the teardown open or abandon it.
void main() {
  test('an upload that finishes is reported done', () async {
    var ran = false;
    expect(await uploadQueueBounded(() async => ran = true), isTrue);
    expect(ran, isTrue);
  });

  test('a stalled upload does not hold the disconnect open', () async {
    final stalled = Completer<void>();
    addTearDown(() {
      if (!stalled.isCompleted) stalled.complete();
    });

    expect(
      await uploadQueueBounded(
        () => stalled.future,
        limit: const Duration(milliseconds: 20),
      ),
      isFalse,
      reason: 'the disconnect clears the queue and releases the session '
          'once the bound runs out',
    );
  });

  test('a failed upload does not abandon the disconnect', () async {
    expect(
      await uploadQueueBounded(() async => throw StateError('no network')),
      isFalse,
    );
  });

  test('the bound keeps the Disconnect tap quick', () {
    expect(disconnectQueueUploadTimeout, const Duration(seconds: 5));
  });
}
