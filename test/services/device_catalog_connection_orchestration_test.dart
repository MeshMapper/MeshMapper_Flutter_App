import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/device_catalog.dart';
import 'package:mesh_mapper/services/device_model_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

DeviceCatalog _catalog() => DeviceCatalog.fromJson({
      'success': true,
      'revision': 1,
      'devices': [
        {
          'id': 1,
          'manufacturer': 'Known',
          'shortName': 'Known',
          'aliases': <String>[],
          'power': 1,
          'platform': 'nrf52',
          'txPower': 22,
          'notes': '',
        }
      ],
    });

void main() {
  for (final transport in ['BLE', 'TCP', 'Android USB', 'generic']) {
    test('$transport handshake resolves after query and self-info', () async {
      SharedPreferences.setMockInitialValues({});
      final service = DeviceModelService(fetchCatalog: () async => _catalog());
      final events = <String>[];

      final model = await service.runConnection((resolve) async {
        events.add('device-query');
        events.add('self-info');
        final selected = await resolve('Known');
        events.add('resolved');
        return selected;
      });

      expect(events, ['device-query', 'self-info', 'resolved']);
      expect(model?.manufacturer, 'Known');
    });
  }

  test('unmatched and unavailable catalogs are unknown without reporting',
      () async {
    SharedPreferences.setMockInitialValues({});
    final unavailable = DeviceModelService(fetchCatalog: () async => null);
    final unmatched = DeviceModelService(fetchCatalog: () async => _catalog());

    expect(
      await unavailable.runConnection((resolve) => resolve('Unknown')),
      isNull,
    );
    expect(
      await unmatched.runConnection((resolve) => resolve('Unknown')),
      isNull,
    );
  });

  test('resolver errors fail the handshake before connection success',
      () async {
    SharedPreferences.setMockInitialValues({});
    final service = DeviceModelService(
      loadStorage: () async => throw StateError('storage failed'),
    );

    expect(
      () => service.runConnection((resolve) => resolve('Known')),
      throwsStateError,
    );
  });

  test('the selected model remains fixed after a late refresh', () async {
    SharedPreferences.setMockInitialValues({});
    final refresh = Completer<DeviceCatalog?>();
    final service = DeviceModelService(fetchCatalog: () => refresh.future);
    final selected = await service.runConnection((resolve) async {
      final initial = await resolve('Known');
      refresh.complete(_catalog());
      await service.refreshFuture;
      return initial;
    });

    expect(selected, isNull);
    expect(service.catalog?.revision, 1);
  });
}
