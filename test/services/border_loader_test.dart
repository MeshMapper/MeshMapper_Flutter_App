import 'dart:async';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mesh_mapper/services/border_loader.dart';

/// The NZ group's `/border` answer is 4.8 MB and phones needed 11 to 161 s
/// for it. With a 10 s timeout and no memory of the failure, every 60 s zone
/// check started another download on top of the last (one phone pulled 41 of
/// them in 45 minutes). These tests pin the rules that stop that.
class _MemoryCache implements BorderCacheStore {
  final Map<String, (String, BorderPolygons)> entries = {};
  int hashReads = 0;
  int reads = 0;
  int writes = 0;

  @override
  Future<String?> hashFor(String contextKey) async {
    hashReads++;
    return entries[contextKey]?.$1;
  }

  @override
  Future<BorderPolygons?> read(String contextKey, String borderHash) async {
    reads++;
    final entry = entries[contextKey];
    return entry != null && entry.$1 == borderHash ? entry.$2 : null;
  }

  @override
  Future<void> write(
      String contextKey, String borderHash, BorderPolygons polygons) async {
    writes++;
    entries[contextKey] = (borderHash, polygons);
  }
}

BorderPolygons _polygons(String code) => [
      {
        'code': code,
        'polygon': [
          [1.0, 2.0],
          [3.0, 4.0],
        ],
      },
    ];

