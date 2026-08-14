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
typedef WatchCommandHandler = FutureOr<String?> Function(WatchCommand command);
typedef WatchCommandRefusalHandler = void Function(String reason);
typedef WatchAvailabilityHandler = void Function(bool available);
typedef WatchSnapshotDeliveryHandler = void Function(WatchSnapshot snapshot);

/// Read-only evidence from both sides of the phone-to-watch bridge.
///
/// These timestamps intentionally do not share the transport's throttle and
/// dedupe fields. Those fields are cleared when WatchConnectivity changes
/// state, while a diagnostic must retain the last known-good send across the
/// exact outage that caused the state change.
@immutable
class WatchDiagnosticStatus {
  const WatchDiagnosticStatus({
    this.supported = false,
    this.paired = false,
    this.installed = false,
    this.reachable = false,
    this.activated = false,
    this.canSync = false,
    this.lastSuccessfulSendAt,
    this.lastAvailabilityChangedAt,
    this.lastSendDelivered,
  });

  final bool supported;
  final bool paired;
  final bool installed;
  final bool reachable;
  final bool activated;
  final bool canSync;
  final DateTime? lastSuccessfulSendAt;
  final DateTime? lastAvailabilityChangedAt;
  final bool? lastSendDelivered;

  List<String> get failingSyncConditions => [
        if (!activated) 'activated',
        if (!paired) 'paired',
        if (!installed) 'installed',
      ];
}

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
  static const Duration _mapGeoClaimFreshFor = Duration(minutes: 10);
  static const Duration _clockTolerance = Duration(seconds: 5);

  final MethodChannel _channel;

  Timer? _scheduledUpdate;
  WatchSnapshotBuilder? _pendingSnapshotBuilder;
  WatchUrgencyKeyBuilder? _pendingUrgencyKeyBuilder;
  WatchCommandHandler? _commandHandler;
  WatchCommandRefusalHandler? _commandRefusalHandler;
  WatchAvailabilityHandler? _availabilityHandler;
  WatchSnapshotDeliveryHandler? _snapshotDeliveryHandler;

  String? _lastPayload;
  String? _lastUrgencyKey;
  DateTime? _lastSentAt;
  DateTime? _lastBuiltAt;
  bool _disposed = false;
  bool _didReconcileNativeState = false;
  bool _canSync = false;
  Map<String, bool>? _lastNativeStatus;
  DateTime? _lastSuccessfulSendAt;
  DateTime? _lastAvailabilityChangedAt;
  bool? _lastSendDelivered;
  final ValueNotifier<WatchDiagnosticStatus> _diagnostics =
      ValueNotifier(const WatchDiagnosticStatus());
  DateTime? _mapGeoSuppressedAt;
  double? _lastMapGeoClaimIssuedAtMs;
  Future<void> _operationChain = Future<void>.value();

  /// Commands already handled, so redelivery can't fire a second transmit.
  final Set<String> _handledCommandIds = <String>{};

  bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  bool get canSync => isSupportedPlatform && _canSync;
  ValueListenable<WatchDiagnosticStatus> get diagnostics => _diagnostics;

  /// Whether the next payload must carry map-only geography.
  ///
  /// Suppression is leased rather than latched. If the wrist stops renewing
  /// its claim, the phone returns to full geo on the next build; excess bytes
  /// are safer than leaving a newly-visible map blank.
  bool get shouldIncludeMapGeo {
    final suppressedAt = _mapGeoSuppressedAt;
    if (suppressedAt == null) return true;
    return DateTime.now().difference(suppressedAt) >= _mapGeoClaimFreshFor;
  }

  /// Wire up the inbound command path. Safe to call more than once.
  void attachCommandHandler(
    WatchCommandHandler handler, {
    WatchCommandRefusalHandler? onRefusal,
    WatchAvailabilityHandler? onAvailabilityChanged,
    WatchSnapshotDeliveryHandler? onSnapshotDelivered,
  }) {
    _commandHandler = handler;
    _commandRefusalHandler = onRefusal;
    _availabilityHandler = onAvailabilityChanged;
    _snapshotDeliveryHandler = onSnapshotDelivered;
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
    final ageMs = issuedAtMs == null
        ? null
        : DateTime.now().millisecondsSinceEpoch - issuedAtMs;
    final requestedMapGeo = args['mapGeoNeeded'];
    final mapGeoNeeded = requestedMapGeo is bool ? requestedMapGeo : null;
    final freshMapGeoSuppression = ageMs != null &&
        ageMs >= -_clockTolerance.inMilliseconds &&
        ageMs <= _maximumCommandAge.inMilliseconds;
    final latestMapGeoClaim = _lastMapGeoClaimIssuedAtMs;
    final suppressionIsNewest = issuedAtMs != null &&
        (latestMapGeoClaim == null || issuedAtMs >= latestMapGeoClaim);
    final effectiveMapGeoNeeded = mapGeoNeeded == false &&
            (!freshMapGeoSuppression || !suppressionIsNewest)
        ? null
        : mapGeoNeeded;
    if (kind == WatchCommandKind.requestSnapshot &&
        effectiveMapGeoNeeded != null) {
      // A stale or out-of-order false could arrive after the wrist returned to
      // the map. Ignore it silently; true is always safe because it only
      // restores detail. Never move the ordering watermark backwards when an
      // older true is accepted for that conservative reason.
      _mapGeoSuppressedAt = effectiveMapGeoNeeded ? null : DateTime.now();
      if (issuedAtMs != null &&
          (latestMapGeoClaim == null || issuedAtMs >= latestMapGeoClaim)) {
        _lastMapGeoClaimIssuedAtMs = issuedAtMs;
      }
    }
    if (kind != WatchCommandKind.requestSnapshot && issuedAtMs != null) {
      if (ageMs! > _maximumCommandAge.inMilliseconds) {
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
      final admission = handler(WatchCommand(
        kind: kind,
        mode: args['mode'] as String?,
        mapGeoNeeded: effectiveMapGeoNeeded,
      ));
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

  /// Re-reads the local WCSession properties for the diagnostic surface.
  /// This does not send a snapshot or bypass the existing availability gate.
  Future<void> refreshAvailability() => _refreshAvailability();

  void _applyAvailability(
    Object? raw, {
    bool refreshNativeState = false,
  }) {
    if (raw is! Map) return;
    final status = <String, bool>{
      'supported': raw['supported'] == true,
      'paired': raw['paired'] == true,
      'installed': raw['installed'] == true,
      'reachable': raw['reachable'] == true,
      'activated': raw['activated'] == true,
    };
    final available =
        status['activated']! && status['paired']! && status['installed']!;
    final availabilityChanged = available != _canSync;
    final statusChanged = !mapEquals(_lastNativeStatus, status);

    if (availabilityChanged || refreshNativeState) _canSync = available;
    if (statusChanged) {
      _lastNativeStatus = Map.unmodifiable(status);
      _lastAvailabilityChangedAt = DateTime.now();
      _publishDiagnostics();
      // This is deliberately tied to a changed native status map. Snapshot
      // scheduling and explicit refreshes can call this path frequently, but
      // repeated state adds no evidence and would hide the useful transition.
      debugLog(
          '[WATCH] Availability changed: status=$status canSync=$_canSync');
    }
    if (!availabilityChanged && !refreshNativeState) return;

    // Native forgets its application-context cache whenever WatchConnectivity
    // reports a state change. Forget ours on the same notification even when
    // availability remains true, or an installed replacement watch could wait
    // forever for state whose fingerprint Dart still considers delivered.
    if (!available || refreshNativeState) {
      _mapGeoSuppressedAt = null;
      _lastMapGeoClaimIssuedAtMs = null;
      _lastPayload = null;
      _lastUrgencyKey = null;
      _lastSentAt = null;
      _lastBuiltAt = null;
    }
    _availabilityHandler?.call(available);
  }

  void _publishDiagnostics() {
    if (_disposed) return;
    final status = _lastNativeStatus;
    _diagnostics.value = WatchDiagnosticStatus(
      supported: status?['supported'] ?? false,
      paired: status?['paired'] ?? false,
      installed: status?['installed'] ?? false,
      reachable: status?['reachable'] ?? false,
      activated: status?['activated'] ?? false,
      canSync: canSync,
      lastSuccessfulSendAt: _lastSuccessfulSendAt,
      lastAvailabilityChangedAt: _lastAvailabilityChangedAt,
      lastSendDelivered: _lastSendDelivered,
    );
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
        _lastSendDelivered = false;
        _publishDiagnostics();
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
      final sentAt = DateTime.now();
      _lastSentAt = sentAt;
      _lastSuccessfulSendAt = sentAt;
      _lastSendDelivered = true;
      _publishDiagnostics();
      _snapshotDeliveryHandler?.call(snapshot);
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
    _snapshotDeliveryHandler = null;
    _mapGeoSuppressedAt = null;
    _lastMapGeoClaimIssuedAtMs = null;
    _diagnostics.dispose();
  }
}
