import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_carplay/controllers/android_auto_controller.dart';
import 'package:flutter_carplay/flutter_carplay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/auto/android_auto_service.dart';
import 'package:mesh_mapper/services/auto/auto_glance_view.dart';
import 'package:mesh_mapper/services/external_commands/external_command_models.dart';
import 'package:mesh_mapper/services/external_commands/external_session_commands.dart';
import 'package:mesh_mapper/services/live_activity/live_activity_models.dart';
import 'package:mesh_mapper/services/watch/watch_models.dart';

const String _methodChannelName = 'com.oguzhnatly.flutter_android_auto';
const String _eventChannelName = 'com.oguzhnatly.flutter_android_auto/event';

final DateTime _now = DateTime.fromMillisecondsSinceEpoch(1760000000000);

WatchSnapshot _snapshot({
  required String sessionId,
  required bool isSessionActive,
}) =>
    WatchSnapshot(
      core: LiveActivitySnapshot(
        sessionId: sessionId,
        mode: 'Active',
        phase: LiveActivityPhase.listening,
        phaseTitle: isSessionActive ? 'Listening' : 'Ready',
        phaseDetail: isSessionActive ? 'Waiting for echoes' : null,
        isConnected: true,
        zoneCode: 'SEA',
        txCount: 0,
        rxCount: 0,
        discoveryCount: 0,
        traceCount: 0,
        queueSize: 0,
        repeaters: const [],
        totalHeardCount: 0,
        repeatersAreCurrent: true,
        updatedAt: _now,
      ),
      geo: const WatchGeo(
        pings: [],
        repeaters: [],
        heard: [],
        linkedRepeaterIds: [],
      ),
      controls: WatchControls(
        canStartStop: true,
        canManualPing: false,
        isSessionActive: isSessionActive,
      ),
      updatedAt: _now,
    );

/// The last template the surface sent native, decoded back into the action
/// closures the plugin would invoke on a tap.
///
/// The controls live in the map action strip, not the pane: the pane was filling
/// half the head unit, and the strip is the vertical bar the host draws down the
/// right edge of the map.
List<AAMapAction> _renderedActions() =>
    (FlutterAndroidAutoController.templateHistory.last
            as AAMapWithContentTemplate)
        .mapActions;

void _tap(String actionId) {
  _renderedActions()
      .firstWhere((action) => action.uniqueId == actionId)
      .onPress!();
}

