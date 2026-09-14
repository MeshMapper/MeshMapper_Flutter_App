import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/device_catalog.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/services/device_model_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

DeviceCatalog catalog() => DeviceCatalog.fromJson({
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
  test('keeps a failed unknown report for a later launch', () async {
    SharedPreferences.setMockInitialValues({});
    final calls = <String>[];
    final service = DeviceModelService(
      fetchCatalog: () async => catalog(),
      reportUnknown: (name, _, __) async {
        calls.add(name);
        return null;
      },
    );
    await service.initialize();
    await service.refreshFuture;
    service.observeUnknownDevice(
      manufacturer: 'Unknown radio',
      appVersion: 'APP-TEST',
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final preferences = await SharedPreferences.getInstance();
    final stored =
        jsonDecode(preferences.getString(DeviceModelService.outboxKey)!);
    expect(calls, ['Unknown radio']);
    expect((stored['entries'] as Map).containsKey('unknownradio'), isTrue);
  });

  test('does not report when the catalog is unavailable', () async {
    SharedPreferences.setMockInitialValues({});
    var reports = 0;
    final service = DeviceModelService(
      fetchCatalog: () async => null,
      reportUnknown: (_, __, ___) async {
        reports++;
        return DeviceReportAcknowledgement.pending;
      },
    );
    await service.initialize();
    await service.refreshFuture;
    service.observeUnknownDevice(manufacturer: 'Unknown', appVersion: 'APP');
    await Future<void>.delayed(Duration.zero);
    expect(reports, 0);
  });

  test('keeps a newer generation when an older report succeeds', () async {
    SharedPreferences.setMockInitialValues({});
    final response = Completer<DeviceReportAcknowledgement?>();
    var calls = 0;
    final service = DeviceModelService(
      fetchCatalog: () async => catalog(),
      reportUnknown: (_, __, ___) {
        calls++;
        return response.future;
      },
    );
    await service.initialize();
    await service.refreshFuture;
    service.observeUnknownDevice(manufacturer: 'New radio', appVersion: 'old');
    await Future<void>.delayed(Duration.zero);
    service.observeUnknownDevice(manufacturer: 'New radio', appVersion: 'new');
    await Future<void>.delayed(Duration.zero);

    final preferences = await SharedPreferences.getInstance();
    final beforeResponse =
        jsonDecode(preferences.getString(DeviceModelService.outboxKey)!);
    final beforeEntry = (beforeResponse['entries'] as Map)['newradio'] as Map;
    expect(beforeEntry['generation'], 2);
    expect(beforeEntry['app_version'], 'new');

    response.complete(DeviceReportAcknowledgement.pending);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final stored =
        jsonDecode(preferences.getString(DeviceModelService.outboxKey)!);
    final entry = (stored['entries'] as Map)['newradio'] as Map;
    expect(calls, 1);
    expect(entry['app_version'], 'new');
  });

  test('retains only the fifty newest unknown identities', () async {
    SharedPreferences.setMockInitialValues({});
    final service = DeviceModelService(
      fetchCatalog: () async => catalog(),
      reportUnknown: (_, __, ___) async => null,
    );
    await service.initialize();
    await service.refreshFuture;
    for (var i = 0; i < 51; i++) {
      service.observeUnknownDevice(
          manufacturer: 'Unknown $i', appVersion: 'APP');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final preferences = await SharedPreferences.getInstance();
    final stored =
        jsonDecode(preferences.getString(DeviceModelService.outboxKey)!);
    final entries = stored['entries'] as Map;
    expect(entries.length, 50);
    expect(entries.containsKey('unknown0'), isFalse);
    expect(entries.containsKey('unknown50'), isTrue);
  });

  test('a failed serialized operation does not block a later identity',
      () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final service = DeviceModelService(
      fetchCatalog: () async => catalog(),
      reportUnknown: (name, _, __) async {
        calls++;
        if (name == 'First') throw StateError('report failure');
        return DeviceReportAcknowledgement.pending;
      },
    );
    await service.initialize();
    await service.refreshFuture;
    service.observeUnknownDevice(manufacturer: 'First', appVersion: 'APP');
    await Future<void>.delayed(Duration.zero);
    service.observeUnknownDevice(manufacturer: 'Second', appVersion: 'APP');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(calls, 2);
  });

  test('drops malformed persisted entries and accepts later valid work',
      () async {
    SharedPreferences.setMockInitialValues({
      DeviceModelService.outboxKey: jsonEncode({
        'version': 1,
        'entries': {
          'broken': {'manufacturer': 7, 'generation': 'bad'},
        },
      }),
    });
    final calls = <String>[];
    final service = DeviceModelService(
      fetchCatalog: () async => catalog(),
      reportUnknown: (manufacturer, _, __) async {
        calls.add(manufacturer);
        return null;
      },
    );
    await service.initialize();
    await service.refreshFuture;
    service.observeUnknownDevice(manufacturer: 'Valid', appVersion: 'APP');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(calls, ['Valid']);
  });
}
