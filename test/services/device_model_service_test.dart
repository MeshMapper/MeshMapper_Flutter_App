import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/device_catalog.dart';
import 'package:mesh_mapper/models/device_model.dart';
import 'package:mesh_mapper/services/device_model_service.dart';

import 'device_catalog_storage_races_test.dart' show DurableStorage;
import 'device_model_service_catalog_test.dart' show catalogJson;

/// Storage that fails at one named step of the launch load.
class BrokenStorage implements DeviceCatalogStorage {
  final String failAt;

  BrokenStorage({required this.failAt});

  @override
  Future<void> reload() async {
    if (failAt == 'reload') throw StateError('prefs channel unavailable');
  }

  @override
  String? getString(String key) {
    if (failAt == 'read') throw StateError('prefs entry unreadable');
    return null;
  }

  @override
  Future<bool> remove(String key) async => true;

  @override
  Future<bool> setString(String key, String value) async => true;
}

Map<String, String> committedSlotA() => {
      'device_catalog_active_slot_v1': 'a',
      'device_catalog_slot_a_v1':
          DeviceCatalog.fromJson(catalogJson(1)).toJsonString(),
    };

void main() {
  test('a failed launch fetch is retried by a later connect resolve', () async {
    var now = DateTime.utc(2026, 1, 1);
    var fetches = 0;
    final service = DeviceModelService(
      loadStorage: () async => DurableStorage({}),
      fetchCatalog: () async {
        fetches++;
        if (fetches == 1) throw StateError('network unavailable');
        return DeviceCatalog.fromJson(catalogJson(2));
      },
      launchTimeout: const Duration(milliseconds: 50),
      now: () => now,
    );

    await service.initialize();
    await service.refreshFuture;
    expect(service.catalog, isNull);
    expect(fetches, 1);

    now = now.add(DeviceModelService.connectRetryFloor);
    final model = await service.resolveForConnection('Tracker');

    expect(fetches, 2);
    expect(model?.manufacturer, 'Tracker');
    expect(service.catalog?.revision, 2);
  });

  test('a connect resolve inside the retry floor does not refetch', () async {
    var now = DateTime.utc(2026, 1, 1);
    var fetches = 0;
    final service = DeviceModelService(
      loadStorage: () async => DurableStorage({}),
      fetchCatalog: () async {
        fetches++;
        return null;
      },
      launchTimeout: const Duration(milliseconds: 50),
      now: () => now,
    );

    await service.initialize();
    await service.refreshFuture;
    expect(fetches, 1);

    now = now.add(DeviceModelService.connectRetryFloor -
        const Duration(milliseconds: 1));
    expect(await service.resolveForConnection('Tracker'), isNull);
    expect(fetches, 1);

    now = now.add(const Duration(milliseconds: 1));
    expect(await service.resolveForConnection('Tracker'), isNull);
    expect(fetches, 2);
  });

  test('one connect resolve arms at most one retry', () async {
    var now = DateTime.utc(2026, 1, 1);
    var fetches = 0;
    final service = DeviceModelService(
      loadStorage: () async => DurableStorage({}),
      fetchCatalog: () async {
        fetches++;
        return null;
      },
      launchTimeout: const Duration(milliseconds: 50),
      // A clock that jumps a whole floor on every read, so the floor can never
      // refuse a retry and only the per-resolve bound limits the fetches.
      now: () => now = now.add(DeviceModelService.connectRetryFloor),
    );

    await service.initialize();
    await service.refreshFuture;
    expect(fetches, 1);

    expect(await service.resolveForConnection('Tracker'), isNull);
    expect(fetches, 2);

    expect(await service.resolveForConnection('Tracker'), isNull);
    expect(fetches, 3);
  });

  test('a refresh already in flight is awaited instead of retried', () async {
    var fetches = 0;
    final gate = Completer<DeviceCatalog?>();
    final service = DeviceModelService(
      loadStorage: () async => DurableStorage({}),
      fetchCatalog: () {
        fetches++;
        return gate.future;
      },
      launchTimeout: const Duration(milliseconds: 200),
      now: () => DateTime.utc(2026, 1, 1),
    );

    await service.initialize();
    final resolved = service.resolveForConnection('Tracker');
    gate.complete(DeviceCatalog.fromJson(catalogJson(2)));

    expect((await resolved)?.manufacturer, 'Tracker');
    expect(fetches, 1);
  });

  for (final armedBy in ['launch refresh', 'connect retry']) {
    test('a connect resolve waiting on the $armedBy stops at the cap', () {
      fakeAsync((async) {
        final retry = armedBy == 'connect retry';
        // The clock only moves to clear the retry floor, so the fetch deadline
        // can never be what ends the wait. Only the cap can.
        var clock = DateTime.utc(2026, 1, 1);
        final hang = Completer<DeviceCatalog?>();
        var fetches = 0;
        final service = DeviceModelService(
          loadStorage: () async => DurableStorage({}),
          fetchCatalog: () {
            fetches++;
            // The retry case needs its launch fetch to end so a retry can be
            // armed at all. The fetch under test is the one that hangs.
            return retry && fetches == 1
                ? Future<DeviceCatalog?>.value(null)
                : hang.future;
          },
          now: () => clock,
        );
        service.initialize();
        async.flushMicrotasks();
        if (retry) clock = clock.add(DeviceModelService.connectRetryFloor);

        DeviceModel? resolved;
        var returned = false;
        service.resolveForConnection('Tracker').then((model) {
          resolved = model;
          returned = true;
        });
        async.elapse(
            DeviceModelService.connectWaitCap - const Duration(milliseconds: 1));
        expect(returned, isFalse);
        expect(fetches, retry ? 2 : 1);

        async.elapse(const Duration(milliseconds: 1));

        expect(returned, isTrue);
        expect(resolved, isNull);
        expect(service.catalog, isNull);

        // The fetch keeps its own deadline and still publishes, so the next
        // connect finds a catalog waiting.
        hang.complete(DeviceCatalog.fromJson(catalogJson(2)));
        async.elapse(Duration.zero);

        expect(service.catalog?.revision, 2);
        expect(fetches, retry ? 2 : 1);
      });
    });
  }

  test('a fetch landing inside the cap is used by that connect', () async {
    final gate = Completer<DeviceCatalog?>();
    final service = DeviceModelService(
      loadStorage: () async => DurableStorage({}),
      fetchCatalog: () => gate.future,
      now: () => DateTime.utc(2026, 1, 1),
    );

    await service.initialize();
    final resolved = service.resolveForConnection('Tracker');
    gate.complete(DeviceCatalog.fromJson(catalogJson(2)));

    expect((await resolved)?.manufacturer, 'Tracker');
  });

  test('a cached catalog never triggers a connect-time refetch', () async {
    var fetches = 0;
    final service = DeviceModelService(
      loadStorage: () async => DurableStorage(committedSlotA()),
      fetchCatalog: () async {
        fetches++;
        return null;
      },
      now: () => DateTime.utc(2026, 1, 1),
    );

    await service.initialize();
    await service.refreshFuture;
    expect(fetches, 1);

    expect((await service.resolveForConnection('Tracker'))?.power, 0.3);
    expect(fetches, 1);
  });

  for (final stage in ['load', 'reload', 'read']) {
    test('initialize survives a storage $stage failure', () async {
      final service = DeviceModelService(
        loadStorage: () async => stage == 'load'
            ? throw StateError('prefs unavailable')
            : BrokenStorage(failAt: stage),
        fetchCatalog: () async => DeviceCatalog.fromJson(catalogJson(2)),
      );

      await service.initialize();

      expect(service.isLoaded, isFalse);
      expect(service.catalog, isNull);

      await service.refreshFuture;

      // No storage is the same failure class as a refused write: the fetched
      // catalog still has to reach memory or the radio is unrecognized.
      expect(service.catalog?.revision, 2);
      expect((await service.resolveForConnection('Tracker'))?.power, 0.3);
    });
  }

  test('an unknown observation is not queued without storage', () async {
    var reports = 0;
    final service = DeviceModelService(
      loadStorage: () async => throw StateError('prefs unavailable'),
      fetchCatalog: () async => DeviceCatalog.fromJson(catalogJson(2)),
      reportUnknown: (_, __, ___) async {
        reports++;
        return null;
      },
    );

    await service.initialize();
    await service.refreshFuture;
    service.observeUnknownDevice(
        manufacturer: 'New hardware', appVersion: 'APP');
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(reports, 0);
  });

  for (final failure in ['false', 'throw']) {
    test('a fetched catalog reaches memory when persistence returns $failure',
        () async {
      final storage = DurableStorage(committedSlotA());
      storage.beforeCommit = (key, _) async {
        if (key != 'device_catalog_slot_b_v1') return true;
        if (failure == 'throw') throw StateError('disk unavailable');
        return false;
      };
      final service = DeviceModelService(
        loadStorage: () async => storage,
        fetchCatalog: () async => DeviceCatalog.fromJson(catalogJson(2)),
      );

      await service.initialize();
      await service.refreshFuture;

      expect(service.catalog?.revision, 2);
      expect(storage.durable['device_catalog_active_slot_v1'], 'a');
      expect(storage.durable.containsKey('device_catalog_slot_b_v1'), isFalse);

      final restarted = DeviceModelService(
          loadStorage: () async => DurableStorage(storage.durable),
          fetchCatalog: () async => null);
      await restarted.initialize();

      expect(restarted.catalog?.revision, 1);
    });
  }

  test('a refused pointer write leaves the committed cache intact', () async {
    final storage = DurableStorage(committedSlotA());
    storage.beforeCommit = (key, _) async =>
        key != 'device_catalog_active_slot_v1';
    final service = DeviceModelService(
      loadStorage: () async => storage,
      fetchCatalog: () async => DeviceCatalog.fromJson(catalogJson(2)),
    );

    await service.initialize();
    await service.refreshFuture;

    expect(service.catalog?.revision, 2);
    expect(storage.durable['device_catalog_active_slot_v1'], 'a');

    final restarted = DeviceModelService(
        loadStorage: () async => DurableStorage(storage.durable),
        fetchCatalog: () async => null);
    await restarted.initialize();

    expect(restarted.catalog?.revision, 1);
  });
}
