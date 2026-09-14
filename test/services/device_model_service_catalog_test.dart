import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/device_catalog.dart';
import 'package:mesh_mapper/services/device_model_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> catalogJson(int revision) => {
      'success': true,
      'revision': revision,
      'devices': [
        {
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
}
