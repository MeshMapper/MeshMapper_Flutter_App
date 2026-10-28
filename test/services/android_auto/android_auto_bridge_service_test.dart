import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/android_auto/android_auto_bridge_service.dart';
import 'package:mesh_mapper/services/external_commands/external_command_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AndroidAutoBridgeService', () {
    late MethodChannel channel;
    late AndroidAutoBridgeService bridge;
    late List<Map<Object?, Object?>> published;
    late bool attachReply;

    setUp(() {
      channel = const MethodChannel('meshmapper/android_auto_test');
      published = [];
      attachReply = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'attach':
            return attachReply;
          case 'publishSnapshot':
            published.add(call.arguments as Map<Object?, Object?>);
        }
        return null;
      });
      bridge = AndroidAutoBridgeService(
        channel: channel,
        debounceDelay: const Duration(milliseconds: 5),
        minimumNonUrgentInterval: const Duration(milliseconds: 25),
        supportedPlatformOverride: true,
      );
    });

    tearDown(() {
      bridge.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<Object?> sendNative(String method, [Object? arguments]) async {
      final reply = await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall(method, arguments)),
        null,
      );
      return reply == null ? null : channel.codec.decodeEnvelope(reply);
    }

    Future<Map<Object?, Object?>> sendCommand(
      String id, {
      String source = 'androidAuto',
      String kind = 'startSession',
      String? mode = 'passive',
    }) async {
      return await sendNative('command', {
        'id': id,
        'source': source,
        'kind': kind,
        'issuedAtMs': DateTime.now().millisecondsSinceEpoch,
        if (mode != null) 'mode': mode,
      }) as Map<Object?, Object?>;
    }

    void attach({
      Future<ExternalCommandCompletion> Function(ExternalSessionCommand)?
          handler,
      List<bool>? sessions,
    }) {
      bridge.attach(
        commandHandler: handler ??
            (_) async => const ExternalCommandCompletion(
                  success: true,
                  disposition: ExternalCommandDisposition.admitted,
                ),
        onSessionChanged: (active) => sessions?.add(active),
      );
    }

    test('publishes nothing while no car is attached', () async {
      attach();
      await pumpEventQueue();
      bridge.schedule(
        () => {'value': 1},
        preflightKeyBuilder: () => '1',
        immediate: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bridge.isCarSessionActive, isFalse);
      expect(published, isEmpty);
    });

    test('a car already attached at startup opens the session', () async {
      attachReply = true;
      final sessions = <bool>[];
      attach(sessions: sessions);
      await pumpEventQueue();
      expect(bridge.isCarSessionActive, isTrue);
      expect(sessions, [true]);
    });

    test('publishes while a car session is open and stops after it closes',
        () async {
      final sessions = <bool>[];
      attach(sessions: sessions);
      await sendNative('carSessionChanged', true);
      bridge.schedule(
        () => {'value': 1, 'updatedAtMs': 1},
        preflightKeyBuilder: () => '1',
        immediate: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(published, hasLength(1));
      expect(published.single['value'], 1);

      await sendNative('carSessionChanged', false);
      bridge.schedule(
        () => {'value': 2},
        preflightKeyBuilder: () => '2',
        immediate: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(published, hasLength(1));
      expect(sessions, [true, false]);
    });

    test('a reconnected car receives the unchanged snapshot again', () async {
      attach();
      await sendNative('carSessionChanged', true);
      Map<String, Object?> build() => {'value': 1};
      bridge.schedule(build, preflightKeyBuilder: () => 'k', immediate: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await sendNative('carSessionChanged', false);
      await sendNative('carSessionChanged', true);
      bridge.schedule(build, preflightKeyBuilder: () => 'k', immediate: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(published, hasLength(2));
    });

    test('rejects commands that claim another source', () async {
      var calls = 0;
      attach(handler: (_) async {
        calls++;
        return const ExternalCommandCompletion(
          success: true,
          disposition: ExternalCommandDisposition.admitted,
        );
      });
      final reply = await sendCommand('a', source: 'siri');
      expect(reply['success'], isFalse);
      expect(reply['message'], 'Malformed command');
      expect(calls, 0);
    });

    test('forwards a car command and deduplicates its id', () async {
      final received = <ExternalSessionCommand>[];
      final released = Completer<void>();
      attach(handler: (command) async {
        received.add(command);
        await released.future;
        return const ExternalCommandCompletion(
          success: true,
          disposition: ExternalCommandDisposition.admitted,
          message: ExternalCommandReason.other('Started'),
        );
      });

      final first = sendCommand('car-1');
      final duplicate = sendCommand('car-1');
      await pumpEventQueue();
      released.complete();

      final replies = await Future.wait([first, duplicate]);
      expect(received, hasLength(1));
      expect(received.single.source, ExternalCommandSource.androidAuto);
      expect(received.single.kind, ExternalSessionCommandKind.startSession);
      expect(received.single.mode, 'passive');
      for (final reply in replies) {
        expect(reply['id'], 'car-1');
        expect(reply['success'], isTrue);
        expect(reply['message'], 'Started');
      }

      final repeat = await sendCommand('car-1');
      expect(repeat['message'], 'Started');
      expect(received, hasLength(1));
    });

    test('a throwing handler becomes a refusal', () async {
      attach(handler: (_) async => throw StateError('boom'));
      final reply = await sendCommand('car-2', kind: 'manualPing', mode: null);
      expect(reply['success'], isFalse);
      expect(reply['message'], 'Command failed');
    });
  });
}
