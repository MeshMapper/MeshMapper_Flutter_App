import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/device_catalog.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/services/device_model_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> catalogJson(int revision) => {
      'success': true,
      'revision': revision,
      'devices': [
        <String, dynamic>{
          'id': 1,
          'manufacturer': 'Tracker',
          'shortName': 'Tracker',
          'aliases': <String>[],
          'power': 0.3,
          'platform': 'nrf52',
          'txPower': 22,
          'notes': '',
        }
      ],
    };

class MemoryCatalogStorage implements DeviceCatalogStorage {
  final Map<String, String> values;
  final Future<bool> Function(String key, String value)? onSet;

  MemoryCatalogStorage(this.values, {this.onSet});

  @override
  Future<void> reload() async {}

  @override
  String? getString(String key) => values[key];

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }

  @override
  Future<bool> setString(String key, String value) async {
    values[key] = value;
    return onSet == null ? true : await onSet!(key, value);
  }
}

void main() {
  test('uses a validated cache without waiting for launch refresh', () async {
    final cached = DeviceCatalog.fromJson(catalogJson(1));
    SharedPreferences.setMockInitialValues({
      DeviceModelService.catalogCacheKey: cached.toJsonString(),
    });
    final gate = Completer<DeviceCatalog?>();
    final service = DeviceModelService(fetchCatalog: () => gate.future);

    await service.initialize();

    expect(service.models.single.manufacturer, 'Tracker');
    expect(await service.resolveForConnection('Tracker'), isNotNull);
    gate.complete(null);
  });

  test('concurrent initialization shares one storage load and refresh',
      () async {
    final storageGate = Completer<DeviceCatalogStorage>();
    var loads = 0;
    var fetches = 0;
    final service = DeviceModelService(
      loadStorage: () {
        loads++;
        return storageGate.future;
      },
      fetchCatalog: () async {
        fetches++;
        return null;
      },
    );

    final first = service.initialize();
    final second = service.initialize();
    storageGate.complete(MemoryCatalogStorage({}));
    await Future.wait([first, second]);
    await service.refreshFuture;

    expect(loads, 1);
    expect(fetches, 1);
  });

  test('replaces cache only after a completely valid refresh', () async {
    SharedPreferences.setMockInitialValues({});
    final service = DeviceModelService(
      fetchCatalog: () async => DeviceCatalog.fromJson(catalogJson(2)),
    );
    await service.initialize();
    await service.refreshFuture;

    expect(service.catalog?.revision, 2);
  });

  test('retains a valid cache when the launch refresh throws', () async {
    final cached = DeviceCatalog.fromJson(catalogJson(1));
    SharedPreferences.setMockInitialValues({
      DeviceModelService.catalogCacheKey: cached.toJsonString(),
    });
    final service = DeviceModelService(
      fetchCatalog: () async => throw StateError('network unavailable'),
    );

    await service.initialize();
    await service.refreshFuture;

    expect(service.catalog?.revision, 1);
  });

  for (final failure in <String>['false', 'throw']) {
    test('keeps the committed cache and publishes memory when persistence '
        'returns $failure', () async {
      final cached = DeviceCatalog.fromJson(catalogJson(1)).toJsonString();
      var firstWrite = true;
      final storage = MemoryCatalogStorage(
        {DeviceModelService.catalogCacheKey: cached},
        onSet: (_, __) async {
          if (!firstWrite) return true;
          firstWrite = false;
          if (failure == 'throw') throw StateError('storage unavailable');
          return false;
        },
      );
      final service = DeviceModelService(
        fetchCatalog: () async => DeviceCatalog.fromJson(catalogJson(2)),
        loadStorage: () async => storage,
      );

      await service.initialize();
      await service.refreshFuture;

      // A refused write does not throw away a validated catalog: this launch
      // uses it from memory while the committed cache stays untouched.
      expect(service.catalog?.revision, 2);
      expect(storage.getString(DeviceModelService.catalogCacheKey), cached);
    });
  }

  test('cacheless resolution does not wait for a hung outbox report', () async {
    SharedPreferences.setMockInitialValues({
      DeviceModelService.outboxKey: jsonEncode({
        'version': 1,
        'entries': {
          'unknown': {
            'manufacturer': 'Unknown',
            'app_version': 'APP',
            'firmware_version': '',
            'observed_at': '2026-01-01T00:00:00.000Z',
            'generation': 1,
          }
        }
      }),
    });
    final stuck = Completer<DeviceReportAcknowledgement?>();
    final service = DeviceModelService(
      fetchCatalog: () async => DeviceCatalog.fromJson(catalogJson(1)),
      reportUnknown: (_, __, ___) => stuck.future,
    );

    final result = await service.resolveForConnection('Tracker').timeout(
          const Duration(milliseconds: 100),
        );

    expect(result?.manufacturer, 'Tracker');
  });
}
