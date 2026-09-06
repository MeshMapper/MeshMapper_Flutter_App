import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_carplay/flutter_carplay.dart';
import 'package:uuid/uuid.dart';

import '../../utils/debug_logger_io.dart';
import '../../utils/serial_task_gate.dart';
import '../../widgets/map_widget.dart' show renderGpsMarkerPng;
import '../external_commands/external_command_models.dart';
import '../external_surfaces/external_surface_color.dart';
import '../external_surfaces/external_surface_publisher.dart';
import '../watch/watch_models.dart';
import 'auto_glance_view.dart';
import 'car_map_channel.dart';

typedef AutoCommandHandler = FutureOr<ExternalCommandReason?> Function(
  ExternalSessionCommand command,
);
typedef AutoCommandRefusalHandler = void Function(ExternalCommandReason reason);

class AndroidAutoService {
  AndroidAutoService({
    @visibleForTesting Duration debounceDelay = defaultDebounceDelay,
    @visibleForTesting
    Duration minimumNonUrgentInterval = defaultMinimumNonUrgentInterval,
    @visibleForTesting CarMapChannel? carMap,
    @visibleForTesting Future<Uint8List> Function(String style)? markerRenderer,
  })  : _debounceDelay = debounceDelay,
        _carMap = carMap ?? CarMapChannel(),
        _renderMarker = markerRenderer ?? renderGpsMarkerPng {
    _pane = ExternalSurfacePublisher<WatchSnapshot, AutoGlanceView>(
      debounceDelay: debounceDelay,
      minimumNonUrgentInterval: minimumNonUrgentInterval,
      isEnabled: () => isSupportedPlatform && _connected && !_isDisposed,
      preflightPolicy:
          ExternalSurfacePreflightPolicy.throttleAgainstPublishedUrgency,
      payloadBuilder: _buildView,
      fingerprintBuilder: (view) => view.fingerprint,
      urgencyKeyBuilder: (_) => _viewUnderConsideration?.urgencyKey,
      publish: _publishPane,
      onQueueError: (error) {
        debugLog('[AUTO] Update queue failed: $error');
      },
      restartDebounce: false,
    );
  }

  static const Duration defaultDebounceDelay = Duration(milliseconds: 250);
  static const Duration defaultMinimumNonUrgentInterval = Duration(seconds: 1);

  static const Duration _markerRenderTimeout = Duration(seconds: 5);

  final Duration _debounceDelay;
  final CarMapChannel _carMap;

  final Future<Uint8List> Function(String style) _renderMarker;

  late final ExternalSurfacePublisher<WatchSnapshot, AutoGlanceView> _pane;

  final SerialTaskGate _mapGate = SerialTaskGate();
  Timer? _mapDebounce;

  AutoGlanceView? _viewUnderConsideration;

  CarMapSettingsBuilder? _carMapSettingsBuilder;

  FlutterAndroidAuto? _auto;

  ExternalSurfaceSnapshotBuilder<WatchSnapshot>? _snapshotBuilder;
  AutoCommandHandler? _commandHandler;
  AutoCommandRefusalHandler? _onRefusal;

  String? _lastMarkerStyle;

  bool _connected = false;
  bool _isDisposed = false;

  bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @visibleForTesting
  bool get isConnected => _connected;

  void attach({
    required ExternalSurfaceSnapshotBuilder<WatchSnapshot> snapshotBuilder,
    required AutoCommandHandler commandHandler,
    AutoCommandRefusalHandler? onRefusal,
    CarMapSettingsBuilder? carMapSettingsBuilder,
  }) {
    if (!isSupportedPlatform || _isDisposed) return;

    _snapshotBuilder = snapshotBuilder;
    _commandHandler = commandHandler;
    _onRefusal = onRefusal;
    _carMapSettingsBuilder = carMapSettingsBuilder;

    _auto = FlutterAndroidAuto()
      ..addListenerOnConnectionChange(_handleConnectionChange);
    debugLog('[AUTO] Android Auto surface attached');
  }

  void _handleConnectionChange(ConnectionStatusTypes status) {
    if (_isDisposed) return;
    debugLog('[AUTO] Connection status: ${status.name}');

    // `background` means the car is still attached but showing another app.
    // Keep publishing: the driver can switch back at any moment and must not
    // find a stale pane waiting.
    final connected = status == ConnectionStatusTypes.connected ||
        status == ConnectionStatusTypes.background;
    if (connected == _connected) return;
    _connected = connected;

    if (!connected) {
      _mapDebounce?.cancel();
      _mapDebounce = null;
      // Force the next connection to send a fresh root template rather than an
      // update against a template history the host no longer has.
      _pane.resetPublishedState();
      return;
    }

    schedule(immediate: true);
  }

  /// Ask for a redraw. Cheap to call on every provider notification.
  void schedule({bool immediate = false}) {
    if (!isSupportedPlatform || _isDisposed || !_connected) return;
    final snapshotBuilder = _snapshotBuilder;
    if (snapshotBuilder == null) return;
    _pane.schedule(
      snapshotBuilder,
      preflightKeyBuilder: _noPreflightKey,
      immediate: immediate,
    );
    _scheduleMapSync(immediate: immediate);
  }

  static Object? _noPreflightKey() => null;

  AutoGlanceView _buildView(WatchSnapshot snapshot) {
    final view = buildAutoGlanceView(
      snapshot,
      now: DateTime.now(),
      nodeName: _carMapSettingsBuilder?.call().nodeName,
    );
    _viewUnderConsideration = view;
    return view;
  }

