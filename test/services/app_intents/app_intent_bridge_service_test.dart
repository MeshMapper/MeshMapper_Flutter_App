import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/app_intents/app_intent_bridge_service.dart';
import 'package:mesh_mapper/services/app_intents/app_intent_commands.dart';
import 'package:mesh_mapper/services/external_commands/external_command_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppIntentBridgeService', () {
    late MethodChannel channel;
    late AppIntentBridgeService bridge;
    late List<Map<Object?, Object?>> published;
    var clearCalls = 0;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      channel = const MethodChannel('meshmapper/app_intents_test');
      published = [];
      clearCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'publishSnapshot') {
          published.add(call.arguments as Map<Object?, Object?>);
        } else if (call.method == 'clearSnapshot') {
          clearCalls++;
        }
        return null;
      });
      bridge = AppIntentBridgeService(
        channel: channel,
        debounceDelay: const Duration(milliseconds: 5),
        minimumNonUrgentInterval: const Duration(milliseconds: 25),
      );
    });

    tearDown(() {
      bridge.dispose();
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<Map<Object?, Object?>> sendCommand(
      String id, {
      String source = 'siri',
      String kind = 'startSession',
      String? mode = 'passive',
    }) async {
      final reply = await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall('command', {
          'id': id,
          'source': source,
          'kind': kind,
          'issuedAtMs': DateTime.now().millisecondsSinceEpoch,
          if (mode != null) 'mode': mode,
        })),
        null,
      );
      return channel.codec.decodeEnvelope(reply!) as Map<Object?, Object?>;
    }

    test('native mutation waits for completion and deduplicates its UUID',
        () async {
      var calls = 0;
      final released = Completer<void>();
      bridge.attachCommandHandler((command) async {
        calls++;
        await released.future;
        return const ExternalCommandCompletion(
          success: true,
          disposition: ExternalCommandDisposition.admitted,
          message: 'MeshMapper started in Passive Discovery mode.',
          sessionId: 'session-1',
          mode: ExternalSessionMode.passive,
        );
      });

      final pending = sendCommand('command-1');
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      var completed = false;
      unawaited(pending.then((_) => completed = true));
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      released.complete();
      final first = await pending;
      final duplicate = await sendCommand('command-1');

      expect(first['success'], isTrue);
      expect(first['disposition'], 'admitted');
      expect(first['sessionId'], 'session-1');
      expect(duplicate, first);
      expect(calls, 1);
    });

    test('wrong-source and malformed commands fail closed', () async {
      bridge.attachCommandHandler((_) async => throw StateError('not called'));

      final result = await sendCommand('command-2', source: 'watch');

      expect(result['success'], isFalse);
      expect(result['disposition'], 'refused');
      expect(result['message'], 'Malformed command');
    });

    test('connect-last-companion remains a Siri-only mutation', () async {
      AppIntentCommand? received;
      bridge.attachCommandHandler((command) async {
        received = command;
        return const ExternalCommandCompletion(
          success: true,
          disposition: ExternalCommandDisposition.admitted,
          message: 'MeshMapper connected to Test Radio.',
        );
      });

      final result = await sendCommand(
        'command-connect',
        kind: 'connectLastCompanion',
        mode: null,
      );

      expect(received?.kind, AppIntentCommandKind.connectLastCompanion);
      expect(received?.toExternalSessionCommand(), isNull);
      expect(result['success'], isTrue);
      expect(result['message'], 'MeshMapper connected to Test Radio.');
    });

    test('semantic duplicate snapshots ignore updatedAtMs', () async {
      Map<String, Object?> snapshot(int updatedAtMs, {bool active = false}) => {
            'version': 1,
            'updatedAtMs': updatedAtMs,
            'session': {'active': active},
          };

      bridge.schedule(() => snapshot(1), immediate: true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      bridge.schedule(() => snapshot(2), immediate: true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      bridge.schedule(() => snapshot(3, active: true), immediate: true);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(published, hasLength(2));
      expect((published.last['session'] as Map)['active'], isTrue);
    });

    test('clearSnapshot uses the independent App Intents channel', () async {
      await bridge.clearSnapshot();
      expect(clearCalls, 1);
    });
  });
}
