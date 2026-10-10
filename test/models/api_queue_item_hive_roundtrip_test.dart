import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:hive/src/hive_impl.dart';
import 'package:mesh_mapper/models/api_queue_item.dart';

/// The generated adapter as it existed before fields 21 to 23 (`scopes`,
/// `altitudeRef`, `altitudeAccuracy`) were added: writes only fields 0-20.
/// A record written with TODAY's adapter always carries field 21 (as an explicit null when [ApiQueueItem.scopes]
/// is null), so it does not exercise a reader's handling of a field that is
/// genuinely ABSENT from the binary data, the shape every item recorded
/// before this migration actually has on disk. This adapter, run against a
/// separate `HiveImpl` instance (its own adapter registry, so it can
/// register a different `ApiQueueItemAdapter` for typeId 3 without
/// colliding with the real one this file registers on the global `Hive`),
/// produces that genuine shape.
class _LegacyApiQueueItemAdapter extends TypeAdapter<ApiQueueItem> {
  @override
  final int typeId = 3;

  @override
  ApiQueueItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ApiQueueItem(
      type: fields[0] as String,
      latitude: fields[1] as double,
      longitude: fields[2] as double,
      timestamp: fields[3] as DateTime,
      heardRepeats: fields[12] as String,
      canUploadAfter: fields[13] as int,
      externalAntenna: fields[14] as bool,
      retryCount: fields[5] as int,
      lastRetryAt: fields[6] as DateTime?,
      noiseFloor: fields[11] as int?,
      power: fields[15] as double?,
      pingCounter: fields[16] as int?,
      wireTag: fields[17] as String?,
      altitude: fields[18] as double?,
      autoMode: fields[19] as String?,
      radioFreq: fields[20] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, ApiQueueItem obj) {
    writer
      ..writeByte(16)
      ..writeByte(0)
      ..write(obj.type)
      ..writeByte(1)
      ..write(obj.latitude)
      ..writeByte(2)
      ..write(obj.longitude)
      ..writeByte(3)
      ..write(obj.timestamp)
      ..writeByte(5)
      ..write(obj.retryCount)
      ..writeByte(6)
      ..write(obj.lastRetryAt)
      ..writeByte(11)
      ..write(obj.noiseFloor)
      ..writeByte(12)
      ..write(obj.heardRepeats)
      ..writeByte(13)
      ..write(obj.canUploadAfter)
      ..writeByte(14)
      ..write(obj.externalAntenna)
      ..writeByte(15)
      ..write(obj.power)
      ..writeByte(16)
      ..write(obj.pingCounter)
      ..writeByte(17)
      ..write(obj.wireTag)
      ..writeByte(18)
      ..write(obj.altitude)
      ..writeByte(19)
      ..write(obj.autoMode)
      ..writeByte(20)
      ..write(obj.radioFreq);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _LegacyApiQueueItemAdapter && runtimeType == other.runtimeType;
}

/// The generated adapter is gitignored and regenerated per machine, so a
/// stale one compiles cleanly while silently dropping field 19 or 20. Every
/// real upload reads its items back out of Hive, so the stamp must survive a
/// write and a read through the adapter, and a DEFER must come back a DEFER.

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mm_hive_');
    Hive.init(dir.path);
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(ApiQueueItemAdapter());
    }
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('the mode stamp survives the adapter', () async {
    final box = await Hive.openBox<ApiQueueItem>('roundtrip');
    await box.add(ApiQueueItem.fromRx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: '4e(12.0)',
      timestamp: 1757400000,
      externalAntenna: false,
      autoMode: 'hybrid',
    ));
    await box.close();

    final reopened = await Hive.openBox<ApiQueueItem>('roundtrip');
    final item = reopened.getAt(0)!;
    expect(item.type, 'RX');
    expect(item.autoMode, 'hybrid');
    expect(item.toApiJson()['auto_mode'], 'hybrid');
  });

  test('a DEFER comes back a DEFER and an unstamped item stays unstamped',
      () async {
    final box = await Hive.openBox<ApiQueueItem>('roundtrip2');
    await box.add(ApiQueueItem.fromDefer(
      latitude: 45.26974,
      longitude: -75.77746,
      timestamp: 1757400000,
      held: 'disc',
    ));
    await box.add(ApiQueueItem.fromTx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: 'None',
      timestamp: 1757400001,
      externalAntenna: true,
    ));
    await box.close();

    final reopened = await Hive.openBox<ApiQueueItem>('roundtrip2');
    final defer = reopened.getAt(0)!;
    final tx = reopened.getAt(1)!;
    expect(defer.toApiJson(), {
      'type': 'DEFER',
      'lat': 45.26974,
      'lon': -75.77746,
      'timestamp': 1757400000,
      'held': 'disc',
    });
    expect(tx.autoMode, isNull);
    expect(tx.toApiJson().containsKey('auto_mode'), isFalse);
  });

  test('the radio tag survives the adapter on a ping and on a DEFER',
      () async {
    final box = await Hive.openBox<ApiQueueItem>('roundtrip3');
    await box.add(ApiQueueItem.fromRx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: '4e(12.0)',
      timestamp: 1757400000,
      externalAntenna: false,
      radioFreq: '910.525,62.5,7,5',
    ));
    await box.add(ApiQueueItem.fromDefer(
      latitude: 45.0,
      longitude: -75.0,
      timestamp: 1757400001,
      held: 'tx',
      radioFreq: '906.875,250,10,5',
    ));
    await box.close();

    final reopened = await Hive.openBox<ApiQueueItem>('roundtrip3');
    expect(reopened.getAt(0)!.radioFreq, '910.525,62.5,7,5');
    expect(reopened.getAt(0)!.toApiJson()['radio_freq'], '910.525,62.5,7,5');
    expect(reopened.getAt(1)!.toApiJson()['radio_freq'], '906.875,250,10,5');
  });

  test('a SCOPES item survives the adapter with its scopes list intact',
      () async {
    final box = await Hive.openBox<ApiQueueItem>('roundtrip4');
    await box.add(ApiQueueItem.fromScopes(
      publicKeyHex:
          'A3B2C1D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2',
      scopes: const ['ROOM1', '*'],
      lat: 45.26974,
      lon: -75.77746,
      timestamp: 1757400000,
      radioFreq: '910.525,62.5,7,5',
    ));
    await box.close();

    final reopened = await Hive.openBox<ApiQueueItem>('roundtrip4');
    final item = reopened.getAt(0)!;
    expect(item.type, 'SCOPES');
    expect(item.scopes, ['ROOM1', '*']);
    expect(item.toApiJson(), {
      'type': 'SCOPES',
      'public_key':
          'A3B2C1D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2',
      'scopes': ['ROOM1', '*'],
      'timestamp': 1757400000,
      'lat': 45.26974,
      'lon': -75.77746,
      'radio_freq': '910.525,62.5,7,5',
    });
  });

  test('the altitude trio survives the adapter, and a null pair stays null',
      () async {
    final box = await Hive.openBox<ApiQueueItem>('roundtrip5');
    await box.add(ApiQueueItem.fromTx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: '4e(12.25)',
      timestamp: 1757400000,
      externalAntenna: false,
      altitude: 84.0,
      altitudeRef: 'msl',
      altitudeAccuracy: 6.0,
    ));
    await box.add(ApiQueueItem.fromTx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: 'None',
      timestamp: 1757400001,
      externalAntenna: false,
      altitude: 84.0,
    ));
    await box.close();

    final reopened = await Hive.openBox<ApiQueueItem>('roundtrip5');
    final labelled = reopened.getAt(0)!;
    final bare = reopened.getAt(1)!;
    expect(labelled.altitudeRef, 'msl');
    expect(labelled.altitudeAccuracy, 6.0);
    expect(labelled.toApiJson()['altitude_ref'], 'msl');
    expect(labelled.toApiJson()['altitude_acc'], 6);
    expect(bare.altitudeRef, isNull);
    expect(bare.altitudeAccuracy, isNull);
    expect(bare.toApiJson().containsKey('altitude'), isFalse);
  });

  test(
      'a record genuinely lacking field 21 (written before it existed) '
      'reads scopes as null through the real adapter', () async {
    // A separate Hive instance/registry, isolated from the global `Hive`
    // this file's setUp registers the real adapter on, writes to the same
    // directory using the OLD adapter shape: field 21 is not merely null,
    // it is not written at all.
    final legacyHive = HiveImpl()..init(dir.path);
    legacyHive.registerAdapter(_LegacyApiQueueItemAdapter());
    final legacyBox = await legacyHive.openBox<ApiQueueItem>('legacy');
    await legacyBox.add(ApiQueueItem.fromRx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: '4e(12.0)',
      timestamp: 1757400000,
      externalAntenna: false,
    ));
    await legacyBox.close();

    // The real adapter (registered on the global `Hive` in setUp) reads
    // that same directory back.
    final reopened = await Hive.openBox<ApiQueueItem>('legacy');
    final item = reopened.getAt(0)!;
    expect(item.type, 'RX');
    expect(item.scopes, isNull);
    expect(item.altitudeRef, isNull);
    expect(item.altitudeAccuracy, isNull);
    expect(item.toApiJson().containsKey('altitude_ref'), isFalse);
    expect(item.toApiJson().containsKey('scopes'), isFalse);
  });
}
