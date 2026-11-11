import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';
import 'package:mesh_mapper/services/scope_discovery/scope_provider_support.dart';
import 'package:mesh_mapper/services/scope_discovery/scope_runner.dart';

Repeater _repeater(String hex, {int? checkedAt}) => Repeater.fromJson({
      'id': hex.substring(0, 2),
      'hex_id': hex,
      'name': 'R',
      'lat': 1.0,
      'lon': 2.0,
      'last_heard': 0,
      'enabled': 1,
      if (checkedAt != null) 'scopes_checked_at': checkedAt,
    });

void main() {
  group('whether a scope refresh changes the map', () {
    test('only the scope stamps moved: no change', () {
      expect(
          scopeRefreshChangesMap(
              [_repeater('ab' * 32), _repeater('cd' * 32, checkedAt: 1)],
              [
                _repeater('ab' * 32, checkedAt: 1790000000),
                _repeater('cd' * 32, checkedAt: 2),
              ]),
          isFalse);
    });

    test('a rendered field moved: changed', () {
      final before = [_repeater('ab' * 32)];
      expect(
          scopeRefreshChangesMap(
              before, [before.single.copyWith(lastHeard: 1790000000)]),
          isTrue);
      expect(scopeRefreshChangesMap(before, [before.single.copyWith(enabled: 2)]),
          isTrue);
      expect(scopeRefreshChangesMap(before, [before.single.copyWith(lat: 3.0)]),
          isTrue);
    });

    test('a repeater added, dropped or reordered: changed', () {
      final a = _repeater('ab' * 32);
      final b = _repeater('cd' * 32);
      expect(scopeRefreshChangesMap([a], [a, b]), isTrue);
      expect(scopeRefreshChangesMap([a, b], [a]), isTrue);
      expect(scopeRefreshChangesMap([a, b], [b, a]), isTrue);
      expect(scopeRefreshChangesMap(const [], [a]), isTrue);
    });
  });

  group('server info map', () {
    test('keys are upper-case full keys; short ids are left out', () {
      final map = scopeServerInfoMap([
        _repeater('ab' * 32, checkedAt: 1790000000),
        _repeater('cd' * 32),
        _repeater('4E7A'),
      ]);
      expect(map.keys, ['AB' * 32, 'CD' * 32]);
      expect(scopeServerInfoFor(map, 'ab' * 32),
          (onList: true, checkedAt: 1790000000));
      expect(scopeServerInfoFor(map, 'CD' * 32),
          (onList: true, checkedAt: null));
    });

    test('a ghost is not on the list', () {
      final map = scopeServerInfoMap([_repeater('ab' * 32)]);
      expect(scopeServerInfoFor(map, 'EF' * 32),
          (onList: false, checkedAt: null));
      expect(scopeServerInfoFor(map, 'not a key'),
          (onList: false, checkedAt: null));
    });
  });

  group('connect-time repeater refresh', () {
    final now = DateTime(2026, 9, 26, 12);

    test('due only when active and the list is missing or an hour old', () {
      expect(
          scopeRepeaterRefreshDue(active: false, loadedAt: null, now: now),
          isFalse);
      expect(scopeRepeaterRefreshDue(active: true, loadedAt: null, now: now),
          isTrue);
      expect(
          scopeRepeaterRefreshDue(
              active: true,
              loadedAt: now.subtract(const Duration(minutes: 59)),
              now: now),
          isFalse);
      expect(
          scopeRepeaterRefreshDue(
              active: true,
              loadedAt: now.subtract(const Duration(hours: 1)),
              now: now),
          isTrue);
    });

    test('a custom maxAge is honoured (mode-start 5 minute check)', () {
      expect(
          scopeRepeaterRefreshDue(
              active: true,
              loadedAt: now.subtract(const Duration(minutes: 4)),
              now: now,
              maxAge: scopeListRefreshOnStartAge),
          isFalse,
          reason: '4 minutes < 5 minute maxAge');
      expect(
          scopeRepeaterRefreshDue(
              active: true,
              loadedAt: now.subtract(const Duration(minutes: 6)),
              now: now,
              maxAge: scopeListRefreshOnStartAge),
          isTrue,
          reason: '6 minutes >= 5 minute maxAge');
      expect(
          scopeRepeaterRefreshDue(
              active: false,
              loadedAt: now.subtract(const Duration(minutes: 6)),
              now: now,
              maxAge: scopeListRefreshOnStartAge),
          isFalse,
          reason: 'inactive: never due, whatever the age');
    });

    test('a refetch landing after a zone change is discarded', () {
      expect(
          scopeRepeaterRefreshStillCurrent(
              requestedZone: 'YOW',
              requestedFilterKey: '910.525,62.5,7',
              currentZone: 'YUL',
              currentFilterKey: '910.525,62.5,7'),
          isFalse);
    });

    test('a refetch landing after a preset change is discarded', () {
      expect(
          scopeRepeaterRefreshStillCurrent(
              requestedZone: 'YOW',
              requestedFilterKey: '910.525,62.5,7',
              currentZone: 'YOW',
              currentFilterKey: '869.525,250,11'),
          isFalse);
    });

    test('neither moved: applied', () {
      expect(
          scopeRepeaterRefreshStillCurrent(
              requestedZone: 'YOW',
              requestedFilterKey: null,
              currentZone: 'YOW',
              currentFilterKey: null),
          isTrue);
    });
  });

  group('the Passive/Hybrid mode-start refresh plan', () {
    final now = DateTime(2026, 9, 26, 12);

    test('a 4-minute-old list: timer armed, no immediate refresh', () {
      final plan = scopeModeStartRefreshPlan(
          active: true,
          zone: 'YOW',
          loadedAt: now.subtract(const Duration(minutes: 4)),
          now: now);
      expect(plan.refreshNow, isFalse);
      expect(plan.armTimer, isTrue);
    });

    test('a 6-minute-old list: refreshes at once and arms the timer', () {
      final plan = scopeModeStartRefreshPlan(
          active: true,
          zone: 'YOW',
          loadedAt: now.subtract(const Duration(minutes: 6)),
          now: now);
      expect(plan.refreshNow, isTrue);
      expect(plan.armTimer, isTrue);
    });

    test('no list loaded yet: refreshes at once and arms the timer', () {
      final plan = scopeModeStartRefreshPlan(
          active: true, zone: 'YOW', loadedAt: null, now: now);
      expect(plan.refreshNow, isTrue);
      expect(plan.armTimer, isTrue);
    });

    test('scope discovery inactive: nothing at all, whatever the age', () {
      final plan = scopeModeStartRefreshPlan(
          active: false,
          zone: 'YOW',
          loadedAt: now.subtract(const Duration(hours: 1)),
          now: now);
      expect(plan.refreshNow, isFalse);
      expect(plan.armTimer, isFalse);
    });

    test('no zone yet: nothing at all', () {
      final plan = scopeModeStartRefreshPlan(
          active: true, zone: null, loadedAt: null, now: now);
      expect(plan.refreshNow, isFalse);
      expect(plan.armTimer, isFalse);
    });

    test('an empty zone string: nothing at all', () {
      final plan = scopeModeStartRefreshPlan(
          active: true, zone: '', loadedAt: null, now: now);
      expect(plan.refreshNow, isFalse);
      expect(plan.armTimer, isFalse);
    });
  });

  group('whether a periodic refresh tick should run', () {
    test('active, mode running, known zone: runs', () {
      expect(
          scopePeriodicRefreshShouldRun(
              active: true, passiveOrHybridRunning: true, zone: 'YOW'),
          isTrue);
    });

    test('the mode is off: does nothing, even though scope discovery is '
        'active', () {
      expect(
          scopePeriodicRefreshShouldRun(
              active: true, passiveOrHybridRunning: false, zone: 'YOW'),
          isFalse);
    });

    test('scope discovery inactive: does nothing, even with the mode '
        'running', () {
      expect(
          scopePeriodicRefreshShouldRun(
              active: false, passiveOrHybridRunning: true, zone: 'YOW'),
          isFalse);
    });

    test('no zone: does nothing', () {
      expect(
          scopePeriodicRefreshShouldRun(
              active: true, passiveOrHybridRunning: true, zone: null),
          isFalse);
    });

    test('an empty zone string: does nothing', () {
      expect(
          scopePeriodicRefreshShouldRun(
              active: true, passiveOrHybridRunning: true, zone: ''),
          isFalse);
    });
  });

  test('stored JSON decodes from a string or a map, junk reads null', () {
    expect(decodeScopeJsonMap('{"a":1}'), {'a': 1});
    expect(decodeScopeJsonMap({'a': 1}), {'a': 1});
    expect(decodeScopeJsonMap('not json'), isNull);
    expect(decodeScopeJsonMap('[1]'), isNull);
    expect(decodeScopeJsonMap(null), isNull);
  });

  test('the serial writer runs one write at a time and survives a throw', () {
    fakeAsync((async) {
      var running = 0;
      var maxRunning = 0;
      var runs = 0;
      var fail = true;
      final writer = ScopeSerialWriter('test state', () async {
        running++;
        if (running > maxRunning) maxRunning = running;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        running--;
        runs++;
        if (fail) {
          fail = false;
          throw StateError('disk');
        }
      });
      writer.schedule();
      writer.schedule();
      writer.schedule();
      async.elapse(const Duration(seconds: 1));
      expect(runs, 3);
      expect(maxRunning, 1);
    });
  });
}
