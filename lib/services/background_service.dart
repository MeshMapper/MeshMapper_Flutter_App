import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../utils/debug_logger_io.dart';

/// Background service manager for continuous wardriving operation.
///
/// Android: Uses a foreground service with persistent notification to keep
/// BLE and GPS active when the app is backgrounded.
///
/// iOS: Uses declared background modes (bluetooth-central, location) with
/// proper delegate setup. iOS may still throttle after extended periods.
///
/// Web: No-op (Web Bluetooth requires active tab).
///
/// Reference: Option A from background execution plan
@pragma('vm:entry-point')
class BackgroundServiceManager {
  static const String _notificationChannelId = 'meshmapper_wardriving';
  static const String _notificationChannelName = 'MeshMapper Wardriving';
  static const int _notificationId = 888;

  static FlutterBackgroundService? _service;
  static bool _isInitialized = false;
  static bool _isRunning = false;

  /// Initialize the background service.
  /// Called lazily on first startService() call — never at app startup.
  /// On Android, configure() may start the foreground service as a side effect
  /// (service resurrection), so this MUST only be called when we actually
  /// intend to start the service. Startup orphan cleanup uses
  /// cleanupOrphanedService() which cancels the notification directly.
  static Future<void> initialize() async {
    // Skip on web - no background service support
    if (kIsWeb) {
      debugLog('[BACKGROUND] Skipping initialization (web platform)');
      return;
    }

    if (_isInitialized) {
      debugLog('[BACKGROUND] Already initialized');
      return;
    }

    debugLog('[BACKGROUND] Initializing background service');

    try {
      // Initialize local notifications for Android
      final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
          FlutterLocalNotificationsPlugin();

      // Android notification channel setup
      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        _notificationChannelId,
        _notificationChannelName,
        description: 'Shows wardriving status while app is in background',
        importance: Importance.low, // Low importance = no sound/vibration
        showBadge: false,
      );

      await flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);

      // Initialize the background service
      _service = FlutterBackgroundService();