  Future<ExternalSurfacePublishResult> _publishPane(
    ExternalSurfacePublication<WatchSnapshot, AutoGlanceView> publication,
  ) async {
    try {
      await FlutterAndroidAuto.setRootTemplate(
        template: AAMapWithContentTemplate(
          id: autoGlanceMapTemplateId,
          contentTemplate: _buildTemplate(publication.payload),
          mapActions: _buildMapActions(publication.payload),
        ),
      );
      return const ExternalSurfacePublishResult.published();
    } catch (e) {
      debugLog('[AUTO] Publish failed: $e');
      return const ExternalSurfacePublishResult.rejected();
    }
  }

  void _scheduleMapSync({required bool immediate}) {
    if (immediate) {
      _mapDebounce?.cancel();
      _mapDebounce = null;
      unawaited(_enqueueMapSync());
      return;
    }
    _mapDebounce ??= Timer(_debounceDelay, () {
      _mapDebounce = null;
      unawaited(_enqueueMapSync());
    });
  }

  Future<void> _enqueueMapSync() => _mapGate.run(() async {
        if (_isDisposed || !_connected) return;
        final snapshot = _snapshotBuilder?.call();
        final settings = _carMapSettingsBuilder?.call();
        if (snapshot == null || settings == null) return;
        await _syncMap(snapshot, settings);
      }).catchError((Object e) {
        debugLog('[AUTO] Map sync failed: $e');
      });

  Future<void> _syncMap(WatchSnapshot snapshot, CarMapSettings settings) async {
    final you = snapshot.geo.you;
    if (you != null) {
      await _carMap.setCamera(
        lat: you.lat,
        lon: you.lon,
        bearing: settings.northUp ? null : you.headingDeg,
        heading: you.headingDeg,
      );
    }

    await _carMap.setStyle(settings.styleUrl);
    await _carMap.setCoverage(settings.coverage);
    await _carMap.setPings(snapshot.geo.pings);

    final endsAt = snapshot.core.phaseEndsAt;
    final durationMs = snapshot.phaseDurationMs;
    await _carMap.setTimer(
      endsAt: durationMs == null ? null : endsAt,
      durationMs: endsAt == null ? null : durationMs,
      argbColor: _argb(snapshot.pingColor),
    );

    await _syncPositionMarker(settings);
  }

  Future<void> _syncPositionMarker(CarMapSettings settings) async {
    if (settings.markerStyle == _lastMarkerStyle) return;
    try {
      final png = await _renderMarker(settings.markerStyle)
          .timeout(_markerRenderTimeout);
      await _carMap.setPositionMarker(
        style: settings.markerStyle,
        png: png,
        facesHeading: settings.markerFacesHeading,
      );
      _lastMarkerStyle = settings.markerStyle;
    } catch (e) {

      debugLog('[AUTO] Could not render the position marker: $e');
    }
  }

  AAPaneTemplate _buildTemplate(AutoGlanceView view) {
    return AAPaneTemplate(
      id: autoGlanceTemplateId,
      title: autoGlanceTitle,
      items: [
        for (final row in view.rows)
          AAPaneItem(title: row.title, detail: row.detail),
      ],
    );
  }

  List<AAMapAction> _buildMapActions(AutoGlanceView view) {
    final renderedSessionId = view.sessionId;
    final running = renderedSessionId != null;

    return [
      AAMapAction(
        id: autoGlanceToggleActionId,
        title: running ? 'Stop' : 'Start',
        imageUrl: running ? 'assets/car_stop.png' : 'assets/car_start.png',
        isPrimary: true,
        onPress: () => _send(
          ExternalSessionCommand(
            id: const Uuid().v4(),
            source: ExternalCommandSource.androidAuto,
            kind: running
                ? ExternalSessionCommandKind.stopSession
                : ExternalSessionCommandKind.startSession,
            issuedAt: DateTime.now(),
            sessionId: running ? renderedSessionId : null,
          ),
        ),
      ),
    ];
  }

  void _send(ExternalSessionCommand command) {
    final handler = _commandHandler;
    if (handler == null || _isDisposed) return;
    debugLog('[AUTO] Command: ${command.kind.name}');

    final refusal = handler(command);
    if (refusal is Future<ExternalCommandReason?>) {
      unawaited(refusal.then(_handleRefusal));
      return;
    }
    _handleRefusal(refusal);
  }

  void _handleRefusal(ExternalCommandReason? reason) {
    if (reason == null || _isDisposed) return;
    debugLog('[AUTO] Refused: ${reason.compactText}');
    _onRefusal?.call(reason);
    schedule(immediate: true);
  }

  void dispose() {
    _isDisposed = true;
    _mapDebounce?.cancel();
    _mapDebounce = null;
    _pane.dispose();
    if (isSupportedPlatform) {
      try {
        _auto?.closeConnection();
      } catch (_) {}
    }
    _auto = null;
    _snapshotBuilder = null;
    _commandHandler = null;
    _onRefusal = null;
    _carMapSettingsBuilder = null;
    _viewUnderConsideration = null;
  }
}

int? _argb(ExternalSurfaceColor? color) {
  if (color == null) return null;
  int channel(double v) => (v * 255.0).round().clamp(0, 255);
  return (0xFF << 24) |
      (channel(color.r) << 16) |
      (channel(color.g) << 8) |
      channel(color.b);
}
