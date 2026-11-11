import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/scope_lease.dart';
import 'package:mesh_mapper/services/scope_discovery/scope_discovery_rules.dart';
import 'package:mesh_mapper/services/scope_discovery/scope_lifecycle.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';
import 'package:mesh_mapper/services/scope_discovery/scope_runner.dart';

import '../meshcore/scope_test_support.dart' as support;

/// A radio that grants a lease and holds the ask until it is cancelled,
/// recording every frame it would have written.
class _HoldingRadio implements ScopeRadio {
  final List<String> frames = [];
  bool leaseHeld = false;

  @override
  Future<ScopeLeaseHandle?> acquire(
      {required Duration admissionWait,
      required ScopeCancelToken cancel}) async {
    if (cancel.isCancelled) return null;
    leaseHeld = true;
    return _HoldingLease(this, cancel);
  }
}

class _HoldingLease implements ScopeLeaseHandle {
  final _HoldingRadio radio;
  final ScopeCancelToken cancel;
  _HoldingLease(this.radio, this.cancel);

  @override
  List<ContactRecord> get unrestored => const [];

  @override
  Future<void> release() async => radio.leaseHeld = false;

  @override
  Future<bool> restore(ContactRecord original) async {
    if (cancel.isCancelled) return false;
    radio.frames.add('restore');
    return true;
  }

  @override
  Future<ScopeRequestOutcome> requestScopes(Uint8List pubkey, Uint8List request,
      {required Duration? answerWait,
      required DateTime notAfter,
      void Function(Duration wait)? onSent}) async {
    if (cancel.isCancelled) return const ScopeAborted();
    radio.frames.add('ask');
    await cancel.whenCancelled;
    radio.leaseHeld = false;
    return const ScopeAborted();
  }
}

ScopeGateInputs _gate({
  bool offered = true,
  bool enforced = false,
  bool userEnabled = true,
  bool offline = false,
  int? firmware = 13,
}) =>
    (
      offered: offered,
      enforced: enforced,
      userEnabled: userEnabled,
      offlineMode: offline,
      firmwareCode: firmware,
    );

ScopeCandidate _cand(int fill) => (
      keyHex: List.filled(32, fill.toRadixString(16).padLeft(2, '0'))
          .join()
          .toUpperCase(),
      repeaterId: fill.toRadixString(16).toUpperCase(),
      lat: 45.0,
      lon: -75.0,
      localRssi: -70,
      localSnr: 5.0,
      discoveryReplyAfter: const Duration(milliseconds: 400),
    );

class _Harness {
  final _HoldingRadio radio = _HoldingRadio();
  final List<String> hostCancels = [];
  int badgeNotifies = 0;
  late final ScopeLifecycle lifecycle = ScopeLifecycle(
    cancelHostRunner: hostCancels.add,
    onBadgeChanged: () => badgeNotifies++,
  );
  final Object connection = Object();
  final List<ScopeCancelToken> tokens = [];

  ScopeRunner? build(
      {ScopeGateInputs? gate, Object? connection, String? deviceKey = 'KEY'}) {
    final token = ScopeCancelToken();
    tokens.add(token);
    return lifecycle.buildRunner(
      gate: gate ?? _gate(),
      connection: connection ?? this.connection,
      deviceKey: deviceKey,
      create: (key, restores, knownNonContacts) => ScopeRunner(
        radio: radio,
        cancel: token,
        hardStop: clock.now().add(const Duration(seconds: 30)),
        refreshDays: () => 14,
        deviceKey: () => key,
        serverInfo: (_) => (onList: false, checkedAt: null),
        cache: ScopeQueryCache.fromJson(null),
        budget: ScopeHourlyBudget(save: (_) async {}),
        enqueue: (_, __) async => true,
        nowSec: () => clock.now().millisecondsSinceEpoch ~/ 1000,
        currentPosition: () => null,
        stillWanted: () => true,
        onActiveChanged: lifecycle.setRequestActive,
        onLogged: (_) {},
        pendingRestores: restores,
        knownNonContacts: knownNonContacts,
      ),
    );
  }
}

