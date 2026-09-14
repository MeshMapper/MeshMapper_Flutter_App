import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/connection_state.dart';
import 'package:mesh_mapper/models/device_catalog.dart';
import 'package:mesh_mapper/services/device_model_service.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';

import 'device_catalog_storage_races_test.dart' show DurableStorage;
import 'device_model_service_catalog_test.dart' show catalogJson;
import 'meshcore/catalog_protocol_transport.dart';

void main() {
  test(
      'real handshake resolves after query and self-info using refreshed catalog',
      () async {
    final refresh = Completer<DeviceCatalog?>();
    final storage = DurableStorage({
      DeviceModelService.catalogCacheKey:
          DeviceCatalog.fromJson(catalogJson(1)).toJsonString()
    });
    final service = DeviceModelService(
        loadStorage: () async => storage, fetchCatalog: () => refresh.future);
    await service.initialize();
    final transport = CatalogProtocolTransport(beforeSelfInfo: () async {
      final fresh = catalogJson(2);
      (fresh['devices'] as List).single['power'] = 2.0;
      refresh.complete(DeviceCatalog.fromJson(fresh));
      await service.refreshFuture;
    });
    final connection = MeshCoreConnection(transport: transport);
    addTearDown(() {
      connection.dispose();
      transport.dispose();
    });
    var resolutions = 0;
    final result = await connection.connect((name) {
      resolutions++;
      expect(transport.writes.map((frame) => frame.first), [
        CommandCodes.deviceQuery,
        CommandCodes.appStart,
        CommandCodes.appStart
      ]);
      expect(connection.selfInfo?.name, 'Radio B');
      expect(connection.devicePublicKey, isNotNull);
      expect(name, 'Tracker');
      return service.resolveForConnection(name);
    });
    expect(result.deviceModelMatched, isTrue);
    expect(result.deviceModel?.power, 2.0);
    expect(connection.currentStep, ConnectionStep.connected);
    expect(resolutions, 1);
    expect(
        transport.writes.any((frame) => frame.first == CommandCodes.setTxPower),
        isFalse);
  });

  for (final outcome in ['null', 'throw']) {
    test('real handshake continues unknown when resolver returns $outcome',
        () async {
      final transport = CatalogProtocolTransport();
      final connection = MeshCoreConnection(transport: transport);
      addTearDown(() {
        connection.dispose();
        transport.dispose();
      });
      final result = await connection.connect((_) async {
        if (outcome == 'throw') throw StateError('catalog unavailable');
        return null;
      });
      expect(result.deviceModel, isNull);
      expect(result.deviceModelMatched, isFalse);
      expect(connection.currentStep, ConnectionStep.connected);
      expect(transport.writes.map((frame) => frame.first),
          contains(CommandCodes.getChannel));
    });
  }

  test('late refresh cannot replace the model selected by a real connection',
      () async {
    final refresh = Completer<DeviceCatalog?>();
    final service = DeviceModelService(
        loadStorage: () async => DurableStorage({
              DeviceModelService.catalogCacheKey:
                  DeviceCatalog.fromJson(catalogJson(1)).toJsonString()
            }),
        fetchCatalog: () => refresh.future);
    final transport = CatalogProtocolTransport();
    final connection = MeshCoreConnection(transport: transport);
    addTearDown(() {
      connection.dispose();
      transport.dispose();
    });
    final result = await connection.connect(service.resolveForConnection);
    final fresh = catalogJson(2);
    (fresh['devices'] as List).single['power'] = 2.0;
    refresh.complete(DeviceCatalog.fromJson(fresh));
    await service.refreshFuture;
    expect(connection.deviceModel, same(result.deviceModel));
    expect(connection.deviceModel?.power, 0.3);
    expect((await service.resolveForConnection('Tracker'))?.power, 2.0);
  });
}
