import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/buffer_utils.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';
import 'package:mesh_mapper/services/meshcore/scope_lease.dart';

import 'scope_test_support.dart';

/// Manage waits while scope discovery owns the radio: a lease, or a reply
/// still owed for a command that lease wrote. The flag has to reach the
/// provider when it flips back, or the button stays disabled until some
/// unrelated control change, and ordinary traffic (the pollers, a flood
/// scope write) must neither set it nor fire the notification.
void main() {
  final key = scopeKey(0xAB);
  final flood16 = Uint8List(16);

  ContactRecord record(Uint8List payload) =>
      ContactRecord.parse(BufferReader(payload));

  ({List<bool> seen}) watch(MeshCoreConnection conn) {
    final seen = <bool>[];
    conn.onScopeRadioBusyChanged = () => seen.add(conn.isScopeRadioBusy);
    return (seen: seen);
  }

  /// A lease whose restore write is still owed at the 4 s release.
  ScopeLease releasedWithDebt(FakeAsync async, ScopeRadio radio,
      MeshCoreConnection conn) {
    final lease = grant(async, conn)!;
    lease.restore(record(scopeContactPayload(pubkey: key)));
    async.elapse(const Duration(seconds: 4));
    expect(lease.active, isFalse);
    return lease;
  }

  test('reply debt from ordinary traffic is not scope debt, and never '
      'notifies', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      final w = watch(conn);
      for (var i = 0; i < 20; i++) {
        conn.setFloodScope(flood16);
        conn.getBatteryVoltage();
      }
      async.flushMicrotasks();
      expect(conn.repliesOwedCount, 40);
      expect(conn.hasScopeReplyDebt, isFalse);
      expect(conn.isScopeRadioBusy, isFalse);
      async.elapse(const Duration(seconds: 11));
      expect(w.seen, isEmpty);
    });
  });

  test('busy while the lease is held, still busy on release with a reply '
      'owed, and notified once when that reply lands', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      final w = watch(conn);
      releasedWithDebt(async, radio, conn);
      expect(conn.hasScopeReplyDebt, isTrue);
      expect(conn.isScopeRadioBusy, isTrue);
      expect(w.seen, [true], reason: 'one change: idle to busy at the grant');

      radio.emit([ResponseCodes.ok]);
      async.flushMicrotasks();
      expect(conn.isScopeRadioBusy, isFalse);
      expect(w.seen, [true, false]);
    });
  });

  test('scope debt expiring notifies once', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      final w = watch(conn);
      releasedWithDebt(async, radio, conn);
      expect(w.seen, [true]);
      async.elapse(const Duration(seconds: 7));
      expect(conn.hasScopeReplyDebt, isFalse);
      expect(w.seen, [true, false]);
    });
  });

  test('a lease released with nothing owed notifies both flips', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      final w = watch(conn);
      final lease = grant(async, conn)!;
      lease.release();
      async.flushMicrotasks();
      expect(conn.isScopeRadioBusy, isFalse);
      expect(w.seen, [true, false]);
    });
  });

  test('disconnect clears scope debt and notifies', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      final w = watch(conn);
      releasedWithDebt(async, radio, conn);
      conn.disconnect();
      async.flushMicrotasks();
      expect(conn.isScopeRadioBusy, isFalse);
      expect(w.seen.last, isFalse);
    });
  });
}
