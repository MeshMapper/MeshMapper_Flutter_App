import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mesh_mapper/models/noise_floor_session.dart';

void main() {
  test('saved history keeps overlapping deferrals and existing ping types',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('deferred-history-');
    Hive.init(directory.path);
    Hive.registerAdapter(PingEventTypeAdapter());
    Hive.registerAdapter(PingEventMarkerAdapter());
    try {
      var box = await Hive.openBox<PingEventMarker>('markers');
      final time = DateTime(2026, 9, 12, 12);
      for (final type in [
        PingEventType.txSuccess,
        PingEventType.deferred,
        PingEventType.deferred
      ]) {
        await box.add(PingEventMarker(
            timestamp: time,
            type: type,
            noiseFloor: -100,
            latitude: 45,
            longitude: -75));
      }
      await box.close();
      box = await Hive.openBox<PingEventMarker>('markers');
      expect(box.values.map((m) => m.type), [
        PingEventType.txSuccess,
        PingEventType.deferred,
        PingEventType.deferred,
      ]);
      expect(box.values.map((m) => m.latitude), [45, 45, 45]);
    } finally {
      await Hive.close();
      Hive.resetAdapters();
      await directory.delete(recursive: true);
    }
  });
}
