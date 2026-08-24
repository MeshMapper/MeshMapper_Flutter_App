import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../utils/debug_logger_io.dart';
import '../external_commands/external_command_models.dart';
import 'app_intent_commands.dart';

typedef AppIntentCommandHandler = Future<ExternalCommandCompletion> Function(
  AppIntentCommand command,
);
typedef AppIntentSnapshotBuilder = Map<String, Object?>? Function();

/// Independent Flutter bridge for Siri/App Intents.
///
/// It deliberately has no WatchConnectivity concepts. Native reads are served
/// from the App Group snapshot; only mutations cross this channel into Dart.
class AppIntentBridgeService {
  AppIntentBridgeService({
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting Duration debounceDelay = defaultDebounceDelay,
    @visibleForTesting
    Duration minimumNonUrgentInterval = defaultMinimumNonUrgentInterval,
  })  : _channel = channel ?? const MethodChannel(_channelName),
        _debounceDelay = debounceDelay,
        _minimumNonUrgentInterval = minimumNonUrgentInterval;

  static const String _channelName = 'meshmapper/app_intents';
  static const int _commandQueueDepth = 8;
  static const int _maximumRememberedCommands = 64;
  static const Duration defaultDebounceDelay = Duration(milliseconds: 200);
  static const Duration defaultMinimumNonUrgentInterval = Duration(seconds: 2);

  static void reserveCommandQueue() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    ServicesBinding.instance.channelBuffers
        .resize(_channelName, _commandQueueDepth);
  }

  final MethodChannel _channel;
  final Duration _debounceDelay;
  final Duration _minimumNonUrgentInterval;
  AppIntentCommandHandler? _commandHandler;
  final Map<String, ExternalCommandCompletion> _commandOutcomes = {};
  bool _disposed = false;
  Timer? _scheduledUpdate;
  AppIntentSnapshotBuilder? _pendingSnapshotBuilder;
  String? _lastFingerprint;
  DateTime? _lastPublishedAt;
  Future<void> _operationChain = Future<void>.value();

  bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  void attachCommandHandler(AppIntentCommandHandler handler) {
    _commandHandler = handler;
    if (!isSupportedPlatform) return;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method != 'command') return null;
    final arguments = call.arguments;
    if (arguments is! Map) {
      return _refusal('Malformed command').toMap();
    }
    final command = AppIntentCommand.fromMap(arguments);
    if (command == null) {
      return _refusal('Malformed command').toMap();
    }

    final previous = _commandOutcomes[command.id];
    if (previous != null) return previous.toMap(commandId: command.id);

    final handler = _commandHandler;
    if (handler == null) {
      return _refusal('App not ready').toMap(commandId: command.id);
    }

    try {
      final completion = await handler(command);
      _remember(command.id, completion);
      return completion.toMap(commandId: command.id);
    } catch (error) {
      debugError('[SIRI] ${command.kind.name} failed: $error');
      final completion = _refusal('Command failed');
      _remember(command.id, completion);
      return completion.toMap(commandId: command.id);
    }
  }

  Future<bool> publishSnapshot(Map<String, Object?> snapshot) async {
    if (!isSupportedPlatform || _disposed) return false;
    try {
      await _channel.invokeMethod<void>('publishSnapshot', snapshot);
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugError(
        '[SIRI] Snapshot publish failed: ${error.code}: ${error.message}',
      );
      return false;
    }
  }

  void schedule(
    AppIntentSnapshotBuilder builder, {
    bool immediate = false,
  }) {
    if (!isSupportedPlatform || _disposed) return;
    _pendingSnapshotBuilder = builder;
    if (immediate) {
      _scheduledUpdate?.cancel();
      _scheduledUpdate = null;
      _queueFlush();
      return;
    }
    _scheduledUpdate ??= Timer(_debounceDelay, () {
      _scheduledUpdate = null;
      final lastPublishedAt = _lastPublishedAt;
      final remaining = lastPublishedAt == null
          ? Duration.zero
          : _minimumNonUrgentInterval -
              DateTime.now().difference(lastPublishedAt);
      if (remaining > Duration.zero) {
        _scheduledUpdate = Timer(remaining, () {
          _scheduledUpdate = null;
          _queueFlush();
        });
      } else {
        _queueFlush();
      }
    });
  }

  void _queueFlush() {
    _operationChain = _operationChain.then((_) => _flush());
  }

  Future<void> _flush() async {
    if (_disposed) return;
    final builder = _pendingSnapshotBuilder;
    _pendingSnapshotBuilder = null;
    if (builder == null) return;
    final snapshot = builder();
    if (snapshot == null) return;

    final semantic = Map<String, Object?>.from(snapshot)..remove('updatedAtMs');
    final fingerprint = jsonEncode(semantic);
    if (fingerprint == _lastFingerprint) return;
    if (await publishSnapshot(snapshot)) {
      _lastFingerprint = fingerprint;
      _lastPublishedAt = DateTime.now();
    }
  }

  Future<void> clearSnapshot() async {
    if (!isSupportedPlatform || _disposed) return;
    try {
      await _channel.invokeMethod<void>('clearSnapshot');
    } on MissingPluginException {
      // Older native builds have no App Intent bridge.
    } on PlatformException catch (error) {
      debugError(
        '[SIRI] Snapshot clear failed: ${error.code}: ${error.message}',
      );
    }
  }

  void _remember(String id, ExternalCommandCompletion completion) {
    _commandOutcomes[id] = completion;
    while (_commandOutcomes.length > _maximumRememberedCommands) {
      _commandOutcomes.remove(_commandOutcomes.keys.first);
    }
  }

  static ExternalCommandCompletion _refusal(String message) =>
      ExternalCommandCompletion(
        success: false,
        disposition: ExternalCommandDisposition.refused,
        message: message,
      );

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _commandHandler = null;
    _commandOutcomes.clear();
    _scheduledUpdate?.cancel();
    _scheduledUpdate = null;
    _pendingSnapshotBuilder = null;
    if (isSupportedPlatform) _channel.setMethodCallHandler(null);
  }
}
