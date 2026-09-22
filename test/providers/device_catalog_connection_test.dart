import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/connection_state.dart';
import 'package:mesh_mapper/models/device_catalog.dart';
import 'package:mesh_mapper/models/user_preferences.dart';
import 'package:mesh_mapper/providers/device_connection_setup.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/services/device_model_service.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';

import '../services/device_catalog_storage_races_test.dart'
    show DurableStorage, settle;
import '../services/device_model_service_catalog_test.dart' show catalogJson;
import '../services/meshcore/catalog_protocol_transport.dart';

void main() {
  for (final offline in [false, true]) {
    for (final savedB in [false, true]) {
      for (final known in [false, true]) {
        test(
            'manual A then ${known ? "known" : "unknown"} B offline=$offline saved=$savedB uses this radio power',
            () async {
          final refresh = Completer<DeviceCatalog?>();
          final service = DeviceModelService(
              loadStorage: () async => DurableStorage({
                    DeviceModelService.catalogCacheKey:
                        DeviceCatalog.fromJson(catalogJson(1)).toJsonString()
                  }),
              fetchCatalog: () => refresh.future,
              reportUnknown: (_, __, ___) async => null);
          var preferences = const UserPreferences().copyWith(
              offlineMode: offline,
              powerLevel: 5,
              txPower: 30,
              powerLevelSet: true,
              autoPowerSet: false);
          final overrides = <String, Map<String, dynamic>>{
            'Radio A': {'powerLevel': 5.0, 'txPower': 30},
            if (savedB) 'Radio B': {'powerLevel': 1.0, 'txPower': 20},
          };
          final transport = CatalogProtocolTransport(
              manufacturer: known ? 'Tracker' : 'New hardware');
          final connection = MeshCoreConnection(transport: transport);
          addTearDown(() {
            connection.dispose();
            transport.dispose();
          });
          final authPowers = <double>[];
          if (!offline) {
            connection.onRequestAuth = () async {
              preferences = preferencesForConnectingDevice(
                  preferences: preferences,
                  model: connection.deviceModel,
                  deviceName: connection.selfInfo?.name,
                  savedOverrides: overrides);
              authPowers.add(preferences.powerLevel);
              expect(preferences.autoPowerSet, known && !savedB);
              expect(preferences.powerLevelSet, savedB);
              return {'success': true, 'session_id': 'TEST'};
            };
          }
          await connection.connect(service.resolveForConnection);
          preferences = prepareConnectedDevice(
              preferences: preferences,
              connection: connection,
              catalog: service,
              deviceName: 'Radio B',
              savedOverrides: overrides,
              appVersion: 'APP');
          expect(preferences.autoPowerSet, known && !savedB);
          expect(preferences.powerLevelSet, savedB);
          if (known || savedB) {
            expect(preferences.powerLevel, savedB ? 1.0 : 0.3);
          }
          expect(authPowers.length, offline ? 0 : 1);
          preferences = preferences.copyWith(
              powerLevel: 2,
              txPower: 9,
              autoPowerSet: false,
              powerLevelSet: true);
          overrides['Radio B'] = {'powerLevel': 2.0, 'txPower': 9};
          final fresh = catalogJson(2);
          (fresh['devices'] as List).single['power'] = 4.0;
          refresh.complete(DeviceCatalog.fromJson(fresh));
          await service.refreshFuture;
          expect(preferences.powerLevel, 2);
          preferences = prepareConnectedDevice(
              preferences: preferences,
              connection: connection,
              catalog: service,
              deviceName: 'Radio B',
              savedOverrides: overrides,
              appVersion: 'APP');
          expect(preferences.powerLevel, 2);
          expect(preferences.powerLevelSet, isTrue);
          expect(connection.deviceModel?.power, known ? 0.3 : null);
        });
      }
    }
  }

  for (final outcome in [
    'success',
    'report failure',
    'no catalog',
    'failed connection'
  ]) {
    test('production post-connect report gate: $outcome', () async {
      final reports = <List<String?>>[];
      final response = Completer<DeviceReportAcknowledgement?>();
      final storage = DurableStorage({
        if (outcome != 'no catalog')
          DeviceModelService.catalogCacheKey:
              DeviceCatalog.fromJson(catalogJson(1)).toJsonString()
      });
      final service = DeviceModelService(
          loadStorage: () async => storage,
          fetchCatalog: () async => null,
          reportUnknown: (name, app, firmware) {
            reports.add([name, app, firmware]);
            return response.future;
          });
      await service.initialize();
      final transport =
          CatalogProtocolTransport(manufacturer: 'Unknown hardware');
      final connection = MeshCoreConnection(transport: transport);
      addTearDown(() {
        connection.dispose();
        transport.dispose();
      });
      if (outcome == 'failed connection') {
        connection.onRequestAuth = () async => {'success': false};
      }
      UserPreferences apply() => prepareConnectedDevice(
          preferences: const UserPreferences(),
          connection: connection,
          catalog: service,
          deviceName: 'Radio B',
          savedOverrides: {},
          appVersion: 'APP');
      apply();
      await settle();
      expect(reports, isEmpty);
      if (outcome == 'failed connection') {
        await expectLater(
            connection.connect(service.resolveForConnection), throwsException);
      } else {
        await connection.connect(service.resolveForConnection);
      }
      apply();
      await settle();
      if (outcome == 'failed connection' || outcome == 'no catalog') {
        expect(reports, isEmpty);
        expect(storage.entries, isEmpty);
      } else {
        expect(reports, [
          ['Unknown hardware', 'APP', 'v1.14.0']
        ]);
        expect(connection.currentStep, ConnectionStep.connected);
        expect(storage.entries, contains('unknownhardware'));
        if (outcome == 'report failure') {
          response.completeError(StateError('report unavailable'));
        } else {
          response.complete(DeviceReportAcknowledgement.pending);
        }
        await settle();
        expect(connection.currentStep, ConnectionStep.connected);
        expect(storage.entries.isEmpty, outcome == 'success');
      }
    });
  }
}
