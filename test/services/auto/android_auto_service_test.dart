import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_carplay/controllers/android_auto_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/auto/android_auto_service.dart';
import 'package:mesh_mapper/services/auto/auto_glance_view.dart';
import 'package:mesh_mapper/services/auto/car_map_channel.dart';
import 'package:mesh_mapper/services/external_surfaces/geo/external_surface_geo_models.dart';
import 'package:mesh_mapper/services/live_activity/live_activity_models.dart';
import 'package:mesh_mapper/services/watch/watch_models.dart';

const String _methodChannelName = 'com.oguzhnatly.flutter_android_auto';
const String _carMapChannelName = 'meshmapper/car_map_ordering_test';
const String _eventChannelName = 'com.oguzhnatly.flutter_android_auto/event';

final DateTime _now = DateTime.fromMillisecondsSinceEpoch(1760000000000);

WatchSnapshot _snapshot({
  bool withPosition = false,
  int txCount = 0,
  bool isSessionActive = true,
  String sessionId = 'session-1',
  LiveActivityPhase phase = LiveActivityPhase.listening,
  String phaseTitle = 'Listening',
}) =>
    WatchSnapshot(
      core: LiveActivitySnapshot(
        sessionId: sessionId,
        mode: 'Active',
        phase: phase,
        phaseTitle: phaseTitle,
        phaseDetail: 'Waiting for echoes',
        isConnected: true,
        zoneCode: 'SEA',
        txCount: txCount,
        rxCount: 0,
        discoveryCount: 0,
        traceCount: 0,
        queueSize: 0,
        repeaters: const [],
        totalHeardCount: 0,
        repeatersAreCurrent: true,
        updatedAt: _now,
      ),
      geo: ExternalSurfaceGeo(
        pings: const [],
        repeaters: const [],
        heard: const [],
        linkedRepeaterIds: const [],
        you: withPosition
            ? ExternalSurfacePosition(lat: 47.6, lon: -122.3, fixedAt: _now)
            : null,
      ),
      controls: WatchControls(
        canStartStop: true,
        canManualPing: false,
        isSessionActive: isSessionActive,
      ),
      updatedAt: _now,
    );

/// Records what the surface sends native, so a test can assert on the sequence
/// rather than on the plugin's internals.
class _NativeRecorder {
  final List<String> calls = <String>[];
  final List<Map<Object?, Object?>> templates = <Map<Object?, Object?>>[];

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel(_methodChannelName),
      (MethodCall call) async {
        calls.add(call.method);
        final args = call.arguments;
        if (args is Map && args['template'] is Map) {
          templates.add(args['template'] as Map<Object?, Object?>);
        }
        return true;
      },
    );
    // The event channel's listen/cancel arrive as method calls on a channel of
    // the same name.
    messenger.setMockMethodCallHandler(
      const MethodChannel(_eventChannelName),
      (MethodCall call) async => null,
    );
  }

  void clear() {
    calls.clear();
    templates.clear();
  }
}

Future<void> _emit(Object event) async {
  const codec = StandardMethodCodec();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    _eventChannelName,
    codec.encodeSuccessEnvelope(event),
    (_) {},
  );
}

Future<void> _connect() => _emit({
      'type': 'onAndroidAutoConnectionChange',
      'data': {'status': 'connected'},
    });