void main() {
  late DateTime now;
  late _MemoryCache cache;
  late BorderLoader loader;
  late int fetches;

  setUp(() {
    now = DateTime.utc(2026, 10, 24, 12);
    cache = _MemoryCache();
    loader = BorderLoader(cache: cache, now: () => now);
    fetches = 0;
  });

  /// A `/border` answer; [hash] is the body's own `border_hash`, which only
  /// a complete answer carries. Most tests send it equal to the /status hash.
  Future<BorderAnswer?> Function() answer(BorderPolygons? result,
          {String? hash}) =>
      () async {
        fetches++;
        return result == null ? null : BorderAnswer(result, borderHash: hash);
      };

  group('without border_hash (old server)', () {
    test('loads once per context and never asks again while loaded',
        () async {
      final first = await loader.ensure(
          contextKey: 'NZ', fetch: answer(_polygons('AKL')));
      expect(first, isNotNull);
      for (var i = 0; i < 5; i++) {
        now = now.add(const Duration(minutes: 1));
        expect(
            await loader.ensure(
                contextKey: 'NZ', fetch: answer(_polygons('AKL'))),
            isNull);
      }
      expect(fetches, 1);
      expect(cache.reads, 0);
      expect(cache.writes, 0);
    });

    test('a new context loads again, and forget() allows a reload', () async {
      await loader.ensure(contextKey: 'NZ', fetch: answer(_polygons('AKL')));
      await loader.ensure(contextKey: 'YOW', fetch: answer(_polygons('YOW')));
      expect(fetches, 2);
      loader.forget();
      await loader.ensure(contextKey: 'YOW', fetch: answer(_polygons('YOW')));
      expect(fetches, 3);
    });
  });

  group('backoff after a failed or empty answer', () {
    test('waits 5, then 15, then 30 minutes, capped at 30', () async {
      final pauses = <Duration>[];
      for (var round = 0; round < 4; round++) {
        await loader.ensure(contextKey: 'NZ', fetch: answer(null));
        pauses.add(loader.retryAt!.difference(now));

        // Zone checks every minute before the pause ends ask nothing.
        final before = fetches;
        var t = now;
        while (true) {
          t = t.add(const Duration(minutes: 1));
          if (!t.isBefore(loader.retryAt!)) break;
          now = t;
          await loader.ensure(contextKey: 'NZ', fetch: answer(null));
        }
        expect(fetches, before);
        now = loader.retryAt!;
      }
      expect(pauses, const [
        Duration(minutes: 5),
        Duration(minutes: 15),
        Duration(minutes: 30),
        Duration(minutes: 30),
      ]);
      expect(fetches, 4);
    });

    test('an empty polygon list counts as a failure', () async {
      await loader.ensure(contextKey: 'NZ', fetch: answer(const []));
      expect(loader.retryAt, now.add(const Duration(minutes: 5)));
      expect(loader.loadedKey, isNull);
    });

    test('a context change resets the backoff', () async {
      await loader.ensure(contextKey: 'NZ', fetch: answer(null));
      final result =
          await loader.ensure(contextKey: 'YOW', fetch: answer(_polygons('Y')));
      expect(result, isNotNull);
      expect(fetches, 2);
    });

    test('a border_hash change resets the backoff', () async {
      await loader.ensure(
          contextKey: 'NZ', borderHash: 'a', fetch: answer(null));
      await loader.ensure(
          contextKey: 'NZ', borderHash: 'b', fetch: answer(_polygons('AKL')));
      expect(fetches, 2);
    });

    test('a success clears the backoff', () async {
      await loader.ensure(contextKey: 'NZ', fetch: answer(null));
      now = loader.retryAt!;
      await loader.ensure(contextKey: 'NZ', fetch: answer(_polygons('AKL')));
      expect(loader.retryAt, isNull);
      // A later failure in another context starts the schedule from 5 min.
      await loader.ensure(contextKey: 'YOW', fetch: answer(null));
      expect(loader.retryAt, now.add(const Duration(minutes: 5)));
    });
  });

  group('one request at a time', () {
    test('zone checks during a slow download start no second one', () async {
      final slow = Completer<BorderAnswer?>();
      final first = loader.ensure(
          contextKey: 'NZ',
          fetch: () {
            fetches++;
            return slow.future;
          });
      expect(loader.fetchInProgress, isTrue);

      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(minutes: 1));
        expect(await loader.ensure(contextKey: 'NZ', fetch: answer(null)),
            isNull);
        expect(await loader.ensure(contextKey: 'YOW', fetch: answer(null)),
            isNull);
      }
      expect(fetches, 1);

      slow.complete(BorderAnswer(_polygons('AKL')));
      expect(await first, isNotNull);
      expect(loader.fetchInProgress, isFalse);
    });

    test('the guard clears when the request fails', () async {
      final slow = Completer<BorderAnswer?>();
      final first = loader.ensure(contextKey: 'NZ', fetch: () => slow.future);
      slow.complete(null);
      await first;
      expect(loader.fetchInProgress, isFalse);
    });
  });

  group('border_hash cache', () {
    test('a hash hit uses the cache and skips /border', () async {
      cache.entries['NZ'] = ('h1', _polygons('AKL'));
      final result = await loader.ensure(
          contextKey: 'NZ', borderHash: 'h1', fetch: answer(_polygons('X')));
      expect(result, _polygons('AKL'));
      expect(fetches, 0);
      expect(loader.loadedKey, 'NZ');
    });

    test('a hash miss fetches and saves under the new hash', () async {
      cache.entries['NZ'] = ('old', _polygons('OLD'));
      final result = await loader.ensure(
          contextKey: 'NZ',
          borderHash: 'new',
          fetch: answer(_polygons('AKL'), hash: 'new'));
      expect(result, _polygons('AKL'));
      expect(fetches, 1);
      expect(cache.entries['NZ']!.$1, 'new');
    });

    test('a changed hash for the loaded context fetches again', () async {
      await loader.ensure(
          contextKey: 'NZ', borderHash: 'h1', fetch: answer(_polygons('A')));
      expect(
          await loader.ensure(
              contextKey: 'NZ', borderHash: 'h1', fetch: answer(_polygons('A'))),
          isNull);
      final result = await loader.ensure(
          contextKey: 'NZ', borderHash: 'h2', fetch: answer(_polygons('B')));
      expect(result, _polygons('B'));
      expect(fetches, 2);
    });

    test('moving back to a cached context reads the cache, not /border',
        () async {
      await loader.ensure(
          contextKey: 'NZ',
          borderHash: 'n',
          fetch: answer(_polygons('AKL'), hash: 'n'));
      await loader.ensure(
          contextKey: 'YOW',
          borderHash: 'y',
          fetch: answer(_polygons('YOW'), hash: 'y'));
      final back = await loader.ensure(
          contextKey: 'NZ', borderHash: 'n', fetch: answer(_polygons('X')));
      expect(back, _polygons('AKL'));
      expect(fetches, 2);
    });

    test('a known miss is not read again during the backoff', () async {
      await loader.ensure(
          contextKey: 'NZ', borderHash: 'h1', fetch: answer(null));
      expect(cache.hashReads, 1);
      for (var i = 0; i < 4; i++) {
        now = now.add(const Duration(minutes: 1));
        await loader.ensure(
            contextKey: 'NZ', borderHash: 'h1', fetch: answer(null));
      }
      expect(cache.hashReads, 1);
      expect(cache.reads, 0);
      expect(fetches, 1);
    });

    test('a hash mismatch never reads the polygons', () async {
      cache.entries['NZ'] = ('old', _polygons('OLD'));
      await loader.ensure(
          contextKey: 'NZ', borderHash: 'new', fetch: answer(null));
      expect(cache.hashReads, 1);
      expect(cache.reads, 0);
    });

    test('an answer without a body hash is shown but never saved', () async {
      final result = await loader.ensure(
          contextKey: 'NZ', borderHash: 'h1', fetch: answer(_polygons('AKL')));
      expect(result, _polygons('AKL'));
      expect(cache.writes, 0);
      // Loaded in memory: the next zone checks ask nothing.
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(minutes: 1));
        expect(
            await loader.ensure(
                contextKey: 'NZ',
                borderHash: 'h1',
                fetch: answer(_polygons('AKL'))),
            isNull);
      }
      expect(fetches, 1);
    });

    test('an answer is saved under its own body hash', () async {
      // The border changed between /status and /border.
      await loader.ensure(
          contextKey: 'NZ',
          borderHash: 'h1',
          fetch: answer(_polygons('AKL'), hash: 'h2'));
      expect(cache.entries['NZ']!.$1, 'h2');
      // Same /status hash again: still loaded, no request.
      await loader.ensure(
          contextKey: 'NZ', borderHash: 'h1', fetch: answer(_polygons('X')));
      expect(fetches, 1);
      // /status catches up: served from the cache.
      final next = await loader.ensure(
          contextKey: 'NZ', borderHash: 'h2', fetch: answer(_polygons('X')));
      expect(next, _polygons('AKL'));
      expect(fetches, 1);
    });

    test('an empty status hash counts as none', () async {
      await loader.ensure(
          contextKey: 'NZ', borderHash: '', fetch: answer(_polygons('AKL')));
      expect(cache.hashReads, 0);
      expect(
          await loader.ensure(
              contextKey: 'NZ', fetch: answer(_polygons('AKL'))),
          isNull);
      expect(fetches, 1);
    });

    test('onStale runs only before a request for another context', () async {
      var stale = 0;
      await loader.ensure(
          contextKey: 'NZ',
          borderHash: 'n',
          fetch: answer(_polygons('AKL')),
          onStale: () => stale++);
      expect(stale, 1);
      // Same context, new hash: the old borders stay until the new arrive.
      await loader.ensure(
          contextKey: 'NZ',
          borderHash: 'n2',
          fetch: answer(_polygons('AKL')),
          onStale: () => stale++);
      expect(stale, 1);
      // Another context served from the cache: nothing to clear.
      cache.entries['YOW'] = ('y', _polygons('YOW'));
      await loader.ensure(
          contextKey: 'YOW',
          borderHash: 'y',
          fetch: answer(null),
          onStale: () => stale++);
      expect(stale, 1);
    });
  });

  group('returning to a context', () {
    test('A ok, B fails, A again shows A', () async {
      var shown = <Map<String, dynamic>>[];
      void clear() => shown = [];

      shown = (await loader.ensure(
          contextKey: 'A', fetch: answer(_polygons('A')), onStale: clear))!;
      expect(shown, _polygons('A'));

      expect(
          await loader.ensure(
              contextKey: 'B', fetch: answer(null), onStale: clear),
          isNull);
      expect(shown, isEmpty);

      final back = await loader.ensure(
          contextKey: 'A', fetch: answer(_polygons('A')), onStale: clear);
      expect(back, _polygons('A'));
      expect(fetches, 3);
    });

    test('A ok, B empty, A again comes from the cache', () async {
      await loader.ensure(
          contextKey: 'A',
          borderHash: 'a',
          fetch: answer(_polygons('A'), hash: 'a'),
          onStale: () {});
      await loader.ensure(
          contextKey: 'B',
          borderHash: 'b',
          fetch: answer(const []),
          onStale: () {});
      final back = await loader.ensure(
          contextKey: 'A',
          borderHash: 'a',
          fetch: answer(_polygons('X')),
          onStale: () {});
      expect(back, _polygons('A'));
      expect(fetches, 2);
    });
  });

  group('answers for another place', () {
    test('a rejected answer is not shown, not saved, and backs off',
        () async {
      final result = await loader.ensure(
          contextKey: 'YOW',
          borderHash: 'y',
          fetch: answer(_polygons('YUL'), hash: 'y'),
          accept: (p) => bordersFitZone(p, zoneCode: 'YOW'));
      expect(result, isNull);
      expect(cache.writes, 0);
      expect(loader.loadedKey, isNull);
      expect(loader.retryAt, now.add(const Duration(minutes: 5)));
    });

    test('bordersFitZone needs the zone and, in a group, only members', () {
      final group = [..._polygons('AKL'), ..._polygons('WLG')];
      expect(bordersFitZone(_polygons('akl'), zoneCode: 'AKL'), isTrue);
      expect(bordersFitZone(_polygons('YOW'), zoneCode: 'AKL'), isFalse);
      expect(
          bordersFitZone(group,
              zoneCode: 'AKL', groupMembers: const ['AKL', 'WLG', 'CHC']),
          isTrue);
      expect(
          bordersFitZone([...group, ..._polygons('YOW')],
              zoneCode: 'AKL', groupMembers: const ['AKL', 'WLG']),
          isFalse);
      expect(
          bordersFitZone(_polygons('WLG'),
              zoneCode: 'AKL', groupMembers: const ['AKL', 'WLG']),
          isFalse);
    });
  });

  group('HiveBorderCacheStore', () {
    late Directory dir;
    late int clock;
    late HiveBorderCacheStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('border_cache_test');
      Hive.init(dir.path);
      clock = 1000;
      store = HiveBorderCacheStore(
          now: () => DateTime.fromMillisecondsSinceEpoch(clock++));
    });

    tearDown(() async {
      await Hive.deleteFromDisk();
      await dir.delete(recursive: true);
    });

    test('round-trips polygons under their hash', () async {
      await store.write('NZ', 'h1', _polygons('AKL'));
      expect(await store.hashFor('NZ'), 'h1');
      expect(await store.read('NZ', 'h1'), _polygons('AKL'));
      expect(await store.read('NZ', 'h2'), isNull);
      expect(await store.hashFor('YOW'), isNull);
    });

    test('keeps the four newest contexts', () async {
      for (final key in ['A', 'B', 'C', 'D', 'E']) {
        await store.write(key, 'h$key', _polygons(key));
      }
      expect(await store.hashFor('A'), isNull);
      for (final key in ['B', 'C', 'D', 'E']) {
        expect(await store.hashFor(key), 'h$key');
      }
      final box = await Hive.openLazyBox(HiveBorderCacheStore.boxName);
      expect(box.keys.toSet(), {'B', 'C', 'D', 'E'});
    });

    test('a malformed saved_at is evicted first, not a stop to eviction',
        () async {
      for (final key in ['A', 'B', 'C', 'D']) {
        await store.write(key, 'h$key', _polygons(key));
      }
      final index = await Hive.openBox(HiveBorderCacheStore.indexBoxName);
      await index.put('C', {'hash': 'hC', 'saved_at': 'yesterday'});
      await store.write('E', 'hE', _polygons('E'));
      await store.write('F', 'hF', _polygons('F'));
      expect(index.keys.toSet(), {'B', 'D', 'E', 'F'});
    });
  });
}
