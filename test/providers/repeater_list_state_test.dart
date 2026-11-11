import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';
import 'package:mesh_mapper/providers/repeater_list_state.dart';

void main() {
  final repeater = Repeater.fromJson({
    'id': 'ab',
    'hex_id': 'ab1234',
    'lat': 45,
    'lon': -75,
    'enabled': 1,
  });
  final now = DateTime.utc(2026, 10, 4);
  RepeaterListState loaded() => const RepeaterListState().afterFetch(
        fetched: [repeater],
        requestedZone: 'YOW',
        requestedPreset: 'preset-a',
        currentZone: 'YOW',
        currentPreset: 'preset-a',
        now: now,
      );

  test('a failed refresh preserves the valid list and its freshness timestamp',
      () {
    final state = loaded();
    final result = state.afterFetch(
        fetched: null,
        requestedZone: 'YOW',
        requestedPreset: 'preset-a',
        currentZone: 'YOW',
        currentPreset: 'preset-a',
        now: now.add(const Duration(hours: 1)));
    expect(result, same(state));
    expect(result.repeaters.single.hexId, 'ab1234');
    expect(result.loadedAt, now);
  });

  for (final context in [
    ('GROUP', 'preset-a'),
    ('YOW', 'preset-b'),
    (null, null)
  ]) {
    test('context $context clears the old list before a request finishes', () {
      final state = loaded().forContext(context.$1, context.$2);
      expect(state.repeaters, isEmpty);
      expect(state.loadedAt, isNull);
      expect(state.zone, isNull);
    });

    test('a failed or late old-context fetch cannot restore $context', () {
      for (final fetched in [
        null,
        [repeater]
      ]) {
        final state = loaded().afterFetch(
            fetched: fetched,
            requestedZone: 'YOW',
            requestedPreset: 'preset-a',
            currentZone: context.$1,
            currentPreset: context.$2,
            now: now);
        expect(state.repeaters, isEmpty);
        expect(state.loadedAt, isNull);
      }
    });
  }

  test('a failed initial read stays unloaded', () {
    final state = const RepeaterListState().afterFetch(
        fetched: null,
        requestedZone: 'YOW',
        requestedPreset: null,
        currentZone: 'YOW',
        currentPreset: null,
        now: now);
    expect(state.repeaters, isEmpty);
    expect(state.loadedAt, isNull);
  });

  test('a current group result replaces the old region list', () {
    final groupRepeater = repeater.copyWith(name: 'Group result');
    final state = loaded().afterFetch(
        fetched: [groupRepeater],
        requestedZone: 'GROUP',
        requestedPreset: null,
        currentZone: 'GROUP',
        currentPreset: null,
        now: now);
    expect(state.repeaters.single.name, 'Group result');
    expect(state.zone, 'GROUP');
    expect(state.preset, isNull);
    expect(state.loadedAt, now);
  });

  test('a list keyed on the group survives a move between members', () {
    final loaded = const RepeaterListState().afterFetch(
      fetched: [repeater],
      requestedZone: 'ONQC',
      requestedPreset: null,
      currentZone: 'ONQC',
      currentPreset: null,
      now: DateTime(2026, 10, 12),
    );
    expect(loaded.repeaters, isNotEmpty);
    // YOW -> YUL inside ONQC: the context key stays ONQC.
    expect(identical(loaded.forContext('ONQC', null), loaded), isTrue);
    // Leaving the group clears it, as today.
    expect(loaded.forContext('SEA', null).repeaters, isEmpty);
  });
}
