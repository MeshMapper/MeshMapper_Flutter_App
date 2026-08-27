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

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      channel = const MethodChannel('meshmapper/app_intents_test');
      published = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'publishSnapshot') {
          published.add(call.arguments as Map<Object?, Object?>);
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
      Object? expiresAtMs,
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
          if (expiresAtMs != null) 'expiresAtMs': expiresAtMs,
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
          message: ExternalCommandReason.other(
            'MeshMapper started in Passive Discovery mode.',
          ),
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

    test('concurrent duplicate mutations share one in-flight execution',
        () async {
      var calls = 0;
      final released = Completer<void>();
      bridge.attachCommandHandler((command) async {
        calls++;
        await released.future;
        return const ExternalCommandCompletion(
          success: true,
          disposition: ExternalCommandDisposition.admitted,
          message: ExternalCommandReason.other('Connected'),
        );
      });

      final first = sendCommand('command-concurrent');
      final duplicate = sendCommand('command-concurrent');
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);

      released.complete();
      expect(await duplicate, await first);
      expect(calls, 1);
    });

    test('concurrent duplicates share the same handler failure refusal',
        () async {
      var calls = 0;
      final released = Completer<void>();
      bridge.attachCommandHandler((command) async {
        calls++;
        await released.future;
        throw StateError('failed once');
      });

      final first = sendCommand('command-concurrent-failure');
      final duplicate = sendCommand('command-concurrent-failure');
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);

      released.complete();
      expect(await duplicate, await first);
      expect(await first, containsPair('message', 'Command failed'));
      expect(calls, 1);
    });

    test('wrong-source and malformed commands fail closed', () async {
      bridge.attachCommandHandler((_) async => throw StateError('not called'));

      final result = await sendCommand('command-2', source: 'watch');

      expect(result['success'], isFalse);
      expect(result['disposition'], 'refused');
      expect(result['message'], 'Malformed command');
    });

    test("the intent's deadline reaches the shared session command", () async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      AppIntentCommand? received;
      bridge.attachCommandHandler((command) async {
        received = command;
        return const ExternalCommandCompletion(
          success: true,
          disposition: ExternalCommandDisposition.admitted,
        );
      });

      await sendCommand(
        'command-deadline',
        expiresAtMs: deadline.millisecondsSinceEpoch,
      );

      expect(
        received?.expiresAt?.millisecondsSinceEpoch,
        deadline.millisecondsSinceEpoch,
      );
      expect(
        received?.toExternalSessionCommand()?.expiresAt,
        received?.expiresAt,
      );
    });

    test('an older native build sending no deadline still runs', () async {
      AppIntentCommand? received;
      bridge.attachCommandHandler((command) async {
        received = command;
        return const ExternalCommandCompletion(
          success: true,
          disposition: ExternalCommandDisposition.admitted,
        );
      });

      final result = await sendCommand('command-no-deadline');

      expect(received?.expiresAt, isNull);
      expect(result['success'], isTrue);
    });

    test('a non-numeric deadline fails closed', () async {
      bridge.attachCommandHandler((_) async => throw StateError('not called'));

      final result = await sendCommand(
        'command-bad-deadline',
        expiresAtMs: 'soon',
      );

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
          message: ExternalCommandReason.other(
            'MeshMapper connected to Test Radio.',
          ),
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

      var builds = 0;
      Map<String, Object?> build(int updatedAtMs, {bool active = false}) {
        builds++;
        return snapshot(updatedAtMs, active: active);
      }

      bridge.schedule(
        () => build(1),
        preflightKeyBuilder: () => 'idle',
        immediate: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      bridge.schedule(
        () => build(2),
        preflightKeyBuilder: () => 'idle',
        immediate: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      bridge.schedule(
        () => build(3, active: true),
        preflightKeyBuilder: () => 'active',
        immediate: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(builds, 2,
          reason: 'an unchanged preflight must skip the expensive builder');
      expect(published, hasLength(2));
      expect((published.last['session'] as Map)['active'], isTrue);
    });

    test('preflight dedupe starts only after a snapshot is published',
        () async {
      var attempts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'publishSnapshot') return null;
        attempts++;
        if (attempts == 1) {
          throw PlatformException(code: 'not-written');
        }
        published.add(call.arguments as Map<Object?, Object?>);
        return null;
      });

      var builds = 0;
      Map<String, Object?> build() {
        builds++;
        return {'version': 1, 'updatedAtMs': builds};
      }

      for (var delivery = 0; delivery < 3; delivery++) {
        bridge.schedule(
          build,
          preflightKeyBuilder: () => 'unchanged',
          immediate: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(attempts, 2);
      expect(builds, 2,
          reason: 'a refused first publish must not arm preflight dedupe');
      expect(published, hasLength(1));
    });
  });
}