void main() {
  group('the gate', () {
    test('open: offered, switched on, online, firmware 13', () {
      expect(scopeDiscoveryGateOpen(_gate()), isTrue);
      expect(_Harness().build(), isNotNull);
    });

    test('each closed input builds no runner', () {
      final closed = {
        'key absent from /auth': _gate(offered: false),
        'switch off': _gate(userEnabled: false),
        'offline mode': _gate(offline: true),
        'firmware 12': _gate(firmware: 12),
        'firmware 11': _gate(firmware: 11),
        'firmware unknown': _gate(firmware: null),
      };
      closed.forEach((name, gate) {
        expect(scopeDiscoveryGateOpen(gate), isFalse, reason: name);
        expect(_Harness().build(gate: gate), isNull, reason: name);
      });
    });

    test('the admin can switch it on for a user who has it off', () {
      expect(
          scopeDiscoveryGateOpen(_gate(userEnabled: false, enforced: true)),
          isTrue);
      expect(
          scopeDiscoveryGateOpen(
              _gate(userEnabled: false, enforced: true, offered: false)),
          isFalse,
          reason: 'no key on /auth: never, whatever else says on');
    });

    test('no connection or no device key builds no runner', () {
      final h = _Harness();
      expect(
          h.lifecycle.buildRunner(
              gate: _gate(),
              connection: null,
              deviceKey: 'KEY',
              create: (_, __, ___) => fail('must not build')),
          isNull);
      expect(h.build(deviceKey: null), isNull);
    });
  });

  group('every stop event cancels the live runner at once', () {
    for (final event in ScopeStopEvent.values) {
      test(event.name, () {
        fakeAsync((async) {
          final h = _Harness();
          final runner = h.build()!;
          runner.run([_cand(0x11), _cand(0x22)],
              discPersisted: Future<void>.value());
          async.flushMicrotasks();
          expect(h.radio.leaseHeld, isTrue);
          expect(h.lifecycle.requestActive, isTrue);
          final frames = List.of(h.radio.frames);

          h.lifecycle.onEvent(event);

          expect(h.tokens.single.isCancelled, isTrue);
          expect(h.hostCancels, [event.reason]);
          expect(h.lifecycle.requestActive, isFalse);
          async.flushMicrotasks();
          expect(h.radio.leaseHeld, isFalse);
          async.elapse(const Duration(seconds: 60));
          expect(h.radio.frames, frames, reason: 'nothing further written');
        });
      });
    }

    test('an event with no runner live only clears the badge', () {
      final h = _Harness();
      h.lifecycle.setRequestActive(true);
      h.lifecycle.onEvent(ScopeStopEvent.airborne);
      expect(h.lifecycle.requestActive, isFalse);
      expect(h.hostCancels, ['airborne']);
    });
  });

  group('an Offline Mode switch', () {
    for (final event in [
      ScopeStopEvent.offlineSwitch,
      ScopeStopEvent.onlineSwitch,
    ]) {
      test(
          '${event.name}: a discovery window completing during the switch '
          'builds no runner', () {
        fakeAsync((async) {
          final h = _Harness();
          final before = h.build()!;
          before.run([_cand(0x11)], discPersisted: Future<void>.value());
          async.flushMicrotasks();
          final frames = List.of(h.radio.frames);

          // The first line of the switch, before anything is awaited: the
          // gate is still open (Offline Mode is not set yet).
          h.lifecycle.beginModeSwitch(event);
          expect(before.isCancelled, isTrue);
          expect(h.hostCancels, [event.reason]);
          expect(h.lifecycle.requestActive, isFalse);

          // The session recovery wait: a discovery window closes and asks
          // for this sweep's runner.
          async.elapse(const Duration(seconds: 10));
          expect(h.build(), isNull, reason: 'the switch is still running');
          async.elapse(const Duration(seconds: 60));
          expect(h.radio.frames, frames, reason: 'nothing further written');

          // The switch is over and the gate is still open (a failed switch
          // back to where it started): sweeps get runners again.
          h.lifecycle.endModeSwitch();
          expect(h.build(), isNotNull);
        });
      });
    }

    test('an overlapping switch keeps the block until both end', () {
      final h = _Harness();
      h.lifecycle.beginModeSwitch(ScopeStopEvent.offlineSwitch);
      h.lifecycle.beginModeSwitch(ScopeStopEvent.onlineSwitch);
      h.lifecycle.endModeSwitch();
      expect(h.build(), isNull);
      h.lifecycle.endModeSwitch();
      expect(h.build(), isNotNull);
    });
  });

  group('borrowed routes', () {
    ContactRecord record() => ContactRecord.newRepeater(
        publicKey: Uint8List.fromList(List.filled(32, 0x11)),
        name: 'R',
        lat: 1,
        lon: 2,
        nowSecs: 5);

    test('kept across runners on one connection, dropped on disconnect', () {
      for (final event in ScopeStopEvent.values) {
        final h = _Harness();
        h.lifecycle.restoresFor(h.connection).add(record());
        h.lifecycle.onEvent(event);
        expect(h.lifecycle.restoresFor(h.connection),
            event.dropsConnection ? isEmpty : hasLength(1),
            reason: event.name);
      }
    });

    test('a new connection starts with none', () {
      final h = _Harness();
      h.lifecycle.restoresFor(h.connection).add(record());
      expect(h.lifecycle.restoresFor(Object()), isEmpty);
    });
  });

  group('known non-contacts', () {
    test('kept across runners on one connection, dropped on disconnect', () {
      for (final event in ScopeStopEvent.values) {
        final h = _Harness();
        h.lifecycle.knownNonContactsFor(h.connection).add('AB' * 32);
        h.lifecycle.onEvent(event);
        expect(h.lifecycle.knownNonContactsFor(h.connection),
            event.dropsConnection ? isEmpty : hasLength(1),
            reason: event.name);
      }
    });

    test('a new connection starts with none', () {
      final h = _Harness();
      h.lifecycle.knownNonContactsFor(h.connection).add('AB' * 32);
      expect(h.lifecycle.knownNonContactsFor(Object()), isEmpty);
    });

    test('reading restores and known non-contacts for the same new '
        'connection resets both together, whichever is read first', () {
      final h = _Harness();
      h.lifecycle.restoresFor(h.connection).add(ContactRecord.newRepeater(
          publicKey: Uint8List.fromList(List.filled(32, 0x11)),
          name: 'R',
          lat: 1,
          lon: 2,
          nowSecs: 5));
      h.lifecycle.knownNonContactsFor(h.connection).add('AB' * 32);
      final other = Object();
      // Read known-non-contacts first this time: it must not leave the
      // restores list stale for the same new connection.
      expect(h.lifecycle.knownNonContactsFor(other), isEmpty);
      expect(h.lifecycle.restoresFor(other), isEmpty);
    });
  });

  group('connect-time repeater refresh', () {
    test('a list landing after a zone change is discarded', () {
      fakeAsync((async) {
        final h = _Harness();
        var zone = 'YOW';
        List<String>? applied;
        var settled = false;
        h.lifecycle
            .resultIfStillCurrent<List<String>>(
              fetch: Future.delayed(
                  const Duration(seconds: 2), () => ['from YOW']),
              zone: 'YOW',
              preset: '910.525,62.5,7',
              currentZone: () => zone,
              currentPreset: () => '910.525,62.5,7',
            )
            .then((r) {
          applied = r;
          settled = true;
        });
        async.elapse(const Duration(seconds: 1));
        zone = 'YUL';
        async.elapse(const Duration(seconds: 2));
        expect(settled, isTrue);
        expect(applied, isNull);
      });
    });

    test('a list landing after a preset change is discarded', () {
      fakeAsync((async) {
        final h = _Harness();
        var preset = '910.525,62.5,7';
        List<String>? applied = const ['untouched'];
        h.lifecycle
            .resultIfStillCurrent<List<String>>(
              fetch: Future.delayed(
                  const Duration(seconds: 2), () => ['old preset']),
              zone: 'YOW',
              preset: preset,
              currentZone: () => 'YOW',
              currentPreset: () => preset,
            )
            .then((r) => applied = r);
        async.elapse(const Duration(seconds: 1));
        preset = '869.525,250,11';
        async.elapse(const Duration(seconds: 2));
        expect(applied, isNull);
      });
    });

    test('nothing moved: the list is applied', () {
      fakeAsync((async) {
        final h = _Harness();
        List<String>? applied;
        h.lifecycle
            .resultIfStillCurrent<List<String>>(
              fetch: Future.delayed(
                  const Duration(seconds: 2), () => ['fresh']),
              zone: 'YOW',
              preset: null,
              currentZone: () => 'YOW',
              currentPreset: () => null,
            )
            .then((r) => applied = r);
        async.elapse(const Duration(seconds: 3));
        expect(applied, ['fresh']);
      });
    });

    test('a failed fetch reads as nothing to apply', () {
      fakeAsync((async) {
        final h = _Harness();
        var settled = false;
        List<String>? applied = const ['untouched'];
        h.lifecycle
            .resultIfStillCurrent<List<String>>(
              fetch: Future.error(StateError('offline')),
              zone: 'YOW',
              preset: null,
              currentZone: () => 'YOW',
              currentPreset: () => null,
            )
            .then((r) {
          applied = r;
          settled = true;
        });
        async.flushMicrotasks();
        expect(settled, isTrue);
        expect(applied, isNull);
      });
    });
  });

  group('the periodic repeater refresh timer', () {
    test('not running until started', () {
      final h = _Harness();
      expect(h.lifecycle.repeaterRefreshTimerRunning, isFalse);
    });

    test('ticks at 15 and 30 minutes, not before', () {
      fakeAsync((async) {
        final h = _Harness();
        var ticks = 0;
        h.lifecycle.startRepeaterRefreshTimer(
            const Duration(minutes: 15), () => ticks++);
        expect(h.lifecycle.repeaterRefreshTimerRunning, isTrue);

        async.elapse(const Duration(minutes: 14, seconds: 59));
        expect(ticks, 0);
        async.elapse(const Duration(seconds: 1));
        expect(ticks, 1);

        async.elapse(const Duration(minutes: 14, seconds: 59));
        expect(ticks, 1);
        async.elapse(const Duration(seconds: 1));
        expect(ticks, 2);
      });
    });

    test('starting again reschedules from now rather than stacking ticks',
        () {
      fakeAsync((async) {
        final h = _Harness();
        var ticks = 0;
        h.lifecycle.startRepeaterRefreshTimer(
            const Duration(minutes: 15), () => ticks++);
        async.elapse(const Duration(minutes: 10));
        h.lifecycle.startRepeaterRefreshTimer(
            const Duration(minutes: 15), () => ticks++);
        // The old schedule would have ticked at 15 minutes; the new one
        // (restarted at 10) only ticks at 25.
        async.elapse(const Duration(minutes: 5));
        expect(ticks, 0);
        async.elapse(const Duration(minutes: 10));
        expect(ticks, 1);
      });
    });

    test('stopRepeaterRefreshTimer cancels it; idempotent when not running',
        () {
      fakeAsync((async) {
        final h = _Harness();
        var ticks = 0;
        h.lifecycle.startRepeaterRefreshTimer(
            const Duration(minutes: 15), () => ticks++);
        h.lifecycle.stopRepeaterRefreshTimer();
        expect(h.lifecycle.repeaterRefreshTimerRunning, isFalse);
        async.elapse(const Duration(minutes: 30));
        expect(ticks, 0);
        // Stopping again (nothing running) does not throw.
        h.lifecycle.stopRepeaterRefreshTimer();
      });
    });

    for (final event in ScopeStopEvent.values) {
      test('onEvent(${event.name}) stops it', () {
        fakeAsync((async) {
          final h = _Harness();
          h.lifecycle.startRepeaterRefreshTimer(
              const Duration(minutes: 15), () {});
          h.lifecycle.onEvent(event);
          expect(h.lifecycle.repeaterRefreshTimerRunning, isFalse);
        });
      });
    }

    test('onGateChanged stops it when the gate closes, even with no live '
        'runner', () {
      final h = _Harness();
      h.lifecycle.startRepeaterRefreshTimer(
          const Duration(minutes: 15), () {});
      expect(h.lifecycle.repeaterRefreshTimerRunning, isTrue);
      h.lifecycle.onGateChanged(_gate(userEnabled: false),
          passiveOrHybridRunning: false, startRepeaterRefresh: () {});
      expect(h.lifecycle.repeaterRefreshTimerRunning, isFalse);
    });

    test('onGateChanged leaves it running while the gate stays open', () {
      final h = _Harness();
      h.lifecycle.startRepeaterRefreshTimer(
          const Duration(minutes: 15), () {});
      h.lifecycle.onGateChanged(_gate(),
          passiveOrHybridRunning: true, startRepeaterRefresh: () {});
      expect(h.lifecycle.repeaterRefreshTimerRunning, isTrue);
    });

    test('onGateChanged re-arms the refresh when the gate reopens while '
        'Passive or Hybrid is still running', () {
      final h = _Harness();
      h.lifecycle.startRepeaterRefreshTimer(
          const Duration(minutes: 15), () {});
      // The gate closes (mode still running): the timer stops.
      h.lifecycle.onGateChanged(_gate(userEnabled: false),
          passiveOrHybridRunning: true, startRepeaterRefresh: () {});
      expect(h.lifecycle.repeaterRefreshTimerRunning, isFalse);

      // The gate reopens with the mode still running: re-armed via the
      // same sequence a fresh mode start uses.
      var rearmed = false;
      h.lifecycle.onGateChanged(_gate(),
          passiveOrHybridRunning: true,
          startRepeaterRefresh: () {
            rearmed = true;
            h.lifecycle.startRepeaterRefreshTimer(
                const Duration(minutes: 15), () {});
          });
      expect(rearmed, isTrue);
      expect(h.lifecycle.repeaterRefreshTimerRunning, isTrue);
    });

    test('onGateChanged does not re-arm when the gate reopens but Passive '
        'or Hybrid is not running', () {
      final h = _Harness();
      h.lifecycle.startRepeaterRefreshTimer(
          const Duration(minutes: 15), () {});
      h.lifecycle.onGateChanged(_gate(userEnabled: false),
          passiveOrHybridRunning: false, startRepeaterRefresh: () {});
      expect(h.lifecycle.repeaterRefreshTimerRunning, isFalse);

      var rearmed = false;
      h.lifecycle.onGateChanged(_gate(),
          passiveOrHybridRunning: false,
          startRepeaterRefresh: () => rearmed = true);
      expect(rearmed, isFalse);
      expect(h.lifecycle.repeaterRefreshTimerRunning, isFalse);
    });

    test('onGateChanged does not re-invoke the re-arm callback when the '
        'timer is already running', () {
      final h = _Harness();
      h.lifecycle.startRepeaterRefreshTimer(
          const Duration(minutes: 15), () {});
      var called = false;
      h.lifecycle.onGateChanged(_gate(),
          passiveOrHybridRunning: true,
          startRepeaterRefresh: () => called = true);
      expect(called, isFalse,
          reason: 'already running: nothing to re-arm');
      expect(h.lifecycle.repeaterRefreshTimerRunning, isTrue);
    });
  });

  group('a live auth that withdraws scope discovery', () {
    test('stops a pending lookup before the scope request is written', () {
      support.onScopeClock(support.ScopeRadio.new, (async, radio, conn) {
        var offerScopes = true;
        final api = ApiService(
          client: MockClient((request) async => http.Response(
              json.encode({
                'success': true,
                'session_id': 'YOW-20260905-0001',
                'tx_allowed': true,
                'rx_allowed': true,
                'expires_at':
                    clock.now().millisecondsSinceEpoch ~/ 1000 + 300,
                if (offerScopes) 'scope_discovery': false,
              }),
              200)),
        );
        void auth() {
          api.requestAuth(
              reason: 'connect',
              publicKey: 'AB' * 32,
              lat: 45.42,
              lon: -75.70);
          async.elapse(const Duration(milliseconds: 10));
        }

        ScopeGateInputs gate() => (
              offered: api.scopeDiscoveryOffered,
              enforced: api.enforceScopeDiscovery,
              userEnabled: true,
              offlineMode: false,
              firmwareCode: 13,
            );
        final h = _Harness();
        // The provider's wiring, as in AppStateProvider. No mode is running
        // in this test, so the re-arm arm is exercised elsewhere.
        api.onScopeDiscoveryChanged = () => h.lifecycle.onGateChanged(gate(),
            passiveOrHybridRunning: false, startRepeaterRefresh: () {});

        auth();
        expect(api.scopeDiscoveryOffered, isTrue);
        final runner = h.lifecycle.buildRunner(
          gate: gate(),
          connection: conn,
          deviceKey: 'KEY',
          create: (key, restores, knownNonContacts) => ScopeRunner(
            radio: MeshCoreScopeRadio(conn),
            cancel: ScopeCancelToken(),
            hardStop: clock.now().add(const Duration(seconds: 30)),
            refreshDays: () => 14,
            deviceKey: () => key,
            serverInfo: (_) => (onList: false, checkedAt: null),
            cache: ScopeQueryCache.fromJson(null),
            budget: ScopeHourlyBudget(save: (_) async {}),
            enqueue: (_, __) async => true,
            nowSec: () => clock.now().millisecondsSinceEpoch ~/ 1000,
            currentPosition: () => null,
            stillWanted: () => true,
            onActiveChanged: h.lifecycle.setRequestActive,
            onLogged: (_) {},
            pendingRestores: restores,
            knownNonContacts: knownNonContacts,
          ),
        )!;
        runner.run([_cand(0x11)], discPersisted: Future<void>.value());
        async.flushMicrotasks();
        expect(radio.commands, [CommandCodes.getContactByKey],
            reason: 'the lookup is out and unanswered');

        // A session recovery's answer arrives without the key.
        offerScopes = false;
        auth();
        expect(api.scopeDiscoveryOffered, isFalse);
        expect(runner.isCancelled, isTrue);
        expect(h.lifecycle.requestActive, isFalse);

        // The lookup's reply (not a saved contact) would lead straight to
        // the scope request.
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.elapse(const Duration(seconds: 10));
        expect(radio.commands, isNot(contains(CommandCodes.sendAnonReq)));
        expect(radio.commands, [CommandCodes.getContactByKey]);
        expect(conn.isScopeLeaseActive, isFalse);
      });
    });

    test(
        'with a new session id it stops the lookup before the stale TX '
        'cleanup runs', () {
      support.onScopeClock(support.ScopeRadio.new, (async, radio, conn) {
        var offerScopes = true;
        var sessionId = 'YOW-20260905-0001';
        final api = ApiService(
          client: MockClient((request) async => http.Response(
              json.encode({
                'success': true,
                'session_id': sessionId,
                'tx_allowed': true,
                'rx_allowed': true,
                'expires_at':
                    clock.now().millisecondsSinceEpoch ~/ 1000 + 300,
                if (offerScopes) 'scope_discovery': false,
              }),
              200)),
        );
        void auth() {
          api.requestAuth(
              reason: 'connect',
              publicKey: 'AB' * 32,
              lat: 45.42,
              lon: -75.70);
          async.elapse(const Duration(milliseconds: 10));
        }

        ScopeGateInputs gate() => (
              offered: api.scopeDiscoveryOffered,
              enforced: api.enforceScopeDiscovery,
              userEnabled: true,
              offlineMode: false,
              firmwareCode: 13,
            );
        final h = _Harness();
        api.onScopeDiscoveryChanged = () => h.lifecycle.onGateChanged(gate(),
            passiveOrHybridRunning: false, startRepeaterRefresh: () {});
        // The stale tagged TX cleanup, held open by the test.
        final cleanup = Completer<void>();
        final sessionChanges = <String>[];
        api.onSessionIdChanged = (previous, next) {
          sessionChanges.add('$previous>$next');
          return cleanup.future;
        };

        auth();
        expect(api.scopeDiscoveryOffered, isTrue);
        final runner = h.lifecycle.buildRunner(
          gate: gate(),
          connection: conn,
          deviceKey: 'KEY',
          create: (key, restores, knownNonContacts) => ScopeRunner(
            radio: MeshCoreScopeRadio(conn),
            cancel: ScopeCancelToken(),
            hardStop: clock.now().add(const Duration(seconds: 30)),
            refreshDays: () => 14,
            deviceKey: () => key,
            serverInfo: (_) => (onList: false, checkedAt: null),
            cache: ScopeQueryCache.fromJson(null),
            budget: ScopeHourlyBudget(save: (_) async {}),
            enqueue: (_, __) async => true,
            nowSec: () => clock.now().millisecondsSinceEpoch ~/ 1000,
            currentPosition: () => null,
            stillWanted: () => true,
            onActiveChanged: h.lifecycle.setRequestActive,
            onLogged: (_) {},
            pendingRestores: restores,
            knownNonContacts: knownNonContacts,
          ),
        )!;
        runner.run([_cand(0x11)], discPersisted: Future<void>.value());
        async.flushMicrotasks();
        expect(radio.commands, [CommandCodes.getContactByKey]);

        // A recovery's answer: no key, and a new session id.
        offerScopes = false;
        sessionId = 'YOW-20260905-0002';
        auth();
        expect(sessionChanges,
            ['YOW-20260905-0001>YOW-20260905-0002'],
            reason: 'the cleanup is running');
        expect(runner.isCancelled, isTrue,
            reason: 'withdrawn before the cleanup is awaited');
        expect(h.lifecycle.requestActive, isFalse);

        // The lookup's reply lands while the cleanup is still running.
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.elapse(const Duration(seconds: 5));
        expect(radio.commands, isNot(contains(CommandCodes.sendAnonReq)));

        cleanup.complete();
        async.elapse(const Duration(seconds: 5));
        expect(api.sessionId, 'YOW-20260905-0002');
        expect(api.scopeDiscoveryOffered, isFalse);
        expect(radio.commands, [CommandCodes.getContactByKey]);
        expect(conn.isScopeLeaseActive, isFalse);
      });
    });

    test('a stale owner after the cleanup still leaves scope withdrawn', () {
      fakeAsync((async) {
        var offerScopes = true;
        var sessionId = 'YOW-20260905-0001';
        final api = ApiService(
          client: MockClient((request) async => http.Response(
              json.encode({
                'success': true,
                'session_id': sessionId,
                'tx_allowed': true,
                'rx_allowed': true,
                'expires_at':
                    clock.now().millisecondsSinceEpoch ~/ 1000 + 300,
                if (offerScopes) 'scope_discovery': true,
              }),
              200)),
        );
        var fired = 0;
        api.onScopeDiscoveryChanged = () => fired++;
        var owner = true;
        api.onSessionIdChanged = (_, __) async => owner = false;
        void auth() {
          api.requestAuth(
              reason: 'connect',
              publicKey: 'AB' * 32,
              lat: 45.42,
              lon: -75.70,
              shouldStoreSession: () => owner);
          async.elapse(const Duration(milliseconds: 10));
        }

        auth();
        expect(api.enforceScopeDiscovery, isTrue);
        expect(fired, 1);
        offerScopes = false;
        sessionId = 'YOW-20260905-0002';
        auth();
        expect(api.scopeDiscoveryOffered, isFalse);
        expect(api.enforceScopeDiscovery, isFalse);
        expect(fired, 2);
        expect(api.sessionId, 'YOW-20260905-0001',
            reason: 'a stale owner stores no session');
      });
    });

    test('an answer that keeps it offered cancels nothing', () {
      final h = _Harness();
      final runner = h.build()!;
      h.lifecycle.onGateChanged(_gate(),
          passiveOrHybridRunning: false, startRepeaterRefresh: () {});
      expect(runner.isCancelled, isFalse);
      expect(h.hostCancels, isEmpty);
    });
  });
}
