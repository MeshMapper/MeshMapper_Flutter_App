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

  /// True from the moment a 'stop' is sent until the service is seen gone (or
  /// the bounded wait gives up). 'stop' is fire-and-forget: the service
  /// isolate answers it with stopSelf() some milliseconds later, and a
  /// startService() sent in that gap reuses the dying service, which then
  /// stops anyway. startService() waits this out first.
  static bool _stopPending = false;

  /// Bumped by every [stopService] call, even one that finds nothing running.
  /// A start that waits for a previous stop captures it first and abandons
  /// itself when it moved, so a disconnect during a mode switch's wait cannot
  /// be followed by the waiting start launching an orphan service.
  static int _stopGeneration = 0;

  /// How often [waitUntilStopped] polls, and how long it waits at most.
  static const Duration _stopPollInterval = Duration(milliseconds: 100);
  static const Duration _stopWaitLimit = Duration(seconds: 2);

  /// How long after a start to check the service is still up (diagnostic).
  static const Duration _startVerifyDelay = Duration(seconds: 1);

  /// Initialize the background service.
  /// Called lazily on first startService() call — never at app startup.
  /// Startup orphan cleanup uses cleanupOrphanedService(), which stops a
  /// running service without configure().
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
          // Defaults to true, and the plugin's BootReceiver then starts the
          // service with nothing attached after every reboot and app update.
          autoStartOnBoot: false,
          isForegroundMode: true,
          notificationChannelId: _notificationChannelId,
          initialNotificationTitle: 'MeshMapper',
          initialNotificationContent: 'Wardriving active',
          foregroundServiceNotificationId: _notificationId,
          foregroundServiceTypes: [
            AndroidForegroundType.location,
            AndroidForegroundType.connectedDevice,
            AndroidForegroundType.dataSync,
          ],
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: _onStart,
          onBackground: _onIosBackground,
        ),
      );

      // Defense-in-depth: a service this session did not start may already
      // be running (BootReceiver acting on a saved autoStartOnBoot).
      final isRunning = await _service!.isRunning();
      if (isRunning) {
        debugLog(
            '[BACKGROUND] Service unexpectedly running after configure(), stopping it');
        _service!.invoke('stop');
        // Wait for it to actually go. Starting straight away let the stale
        // service's stopSelf() land after our start and take the new
        // service down with it, so GPS stopped in the background.
        await _awaitPendingStop(_service!, 'stale service after configure()');
      }

      _isInitialized = true;
      debugLog('[BACKGROUND] Background service initialized');
    } catch (e) {
      debugError('[BACKGROUND] Failed to initialize: $e');
    }
  }

  /// Start the background service.
  /// Called when auto-ping mode (TX/RX or RX-only) is enabled.
  ///
  /// [title] and [body] are the finished notification strings. The caller
  /// composes them (mode name and stats live on the app side); the background
  /// isolate only displays what it is handed.
  static Future<void> startService({
    required String title,
    required String body,
  }) async {
    if (kIsWeb) {
      debugLog('[BACKGROUND] Cannot start service on web');
      return;
    }

    final generation = _stopGeneration;

    if (!_isInitialized) {
      debugLog('[BACKGROUND] Service not initialized, initializing now');
      await initialize();
    }

    if (_isRunning) {
      debugLog('[BACKGROUND] Service already running, updating notification');
      await updateNotification(title: title, body: body);
      return;
    }

    try {
      // A stop sent just before (a mode switch stops the old mode's service
      // and starts the new one within milliseconds) must finish first, or
      // its stopSelf() kills the service this call is about to start. Android
      // only: that is where stop and start race on one service instance.
      final service = _service;
      if (_stopPending &&
          service != null &&
          defaultTargetPlatform == TargetPlatform.android) {
        await _awaitPendingStop(service, 'previous stop');
      }
      if (generation != _stopGeneration) {
        debugLog('[BACKGROUND] Start abandoned: a stop arrived while it '
            'was waiting');
        return;
      }

      debugLog('[BACKGROUND] Starting background service ($title)');

      // Seed the title so the "Starting wardriving..." notification names the
      // mode before the first stats update lands.
      _service?.invoke('setInitialTitle', {'title': title});

      await _service?.startService();
      if (generation != _stopGeneration) {
        debugLog('[BACKGROUND] A stop arrived during the start, stopping it');
        _service?.invoke('stop');
        _stopPending = true;
        return;
      }
      _isRunning = true;

      // Update notification with initial stats
      await updateNotification(title: title, body: body);

      debugLog('[BACKGROUND] Background service started');
      unawaited(_verifyStillRunning(
        generation: generation,
        title: title,
        body: body,
      ));
    } catch (e) {
      debugError('[BACKGROUND] Failed to start service: $e');
    }
  }

  /// Wait (bounded) for a service that was sent 'stop' to actually stop, and
  /// log how long it took. [onTimeout] ends the log line when it gives up.
  /// Never throws.
  static Future<void> _awaitPendingStop(
    FlutterBackgroundService service,
    String what, {
    String onTimeout = 'starting anyway',
  }) async {
    _stopPending = true;
    final elapsed = await waitUntilStopped(
      isRunning: service.isRunning,
      pollInterval: _stopPollInterval,
      timeout: _stopWaitLimit,
    );
    _stopPending = false;
    if (elapsed == null) {
      debugWarn('[BACKGROUND] $what still running after '
          '${_stopWaitLimit.inMilliseconds} ms, $onTimeout');
    } else {
      debugLog('[BACKGROUND] $what stopped after ${elapsed.inMilliseconds} ms');
    }
  }

  /// Poll [isRunning] every [pollInterval] until it reports false, for at most
  /// [timeout]. Returns how long that took, or null if it was still running
  /// at the bound. A poll that throws counts as still running.
  @visibleForTesting
  static Future<Duration?> waitUntilStopped({
    required Future<bool> Function() isRunning,
    Duration pollInterval = _stopPollInterval,
    Duration timeout = _stopWaitLimit,
  }) async {
    final watch = Stopwatch()..start();
    while (true) {
      bool running;
      try {
        running = await isRunning();
      } catch (e) {
        debugWarn('[BACKGROUND] isRunning() check failed: $e');
        running = true;
      }
      if (!running) return watch.elapsed;
      if (watch.elapsed >= timeout) return null;
      await Future<void>.delayed(pollInterval);
    }
  }

  /// Shortly after a start, confirm the service is still up. A stale
  /// service whose stopSelf() landed after the bounded wait takes the new
  /// start down with it while [_isRunning] stays true, so a service found
  /// gone is started once more, unless a stop has arrived since. One retry
  /// only: the second check just logs.
  static Future<void> _verifyStillRunning({
    required int generation,
    required String title,
    required String body,
    bool retried = false,
  }) async {
    final service = _service;
    if (service == null || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    await Future<void>.delayed(_startVerifyDelay);
    if (!_isRunning || _stopPending || generation != _stopGeneration) return;
    try {
      if (await service.isRunning()) return;
      if (!_isRunning || _stopPending || generation != _stopGeneration) return;
      if (retried) {
        debugWarn('[BACKGROUND] Service still not running after the retry');
        return;
      }
      debugWarn('[BACKGROUND] Service not running '
          '${_startVerifyDelay.inMilliseconds} ms after start, starting it '
          'once more');
      service.invoke('setInitialTitle', {'title': title});
      await service.startService();
      if (generation != _stopGeneration) {
        // A stop landed during the restart: take it down again.
        debugLog('[BACKGROUND] Stop arrived during the retry, stopping it');
        service.invoke('stop');
        _stopPending = true;
        return;
      }
      await updateNotification(title: title, body: body);
      unawaited(_verifyStillRunning(
        generation: generation,
        title: title,
        body: body,
        retried: true,
      ));
    } catch (e) {
      debugWarn('[BACKGROUND] Post-start check failed: $e');
    }
  }

  /// Stop the background service.
  /// Called when auto-ping mode is disabled or on disconnect.
  static Future<void> stopService() async {
    if (kIsWeb) return;

    // Always, even with nothing running: a start may be waiting out an
    // earlier stop and must not go ahead after this one.
    _stopGeneration++;

    if (!_isRunning) {
      debugLog('[BACKGROUND] Service not running');
      return;
    }

    try {
      debugLog('[BACKGROUND] Stopping background service');
      _service?.invoke('stop');
      _isRunning = false;
      _stopPending = true;
      debugLog('[BACKGROUND] Background service stopped');
    } catch (e) {
      debugError('[BACKGROUND] Failed to stop service: $e');
    }
  }

  /// Stop the Android service if it is running, whoever started it, and wait
  /// (bounded) for it to go. [stopService] trusts [_isRunning], which is false
  /// in a fresh session, so it cannot stop a service BootReceiver started or
  /// one left behind when the app was swiped away. Does not call configure():
  /// isRunning() and 'stop' work on the plugin's channel without it, and
  /// configure() would save the boot-start setting again. Never throws.
  static Future<void> stopLiveService(String what) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    final service = _service ?? FlutterBackgroundService();
    try {
      if (!await service.isRunning()) return;
    } catch (e) {
      debugWarn('[BACKGROUND] Could not check for a running service ($what): '
          '$e');
      return;
    }

    debugLog('[BACKGROUND] Stopping running service ($what)');
    // A start waiting out an earlier stop must not go ahead after this one.
    _stopGeneration++;
    try {
      service.invoke('stop');
    } catch (e) {
      debugError('[BACKGROUND] Failed to send stop ($what): $e');
    }
    _isRunning = false;
    await _awaitPendingStop(service, what, onTimeout: 'giving up');
  }

  /// Update the notification with the current wardriving title and body.
  /// Called periodically to show TX/RX counts and queue size.
  static Future<void> updateNotification({
    required String title,
    required String body,
  }) async {
    if (kIsWeb || !_isRunning) return;

    try {
      _service?.invoke('updateNotification', {
        'title': title,
        'body': body,
      });
    } catch (e) {
      debugError('[BACKGROUND] Failed to update notification: $e');
    }
  }

  /// Check if the background service is running.
  static bool get isRunning => _isRunning;

  /// Install a stand-in service and reset the manager's state, so the start
  /// and stop paths can be driven without the plugin.
  @visibleForTesting
  static void debugInstallService(FlutterBackgroundService? service) {
    _service = service;
    _isInitialized = service != null;
    _isRunning = false;
    _stopPending = false;
    _stopGeneration = 0;
  }

  /// Check if the background service is initialized.
  static bool get isInitialized => _isInitialized;

  /// Clean up any orphaned foreground service from a previous app session.
  /// Call this at app startup, from a cold main(): the isolate that drove any
  /// earlier service is gone, so a service running now is an orphan.
  ///
  /// Where orphans come from: the plugin's autoStartOnBoot defaulted to true
  /// and configure() saved it, so its BootReceiver started the service after
  /// every reboot and app update (MY_PACKAGE_REPLACED), with nothing attached
  /// and a stuck "Starting wardriving..." notification. That was the "3am
  /// notification" (#83, #178) and the notification Close App could not clear
  /// (#604). A swiped-away app also leaves its service running
  /// (stopWithTask is false). initialize() now saves false and _onStart
  /// clears it on installs that saved true.
  ///
  /// Cancelling notification [_notificationId] is not enough: Android keeps a
  /// running foreground service's notification, so this also stops the
  /// service itself via [stopLiveService]. It never calls configure().
  ///
  /// We DO initialize the local-notifications plugin first: cancel() silently
  /// no-ops until the plugin's platform channel is initialized.
  static Future<void> cleanupOrphanedService() async {
    if (kIsWeb) return;
    try {
      debugLog(
          '[BACKGROUND] Dismissing any orphaned notification from previous session');
      final plugin = FlutterLocalNotificationsPlugin();
      // Establish the platform channel so cancel() actually reaches native.
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosInit = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await plugin.initialize(
        const InitializationSettings(android: androidInit, iOS: iosInit),
      );
      await plugin.cancel(_notificationId);
      debugLog('[BACKGROUND] Orphaned notification cleanup complete');
    } catch (e) {
      debugError('[BACKGROUND] Failed to cleanup orphaned notification: $e');
    }
    await stopLiveService('orphaned service');
  }

  /// Called when the background service starts (Android).
  @pragma('vm:entry-point')
  static Future<void> _onStart(ServiceInstance service) async {
    // Required for background execution
    DartPluginRegistrant.ensureInitialized();

    String currentTitle = 'MeshMapper';

    // Listen for stop command
    service.on('stop').listen((event) {
      service.stopSelf();
    });

    // Seed the title used until the first stats update arrives.
    service.on('setInitialTitle').listen((event) {
      if (event != null && event['title'] != null) {
        currentTitle = event['title'] as String;
      }
    });

    // Display the finished title and body composed on the app side. The isolate
    // no longer knows about modes or stat formatting, so there is nothing here
    // to drift from the phone.
    service.on('updateNotification').listen((event) {
      if (event != null && service is AndroidServiceInstance) {
        currentTitle = event['title'] as String? ?? currentTitle;
        service.setForegroundNotificationInfo(
          title: currentTitle,
          content: event['body'] as String? ?? '',
        );
      }
    });

    // Set initial notification
    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
      service.setForegroundNotificationInfo(
        title: currentTitle,
        content: 'Starting wardriving...',
      );

      // Clear a boot-start flag saved by older builds, so this start (often
      // the BootReceiver's own, on the update that installs this build) is
      // the last one it makes. Done after the listeners above: events that
      // arrive before a listener exists are dropped, so awaiting first could
      // lose a 'stop'.
      try {
        await service.setAutoStartOnBootMode(false);
      } catch (_) {
        // Best effort: initialize() also saves false on the next mode start.
      }
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
