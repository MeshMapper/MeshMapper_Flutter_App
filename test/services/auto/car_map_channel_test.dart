import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/auto/car_map_channel.dart';
import 'package:mesh_mapper/widgets/map_widget.dart' show gpsMarkerFacesHeading;
import 'package:mesh_mapper/services/watch/watch_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('meshmapper/car_map_test');
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });

  CarMapChannel build() => CarMapChannel(channel: channel);

  test('sends the camera through to native', () async {
    await build().setCamera(lat: 47.6, lon: -122.3, bearing: 90);
    expect(calls.single.method, 'setCamera');
    expect(calls.single.arguments['lat'], 47.6);
    expect(calls.single.arguments['lon'], -122.3);
    expect(calls.single.arguments['bearing'], 90);
  });

  // GPS ticks at 1–2 Hz and jitters below a metre. Forwarding every one would
  // be a platform round-trip per tick for a camera move no driver can see.
  test('sub-metre jitter does not reach native', () async {
    final map = build();
    await map.setCamera(lat: 47.600000, lon: -122.300000);
    await map.setCamera(lat: 47.600001, lon: -122.300001);
    expect(calls, hasLength(1));
  });

  test('real movement does reach native', () async {
    final map = build();
    await map.setCamera(lat: 47.6000, lon: -122.3000);
    await map.setCamera(lat: 47.6010, lon: -122.3000);
    expect(calls, hasLength(2));
  });

  test('a style change is sent', () async {
    final map = build();
    await map.setStyle('https://tiles.openfreemap.org/styles/dark');
    await map.setStyle('https://tiles.openfreemap.org/styles/bright');
    expect(calls, hasLength(2));
  });

  test('an empty style is ignored', () async {
    await build().setStyle('');
    expect(calls, isEmpty);
  });

  group('settings', () {
    CarMapSettings settings({
      bool northUp = true,
      bool rotationLocked = false,
      String style = 'https://tiles.openfreemap.org/styles/dark',
      String marker = 'arrow',
    }) =>
        CarMapSettings.from(
          styleUrl: style,
          zoneCode: 'sea',
          tilesEnabled: true,
          gridSize: 300,
          colorVisionType: 'none',
          opacity: 0.7,
          mapAlwaysNorth: northUp,
          mapRotationLocked: rotationLocked,
          markerStyle: marker,
          markerFacesHeading: gpsMarkerFacesHeading(marker),
        );

    // mapAlwaysNorth defaults true, so getting this wrong rotates the car map
    // for most people who never asked for it.
    test('north-up is honoured', () {
      expect(settings(northUp: true).northUp, isTrue);
      expect(settings(northUp: false).northUp, isFalse);
    });

    test('the marker style and its rotation rule ride along', () {
      expect(settings(marker: 'arrow').markerStyle, 'arrow');
      expect(settings(marker: 'arrow').markerFacesHeading, isTrue);
      // Car, bike and boat stay upright on a rotated map.
      expect(settings(marker: 'car').markerFacesHeading, isFalse);
    });

    test('a rotation lock also means north-up', () {
      expect(settings(northUp: false, rotationLocked: true).northUp, isTrue);
    });

    // The satellite style is an inline style document, not a URL. Anything that
    // trims, normalises or url-encodes it on the way through breaks it.
    test('an inline style document passes through unmangled', () {
      const doc = '{"version":8,"sources":{}}';
      expect(settings(style: doc).styleUrl, doc);
    });
  });

  group('pings', () {
    WatchPing ping(String id, double lat, double lon, WatchColor color) =>
        WatchPing(
          id: id,
          lat: lat,
          lon: lon,
          kind: 'tx',
          color: color,
          at: DateTime.fromMillisecondsSinceEpoch(1760000000000),
        );

    test('one feature per ping, with its resolved colour', () {
      final json = jsonDecode(encodePingsGeoJson([
        ping('a', 47.6, -122.3, const WatchColor(1, 0, 0)),
        ping('b', 47.7, -122.4, const WatchColor(0, 1, 0)),
      ])) as Map<String, Object?>;

      expect(json['type'], 'FeatureCollection');
      final features = json['features'] as List;
      expect(features, hasLength(2));
      expect((features.first as Map)['properties'], {
        'color': '#ff0000',
        'kind': 'tx',
      });
      expect((features.last as Map)['properties'], contains('color'));
    });

    // GeoJSON is lon,lat. Getting it backwards produces a map that looks
    // plausible and is wrong.
    test('coordinates are lon,lat', () {
      final json = jsonDecode(
        encodePingsGeoJson(
            [ping('a', 47.6, -122.3, const WatchColor(1, 1, 1))]),
      ) as Map<String, Object?>;
      final geometry =
          ((json['features'] as List).single as Map)['geometry'] as Map;
      expect(geometry['coordinates'], [-122.3, 47.6]);
    });

    test('no pings is an empty collection, not a missing one', () {
      final json = jsonDecode(encodePingsGeoJson([])) as Map<String, Object?>;
      expect(json['features'], isEmpty);
    });

    test('is sent, then deduped', () async {
      final map = build();
      final one = [ping('a', 47.6, -122.3, const WatchColor(1, 0, 0))];
      await map.setPings(one);
      await map.setPings([...one]);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setPings');
    });

    test('a new ping is sent', () async {
      final map = build();
      await map.setPings([ping('a', 47.6, -122.3, const WatchColor(1, 0, 0))]);
      await map.setPings([
        ping('a', 47.6, -122.3, const WatchColor(1, 0, 0)),
        ping('b', 47.7, -122.4, const WatchColor(0, 1, 0)),
      ]);
      expect(calls, hasLength(2));
    });
  });

  group('timer', () {
    final deadline = DateTime.fromMillisecondsSinceEpoch(1760000030000);

    test('deadline and duration cross, nothing per-second', () async {
      await build()
          .setTimer(endsAt: deadline, durationMs: 30000, argbColor: 0xFFFF0000);
      expect(calls.single.method, 'setTimer');
      expect(calls.single.arguments['endsAtMs'], 1760000030000);
      expect(calls.single.arguments['durationMs'], 30000);
    });

    // A phase with no deadline must clear the bar, not leave a stuck one.
    test('a deadline-less phase clears it', () async {
      await build().setTimer();
      expect(calls.single.arguments['endsAtMs'], isNull);
      expect(calls.single.arguments['durationMs'], isNull);
    });

    test('an unchanged phase is not re-sent', () async {
      final map = build();
      await map.setTimer(endsAt: deadline, durationMs: 30000);
      await map.setTimer(endsAt: deadline, durationMs: 30000);
      expect(calls, hasLength(1));
    });

    test('a new cycle is sent', () async {
      final map = build();
      await map.setTimer(endsAt: deadline, durationMs: 30000);
      await map.setTimer(
        endsAt: deadline.add(const Duration(seconds: 30)),
        durationMs: 30000,
      );
      expect(calls, hasLength(2));
    });
  });

  // The style is deliberately not deduped on this side: a load is asynchronous
  // and can fail, and caching what we sent would remember a failure as a
  // success and never retry. Native dedupes on what actually loaded.
  test('the style is re-sent every time', () async {
    final map = build();
    await map.setStyle('https://tiles.openfreemap.org/styles/dark');
    await map.setStyle('https://tiles.openfreemap.org/styles/dark');
    expect(calls, hasLength(2));
  });

  group('the position marker', () {
    final png = Uint8List.fromList(const [1, 2, 3, 4]);

    test('is sent once, then deduped on the style name', () async {
      final map = build();
      await map.setPositionMarker(style: 'arrow', png: png, facesHeading: true);
      await map.setPositionMarker(style: 'arrow', png: png, facesHeading: true);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setPositionMarker');
      expect(calls.single.arguments['facesHeading'], isTrue);
    });

    test('a style change re-sends it', () async {
      final map = build();
      await map.setPositionMarker(style: 'arrow', png: png, facesHeading: true);
      await map.setPositionMarker(style: 'car', png: png, facesHeading: false);
      expect(calls, hasLength(2));
      expect(calls.last.arguments['facesHeading'], isFalse);
    });
  });

  group('camera bearing versus marker heading', () {
    // The subtle one. In north-up mode the camera bearing is deliberately null
    // so the map does not turn, but the marker still has to point along the
    // direction of travel. Collapsing these into one field leaves the arrow
    // stuck pointing north on the setting most people have on by default.
    test('heading survives while bearing is nulled', () async {
      await build().setCamera(
        lat: 47.6,
        lon: -122.3,
        bearing: null,
        heading: 90,
      );
      expect(calls.single.arguments['bearing'], isNull);
      expect(calls.single.arguments['heading'], 90);
    });

    test('turning on the spot still moves the marker', () async {
      final map = build();
      await map.setCamera(lat: 47.6, lon: -122.3, heading: 0);
      await map.setCamera(lat: 47.6, lon: -122.3, heading: 90);
      expect(calls, hasLength(2),
          reason: 'position deduping must not swallow a heading change');
    });
  });

  // The channel exists only on Android, and only once the engine has registered
  // it. Every other platform must be a silent no-op, not a crash on a GPS tick.
  group('coverage', () {
    CarMapCoverage? forZone({
      String? zone = 'sea',
      int gridSize = 300,
      String cvd = 'none',
      double opacity = 0.7,
      bool tilesEnabled = true,
    }) =>
        CarMapCoverage.forZone(
          zoneCode: zone,
          gridSize: gridSize,
          colorVisionType: cvd,
          opacity: opacity,
          tilesEnabled: tilesEnabled,
        );

    // The user turns tiles off to stop spending a tethered connection.
    // Honouring that only on the phone spends it anyway, where they cannot see.
    test('tiles switched off means nothing to draw', () {
      expect(forZone(tilesEnabled: false), isNull);
    });

    test('the tile url carries the zone and grid size', () {
      final coverage = forZone(zone: 'SEA', gridSize: 500)!;
      expect(
        coverage.tileUrl,
        'https://sea.meshmapper.net/vector_tile.php'
        '?z={z}&x={x}&y={y}&gsize=500',
      );
    });

    // Zone and grid size live in the URL, so either changing is a different
    // source — not a restyled one. The dedupe below has to see that.
    test('a grid change is a different overlay', () {
      expect(forZone(gridSize: 300), isNot(forZone(gridSize: 500)));
    });

    test('a zone change is a different overlay', () {
      expect(forZone(zone: 'sea'), isNot(forZone(zone: 'pdx')));
    });

    test('there is nothing to draw before a zone is known', () {
      expect(forZone(zone: null), isNull);
      expect(forZone(zone: ''), isNull);
    });

    test('a fully transparent overlay is nothing to draw', () {
      expect(forZone(opacity: 0), isNull);
    });

    // Dart owns the palette; native must never hold a second copy that drifts.
    // What crosses the channel is a finished MapLibre expression.
    test('the palette crosses as a MapLibre match expression', () {
      final coverage = forZone()!;
      final fill = jsonDecode(coverage.fillColor) as List;
      expect(fill.first, 'match');
      expect(fill[1], ['get', 'st']);
      expect(fill, contains('#1e7e34'), reason: 'st 1 green, from the palette');
      expect(
        jsonDecode(coverage.outlineColor) as List,
        contains('#14522d'),
        reason: 'st 1 border, from the palette',
      );
    });

    test('a colour-vision mode changes the expression', () {
      expect(forZone(cvd: 'none')!.fillColor,
          isNot(forZone(cvd: 'protanopia')!.fillColor));
    });

    test('is sent to native', () async {
      await build().setCoverage(forZone());
      expect(calls.single.method, 'setCoverage');
      expect(calls.single.arguments['tileUrl'], contains('sea.meshmapper.net'));
      expect(calls.single.arguments['opacity'], 0.7);
    });

    // Re-applying rebuilds the layer, which restarts every tile request —
    // expensive on a tether and visible as a flash of empty map.
    test('an unchanged overlay is not re-sent', () async {
      final map = build();
      await map.setCoverage(forZone());
      await map.setCoverage(forZone());
      expect(calls, hasLength(1));
    });

    test('a changed overlay is re-sent', () async {
      final map = build();
      await map.setCoverage(forZone(gridSize: 300));
      await map.setCoverage(forZone(gridSize: 500));
      expect(calls, hasLength(2));
    });

    test('clearing is sent once, then deduped', () async {
      final map = build();
      await map.setCoverage(null);
      await map.setCoverage(null);
      expect(calls, hasLength(1));
      expect(calls.single.arguments, isEmpty);
    });
  });

  test('a missing native side is not fatal', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await expectLater(
      build().setCamera(lat: 47.6, lon: -122.3),
      completes,
    );
  });
}
