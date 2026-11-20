import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mesh_mapper/models/map_view_state.dart';

void main() {
  group('MapViewState defaults', () {
    test('a first launch keeps today\'s layout and no remembered zoom', () {
      const s = MapViewState();
      expect(s.zoom, isNull);
      expect(s.controlsMinimized, isFalse);
      expect(s.controlPanelShown, isTrue);
      expect(s.landscapeMapControlsExpanded, isFalse);
      expect(s.mapControlsExpanded, isTrue);
    });

    test('nothing stored reads as the defaults', () {
      expect(MapViewState.fromStored(null), const MapViewState());
      expect(MapViewState.fromStored('junk'), const MapViewState());
      expect(MapViewState.fromStored(<String, dynamic>{}),
          const MapViewState());
    });

    test('a malformed field falls back to its own default only', () {
      final s = MapViewState.fromStored({
        'zoom': 'twelve',
        'controlsMinimized': 1,
        'controlPanelShown': false,
        'mapControlsExpanded': null,
      });
      expect(s.zoom, isNull);
      expect(s.controlsMinimized, isFalse);
      expect(s.controlPanelShown, isFalse);
      expect(s.mapControlsExpanded, isTrue);
    });
  });

  group('MapViewState persistence', () {
    test('round-trips every field through storage', () {
      const s = MapViewState(
        zoom: 12.4,
        controlsMinimized: true,
        controlPanelShown: false,
        landscapeMapControlsExpanded: true,
        mapControlsExpanded: false,
      );
      expect(MapViewState.fromStored(s.toStorage()), s);
    });

    test('no zoom is written until one is recorded', () {
      expect(const MapViewState().toStorage().containsKey('zoom'), isFalse);
    });

    test('a stored zoom outside the map range is clamped on read', () {
      expect(MapViewState.fromStored({'zoom': 30}).zoom, MapViewState.maxZoom);
    });

    test('survives a Hive box close and reopen', () async {
      final dir = await Directory.systemTemp.createTemp('map-view-state-');
      Hive.init(dir.path);
      try {
        const s = MapViewState(zoom: 9.75, controlsMinimized: true);
        var box = await Hive.openBox('user_preferences');
        await box.put('map_view_state', s.toStorage());
        await box.close();
        box = await Hive.openBox('user_preferences');
        expect(MapViewState.fromStored(box.get('map_view_state')), s);
      } finally {
        await Hive.close();
        await dir.delete(recursive: true);
      }
    });
  });

  group('MapViewState.clampZoom', () {
    test('keeps an in-range zoom', () {
      expect(MapViewState.clampZoom(12.4), 12.4);
    });

    test('clamps to the map\'s min and max', () {
      expect(MapViewState.clampZoom(1.0),
          closeTo(MapViewState.minZoom + MapViewState.zoomEpsilon, 1e-9));
      expect(MapViewState.clampZoom(22.0), MapViewState.maxZoom);
      expect(
          MapViewState.clampZoom(MapViewState.maxZoom), MapViewState.maxZoom);
    });

    test('nudges an integer zoom off the integer', () {
      expect(MapViewState.clampZoom(14), closeTo(13.999, 1e-9));
    });

    test('rejects non-numbers and non-finite values', () {
      expect(MapViewState.clampZoom(null), isNull);
      expect(MapViewState.clampZoom('12'), isNull);
      expect(MapViewState.clampZoom(double.nan), isNull);
      expect(MapViewState.clampZoom(double.infinity), isNull);
    });
  });

  group('MapViewState.zoomWorthSaving', () {
    test('the first zoom is always worth saving', () {
      expect(MapViewState.zoomWorthSaving(null, 15.0), isTrue);
    });

    test('a camera idle at the same zoom is not', () {
      expect(MapViewState.zoomWorthSaving(15.0, 15.0), isFalse);
      expect(MapViewState.zoomWorthSaving(15.0, 15.005), isFalse);
    });

    test('a real zoom change is', () {
      expect(MapViewState.zoomWorthSaving(15.0, 14.5), isTrue);
      expect(MapViewState.zoomWorthSaving(15.0, 15.02), isTrue);
    });

    test('a non-finite camera zoom never is', () {
      expect(MapViewState.zoomWorthSaving(15.0, double.nan), isFalse);
      expect(MapViewState.zoomWorthSaving(null, double.infinity), isFalse);
    });
  });
}
