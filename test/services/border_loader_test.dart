import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/border_loader.dart';

/// The NZ group's `/border` answer is 4.8 MB and phones needed 11 to 161 s
/// for it. With a 10 s timeout and no memory of the failure, every 60 s zone
/// check started another download on top of the last (one phone pulled 41 of
/// them in 45 minutes). These tests pin the rules that stop that.
class _MemoryCache implements BorderCacheStore {
  final Map<String, (String, BorderPolygons)> entries = {};
  int reads = 0;
  int writes = 0;

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

  Future<BorderPolygons?> Function() answer(BorderPolygons? result) => () async {
        fetches++;
        return result;
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
      final slow = Completer<BorderPolygons?>();
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

      slow.complete(_polygons('AKL'));
      expect(await first, isNotNull);
      expect(loader.fetchInProgress, isFalse);
    });

    test('the guard clears when the request fails', () async {
      final slow = Completer<BorderPolygons?>();
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
          contextKey: 'NZ', borderHash: 'new', fetch: answer(_polygons('AKL')));
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
          contextKey: 'NZ', borderHash: 'n', fetch: answer(_polygons('AKL')));
      await loader.ensure(
          contextKey: 'YOW', borderHash: 'y', fetch: answer(_polygons('YOW')));
      final back = await loader.ensure(
          contextKey: 'NZ', borderHash: 'n', fetch: answer(_polygons('X')));
      expect(back, _polygons('AKL'));
      expect(fetches, 2);
    });

    test('a cache hit beats a running backoff', () async {
      await loader.ensure(
          contextKey: 'NZ', borderHash: 'h1', fetch: answer(null));
      cache.entries['NZ'] = ('h1', _polygons('AKL'));
      final result = await loader.ensure(
          contextKey: 'NZ', borderHash: 'h1', fetch: answer(null));
      expect(result, _polygons('AKL'));
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
}
