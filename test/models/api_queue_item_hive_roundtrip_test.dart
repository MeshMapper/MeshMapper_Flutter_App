import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mesh_mapper/models/api_queue_item.dart';

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
}
