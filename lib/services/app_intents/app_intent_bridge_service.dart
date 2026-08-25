import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../utils/debug_logger_io.dart';
import '../external_commands/external_command_models.dart';
import '../external_surfaces/external_surface_publisher.dart';
import 'app_intent_commands.dart';

typedef AppIntentCommandHandler = Future<ExternalCommandCompletion> Function(
  AppIntentCommand command,
);
typedef AppIntentSnapshotBuilder = Map<String, Object?>? Function();
typedef AppIntentPreflightKeyBuilder = String Function();

/// Independent Flutter bridge for Siri/App Intents.
///
/// It deliberately has no WatchConnectivity, widget, or CarPlay concepts.
/// Native reads are served from the Foundation-only App Group snapshot; only
/// App Intent mutations cross this channel into Dart. Future native surfaces
/// can consume that bounded projection while retaining their own lifecycle and
/// command transport.
class AppIntentBridgeService {
  AppIntentBridgeService({
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting Duration debounceDelay = defaultDebounceDelay,
    @visibleForTesting
    Duration minimumNonUrgentInterval = defaultMinimumNonUrgentInterval,
  }) : _channel = channel ?? const MethodChannel(_channelName) {
    _publisher =
        ExternalSurfacePublisher<Map<String, Object?>, Map<String, Object?>>(
      debounceDelay: debounceDelay,
      minimumNonUrgentInterval: minimumNonUrgentInterval,
      isEnabled: () => isSupportedPlatform,
      preflightPolicy: ExternalSurfacePreflightPolicy.deduplicateAfterPublish,
      payloadBuilder: (snapshot) => snapshot,
      fingerprintBuilder: (snapshot) {
        final semantic = Map<String, Object?>.from(snapshot)
          ..remove('updatedAtMs');
        return jsonEncode(semantic);
      },
      urgencyKeyBuilder: (_) => null,
      publish: (publication) async => await publishSnapshot(publication.payload)
          ? const ExternalSurfacePublishResult.published()
          : const ExternalSurfacePublishResult.rejected(),
      restartDebounce: false,
      immediateBypassesMinimumInterval: true,
    );
  }

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
  late final ExternalSurfacePublisher<Map<String, Object?>,
      Map<String, Object?>> _publisher;
  AppIntentCommandHandler? _commandHandler;
  final Map<String, ExternalCommandCompletion> _commandOutcomes = {};
  final Map<String, Future<ExternalCommandCompletion>> _inFlightCommands = {};
  bool _disposed = false;

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
    final inFlight = _inFlightCommands[command.id];
    if (inFlight != null) {
      final completion = await inFlight;
      return completion.toMap(commandId: command.id);
    }

    final handler = _commandHandler;
    if (handler == null) {
      return _refusal('App not ready').toMap(commandId: command.id);
    }

    // Normalize handler failures inside the shared future so every concurrent
    // delivery of this UUID receives the same refusal instead of the owner
    // catching an error while a duplicate sees a PlatformException.
    final execution = _executeCommand(handler, command);
    _inFlightCommands[command.id] = execution;
    try {
      final completion = await execution;
      _remember(command.id, completion);
      return completion.toMap(commandId: command.id);
    } finally {
      if (identical(_inFlightCommands[command.id], execution)) {
        _inFlightCommands.remove(command.id);
      }
    }
  }

  Future<ExternalCommandCompletion> _executeCommand(
    AppIntentCommandHandler handler,
    AppIntentCommand command,
  ) async {
    try {
      return await handler(command);
    } catch (error) {
      debugError('[SIRI] ${command.kind.name} failed: $error');
      return _refusal('Command failed');
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
    required AppIntentPreflightKeyBuilder preflightKeyBuilder,
    bool immediate = false,
  }) {
    if (!isSupportedPlatform || _disposed) return;
    _publisher.schedule(
      builder,
      preflightKeyBuilder: preflightKeyBuilder,
      immediate: immediate,
    );
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
        message: ExternalCommandReason.other(message),
      );

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _commandHandler = null;
    _commandOutcomes.clear();
    _inFlightCommands.clear();
    _publisher.dispose();
    if (isSupportedPlatform) _channel.setMethodCallHandler(null);
  }
}
