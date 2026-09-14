import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/models/device_catalog.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/services/device_model_service.dart';

import 'device_catalog_storage_races_test.dart' show DurableStorage, settle;
import 'device_model_service_catalog_test.dart' show catalogJson;

Map<String, String> committedCache() => {
      'device_catalog_active_slot_v1': 'a',
      'device_catalog_slot_a_v1':
          DeviceCatalog.fromJson(catalogJson(1)).toJsonString(),
    };

void main() {
  for (final refreshOutcome in ['failure', 'still unknown', 'now known']) {
    test('later launch $refreshOutcome has correct outbox precedence',
        () async {
      final storage = DurableStorage(committedCache());
      final calls = <String>[];
      final first = DeviceModelService(
          loadStorage: () async => storage,
          fetchCatalog: () async => null,
          reportUnknown: (name, _, __) async {
            calls.add('first:$name');
            return null;
          });
      await first.initialize();
      first.observeUnknownDevice(manufacturer: 'Old radio', appVersion: 'old');
      first.observeUnknownDevice(manufacturer: 'OLD-RADIO', appVersion: 'new');
      await settle();
      expect(calls, ['first:Old radio']);
      final refresh = Completer<DeviceCatalog?>();
      final second = DeviceModelService(
          loadStorage: () async => storage,
          fetchCatalog: () => refresh.future,
          reportUnknown: (name, _, __) async {
            calls.add('second:$name');
            return DeviceReportAcknowledgement.known;
          });
      await second.initialize();
      await settle();
      expect(calls.length, 1);
      if (refreshOutcome == 'failure') {
        refresh.complete(null);
      } else {
        final fresh = catalogJson(2);
        if (refreshOutcome == 'now known') {
          (fresh['devices'] as List).single['aliases'] = ['Old radio'];
        }
        refresh.complete(DeviceCatalog.fromJson(fresh));
      }
      await second.refreshFuture;
      await settle();
      expect(calls.length, refreshOutcome == 'still unknown' ? 2 : 1);
      expect(storage.entries.isEmpty, refreshOutcome != 'failure');
      second.observeUnknownDevice(
          manufacturer: 'Fresh unknown', appVersion: 'APP');
      await settle();
      expect(calls.last, 'second:Fresh unknown');
    });
  }

  test(
      'hung report expires, late acknowledgement cannot delete a later observation, future launch retries',
      () {
    fakeAsync((async) {
      final storage = DurableStorage(committedCache());
      final response = Completer<DeviceReportAcknowledgement?>();
      var reports = 0;
      final service = DeviceModelService(
          loadStorage: () async => storage,
          fetchCatalog: () async => null,
          reportUnknown: (_, __, ___) {
            reports++;
            return response.future;
          });
      service.initialize();
      async.flushMicrotasks();
      service.observeUnknownDevice(manufacturer: 'Unknown', appVersion: 'old');
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 10));
      service.observeUnknownDevice(manufacturer: 'Unknown', appVersion: 'new');
      async.flushMicrotasks();
      response.complete(DeviceReportAcknowledgement.pending);
      async.flushMicrotasks();
      expect(reports, 1);
      expect(storage.entries['unknown']['app_version'], 'new');
      final retry = DeviceModelService(
          loadStorage: () async => storage,
          fetchCatalog: () async => DeviceCatalog.fromJson(catalogJson(2)),
          reportUnknown: (_, __, ___) async {
            reports++;
            return DeviceReportAcknowledgement.pending;
          });
      retry.initialize();
      async.flushMicrotasks();
      expect(reports, 2);
      expect(storage.entries, isEmpty);
    });
  });

  test('cacheless resolution uses only the remaining shared launch wait',
      () async {
    final refresh = Completer<DeviceCatalog?>();
    final service = DeviceModelService(
        loadStorage: () async => DurableStorage({}),
        fetchCatalog: () => refresh.future,
        launchTimeout: const Duration(milliseconds: 100));
    await service.initialize();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(
        await service
            .resolveForConnection('Unknown')
            .timeout(const Duration(milliseconds: 60)),
        isNull);
    refresh.complete(null);
  });

  final invalid = <String, Object?>{
    'non-object': [],
    'false success': catalogJson(2)..['success'] = false,
    'string success': catalogJson(2)..['success'] = 'true',
    'negative revision': catalogJson(2)..['revision'] = -1,
    'string revision': catalogJson(2)..['revision'] = '2',
    'fractional revision': catalogJson(2)..['revision'] = 2.5,
    'missing devices': {'success': true, 'revision': 2},
    'empty devices': catalogJson(2)..['devices'] = [],
    'non-list devices': catalogJson(2)..['devices'] = {},
    'non-object record': catalogJson(2)..['devices'] = [null],
  };
  for (final field in [
    'id',
    'manufacturer',
    'shortName',
    'aliases',
    'power',
    'platform',
    'txPower',
    'notes'
  ]) {
    for (final value in [null, true, [], {}]) {
      if (field == 'aliases' && value is List) continue;
      final json = catalogJson(2);
      (json['devices'] as List).single[field] = value;
      invalid['$field rejects ${jsonEncode(value)}'] = json;
    }
  }
  for (final entry in <String, Object>{
    'power zero': 0,
    'power negative': -1,
    'power over maximum': 101,
    'txPower below minimum': -31,
    'txPower over maximum': 101,
    'txPower fractional': 2.5,
    'id string': '2',
    'power string': '0.3',
    'aliases wrong element': [7]
  }.entries) {
    final json = catalogJson(2);
    (json['devices'] as List).single[entry.key.split(' ').first] = entry.value;
    invalid[entry.key] = json;
  }
  for (final count in [501]) {
    invalid['$count devices'] = catalogJson(2)
      ..['devices'] = List.generate(
          count,
          (i) => {
                ...(catalogJson(2)['devices'] as List).single as Map,
                'id': i,
                'manufacturer': 'Radio $i'
              });
  }
  final aliases = catalogJson(2);
  (aliases['devices'] as List).single['aliases'] =
      List.generate(51, (i) => 'alias$i');
  invalid['51 aliases'] = aliases;
  for (final kind in ['manufacturer', 'alias', 'duplicate id']) {
    final json = catalogJson(2);
    (json['devices'] as List).add(<String, dynamic>{
      ...(catalogJson(2)['devices'] as List).single as Map,
      'id': kind == 'duplicate id' ? 1 : 2,
      'manufacturer': kind == 'manufacturer' ? 'TRACK-ER' : 'Other',
      'aliases': kind == 'alias' ? ['Tracker'] : []
    });
    invalid['collision $kind'] = json;
  }
  for (final entry in invalid.entries) {
    test('committed cache survives ${entry.key}', () async {
      final storage = DurableStorage(committedCache());
      final before = Map.of(storage.durable);
      final api = ApiService(
          client: MockClient(
              (_) async => http.Response(jsonEncode(entry.value), 200)));
      final service = DeviceModelService(
          loadStorage: () async => storage,
          fetchCatalog: api.fetchDeviceCatalog);
      await service.initialize();
      await service.refreshFuture;
      expect(service.catalog?.revision, 1);
      expect(storage.durable, before);
      final reconstructed = DeviceModelService(
          loadStorage: () async => storage, fetchCatalog: () async => null);
      await reconstructed.initialize();
      expect(reconstructed.catalog?.revision, 1);
    });
  }
  for (final failure in [
    'timeout',
    'transport',
    'authentication',
    'invalid JSON',
    'invalid UTF8',
    'overflow',
    'nonfinite'
  ]) {
    test('committed cache survives $failure response', () async {
      final storage = DurableStorage(committedCache());
      final before = Map.of(storage.durable);
      final api = ApiService(
          deviceCatalogTimeout: const Duration(milliseconds: 5),
          client: MockClient((_) async {
            if (failure == 'timeout') {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            if (failure == 'transport') {
              throw http.ClientException('network unavailable');
            }
            if (failure == 'invalid UTF8') {
              return http.Response.bytes([0xff], 200);
            }
            return http.Response(
                switch (failure) {
                  'invalid JSON' => '{',
                  'overflow' =>
                    '${jsonEncode(catalogJson(2))}${' ' * DeviceCatalog.maxEncodedBytes}',
                  'nonfinite' =>
                    jsonEncode(catalogJson(2)).replaceFirst('0.3', '1e999'),
                  _ => jsonEncode(catalogJson(2)),
                },
                failure == 'authentication' ? 401 : 200);
          }));
      final service = DeviceModelService(
          loadStorage: () async => storage,
          fetchCatalog: api.fetchDeviceCatalog);
      await service.initialize();
      await service.refreshFuture;
      expect(service.catalog?.revision, 1);
      expect(storage.durable, before);
    });
  }

  for (final boundary in [
    '500 devices',
    '50 aliases',
    'one MiB',
    'power bounds'
  ]) {
    test('commits valid boundary $boundary and reconstructs it', () async {
      final json = catalogJson(2);
      if (boundary == '500 devices') {
        json['devices'] = List.generate(
            500,
            (i) => {
                  ...(catalogJson(2)['devices'] as List).single as Map,
                  'id': i,
                  'manufacturer': 'Radio $i'
                });
      }
      if (boundary == '50 aliases') {
        (json['devices'] as List).single['aliases'] =
            List.generate(50, (i) => 'alias$i');
      }
      if (boundary == 'power bounds') {
        (json['devices'] as List).single['power'] = 100;
        (json['devices'] as List).single['txPower'] = -30;
      }
      var body = jsonEncode(json);
      if (boundary == 'one MiB') {
        body +=
            ' ' * (DeviceCatalog.maxEncodedBytes - utf8.encode(body).length);
      }
      final storage = DurableStorage(committedCache());
      final api =
          ApiService(client: MockClient((_) async => http.Response(body, 200)));
      final service = DeviceModelService(
          loadStorage: () async => storage,
          fetchCatalog: api.fetchDeviceCatalog);
      await service.initialize();
      await service.refreshFuture;
      expect(service.catalog?.revision, 2);
      final reconstructed = DeviceModelService(
          loadStorage: () async => storage, fetchCatalog: () async => null);
      await reconstructed.initialize();
      expect(reconstructed.catalog?.revision, 2);
    });
  }
}
