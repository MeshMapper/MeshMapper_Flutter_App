import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../utils/debug_logger_io.dart';
import '../external_commands/external_command_models.dart';
import '../external_surfaces/external_surface_publisher.dart';

typedef AndroidAutoCommandHandler = Future<ExternalCommandCompletion> Function(
  ExternalSessionCommand command,
);
typedef AndroidAutoSnapshotBuilder = Map<String, Object?>? Function();
typedef AndroidAutoPreflightKeyBuilder = String Function();
typedef AndroidAutoSessionHandler = void Function(bool active);

/// Flutter half of the Android Auto dashboard.
///
/// The car screens live in MeshMapperCarAppService.kt and render the same
/// bounded snapshot Siri reads, so the head unit never learns a fact the
/// phone's other glance surfaces do not already publish. Snapshots only cross
/// the channel while a car session is open: with no head unit attached the
/// publisher stays disabled and the provider's notify pays one early return.
///
/// Car taps arrive as [ExternalSessionCommand]s and go through the provider's
/// shared admission, so a stale car template can never transmit anything the
/// phone's own buttons would refuse.
class AndroidAutoBridgeService {
  AndroidAutoBridgeService({
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting Duration debounceDelay = defaultDebounceDelay,
    @visibleForTesting
    Duration minimumNonUrgentInterval = defaultMinimumNonUrgentInterval,
    @visibleForTesting bool? supportedPlatformOverride,
  })  : _channel = channel ?? const MethodChannel(_channelName),
        _supportedPlatformOverride = supportedPlatformOverride {
    _publisher =
        ExternalSurfacePublisher<Map<String, Object?>, Map<String, Object?>>(
      debounceDelay: debounceDelay,
      minimumNonUrgentInterval: minimumNonUrgentInterval,
      isEnabled: () => isSupportedPlatform && _carSessionActive,
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

  static const String _channelName = 'meshmapper/android_auto';
  static const int _commandQueueDepth = 8;
  static const int _maximumRememberedCommands = 64;
  static const Duration defaultDebounceDelay = Duration(milliseconds: 250);

  /// Head units throttle template refreshes on their own; matching that floor
  /// here keeps a busy session from queueing work the car will drop anyway.
  static const Duration defaultMinimumNonUrgentInterval = Duration(seconds: 1);

  /// A car tap can land while the provider is still initializing. Reserve a
  /// buffer so the relay is held instead of dropped, as the watch does.
  static void reserveCommandQueue() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    ServicesBinding.instance.channelBuffers
        .resize(_channelName, _commandQueueDepth);
  }

  final MethodChannel _channel;
  final bool? _supportedPlatformOverride;
  late final ExternalSurfacePublisher<Map<String, Object?>,
      Map<String, Object?>> _publisher;
  AndroidAutoCommandHandler? _commandHandler;
  AndroidAutoSessionHandler? _onSessionChanged;
  final Map<String, ExternalCommandCompletion> _commandOutcomes = {};
  final Map<String, Future<ExternalCommandCompletion>> _inFlightCommands = {};
  bool _carSessionActive = false;
  bool _disposed = false;

  bool get isSupportedPlatform =>
      _supportedPlatformOverride ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  bool get isCarSessionActive => _carSessionActive;

  /// Wires native calls to the provider and asks whether a car is already
  /// attached, which happens when the head unit started the process.
  void attach({
    required AndroidAutoCommandHandler commandHandler,
    required AndroidAutoSessionHandler onSessionChanged,
  }) {
    _commandHandler = commandHandler;
    _onSessionChanged = onSessionChanged;
    if (!isSupportedPlatform) return;
    _channel.setMethodCallHandler(_handleNativeCall);
    unawaited(_queryInitialSession());
  }

  Future<void> _queryInitialSession() async {
    try {
      final active = await _channel.invokeMethod<bool>('attach');
      if (active == true) _setCarSessionActive(true);
    } on MissingPluginException {
      // Engine without the native half (tests, add-to-app). Nothing to mirror.
    } on PlatformException catch (error) {
      debugError('[CAR] Attach failed: ${error.code}: ${error.message}');
    }
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'carSessionChanged':
        _setCarSessionActive(call.arguments == true);
        return null;
      case 'command':
        return _handleCommand(call.arguments);
      default:
        return null;
    }
  }

  void _setCarSessionActive(bool active) {
    if (_disposed || _carSessionActive == active) return;
    _carSessionActive = active;
    debugLog('[CAR] Car session ${active ? 'opened' : 'closed'}');
    // A new head unit has none of the earlier screens' state, so the next
    // build must not be deduplicated against what a previous car was sent.
    _publisher.resetPublishedState();
    _onSessionChanged?.call(active);
  }

  Future<Object?> _handleCommand(Object? arguments) async {
    if (arguments is! Map) return _refusal('Malformed command').toMap();
    final command = ExternalSessionCommand.fromMap(
      arguments,
      expectedSource: ExternalCommandSource.androidAuto,
    );
    if (command == null) return _refusal('Malformed command').toMap();

    final previous = _commandOutcomes[command.id];
    if (previous != null) return previous.toMap(commandId: command.id);
    final inFlight = _inFlightCommands[command.id];
    if (inFlight != null) {
      return (await inFlight).toMap(commandId: command.id);
    }

    final handler = _commandHandler;
    if (handler == null) {
      debugWarn('[CAR] ${command.kind.name}: refused, no handler attached');
      return _refusal('App not ready').toMap(commandId: command.id);
    }

    debugLog('[CAR] ${command.kind.name}'
        '${command.mode == null ? '' : ' (${command.mode})'}: received');
    final execution = _executeCommand(handler, command);
    _inFlightCommands[command.id] = execution;
    try {
      final completion = await execution;
      _remember(command.id, completion);
      debugLog('[CAR] ${command.kind.name}: '
          '${completion.disposition.name} success=${completion.success}');
      return completion.toMap(commandId: command.id);
    } finally {
      if (identical(_inFlightCommands[command.id], execution)) {
        _inFlightCommands.remove(command.id);
      }
    }
  }

  Future<ExternalCommandCompletion> _executeCommand(
    AndroidAutoCommandHandler handler,
    ExternalSessionCommand command,
  ) async {
    try {
      return await handler(command);
    } catch (error) {
      debugError('[CAR] ${command.kind.name} failed: $error');
      return _refusal('Command failed');
    }
  }

  Future<bool> publishSnapshot(Map<String, Object?> snapshot) async {
    if (!isSupportedPlatform || _disposed || !_carSessionActive) return false;
    try {
      await _channel.invokeMethod<void>('publishSnapshot', snapshot);
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugError(
        '[CAR] Snapshot publish failed: ${error.code}: ${error.message}',
      );
      return false;
    }
  }

  void schedule(
    AndroidAutoSnapshotBuilder builder, {
    required AndroidAutoPreflightKeyBuilder preflightKeyBuilder,
    bool immediate = false,
  }) {
    if (!isSupportedPlatform || _disposed || !_carSessionActive) return;
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
    _onSessionChanged = null;
    _commandOutcomes.clear();
    _inFlightCommands.clear();
    _publisher.dispose();
    if (isSupportedPlatform) _channel.setMethodCallHandler(null);
  }
}