      await _service!.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: _onStart,
          autoStart: false, // We'll start it manually when auto-mode is enabled
          isForegroundMode: true,
          notificationChannelId: _notificationChannelId,
          initialNotificationTitle: 'MeshMapper',
          initialNotificationContent: 'Wardriving active',
          foregroundServiceNotificationId: _notificationId,
          foregroundServiceTypes: [
            AndroidForegroundType.location,
            AndroidForegroundType.connectedDevice,
          ],
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: _onStart,
          onBackground: _onIosBackground,
        ),
      );

      // Defense-in-depth: configure() may unexpectedly start the service
      // (e.g., Android resurrecting a previously-killed foreground service).
      final isRunning = await _service!.isRunning();
      if (isRunning) {
        debugLog(
            '[BACKGROUND] Service unexpectedly running after configure(), stopping it');
        _service!.invoke('stop');
      }

      _isInitialized = true;
      debugLog('[BACKGROUND] Background service initialized');
    } catch (e) {
      debugError('[BACKGROUND] Failed to initialize: $e');
    }
  }

  /// Start the background service.
  /// Called when auto-ping mode (TX/RX or RX-only) is enabled.
  static Future<void> startService({
    required String mode,
    int txCount = 0,
    int rxCount = 0,
    int queueSize = 0,
  }) async {
    if (kIsWeb) {
      debugLog('[BACKGROUND] Cannot start service on web');
      return;
    }

    if (!_isInitialized) {
      debugLog('[BACKGROUND] Service not initialized, initializing now');
      await initialize();
    }

    if (_isRunning) {
      debugLog('[BACKGROUND] Service already running, updating notification');
      await updateNotification(
        mode: mode,
        txCount: txCount,
        rxCount: rxCount,
        queueSize: queueSize,
      );
      return;
    }

    try {
      debugLog('[BACKGROUND] Starting background service (mode: $mode)');

      // Store the mode for the notification
      _service?.invoke('setMode', {'mode': mode});

      await _service?.startService();
      _isRunning = true;

      // Update notification with initial stats
      await updateNotification(
        mode: mode,
        txCount: txCount,
        rxCount: rxCount,
        queueSize: queueSize,
      );

      debugLog('[BACKGROUND] Background service started');
    } catch (e) {
      debugError('[BACKGROUND] Failed to start service: $e');
    }
  }

  /// Stop the background service.
  /// Called when auto-ping mode is disabled or on disconnect.
  static Future<void> stopService() async {
    if (kIsWeb) return;

    if (!_isRunning) {
      debugLog('[BACKGROUND] Service not running');
      return;
    }

    try {
      debugLog('[BACKGROUND] Stopping background service');
      _service?.invoke('stop');
      _isRunning = false;
      debugLog('[BACKGROUND] Background service stopped');
    } catch (e) {
      debugError('[BACKGROUND] Failed to stop service: $e');
    }
  }

  /// Update the notification with current wardriving stats.
  /// Called periodically to show TX/RX counts and queue size.
  static Future<void> updateNotification({
    required String mode,
    required int txCount,
    required int rxCount,
    required int queueSize,
  }) async {
    if (kIsWeb || !_isRunning) return;

    try {
      _service?.invoke('updateNotification', {
        'mode': mode,
        'txCount': txCount,
        'rxCount': rxCount,
        'queueSize': queueSize,
      });
    } catch (e) {
      debugError('[BACKGROUND] Failed to update notification: $e');
    }
  }

  /// Check if the background service is running.
  static bool get isRunning => _isRunning;

  /// Check if the background service is initialized.
  static bool get isInitialized => _isInitialized;

  /// Clean up any orphaned foreground service from a previous app session.
  /// On Android, the foreground service can survive app process death.
  /// Call this at app startup to ensure no stale notification persists.
  ///
  /// This intentionally does NOT call initialize()/configure(), because
  /// configure() with isForegroundMode:true can cause Android to resurrect
  /// a killed foreground service as a side effect — producing a phantom
  /// notification hours later (the "3am notification" bug).
  ///
  /// Instead, we cancel the notification directly by ID. Without its
  /// required notification, Android will terminate any orphaned foreground
  /// service within seconds.
  static Future<void> cleanupOrphanedService() async {
    if (kIsWeb) return;
    try {
      debugLog(
          '[BACKGROUND] Dismissing any orphaned notification from previous session');
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.cancel(_notificationId);
      debugLog('[BACKGROUND] Orphaned notification cleanup complete');
    } catch (e) {
      debugError('[BACKGROUND] Failed to cleanup orphaned notification: $e');
    }
  }

  /// Called when the background service starts (Android).
  @pragma('vm:entry-point')
  static Future<void> _onStart(ServiceInstance service) async {
    // Required for background execution
    DartPluginRegistrant.ensureInitialized();

    String currentMode = 'Active Mode';

    // Listen for stop command
    service.on('stop').listen((event) {
      service.stopSelf();
    });

    // Listen for mode updates
    service.on('setMode').listen((event) {
      if (event != null && event['mode'] != null) {
        currentMode = event['mode'] as String;
      }
    });

    // Listen for notification updates
    service.on('updateNotification').listen((event) {
      if (event != null && service is AndroidServiceInstance) {
        final mode = event['mode'] as String? ?? currentMode;
        final txCount = event['txCount'] as int? ?? 0;
        final rxCount = event['rxCount'] as int? ?? 0;
        final queueSize = event['queueSize'] as int? ?? 0;

        String body;
        if (mode == 'Passive Mode') {
          body = 'RX: $rxCount | Queue: $queueSize';
        } else if (mode == 'Trace Mode') {
          body = 'Trace: $txCount | RX: $rxCount | Queue: $queueSize';
        } else {
          body = 'TX: $txCount | RX: $rxCount | Queue: $queueSize';
        }

        service.setForegroundNotificationInfo(
          title: 'MeshMapper - $mode',
          content: body,
        );
      }
    });

    // Set initial notification
    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
      service.setForegroundNotificationInfo(
        title: 'MeshMapper - $currentMode',
        content: 'Starting wardriving...',
      );
    }
  }

  /// Called when the iOS app goes to background.
  @pragma('vm:entry-point')
  static Future<bool> _onIosBackground(ServiceInstance service) async {
    debugLog('[BACKGROUND] iOS entering background');

    // Return true to indicate the task should continue
    // iOS will handle BLE and location through the declared background modes
    return true;
  }
}