Future<void> _disconnect() => _emit({
      'type': 'onAndroidAutoConnectionChange',
      'data': {'status': 'disconnected'},
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _NativeRecorder native;
  late AndroidAutoService service;
  late WatchSnapshot current;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    // Static across instances in the plugin; a leftover entry would make an
    // update look like it matched when it did not.
    FlutterAndroidAutoController.templateHistory.clear();
    native = _NativeRecorder()..install();
    current = _snapshot();
  });

  tearDown(() {
    service.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  AndroidAutoService build({
    Duration debounce = Duration.zero,
    Duration floor = const Duration(seconds: 1),
    AutoCommandHandler? onCommand,
    AutoCommandRefusalHandler? onRefusal,
    CarMapSettingsBuilder? settings,
    Future<Uint8List> Function(String)? markerRenderer,
  }) {
    service = AndroidAutoService(
      debounceDelay: debounce,
      minimumNonUrgentInterval: floor,
      carMap: CarMapChannel(channel: const MethodChannel(_carMapChannelName)),
      markerRenderer: markerRenderer,
    )..attach(
        snapshotBuilder: () => current,
        commandHandler: onCommand ?? (_) => null,
        onRefusal: onRefusal,
        carMapSettingsBuilder: settings,
      );
    return service;
  }

  /// The ordering this pins is load-bearing and easy to lose.
  ///
  /// `_publish` runs `_syncMap` *above* the fingerprint gate. A settings change
  /// alters no pane text, so its fingerprint is unchanged and the gate returns
  /// early — if the map sync sat below it, every settings change would be
  /// swallowed and the head unit would quietly keep the old style, palette and
  /// coverage. That failure is invisible in tests and only shows up in a car.
  group('settings reach the map even when the pane does not change', () {
    late List<String> carMapCalls;

    setUp(() {
      carMapCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(_carMapChannelName),
        (call) async {
          carMapCalls.add(call.method);
          return true;
        },
      );
    });

    /// Rendering the marker rasterizes a CustomPainter, which needs the
    /// engine's raster thread — and a backgrounded phone, which is exactly the
    /// car case, may not be pumping it. When that render ran before the camera,
    /// one stall left the camera unset and the head unit showed a whole-world
    /// view over null island. Nothing cosmetic may precede the thing that
    /// decides where the map looks.
    test('the camera is sent even when the marker cannot be rendered',
        () async {
      build(
        settings: () => CarMapSettings.from(
          styleUrl: 'https://tiles.openfreemap.org/styles/dark',
          zoneCode: 'sea',
          tilesEnabled: true,
          gridSize: 300,
          colorVisionType: 'none',
          opacity: 0.7,
          mapAlwaysNorth: true,
          mapRotationLocked: false,
          markerStyle: 'arrow',
          markerFacesHeading: true,
        ),
        markerRenderer: (_) => Future<Uint8List>.error(
          StateError('no rasterizer'),
        ),
      );
      current = _snapshot(withPosition: true);
      await _connect();
      await pumpEventQueue();

      expect(carMapCalls, contains('setCamera'));
    });

    test('a publish with an unchanged fingerprint still syncs the map',
        () async {
      build(
        settings: () => CarMapSettings.from(
          styleUrl: 'https://tiles.openfreemap.org/styles/dark',
          zoneCode: 'sea',
          tilesEnabled: true,
          gridSize: 300,
          colorVisionType: 'none',
          opacity: 0.7,
          mapAlwaysNorth: true,
          mapRotationLocked: false,
          markerStyle: 'arrow',
          markerFacesHeading: true,
        ),
      );
      await _connect();
      await pumpEventQueue();

      // Everything the pane renders is identical, so the template is skipped.
      native.clear();
      carMapCalls.clear();
      service.schedule(immediate: true);
      await pumpEventQueue();

      expect(native.calls, isEmpty, reason: 'the pane really is unchanged');
      expect(carMapCalls, contains('setStyle'),
          reason: 'but the map must still be told');
    });

    /// The pane's update floor is quota insurance for template refreshes. The
    /// map costs no quota, and a driver's camera must not inherit a text
    /// throttle: at a one-second floor the map would lag a moving vehicle by up
    /// to a second, and at the thirty here it would look frozen. This is why
    /// the two run on separate paths rather than sharing one publisher.
    test('the pane floor does not throttle the map', () async {
      build(
        floor: const Duration(seconds: 30),
        settings: () => CarMapSettings.from(
          styleUrl: 'https://tiles.openfreemap.org/styles/dark',
          zoneCode: 'sea',
          tilesEnabled: true,
          gridSize: 300,
          colorVisionType: 'none',
          opacity: 0.7,
          mapAlwaysNorth: true,
          mapRotationLocked: false,
          markerStyle: 'arrow',
          markerFacesHeading: true,
        ),
      );
      await _connect();
      await pumpEventQueue();
      native.clear();
      carMapCalls.clear();

      // A counter change: the pane's text differs, but nothing in it is urgent,
      // so the floor holds the template back.
      current = _snapshot(txCount: 1);
      service.schedule(immediate: true);
      await pumpEventQueue();

      expect(native.calls, isEmpty, reason: 'the pane is inside its floor');
      expect(carMapCalls, contains('setStyle'),
          reason: 'the map is not, and never was');
    });
  });

  test('publishes nothing until the car connects', () async {
    build().schedule(immediate: true);
    await pumpEventQueue();
    expect(native.calls, isEmpty);
  });

  test('always re-sets the root template, never updatePaneTemplate', () async {
    build();
    await _connect();
    await pumpEventQueue();
    expect(native.calls, ['setRootTemplate']);

    native.clear();
    current =
        _snapshot(phase: LiveActivityPhase.sending, phaseTitle: 'Sending');
    service.schedule(immediate: true);
    await pumpEventQueue();
    // updatePaneTemplate rebuilds the addressed element *as* the root, which
    // would swap the map out for a bare pane.
    expect(native.calls, ['setRootTemplate']);
  });

  test('the root is a map template wrapping the pane', () async {
    build();
    await _connect();
    await pumpEventQueue();

    final root = native.templates.single;
    expect(root['contentRuntimeType'], 'FAAPaneTemplate');
    final content = root['contentTemplate'] as Map<Object?, Object?>;
    expect(content['_elementId'], autoGlanceTemplateId);
    // An empty title means no header row. The panel's width is the host's, so
    // the header was the only part of it we could give back to the map — and a
    // stray title would quietly take it again.
    expect(content['title'], isEmpty);
    expect((content['items'] as List), hasLength(1),
        reason: 'one status row, not a menu — the map needs the space');
    expect((content['actions'] as List), isEmpty,
        reason: 'the controls are in the map action strip');
    expect((root['mapActions'] as List), hasLength(1),
        reason: 'one toggle button, not a permanent Start and Stop pair');
  });

  test('every update reuses the root template id', () async {
    build();
    await _connect();
    await pumpEventQueue();
    current =
        _snapshot(phase: LiveActivityPhase.sending, phaseTitle: 'Sending');
    service.schedule(immediate: true);
    await pumpEventQueue();

    // A fresh uuid per rebuild would leave the plugin matching nothing in its
    // template history, and the surface would silently desync.
    expect(native.templates, hasLength(2));
    for (final template in native.templates) {
      expect(template['_elementId'], autoGlanceMapTemplateId);
      expect(
        (template['contentTemplate'] as Map<Object?, Object?>)['_elementId'],
        autoGlanceTemplateId,
      );
    }
  });

  test('identical content is not sent twice', () async {
    build();
    await _connect();
    await pumpEventQueue();
    native.clear();

    service.schedule(immediate: true);
    service.schedule(immediate: true);
    await pumpEventQueue();
    expect(native.calls, isEmpty);
  });

  test('counter churn waits out the floor', () async {
    build(floor: const Duration(milliseconds: 200));
    await _connect();
    await pumpEventQueue();
    native.clear();

    current = _snapshot(txCount: 1);
    service.schedule(immediate: true);
    await pumpEventQueue();
    expect(native.calls, isEmpty, reason: 'inside the floor');

    await Future<void>.delayed(const Duration(milliseconds: 260));
    await pumpEventQueue();
    expect(native.calls, ['setRootTemplate'],
        reason: 'deferred, not dropped — the last pings of a run still draw');
  });

  test('an urgent change bypasses the floor', () async {
    build(floor: const Duration(seconds: 30));
    await _connect();
    await pumpEventQueue();
    native.clear();

    current =
        _snapshot(phase: LiveActivityPhase.sending, phaseTitle: 'Sending');
    service.schedule(immediate: true);
    await pumpEventQueue();
    expect(native.calls, ['setRootTemplate']);
  });

  test('a reconnect sends a fresh root template', () async {
    build();
    await _connect();
    await pumpEventQueue();
    native.clear();

    await _disconnect();
    await _connect();
    await pumpEventQueue();
    expect(native.calls, ['setRootTemplate'],
        reason:
            'the host no longer holds the template history we updated into');
  });

  test('a disconnected surface publishes nothing', () async {
    build();
    await _connect();
    await pumpEventQueue();
    await _disconnect();
    native.clear();

    current =
        _snapshot(phase: LiveActivityPhase.sending, phaseTitle: 'Sending');
    service.schedule(immediate: true);
    await pumpEventQueue();
    expect(native.calls, isEmpty);
  });

  test('is inert off Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    build();
    expect(service.isSupportedPlatform, isFalse);
    await _connect();
    await pumpEventQueue();
    expect(native.calls, isEmpty);
  });
}
