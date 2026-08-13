import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../utils/debug_logger_io.dart';
import 'watch_models.dart';

typedef WatchSnapshotBuilder = WatchSnapshot? Function();
typedef WatchUrgencyKeyBuilder = String Function();

/// Decides whether a wrist command may begin. Returns null when admitted, or a
/// reason when refused; admitted work continues independently of this reply.
/// Production handlers must decide synchronously; FutureOr keeps existing
/// bridge fakes source-compatible without putting the real path behind a wait.
typedef WatchCommandHandler = FutureOr<String?> Function(WatchCommandKind kind);
typedef WatchCommandRefusalHandler = void Function(String reason);
typedef WatchAvailabilityHandler = void Function(bool available);

/// Owns the Flutter↔WatchConnectivity bridge and coalesces noisy app state.
///
/// Deliberately mirrors [LiveActivityService]'s shape — fingerprint dedupe,
/// urgency bypass, minimum non-urgent interval — because that pattern is
/// already proven in this app. The one addition is a movement gate: GPS
/// updates arrive continuously while driving, and forwarding every one would
/// flatten the watch battery for sub-pixel map changes.
class WatchBridgeService {
  WatchBridgeService({@visibleForTesting MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'meshmapper/watch';

  static const Duration _debounceDelay = Duration(milliseconds: 200);
  static const Duration _minimumNonUrgentInterval = Duration(seconds: 2);
  static const Duration _maximumCommandAge = Duration(seconds: 30);

  final MethodChannel _channel;

  Timer? _scheduledUpdate;
  WatchSnapshotBuilder? _pendingSnapshotBuilder;
  WatchUrgencyKeyBuilder? _pendingUrgencyKeyBuilder;
  WatchCommandHandler? _commandHandler;
  WatchCommandRefusalHandler? _commandRefusalHandler;
  WatchAvailabilityHandler? _availabilityHandler;

  String? _lastPayload;
  String? _lastUrgencyKey;
  DateTime? _lastSentAt;
  DateTime? _lastBuiltAt;
  bool _disposed = false;
  bool _didReconcileNativeState = false;
  bool _canSync = false;
  Future<void> _operationChain = Future<void>.value();

  /// Commands already handled, so redelivery can't fire a second transmit.
  final Set<String> _handledCommandIds = <String>{};

  bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  bool get canSync => isSupportedPlatform && _canSync;

  /// Wire up the inbound command path. Safe to call more than once.
  void attachCommandHandler(
    WatchCommandHandler handler, {
    WatchCommandRefusalHandler? onRefusal,
    WatchAvailabilityHandler? onAvailabilityChanged,
  }) {
    _commandHandler = handler;
    _commandRefusalHandler = onRefusal;
    _availabilityHandler = onAvailabilityChanged;
    if (!isSupportedPlatform) return;
    _channel.setMethodCallHandler(_handleNativeCall);
    unawaited(_refreshAvailability());
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method == 'availabilityChanged') {
      _applyAvailability(call.arguments, refreshNativeState: true);
      return null;
    }
    if (call.method != 'command') return null;

    final args = call.arguments;
    if (args is! Map) return {'accepted': false, 'reason': 'Malformed command'};

    final id = args['id'] as String?;
    final rawKind = args['kind'] as String?;
    if (id == null || rawKind == null) {
      return {'accepted': false, 'reason': 'Malformed command'};
    }

    // WatchConnectivity redelivers; a duplicate must not transmit twice.
    if (_handledCommandIds.contains(id)) {
      return {'id': id, 'accepted': true, 'reason': null};
    }

    final kind = WatchCommandKind.fromWire(rawKind);
    if (kind == null) {
      return {'id': id, 'accepted': false, 'reason': 'Unsupported command'};
    }

    final handler = _commandHandler;
    if (handler == null) {
      return {'id': id, 'accepted': false, 'reason': 'App not ready'};
    }

    _rememberCommandId(id);

    final rawIssuedAtMs = args['issuedAtMs'];
    final issuedAtMs = rawIssuedAtMs is num ? rawIssuedAtMs.toDouble() : null;
    if (kind != WatchCommandKind.requestSnapshot && issuedAtMs != null) {
      final ageMs = DateTime.now().millisecondsSinceEpoch - issuedAtMs;
      if (ageMs > _maximumCommandAge.inMilliseconds) {
        const reason = 'Took too long to reach iPhone';
        // This window is about correctness, not queue housekeeping: executing
        // a transmit after the vehicle has moved attributes it to the wrong
        // place. Missing timestamps remain accepted for older watch builds.
        _commandRefusalHandler?.call(reason);
        return {'id': id, 'accepted': false, 'reason': reason};
      }
    }

    try {
      // This is admission, not completion. Keeping the handler synchronous is
      // what makes the MethodChannel response fit inside WatchConnectivity's
      // short reply window; the admitted action reports its later outcome via
      // normal snapshots and one-shot cues.
      final admission = handler(kind);
      final refusal =
          admission is Future<String?> ? await admission : admission;
      if (refusal != null) {
        _commandRefusalHandler?.call(refusal);
        // Reply-capable legacy watches could retry an admission refusal with
        // the same ID. Queued commands must stay remembered: redelivery after
        // conditions change must never turn yesterday's tap into a transmit.
        if (issuedAtMs == null) _handledCommandIds.remove(id);
      }
      return {'id': id, 'accepted': refusal == null, 'reason': refusal};
    } catch (error) {
      debugError('[WATCH] Command $rawKind failed: $error');
      const reason = 'Command failed';
      _commandRefusalHandler?.call(reason);
      return {'id': id, 'accepted': false, 'reason': reason};
    }
  }

  Future<void> _refreshAvailability() async {
    try {
      _applyAvailability(await _channel.invokeMethod<Object?>('status'));
    } on MissingPluginException {
      // Expected on non-iOS test hosts and older generated projects.
    } on PlatformException catch (error) {
      debugError('[WATCH] Status failed: ${error.code}: ${error.message}');
    }
  }

  void _applyAvailability(
    Object? raw, {
    bool refreshNativeState = false,
  }) {
    if (raw is! Map) return;
    final available = raw['activated'] == true &&
        raw['paired'] == true &&
        raw['installed'] == true;
    if (available == _canSync && !refreshNativeState) return;
    _canSync = available;

    // Native forgets its application-context cache whenever WatchConnectivity
    // reports a state change. Forget ours on the same notification even when
    // availability remains true, or an installed replacement watch could wait
    // forever for state whose fingerprint Dart still considers delivered.
    if (!available || refreshNativeState) {
      _lastPayload = null;
      _lastUrgencyKey = null;
      _lastSentAt = null;
      _lastBuiltAt = null;
    }
    _availabilityHandler?.call(available);
  }

  void _rememberCommandId(String id) {
    _handledCommandIds.add(id);
    // Unbounded growth would leak across a long session.
    if (_handledCommandIds.length > 64) {
      _handledCommandIds.remove(_handledCommandIds.first);
    }
  }

  void schedule(
    WatchSnapshotBuilder snapshotBuilder, {
    required WatchUrgencyKeyBuilder urgencyKeyBuilder,
    bool immediate = false,
  }) {
    if (_disposed || !canSync) return;

    _pendingSnapshotBuilder = snapshotBuilder;
    _pendingUrgencyKeyBuilder = urgencyKeyBuilder;
    _scheduledUpdate?.cancel();

    if (immediate) {
      _enqueueFlush();
      return;
    }

    _scheduledUpdate = Timer(_debounceDelay, _enqueueFlush);
  }

  void _enqueueFlush() {
    _operationChain = _operationChain.then((_) => _flush()).catchError(
      (Object error) {
        debugError('[WATCH] Update queue failed: $error');
      },
    );
  }

  Future<void> _flush() async {
    _scheduledUpdate?.cancel();
    _scheduledUpdate = null;

    if (_disposed || !canSync) return;

    // Urgency is intentionally a small scalar projection of provider state.
    // If it has not changed, enforce the radio throttle before constructing,
    // sorting, or JSON-encoding any geography. Phase/control/cue transitions
    // still differ here and retain their existing immediate path.
    final pendingUrgencyKey = _pendingUrgencyKeyBuilder?.call();
    final predictedUrgent = pendingUrgencyKey != _lastUrgencyKey;
    final lastBuiltAt = _lastBuiltAt;
    if (!predictedUrgent && lastBuiltAt != null) {
      final elapsed = DateTime.now().difference(lastBuiltAt);
      if (elapsed < _minimumNonUrgentInterval) {
        _scheduledUpdate = Timer(
          _minimumNonUrgentInterval - elapsed,
          _enqueueFlush,
        );
        return;
      }
    }

    _lastBuiltAt = DateTime.now();
    final snapshot = _pendingSnapshotBuilder?.call();
    if (snapshot == null) {
      if (_lastPayload == null && _didReconcileNativeState) return;
      await _clear();
      return;
    }

    final payload = snapshot.toMap();

    // updatedAt is metadata for staleness, not a visible state change.
    // Excluding it stops timer ticks from causing native updates; the watch
    // renders countdowns from the absolute phaseEndsAt deadline instead.
    final fingerprint = Map<String, Object?>.from(payload)
      ..remove('updatedAtMs');
    final encoded = jsonEncode(fingerprint);
    if (encoded == _lastPayload) return;

    final urgent = snapshot.urgencyKey != _lastUrgencyKey;
    final sentAt = _lastSentAt;
    if (!urgent && sentAt != null) {
      final elapsed = DateTime.now().difference(sentAt);
      if (elapsed < _minimumNonUrgentInterval) {
        _scheduledUpdate = Timer(
          _minimumNonUrgentInterval - elapsed,
          _enqueueFlush,
        );
        return;
      }
    }

    try {
      final delivered = await _channel.invokeMethod<Object?>('sync', {
        'payload': payload,
        'urgent': urgent,
      });
      if (delivered != true) {
        // Native can lose availability between status and send. Do not cache
        // a payload it refused. Re-query rather than guessing which condition
        // failed, so a transient context error cannot permanently close the
        // gate while the watch is actually still installed.
        await _refreshAvailability();
        return;
      }
      _didReconcileNativeState = true;
      _lastPayload = encoded;
      _lastUrgencyKey = snapshot.urgencyKey;
      _lastSentAt = DateTime.now();
    } on MissingPluginException {
      // Expected on non-iOS hosts and in tests.
    } on PlatformException catch (error) {
      debugError('[WATCH] Sync failed: ${error.code}: ${error.message}');
    } catch (error) {
      debugError('[WATCH] Unexpected sync failure: $error');
    }
  }

  Future<void> _clear() async {
    try {
      await _channel.invokeMethod<void>('clear');
    } on MissingPluginException {
      // Expected on non-iOS hosts and in tests.
    } on PlatformException catch (error) {
      debugError('[WATCH] Clear failed: ${error.code}: ${error.message}');
    } catch (error) {
      debugError('[WATCH] Unexpected clear failure: $error');
    } finally {
      _didReconcileNativeState = true;
      _lastPayload = null;
      _lastUrgencyKey = null;
      _lastSentAt = null;
      _lastBuiltAt = null;
    }
  }

  void dispose() {
    _disposed = true;
    _scheduledUpdate?.cancel();
    _scheduledUpdate = null;
    _pendingSnapshotBuilder = null;
    _pendingUrgencyKeyBuilder = null;
    _commandHandler = null;
    _commandRefusalHandler = null;
    _availabilityHandler = null;
  }
}
