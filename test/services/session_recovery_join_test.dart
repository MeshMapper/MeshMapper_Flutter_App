import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/session_recovery_join.dart';

/// A group handoff drains the queue under the old session. If that session
/// has lapsed, the drain's upload comes back session_expired and asks for a
/// recovery; handing it the handoff's own future deadlocked both (TX held for
/// good, the queue stuck uploading). The rule here is what prevents that.
void main() {
  test('a handoff holding the slot answers every joiner superseded', () {
    expect(
      resolveSessionRecoveryJoin(
          groupHandoffOwnsSlot: true, recoveryInFlight: true),
      SessionRecoveryJoin.supersededByHandoff,
      reason: 'the in-flight future is the handoff itself',
    );
    expect(
      resolveSessionRecoveryJoin(
          groupHandoffOwnsSlot: true, recoveryInFlight: false),
      SessionRecoveryJoin.supersededByHandoff,
      reason: 'the flag outranks the slot, which is set a moment later',
    );
  });

  test('a running recovery is joined, otherwise one is started', () {
    expect(
      resolveSessionRecoveryJoin(
          groupHandoffOwnsSlot: false, recoveryInFlight: true),
      SessionRecoveryJoin.joinInFlight,
    );
    expect(
      resolveSessionRecoveryJoin(
          groupHandoffOwnsSlot: false, recoveryInFlight: false),
      SessionRecoveryJoin.startNew,
    );
  });
}
