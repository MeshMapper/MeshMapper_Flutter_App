import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';

/// The bound on the wait that disconnect() and auto-reconnect put on an
/// in-flight session recovery. The recovery is two network legs, so a stalled
/// one used to hold the whole teardown open with the UI already reading
/// Disconnecting and the radio still up.
void main() {
  test('a recovery that settles is waited for', () async {
    expect(await awaitSessionRecoveryBounded(Future<void>.value()), isTrue);
  });

  test('a stalled recovery does not hold the teardown open', () async {
    final stalled = Completer<void>();
    addTearDown(() {
      if (!stalled.isCompleted) stalled.complete();
    });

    expect(
      await awaitSessionRecoveryBounded(
        stalled.future,
        limit: const Duration(milliseconds: 20),
      ),
      isFalse,
      reason: 'the teardown carries on and the recovery finds itself '
          'superseded on its own',
    );
  });

  test('a recovery that fails after the wait gave up is not rethrown',
      () async {
    final stalled = Completer<void>();

    expect(
      await awaitSessionRecoveryBounded(
        stalled.future,
        limit: const Duration(milliseconds: 20),
      ),
      isFalse,
    );

    // The teardown is long past this point. The failure must not escape into
    // the zone as an unhandled error.
    stalled.completeError(StateError('re-authentication failed late'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  test('a recovery that fails while the wait is running still reports it',
      () async {
    await expectLater(
      awaitSessionRecoveryBounded(
        Future<void>.error(StateError('re-authentication failed')),
        limit: const Duration(seconds: 5),
      ),
      throwsStateError,
    );
  });

  test('the shipped bound is 15 seconds', () {
    expect(sessionRecoveryWaitTimeout, const Duration(seconds: 15));
  });
}
