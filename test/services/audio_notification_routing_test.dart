import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mesh_mapper/services/audio_service.dart';
import 'package:mesh_mapper/services/sound_notification_service.dart';

class _RecordingNotifications extends SoundNotificationService {
  final enabledSounds = <SoundNotification>[];

  @override
  Future<void> play({
    SoundNotification sound = SoundNotification.disconnected,
    bool enabled = true,
    required AppLifecycleState? lifecycleState,
    required Future<void> Function() playAudio,
  }) async {
    if (enabled) enabledSounds.add(sound);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _RecordingNotifications notifications;
  late AudioService audio;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('audio-routing-test-');
    Hive.init(directory.path);
    notifications = _RecordingNotifications();
    audio = AudioService(notifications: notifications);
  });

  tearDown(() async {
    audio.dispose();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('master off suppresses TX and RX notifications', () async {
    await audio.playTransmitSound();
    await audio.playReceiveSound();
    expect(notifications.enabledSounds, isEmpty);
  });

  test('TX and RX toggles independently gate their notification sounds',
      () async {
    await audio.setEnabled(true);
    await audio.setTxEnabled(false);
    await audio.playTransmitSound();
    await audio.playReceiveSound();
    expect(notifications.enabledSounds, [SoundNotification.received]);
    notifications.enabledSounds.clear();
    await audio.setTxEnabled(true);
    await audio.setRxEnabled(false);
    await audio.playTransmitSound();
    await audio.playReceiveSound();
    expect(notifications.enabledSounds, [SoundNotification.transmitted]);
  });

  test('turning master off suppresses previously enabled sounds', () async {
    await audio.setEnabled(true);
    await audio.setEnabled(false);
    await audio.playTransmitSound();
    await audio.playReceiveSound();
    expect(notifications.enabledSounds, isEmpty);
  });
}
