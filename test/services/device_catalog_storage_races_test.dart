import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/device_catalog.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/services/device_model_service.dart';

import 'device_model_service_catalog_test.dart' show catalogJson;

class DurableStorage implements DeviceCatalogStorage {
  final Map<String, String> durable;
  late Map<String, String> cache = Map.of(durable);
  Future<bool> Function(String, String)? beforeCommit;
  DurableStorage(this.durable);
  @override
  Future<void> reload() async {
    cache = Map.of(durable);
  }

  @override
  String? getString(String key) => cache[key];
  @override
  Future<bool> setString(String key, String value) async {
    cache[key] = value;
    if (await beforeCommit?.call(key, value) == false) return false;
    durable[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    cache.remove(key);
    durable.remove(key);
    return true;
  }

  Map<String, dynamic> get entries =>
      (jsonDecode(durable[DeviceModelService.outboxKey] ?? '{"entries":{}}')
          as Map)['entries'] as Map<String, dynamic>;
}

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  for (final failure in ['false', 'throw']) {
    test('outbox $failure cannot dispatch unpersisted data or poison retry',
        () async {
      final storage = DurableStorage({
        DeviceModelService.catalogCacheKey:
            DeviceCatalog.fromJson(catalogJson(1)).toJsonString()
      });
      final reports = <String>[];
      final service = DeviceModelService(
          loadStorage: () async => storage,
          fetchCatalog: () async => null,
          reportUnknown: (name, _, __) async {
            reports.add(name);
            return null;
          });
      await service.initialize();
      var failed = false;
      storage.beforeCommit = (key, _) async {
        if (key == DeviceModelService.outboxKey && !failed) {
          failed = true;
          if (failure == 'throw') throw StateError('disk failure');
          return false;
        }
        return true;
      };
      service.observeUnknownDevice(manufacturer: 'Retry', appVersion: 'old');
      await settle();
      expect(reports, isEmpty);
      expect(storage.entries, isEmpty);
      service.observeUnknownDevice(manufacturer: 'Retry', appVersion: 'new');
      service.observeUnknownDevice(manufacturer: 'Other', appVersion: 'new');
      await settle();
      expect(reports, ['Retry', 'Other']);
      expect(storage.entries['retry']['generation'], 1);
      expect(storage.entries['retry']['app_version'], 'new');
    });
  }

  test('refresh during a delayed observation suppresses its report', () async {
    final storage = DurableStorage({
      DeviceModelService.catalogCacheKey:
          DeviceCatalog.fromJson(catalogJson(1)).toJsonString()
    });
    final refresh = Completer<DeviceCatalog?>();
    final gate = Completer<bool>();
    final reports = <String>[];
    final service = DeviceModelService(
        loadStorage: () async => storage,
        fetchCatalog: () => refresh.future,
        reportUnknown: (name, _, __) async {
          reports.add(name);
          return null;
        });
    await service.initialize();
    var held = false;
    storage.beforeCommit = (key, _) async {
      if (key == DeviceModelService.outboxKey && !held) {
        held = true;
        return gate.future;
      }
      return true;
    };
    service.observeUnknownDevice(manufacturer: 'New alias', appVersion: 'APP');
    await settle();
    final fresh = catalogJson(2);
    (fresh['devices'] as List).single['aliases'] = ['New alias'];
    refresh.complete(DeviceCatalog.fromJson(fresh));
    await service.refreshFuture;
    gate.complete(true);
    await settle();
    expect(reports, isEmpty);
    expect(storage.entries, isEmpty);
  });

  for (final initial in ['none', 'legacy', 'slot']) {
    for (final stage in ['slot', 'pointer']) {
      for (final failure in ['false', 'throw']) {
        test('$initial cache survives $stage $failure and reconstruction',
            () async {
          final old = DeviceCatalog.fromJson(catalogJson(1)).toJsonString();
          final values = <String, String>{
            if (initial == 'legacy') DeviceModelService.catalogCacheKey: old,
            if (initial == 'slot') 'device_catalog_active_slot_v1': 'a',
            if (initial == 'slot') 'device_catalog_slot_a_v1': old,
          };
          final storage = DurableStorage(values);
          storage.beforeCommit = (key, _) async {
            if (key ==
                (stage == 'pointer'
                    ? 'device_catalog_active_slot_v1'
                    : initial == 'slot'
                        ? 'device_catalog_slot_b_v1'
                        : 'device_catalog_slot_a_v1')) {
              if (failure == 'throw') throw StateError('write failed');
              return false;
            }
            return true;
          };
          final service = DeviceModelService(
              loadStorage: () async => storage,
              fetchCatalog: () async => DeviceCatalog.fromJson(catalogJson(2)));
          await service.initialize();
          await service.refreshFuture;
          expect(service.catalog?.revision, initial == 'none' ? null : 1);
          final reconstructed = DeviceModelService(
              loadStorage: () async => storage, fetchCatalog: () async => null);
          await reconstructed.initialize();
          expect(reconstructed.catalog?.revision, initial == 'none' ? null : 1);
          final restarted = DeviceModelService(
              loadStorage: () async => DurableStorage(values),
              fetchCatalog: () async => null);
          await restarted.initialize();
          expect(restarted.catalog?.revision, initial == 'none' ? null : 1);
        });
      }
    }
  }

  for (final competing in ['observation', 'acknowledgement', 'refresh']) {
    test('delayed acknowledgement cannot overwrite $competing', () async {
      final storage = DurableStorage({
        DeviceModelService.catalogCacheKey:
            DeviceCatalog.fromJson(catalogJson(1)).toJsonString()
      });
      final refresh = Completer<DeviceCatalog?>();
      final replies = <String, Completer<DeviceReportAcknowledgement?>>{};
      final service = DeviceModelService(
          loadStorage: () async => storage,
          fetchCatalog: () => refresh.future,
          reportUnknown: (name, _, __) => (replies[name] =
                  Completer<DeviceReportAcknowledgement?>())
              .future);
      await service.initialize();
      service.observeUnknownDevice(manufacturer: 'First', appVersion: 'old');
      service.observeUnknownDevice(manufacturer: 'Second', appVersion: 'old');
      await settle();
      final gate = Completer<bool>();
      var held = false;
      storage.beforeCommit = (key, value) async {
        if (key == DeviceModelService.outboxKey && !held) {
          held = true;
          return gate.future;
        }
        return true;
      };
      replies['First']!.complete(DeviceReportAcknowledgement.pending);
      await settle();
      expect(held, isTrue);
      if (competing == 'observation') {
        service.observeUnknownDevice(manufacturer: 'First', appVersion: 'new');
      } else if (competing == 'acknowledgement') {
        replies['Second']!.complete(DeviceReportAcknowledgement.pending);
      } else {
        final fresh = catalogJson(2);
        (fresh['devices'] as List).single['aliases'] = ['Second'];
        refresh.complete(DeviceCatalog.fromJson(fresh));
      }
      await settle();
      gate.complete(true);
      await settle();
      if (competing == 'observation') {
        expect(storage.entries, contains('first'));
        expect(storage.entries['first']['app_version'], 'new');
      } else {
        expect(storage.entries, isEmpty);
      }
      if (!refresh.isCompleted) refresh.complete(null);
      if (!replies['Second']!.isCompleted) replies['Second']!.complete(null);
    });
  }
}
