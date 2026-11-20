import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../utils/debug_logger_io.dart';

/// Background service manager for continuous wardriving operation.
///
/// Android: the app's own foreground service (MeshMapperSessionService.kt),
/// driven over the `meshmapper/session_service` channel. Its notification
/// keeps BLE and GPS running while the app is in the background. Android
/// decides a foreground service's while-in-use location access when it is
/// started, so a start is only worth sending while the app is on screen. It
/// stops when the app is swiped away (stopWithTask), and nothing restarts it:
/// no boot start and no restart timer. The flutter_background_service
/// plugin's Android service and receivers are removed from the manifest.
///
/// iOS: the flutter_background_service plugin, started and stopped per mode.
/// The declared background modes (bluetooth-central, location) do the real
/// work, and iOS may still throttle after extended periods.
///
/// Web: No-op (Web Bluetooth requires active tab).
@pragma('vm:entry-point')
class BackgroundServiceManager {
  static const String _notificationChannelId = 'meshmapper_wardriving';
  static const int _notificationId = 888;

  /// The Android session service (MeshMapperSessionService.kt).
  static const MethodChannel _sessionChannel =
      MethodChannel('meshmapper/session_service');

  static FlutterBackgroundService? _service;
  static bool _isInitialized = false;
  static bool _isRunning = false;

  /// Bumped by every [stopService] call, even one that finds nothing running.
  /// A start captures it first and abandons itself when it moved, so a
  /// disconnect that lands while a start is on its way cannot be followed by
  /// that start marking the service running (or, on iOS, leaving one behind).
  static int _stopGeneration = 0;

  /// Bumped by every Android start. The status check after a start only acts
  /// if no other start or stop came after it.
  static int _startGeneration = 0;

  /// The last content sent to the Android service, so a repeat is dropped.
  /// Cleared by every start and stop.
  static ({String title, String body, bool keepAwake})? _lastNotification;

  /// How often [waitUntilStopped] polls, and how long it waits at most.
  static const Duration _stopPollInterval = Duration(milliseconds: 100);
  static const Duration _stopWaitLimit = Duration(seconds: 2);

  /// How long after an Android start to ask the service whether it came up.
  /// A start that fails inside the service (startForeground refused) is only
  /// reported there, after the channel call has already answered.
  static const Duration _startStatusDelay = Duration(milliseconds: 1500);

  /// True where the background service runs for the whole radio session
  /// (Android, the app's own session service). False where it runs per mode
  /// (iOS, the plugin) and on web.
  static bool get followsConnection =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Initialize the iOS background service.
  /// Called lazily on first startService() call — never at app startup.
  /// Startup orphan cleanup uses cleanupOrphanedService(), which needs no
  /// configure().
  static Future<void> initialize() async {
    // Skip on web - no background service support
    if (kIsWeb) {
      debugLog('[BACKGROUND] Skipping initialization (web platform)');
      return;
    }

    // Android runs the app's own session service, not the plugin's.
    if (followsConnection) return;

    if (_isInitialized) {
      debugLog('[BACKGROUND] Already initialized');
      return;
    }

    debugLog('[BACKGROUND] Initializing background service');

    try {
      // Initialize the background service
      _service = FlutterBackgroundService();

      await _service!.configure(
        // configure() requires an Android configuration even though Android
        // never runs the plugin's service. Both starts stay off explicitly.
        androidConfiguration: AndroidConfiguration(
          onStart: _onStart,
          autoStart: false,
          autoStartOnBoot: false,
          isForegroundMode: true,
          notificationChannelId: _notificationChannelId,
          initialNotificationTitle: 'MeshMapper',
          initialNotificationContent: 'Wardriving active',
          foregroundServiceNotificationId: _notificationId,
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: _onStart,
          onBackground: _onIosBackground,
        ),
      );

      // Defense-in-depth: a service this session did not start may already
      // be running.
      final isRunning = await _service!.isRunning();
      if (isRunning) {
        debugLog(
            '[BACKGROUND] Service unexpectedly running after configure(), stopping it');
        _service!.invoke('stop');
        // Wait for it to actually go, so its stop cannot land after the
        // start that follows and take that one down with it.
        await _awaitPendingStop(_service!, 'stale service after configure()');
      }

      _isInitialized = true;
      debugLog('[BACKGROUND] Background service initialized');
    } catch (e) {
      debugError('[BACKGROUND] Failed to initialize: $e');
    }
  }