Future<void> _emitConnected() async {
  const codec = StandardMethodCodec();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    _eventChannelName,
    codec.encodeSuccessEnvelope({
      'type': 'onAndroidAutoConnectionChange',
      'data': {'status': 'connected'},
    }),
    (_) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AndroidAutoService service;
  late List<ExternalSessionCommand> received;
  late List<ExternalCommandReason> refusals;
  late WatchSnapshot current;
  ExternalCommandReason? nextRefusal;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterAndroidAutoController.templateHistory.clear();
    received = <ExternalSessionCommand>[];
    refusals = <ExternalCommandReason>[];
    nextRefusal = null;
    current = _snapshot(sessionId: 'session-1', isSessionActive: true);

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel(_methodChannelName),
      (MethodCall call) async => true,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(_eventChannelName),
      (MethodCall call) async => null,
    );

    service = AndroidAutoService(
      debounceDelay: Duration.zero,
      minimumNonUrgentInterval: Duration.zero,
    )..attach(
        snapshotBuilder: () => current,
        commandHandler: (command) {
          received.add(command);
          return nextRefusal;
        },
        onRefusal: refusals.add,
      );
  });

  tearDown(() {
    service.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test('the strip carries one toggle action', () async {
    await _emitConnected();
    await pumpEventQueue();

    // One button, not two: Start and Stop are mutually exclusive, so showing
    // both meant one of them was always the wrong thing to press.
    final actions = _renderedActions();
    expect(actions, hasLength(1));
    expect(actions.single.uniqueId, autoGlanceToggleActionId);
    expect(actions.single.isPrimary, isTrue);
    // The map strip is icon-only — ACTIONS_CONSTRAINTS_MAP leaves
    // maxCustomTitles at zero, so an action without an icon is rejected and the
    // whole template goes with it.
    for (final action in actions) {
      expect(action.imageUrl, isNotEmpty);
    }
  });

  test('Start sends no mode, deferring to the mode the screen promised',
      () async {
    // Idle, so the toggle points at Start.
    current = _snapshot(sessionId: 'session-1', isSessionActive: false);
    await _emitConnected();
    await pumpEventQueue();

    _tap(autoGlanceToggleActionId);
    expect(received, hasLength(1));
    expect(received.single.kind, ExternalSessionCommandKind.startSession);
    expect(received.single.source, ExternalCommandSource.androidAuto);
    // Null defers to the phone, which resolves it to the same value the
    // status row renders. Naming a mode here would let the button start
    // something other than what the driver was shown.
    expect(received.single.mode, isNull);
  });

  test('Stop names the session the screen was rendering', () async {
    await _emitConnected();
    await pumpEventQueue();

    _tap(autoGlanceToggleActionId);
    expect(received.single.kind, ExternalSessionCommandKind.stopSession);
    expect(received.single.sessionId, 'session-1');
  });

  test('with no session the button starts one instead', () async {
    current = _snapshot(sessionId: 'session-1', isSessionActive: false);
    await _emitConnected();
    await pumpEventQueue();

    // With no session the button points the other way: it starts one.
    _tap(autoGlanceToggleActionId);
    expect(received.single.kind, ExternalSessionCommandKind.startSession);
  });

  test('a Stop from a stale screen is refused rather than stopping the new run',
      () async {
    await _emitConnected();
    await pumpEventQueue();

    // The driver is looking at a screen for session-1. It ends and session-2
    // begins; a fresh snapshot is published.
    final staleActions = _renderedActions();
    current = _snapshot(sessionId: 'session-2', isSessionActive: true);
    service.schedule(immediate: true);
    await pumpEventQueue();

    // They tap the Stop they were looking at.
    staleActions
        .firstWhere((action) => action.uniqueId == autoGlanceToggleActionId)
        .onPress!();

    final command = received.single;
    expect(command.sessionId, 'session-1');

    // Which is exactly what the provider's guard needs to refuse it — and it
    // is the shared guard, reached with the very command the strip built.
    final admission = resolveExternalSessionTransition(
      command: command,
      isSessionActive: true,
      isSessionStarting: false,
      currentMode: 'passive',
      currentSessionId: 'session-2',
      currentModeLabel: 'Passive',
    );
    expect(admission.shouldExecute, isFalse);
    expect(admission.reason, ExternalCommandReason.sessionAlreadyEnded);
  });

  test('a refusal reaches the refusal handler', () async {
    await _emitConnected();
    await pumpEventQueue();

    nextRefusal = ExternalCommandReason.notConnected;
    _tap(autoGlanceToggleActionId);
    await pumpEventQueue();
    expect(refusals, [ExternalCommandReason.notConnected]);
  });

  test('an admitted command reports no refusal', () async {
    await _emitConnected();
    await pumpEventQueue();

    _tap(autoGlanceToggleActionId);
    await pumpEventQueue();
    expect(refusals, isEmpty);
  });

  test('an asynchronous refusal still reaches the handler', () async {
    service.dispose();
    service = AndroidAutoService(
      debounceDelay: Duration.zero,
      minimumNonUrgentInterval: Duration.zero,
    )..attach(
        snapshotBuilder: () => current,
        commandHandler: (command) async => ExternalCommandReason.couldNotStart,
        onRefusal: refusals.add,
      );
    await _emitConnected();
    await pumpEventQueue();

    _tap(autoGlanceToggleActionId);
    await pumpEventQueue();
    expect(refusals, [ExternalCommandReason.couldNotStart]);
  });
}
