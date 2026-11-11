import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/disc_tracker.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';

import 'fake_companion_transport.dart';
import 'scope_test_support.dart';

/// A discovery response as the radio pushes it: [status][flags][snr][tag:4]
/// [pubkey:32].
Uint8List _reply(List<int> tag, int keyFill,
        {int type = DiscoveryConstants.nodeTypeRepeater}) =>
    Uint8List.fromList([
      0,
      DiscoveryConstants.discoverRespFlag | type,
      20,
      ...tag,
      ...List<int>.filled(32, keyFill),
    ]);

/// The discovery write reaches the radio at once but its acknowledged write
/// completes only 500 ms later, the way a BLE write with response does.
class _SlowAckRadio extends FakeCompanionTransport {
  @override
  Future<void> write(Uint8List data) async {
    writes.add(Uint8List.fromList(data));
    if (data.isNotEmpty && data.first == CommandCodes.sendControlData) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
}

void main() {
  const own = [1, 2, 3, 4];
  const foreign = [9, 9, 9, 9];

  test('own-tag replies carry their time after the send; foreign ones none',
      () {
    fakeAsync((async) {
      final tracker = DiscTracker(hopBytes: 1);
      tracker.startTracking(
          tag: Uint8List.fromList(own), sentAt: clock.now());
      async.elapse(const Duration(milliseconds: 300));
      tracker.handlePacket(_reply(own, 0x11), 5, -80);
      async.elapse(const Duration(milliseconds: 900));
      tracker.handlePacket(_reply(own, 0x22), 5, -80);
      tracker.handlePacket(_reply(foreign, 0x33), 5, -80);
      final nodes = {for (final n in tracker.stopTracking()) n.repeaterId: n};
      expect(nodes['11']!.discoveryReplyAfter,
          const Duration(milliseconds: 300));
      expect(nodes['22']!.discoveryReplyAfter,
          const Duration(milliseconds: 1200));
      expect(nodes['33']!.discoveryReplyAfter, isNull,
          reason: 'another phone\'s discovery: accepted, no reply time');
    });
  });

  test('a better-SNR foreign reply keeps the own reply time', () {
    fakeAsync((async) {
      final tracker = DiscTracker(hopBytes: 1);
      tracker.startTracking(
          tag: Uint8List.fromList(own), sentAt: clock.now());
      async.elapse(const Duration(milliseconds: 400));
      tracker.handlePacket(_reply(own, 0x11), 2, -80);
      async.elapse(const Duration(milliseconds: 400));
      tracker.handlePacket(_reply(foreign, 0x11), 9, -80);
      final node = tracker.stopTracking().single;
      expect(node.localSnr, 9);
      expect(node.discoveryReplyAfter, const Duration(milliseconds: 400));
    });
  });

  test('one-byte ids shared by two keys never share a reply time', () {
    Uint8List reply(List<int> tag, int second, {required bool own}) =>
        Uint8List.fromList([
          0,
          DiscoveryConstants.discoverRespFlag |
              DiscoveryConstants.nodeTypeRepeater,
          20,
          ...tag,
          0xAA,
          second,
          ...List<int>.filled(30, 0x33),
        ]);
    fakeAsync((async) {
      // Own AA01 first, then a stronger foreign AA02 replaces it.
      final tracker = DiscTracker(hopBytes: 1);
      tracker.startTracking(
          tag: Uint8List.fromList(own), sentAt: clock.now());
      async.elapse(const Duration(milliseconds: 400));
      tracker.handlePacket(reply(own, 0x01, own: true), 2, -80);
      async.elapse(const Duration(milliseconds: 400));
      tracker.handlePacket(reply(foreign, 0x02, own: false), 9, -80);
      final node = tracker.stopTracking().single;
      expect(node.pubkeyFull.substring(0, 4), 'AA02');
      expect(node.discoveryReplyAfter, isNull);
    });
    fakeAsync((async) {
      // Foreign AA02 first, then a weaker own AA01: no timing copied over.
      final tracker = DiscTracker(hopBytes: 1);
      tracker.startTracking(
          tag: Uint8List.fromList(own), sentAt: clock.now());
      async.elapse(const Duration(milliseconds: 400));
      tracker.handlePacket(reply(foreign, 0x02, own: false), 9, -80);
      async.elapse(const Duration(milliseconds: 400));
      tracker.handlePacket(reply(own, 0x01, own: true), 2, -80);
      final node = tracker.stopTracking().single;
      expect(node.pubkeyFull.substring(0, 4), 'AA02');
      expect(node.discoveryReplyAfter, isNull);
    });
  });

  test('no sentAt: no reply times at all', () {
    fakeAsync((async) {
      final tracker = DiscTracker(hopBytes: 1);
      tracker.startTracking(tag: Uint8List.fromList(own));
      async.elapse(const Duration(milliseconds: 300));
      tracker.handlePacket(_reply(own, 0x11), 5, -80);
      expect(tracker.stopTracking().single.discoveryReplyAfter, isNull);
    });
  });

  test('a write held behind a gate is timed from after the gate', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      final lease = grant(async, conn)!;
      ({Uint8List tag, DateTime sentAt})? sent;
      conn.sendDiscoveryRequest().then((s) => sent = s);
      async.elapse(const Duration(seconds: 1));
      expect(radio.commands, isEmpty, reason: 'parked at the lease gate');
      final releasedAt = clock.now();
      lease.release();
      async.flushMicrotasks();
      expect(sent, isNotNull);
      expect(sent!.sentAt, releasedAt);
      expect(sent!.tag, radio.writes.single.sublist(3, 7));
    });
  });

  test('a write acked 500 ms later is still timed from its submission', () {
    onScopeClock(_SlowAckRadio.new, (async, radio, conn) {
      final submittedAt = clock.now();
      ({Uint8List tag, DateTime sentAt})? sent;
      conn.sendDiscoveryRequest().then((s) => sent = s);
      async.elapse(const Duration(milliseconds: 499));
      expect(sent, isNull);
      async.elapse(const Duration(milliseconds: 1));
      expect(sent, isNotNull);
      expect(sent!.sentAt, submittedAt);
    });
  });
}
