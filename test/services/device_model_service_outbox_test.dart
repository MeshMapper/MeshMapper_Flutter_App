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
    final stored = jsonDecode(preferences.getString(DeviceModelService.outboxKey)!);
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
}