  /// Start the background service.
  ///
  /// [title] and [body] are the finished notification strings. The caller
  /// composes them (mode name and stats live on the app side); the service
  /// only displays what it is handed.
  ///
  /// Android only: [keepAwake] holds a wake lock while the service runs, and
  /// [mayStart], when given, is asked right before the start is sent, with no
  /// await in between. A start it refuses sends nothing. A service that is
  /// already running or starting only takes the new content.
  static Future<void> startService({
    required String title,
    required String body,
    bool keepAwake = false,
    bool Function()? mayStart,
  }) async {
    if (kIsWeb) {
      debugLog('[BACKGROUND] Cannot start service on web');
      return;
    }

    if (followsConnection) {
      return _startSessionService(
        title: title,
        body: body,
        keepAwake: keepAwake,
        mayStart: mayStart,
      );
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
        return;
      }
      _isRunning = true;

      // Update notification with initial stats
      await updateNotification(title: title, body: body);

      debugLog('[BACKGROUND] Background service started');
    } catch (e) {
      debugError('[BACKGROUND] Failed to start service: $e');
    }
  }

  static Future<void> _startSessionService({
    required String title,
    required String body,
    required bool keepAwake,
    required bool Function()? mayStart,
  }) async {
    // Asked here, synchronously before the channel call: Android only grants
    // the service while-in-use location if the app is on screen at the
    // start, and the app may have left it since the caller decided to start.
    if (mayStart != null && !mayStart()) {
      debugLog('[BACKGROUND] Start skipped: the caller no longer wants it');
      return;
    }

    final startGeneration = ++_startGeneration;
    final stopGeneration = _stopGeneration;
    _lastNotification = null;
    debugLog('[BACKGROUND] Starting background service ($title)');

    try {
      final reply = await _sessionChannel.invokeMapMethod<String, Object?>(
        'start',
        {'title': title, 'body': body, 'keepAwake': keepAwake},
      );
      if (reply?['started'] != true) {
        debugError('[BACKGROUND] Failed to start service: ${reply?['error']}');
        return;
      }
      if (stopGeneration != _stopGeneration) {
        // The stop already reached the service, which stops itself once it
        // is up. Counting it running here would outlive that stop.
        debugLog('[BACKGROUND] A stop arrived during the start');
        return;
      }
      _isRunning = true;
      debugLog('[BACKGROUND] Background service started');
      unawaited(_checkStartStatus(
        startGeneration: startGeneration,
        stopGeneration: stopGeneration,
      ));
    } catch (e) {
      debugError('[BACKGROUND] Failed to start service: $e');
    }
  }

  /// Shortly after an Android start, ask the service whether it came up. The
  /// channel answers a start before the service has tried startForeground,
  /// so a refusal there (no location permission, started from the
  /// background) only shows up here. Skipped when another start or stop came
  /// since: the answer would describe that one instead.
  static Future<void> _checkStartStatus({
    required int startGeneration,
    required int stopGeneration,
  }) async {
    bool superseded() =>
        startGeneration != _startGeneration || stopGeneration != _stopGeneration;

    await Future<void>.delayed(_startStatusDelay);
    if (superseded()) return;
    final running = await _readStatus();
    if (running == null || superseded()) return;
    if (!running) _isRunning = false;
  }

  /// Ask the Android service whether it is running (or still starting).
  /// Reading the status clears the service's last error, so the error is
  /// logged here, whoever asked. Null when the channel call failed.
  static Future<bool?> _readStatus() async {
    try {
      final status =
          await _sessionChannel.invokeMapMethod<String, Object?>('status');
      if (status == null) return null;
      final lastError = status['lastError'];
      if (lastError != null) {
        debugError('[BACKGROUND] Service failed to start: $lastError');
      }
      return status['running'] == true;
    } catch (e) {
      debugWarn('[BACKGROUND] Could not read the service status: $e');
      return null;
    }
  }

  /// On return to the app (Android), bring the service in line with the
  /// radio session. A service still running with no session left is stopped;
  /// otherwise [isRunning] takes the service's own answer, so a service that
  /// died in the background can be started again while the app is on screen.
  static Future<void> healAfterResume({required bool sessionActive}) async {
    if (!followsConnection) return;

    final startGeneration = _startGeneration;
    final stopGeneration = _stopGeneration;
    final running = await _readStatus();
    if (running == null) return;
    // A start or stop sent meanwhile is newer than this answer.
    if (startGeneration != _startGeneration ||
        stopGeneration != _stopGeneration) {
      return;
    }

    if (running && !sessionActive) {
      debugLog('[BACKGROUND] Service running with no radio session, '
          'stopping it');
      await _stopSessionService();
      return;
    }
    _isRunning = running;
  }

  /// Wait (bounded) for a service that was sent 'stop' to actually stop, and
  /// log how long it took. Never throws.
  static Future<void> _awaitPendingStop(
    FlutterBackgroundService service,
    String what,
  ) async {
    final elapsed = await waitUntilStopped(
      isRunning: service.isRunning,
      pollInterval: _stopPollInterval,
      timeout: _stopWaitLimit,
    );
    if (elapsed == null) {
      debugWarn('[BACKGROUND] $what still running after '
          '${_stopWaitLimit.inMilliseconds} ms, starting anyway');
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

  /// Stop the background service.
  /// Called when auto-ping mode is disabled or on disconnect.
  ///
  /// Android always sends the stop, even with nothing counted as running: a
  /// start may still be on its way, and the service holds the stop until it
  /// is up (stopping it before startForeground would crash the app).
  static Future<void> stopService() async {
    if (kIsWeb) return;

    if (followsConnection) {
      await _stopSessionService();
      return;
    }

    // Always, even with nothing running: a start may be waiting on
    // initialize() and must not go ahead after this one.
    _stopGeneration++;

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

  static Future<void> _stopSessionService() async {
    _stopGeneration++;
    _isRunning = false;
    _lastNotification = null;
    debugLog('[BACKGROUND] Stopping background service');
    try {
      await _sessionChannel.invokeMethod<void>('stop');
    } catch (e) {
      debugError('[BACKGROUND] Failed to stop service: $e');
    }
  }

  /// Stop the Android service whoever started it, before the app closes
  /// itself or at startup. On Android this is the same stop as
  /// [stopService], which is always sent. A no-op elsewhere.
  static Future<void> stopLiveService(String what) async {
    if (!followsConnection) return;
    debugLog('[BACKGROUND] Stopping running service ($what)');
    await _stopSessionService();
  }

  /// Update the notification with the current wardriving title and body.
  /// Called periodically to show TX/RX counts and queue size.
  ///
  /// Android drops an update identical to the last one sent, and sends one
  /// even before a start has answered: the service keeps the latest content
  /// and shows it once it is up. [keepAwake] is Android only.
  static Future<void> updateNotification({
    required String title,
    required String body,
    bool keepAwake = false,
  }) async {
    if (kIsWeb) return;

    if (followsConnection) {
      final content = (title: title, body: body, keepAwake: keepAwake);
      if (content == _lastNotification) return;
      _lastNotification = content;
      try {
        await _sessionChannel.invokeMethod<void>('update', {
          'title': title,
          'body': body,
          'keepAwake': keepAwake,
        });
      } catch (e) {
        // Let the same content through again next time.
        if (_lastNotification == content) _lastNotification = null;
        debugError('[BACKGROUND] Failed to update notification: $e');
      }
      return;
    }

    if (!_isRunning) return;

    try {
      _service?.invoke('updateNotification', {
        'title': title,
        'body': body,
      });
    } catch (e) {
      debugError('[BACKGROUND] Failed to update notification: $e');
    }
  }

  /// Check if the background service is running. On Android this counts a
  /// start the service has accepted and not yet finished.
  static bool get isRunning => _isRunning;

  /// Install a stand-in plugin service and reset the manager's state, so the
  /// start and stop paths can be driven without the plugin.
  @visibleForTesting
  static void debugInstallService(FlutterBackgroundService? service) {
    _service = service;
    _isInitialized = service != null;
    _isRunning = false;
    _lastNotification = null;
    // Moved on, not reset, so a status check still waiting from before finds
    // itself superseded.
    _stopGeneration++;
    _startGeneration++;
  }

  /// Check if the background service is initialized.
  static bool get isInitialized => _isInitialized;

  /// Clean up any orphaned service from a previous app session. Call this at
  /// app startup, from a cold main(): the isolate that drove any earlier
  /// service is gone, so a service running now is an orphan.
  ///
  /// Android: stops the session service. Its notification belongs to a
  /// foreground service, which Android does not let the app cancel, only
  /// stop. One can still be up here when the process outlived the engine
  /// that started it.
  ///
  /// iOS: cancels notification [_notificationId]. The local-notifications
  /// plugin is initialized first: cancel() silently no-ops until its platform
  /// channel is initialized.
  static Future<void> cleanupOrphanedService() async {
    if (kIsWeb) return;
    if (followsConnection) {
      await stopLiveService('orphaned service');
      return;
    }
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
  }

  /// Called when the plugin's service starts: iOS's onForeground. The
  /// Android branches never run now that Android uses its own service.
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
