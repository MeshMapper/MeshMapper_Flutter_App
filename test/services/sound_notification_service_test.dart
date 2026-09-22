import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/sound_notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  late List<MethodCall> calls;
  late SoundNotificationService service;
  late int audioPlays;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls = [];
    audioPlays = 0;
    service = SoundNotificationService();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> play(AppLifecycleState state) => service.play(
        lifecycleState: state,
        playAudio: () async {
          audioPlays++;
        },
      );

  test('background iOS uses a standard custom sound without asking permission',
      () async {
    await play(AppLifecycleState.paused);
    expect(audioPlays, 0);
    expect(calls.map((call) => call.method), ['initialize', 'show']);
    // Foreground service and offline map notifications own 888 through 890.
    expect((calls.last.arguments as Map)['id'], isNot(isIn([888, 889, 890])));
    final init = calls.first.arguments as Map;
    expect(init['requestSoundPermission'], false);
    expect(init['requestAlertPermission'], false);
    final details = (calls.last.arguments as Map)['platformSpecifics'] as Map;
    expect(details['sound'], 'disconnect_alert.wav');
    expect(details['interruptionLevel'], 1); // active, never critical
    expect(details['presentSound'], true);
  });

  test('TX and RX use their own sounds and stable, separate IDs', () async {
    final ids = <SoundNotification, int>{};
    for (final sound in SoundNotification.values) {
      for (var repeat = 0; repeat < 2; repeat++) {
        await service.play(
          sound: sound,
          lifecycleState: AppLifecycleState.paused,
          playAudio: () async {
            audioPlays++;
          },
        );
        final args = calls.last.arguments as Map;
        expect(args['id'], isNot(isIn([888, 889, 890])));
        expect(args['id'], ids.putIfAbsent(sound, () => args['id'] as int));
        final details = args['platformSpecifics'] as Map;
        expect(
            details['sound'],
            switch (sound) {
              SoundNotification.transmitted => 'transmitted_packet.wav',
              SoundNotification.received => 'received_packet.wav',
              SoundNotification.disconnected => 'disconnect_alert.wav',
            });
        expect(details['interruptionLevel'], 1);
      }
    }
    expect(ids.values.toSet(), hasLength(3));
    expect(audioPlays, 0);
  });

  test('disabled sound never plays audio or submits a notification', () async {
    for (final sound in SoundNotification.values) {
      for (final state in [
        AppLifecycleState.resumed,
        AppLifecycleState.paused
      ]) {
        await service.play(
          sound: sound,
          enabled: false,
          lifecycleState: state,
          playAudio: () async {
            audioPlays++;
          },
        );
      }
    }
    expect(audioPlays, 0);
    expect(calls, isEmpty);
  });

  test('foreground iOS keeps existing audio playback', () async {
    await play(AppLifecycleState.resumed);
    expect(audioPlays, 1);
    expect(calls, isEmpty);
  });

  test('inactive iOS uses notification during the lock transition', () async {
    await play(AppLifecycleState.inactive);
    expect(audioPlays, 0);
    expect(calls.last.method, 'show');
  });

  test('Android keeps audio playback in background', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await play(AppLifecycleState.paused);
    await service.requestPermission();
    expect(audioPlays, 1);
    expect(calls, isEmpty);
  });

  test('permission requests sound and alerts but never critical access',
      () async {
    await service.requestPermission();
    final request = calls.last;
    expect(request.method, 'requestPermissions');
    expect(request.arguments['sound'], true);
    expect(request.arguments['alert'], true);
    expect(request.arguments['critical'], false);
    expect(request.arguments['badge'], false);
  });

  test('notification errors do not fall back to media audio', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'show') throw PlatformException(code: 'unavailable');
      return true;
    });
    await play(AppLifecycleState.paused);
    expect(audioPlays, 0);
  });
}
