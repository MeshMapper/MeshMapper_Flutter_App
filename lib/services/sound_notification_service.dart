import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../utils/debug_logger_io.dart';

enum SoundNotification {
  // 888 is the foreground service; 889 and 890 belong to offline maps.
  disconnected(891, 'disconnect_alert.wav', 'MeshMapper stopped',
      'Your automatic mode stopped unexpectedly. Open MeshMapper to check your session.'),
  transmitted(892, 'transmitted_packet.wav', 'MeshMapper: ping sent',
      'A ping or discovery request was sent.'),
  received(893, 'received_packet.wav', 'MeshMapper: response received',
      'A repeater response or mesh packet was received.');

  const SoundNotification(this.id, this.filename, this.title, this.body);
  final int id;
  final String filename;
  final String title;
  final String body;
}

/// Delivers background iOS sounds through the system so silent mode,
/// Focus and notification permissions govern their sound.
class SoundNotificationService {
  final _notifications = IOSFlutterLocalNotificationsPlugin();
  Future<bool?>? _initialization;

  bool get _isIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> _initialize() async {
    try {
      await (_initialization ??= _notifications.initialize(
        const DarwinInitializationSettings(
          requestAlertPermission: false,
          requestSoundPermission: false,
          requestBadgePermission: false,
        ),
      ));
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  /// Called while enabling sounds, never from a sound event callback.
  Future<void> requestPermission() async {
    if (!_isIos) return;
    try {
      await _initialize();
      final granted = await _notifications.requestPermissions(
        alert: true,
        sound: true,
      );
      debugLog('[AUDIO] iOS sound notification permission: $granted');
    } catch (error) {
      debugError(
          '[AUDIO] Cannot request sound notification permission: $error');
    }
  }

  Future<void> play({
    SoundNotification sound = SoundNotification.disconnected,
    bool enabled = true,
    required AppLifecycleState? lifecycleState,
    required Future<void> Function() playAudio,
  }) async {
    if (!enabled) return;
    if (!_isIos || lifecycleState == AppLifecycleState.resumed) {
      await playAudio();
      return;
    }
    try {
      await _initialize();
      await _notifications.show(
        sound.id,
        sound.title,
        sound.body,
        notificationDetails: DarwinNotificationDetails(
          sound: sound.filename,
          presentSound: true,
          presentAlert: true,
          presentBanner: true,
          presentList: true,
          presentBadge: false,
          interruptionLevel: InterruptionLevel.active,
        ),
      );
      debugLog('[AUDIO] Submitted iOS ${sound.name} notification');
    } catch (error) {
      debugError('[AUDIO] Failed to submit ${sound.name} notification: $error');
    }
  }
}
