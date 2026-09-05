import 'dart:async';

enum ExternalSurfacePreflightPolicy {
  deduplicateAfterPublish,
  throttleAgainstPublishedUrgency,
  throttleAgainstLastBuild,
}

enum ExternalSurfacePublishDisposition {
  published,
  rejected,
  disable,
}

class ExternalSurfacePublishResult {
  const ExternalSurfacePublishResult._(
    this.disposition, {
    this.retryAfter,
  });

  const ExternalSurfacePublishResult.published()
      : this._(ExternalSurfacePublishDisposition.published);

  const ExternalSurfacePublishResult.rejected({Duration? retryAfter})
      : this._(
          ExternalSurfacePublishDisposition.rejected,
          retryAfter: retryAfter,
        );

  const ExternalSurfacePublishResult.disable()
      : this._(ExternalSurfacePublishDisposition.disable);

  final ExternalSurfacePublishDisposition disposition;
  final Duration? retryAfter;
}

class ExternalSurfacePublication<TSnapshot, TPayload> {
  const ExternalSurfacePublication({
    required this.snapshot,
    required this.payload,
    required this.fingerprint,
    required this.urgent,
    required this.forceDelivery,
  });

  final TSnapshot snapshot;
  final TPayload payload;
  final String fingerprint;
  final bool urgent;
  final bool forceDelivery;
}

typedef ExternalSurfaceSnapshotBuilder<TSnapshot> = TSnapshot? Function();
typedef ExternalSurfacePreflightKeyBuilder = Object? Function();
typedef ExternalSurfacePayloadBuilder<TSnapshot, TPayload> = TPayload Function(
  TSnapshot snapshot,
);
typedef ExternalSurfaceFingerprintBuilder<TPayload> = String Function(
  TPayload payload,
);
typedef ExternalSurfaceUrgencyKeyBuilder<TSnapshot> = Object? Function(
  TSnapshot snapshot,
);
typedef ExternalSurfacePublish<TSnapshot, TPayload>
    = Future<ExternalSurfacePublishResult> Function(
  ExternalSurfacePublication<TSnapshot, TPayload> publication,
);
typedef ExternalSurfaceClear = Future<void> Function({
  required bool immediate,
});
typedef ExternalSurfaceCandidateGate<TSnapshot, TPayload> = bool Function(
  ExternalSurfacePublication<TSnapshot, TPayload> publication,
);

/// Shared debounce, preflight, dedupe, throttle, and serialization pipeline for
/// state projected onto an external surface.
///
/// The owner supplies domain serialization and transport callbacks. This class
/// deliberately knows nothing about WatchConnectivity, ActivityKit, App Groups,
/// or the shape of their payloads.
class ExternalSurfacePublisher<TSnapshot, TPayload> {
  ExternalSurfacePublisher({
    required Duration debounceDelay,
    required Duration minimumNonUrgentInterval,
    required bool Function() isEnabled,
    required ExternalSurfacePreflightPolicy preflightPolicy,
    required ExternalSurfacePayloadBuilder<TSnapshot, TPayload> payloadBuilder,
    required ExternalSurfaceFingerprintBuilder<TPayload> fingerprintBuilder,
    required ExternalSurfaceUrgencyKeyBuilder<TSnapshot> urgencyKeyBuilder,
    required ExternalSurfacePublish<TSnapshot, TPayload> publish,
    ExternalSurfaceClear? clear,
    ExternalSurfaceCandidateGate<TSnapshot, TPayload>? candidateGate,
    void Function(Object error)? onQueueError,
    void Function(Duration remaining)? onHeld,
    bool restartDebounce = true,
    bool immediateBypassesMinimumInterval = false,
  })  : _debounceDelay = debounceDelay,
        _minimumNonUrgentInterval = minimumNonUrgentInterval,
        _isEnabled = isEnabled,
        _preflightPolicy = preflightPolicy,
        _payloadBuilder = payloadBuilder,
        _fingerprintBuilder = fingerprintBuilder,
        _urgencyKeyBuilder = urgencyKeyBuilder,
        _publish = publish,
        _clear = clear,
        _candidateGate = candidateGate,
        _onQueueError = onQueueError,
        _onHeld = onHeld,
        _restartDebounce = restartDebounce,
        _immediateBypassesMinimumInterval = immediateBypassesMinimumInterval;

  final Duration _debounceDelay;
  final Duration _minimumNonUrgentInterval;
  final bool Function() _isEnabled;
  final ExternalSurfacePreflightPolicy _preflightPolicy;
  final ExternalSurfacePayloadBuilder<TSnapshot, TPayload> _payloadBuilder;
  final ExternalSurfaceFingerprintBuilder<TPayload> _fingerprintBuilder;
  final ExternalSurfaceUrgencyKeyBuilder<TSnapshot> _urgencyKeyBuilder;
  final ExternalSurfacePublish<TSnapshot, TPayload> _publish;
  final ExternalSurfaceClear? _clear;
  final ExternalSurfaceCandidateGate<TSnapshot, TPayload>? _candidateGate;
  final void Function(Object error)? _onQueueError;

  /// Told once per held window, with the time left on the floor, when a
  /// non-urgent update is deferred. Once, because ordinary notifies re-arm
  /// the floor timer several times a second and a report per re-arm would
  /// drown the log it exists for. The window closes on the next publish.
  final void Function(Duration remaining)? _onHeld;
  final bool _restartDebounce;
  final bool _immediateBypassesMinimumInterval;

  Timer? _scheduledUpdate;
  ExternalSurfaceSnapshotBuilder<TSnapshot>? _pendingSnapshotBuilder;
  ExternalSurfacePreflightKeyBuilder? _pendingPreflightKeyBuilder;
  String? _lastFingerprint;
  Object? _lastPublishedUrgencyKey;
  Object? _lastBuiltPreflightKey;
  DateTime? _lastBuiltAt;
  DateTime? _lastPublishedAt;
  Future<void> _operationChain = Future<void>.value();
  bool _forceDelivery = false;
  bool _bypassBuildFloor = false;
  bool _heldReported = false;
  bool _didReconcileEmptyState = false;
  bool _disabled = false;
  bool _disposed = false;

  bool get hasPublishedFingerprint => _lastFingerprint != null;

  void schedule(
    ExternalSurfaceSnapshotBuilder<TSnapshot> snapshotBuilder, {
    required ExternalSurfacePreflightKeyBuilder preflightKeyBuilder,
    bool immediate = false,
    bool forceDelivery = false,
  }) {
    if (_disposed || _disabled || !_isEnabled()) return;

    _pendingSnapshotBuilder = snapshotBuilder;
    _pendingPreflightKeyBuilder = preflightKeyBuilder;
    if (forceDelivery) _forceDelivery = true;
    if (_restartDebounce) {
      _scheduledUpdate?.cancel();
      _scheduledUpdate = null;
    }

    if (immediate) {
      _scheduledUpdate?.cancel();
      _scheduledUpdate = null;
      _enqueueFlush(
        bypassMinimumInterval: _immediateBypassesMinimumInterval,
      );
      return;
    }

    _scheduledUpdate ??= Timer(_debounceDelay, _enqueueFlush);
  }

  /// Re-attempt the latest pending projection after an owner-specific backoff.
  void retryAfter(Duration delay, {bool bypassBuildFloor = true}) {
    if (_disposed || _disabled || !_isEnabled()) return;
    if (bypassBuildFloor) _bypassBuildFloor = true;
    _scheduledUpdate?.cancel();
    _scheduledUpdate = Timer(delay, _enqueueFlush);
  }

  /// Makes the next queued build independent of the ordinary pre-build floor.
  void bypassNextBuildFloor() {
    if (_disposed || _disabled) return;
    _bypassBuildFloor = true;
  }

  void _enqueueFlush({bool bypassMinimumInterval = false}) {
    _operationChain = _operationChain
        .then(
      (_) => _flush(bypassMinimumInterval: bypassMinimumInterval),
    )
        .catchError((Object error) {
      _onQueueError?.call(error);
    });
  }

  Future<void> _flush({required bool bypassMinimumInterval}) async {
    _scheduledUpdate?.cancel();
    _scheduledUpdate = null;
    if (_disposed || _disabled || !_isEnabled()) return;

    final snapshotBuilder = _pendingSnapshotBuilder;
    final preflightKeyBuilder = _pendingPreflightKeyBuilder;
    if (snapshotBuilder == null || preflightKeyBuilder == null) return;

    final preflightKey = preflightKeyBuilder();
    final floorAnchor = _preflightPolicy ==
            ExternalSurfacePreflightPolicy.deduplicateAfterPublish
        ? _lastPublishedAt
        : _lastBuiltAt;
    if (_preflightPolicy ==
            ExternalSurfacePreflightPolicy.deduplicateAfterPublish &&
        !bypassMinimumInterval &&
        _deferUntilFloor(floorAnchor)) {
      return;
    }
    if (_preflightPolicy ==
            ExternalSurfacePreflightPolicy.deduplicateAfterPublish &&
        _lastFingerprint != null &&
        preflightKey == _lastBuiltPreflightKey) {
      _clearPendingBuilders();
      return;
    }

    final comparisonKey = _preflightPolicy ==
            ExternalSurfacePreflightPolicy.throttleAgainstPublishedUrgency
        ? _lastPublishedUrgencyKey
        : _lastBuiltPreflightKey;
    final predictedUrgent = preflightKey != comparisonKey;
    final buildFloorApplies = _preflightPolicy !=
            ExternalSurfacePreflightPolicy.deduplicateAfterPublish &&
        !_bypassBuildFloor &&
        !predictedUrgent;
    if (buildFloorApplies && _deferUntilFloor(floorAnchor)) return;

    _bypassBuildFloor = false;
    if (_preflightPolicy !=
        ExternalSurfacePreflightPolicy.deduplicateAfterPublish) {
      _lastBuiltAt = DateTime.now();
      if (_preflightPolicy ==
          ExternalSurfacePreflightPolicy.throttleAgainstLastBuild) {
        _lastBuiltPreflightKey = preflightKey;
      }
    }

    final snapshot = snapshotBuilder();
    if (_preflightPolicy ==
        ExternalSurfacePreflightPolicy.deduplicateAfterPublish) {
      _clearPendingBuilders();
    }
    if (snapshot == null) {
      await _clearEmptyState();
      return;
    }

    final payload = _payloadBuilder(snapshot);
    final fingerprint = _fingerprintBuilder(payload);
    final forceDelivery = _forceDelivery;
    if (!forceDelivery && fingerprint == _lastFingerprint) {
      if (_preflightPolicy ==
          ExternalSurfacePreflightPolicy.deduplicateAfterPublish) {
        _lastBuiltPreflightKey = preflightKey;
      }
      return;
    }

    final urgencyKey = _urgencyKeyBuilder(snapshot);
    final urgent = urgencyKey != _lastPublishedUrgencyKey;
    final publication = ExternalSurfacePublication<TSnapshot, TPayload>(
      snapshot: snapshot,
      payload: payload,
      fingerprint: fingerprint,
      urgent: urgent,
      forceDelivery: forceDelivery,
    );
    if (_candidateGate != null && !_candidateGate(publication)) return;

    if (!urgent &&
        !bypassMinimumInterval &&
        _deferUntilFloor(_lastPublishedAt)) {
      return;
    }

    final result = await _publish(publication);
    switch (result.disposition) {
      case ExternalSurfacePublishDisposition.published:
        _forceDelivery = false;
        _lastFingerprint = fingerprint;
        _lastPublishedUrgencyKey = urgencyKey;
        _lastBuiltPreflightKey = preflightKey;
        _lastPublishedAt = DateTime.now();
        _heldReported = false;
        _didReconcileEmptyState = false;
        break;
      case ExternalSurfacePublishDisposition.rejected:
        final retryAfter = result.retryAfter;
        if (retryAfter != null) this.retryAfter(retryAfter);
        break;
      case ExternalSurfacePublishDisposition.disable:
        disable();
        break;
    }
  }

  bool _deferUntilFloor(DateTime? anchor) {
    if (anchor == null) return false;
    final elapsed = DateTime.now().difference(anchor);
    if (elapsed >= _minimumNonUrgentInterval) return false;
    final remaining = _minimumNonUrgentInterval - elapsed;
    _scheduledUpdate?.cancel();
    _scheduledUpdate = Timer(remaining, _enqueueFlush);
    if (!_heldReported) {
      _heldReported = true;
      _onHeld?.call(remaining);
    }
    return true;
  }

  Future<void> _clearEmptyState() async {
    final clear = _clear;
    if (clear == null) return;
    if (_lastFingerprint == null && _didReconcileEmptyState) return;
    await clear(immediate: _lastFingerprint == null);
    _didReconcileEmptyState = true;
    resetPublishedState(reconciledEmptyState: true);
  }

  void resetPublishedState({bool reconciledEmptyState = false}) {
    _lastFingerprint = null;
    _lastPublishedUrgencyKey = null;
    _lastBuiltPreflightKey = null;
    _lastBuiltAt = null;
    _lastPublishedAt = null;
    _heldReported = false;
    _didReconcileEmptyState = reconciledEmptyState;
  }

  void disable() {
    if (_disabled) return;
    _disabled = true;
    _scheduledUpdate?.cancel();
    _scheduledUpdate = null;
    _clearPendingBuilders();
    _forceDelivery = false;
    _bypassBuildFloor = false;
  }

  void _clearPendingBuilders() {
    _pendingSnapshotBuilder = null;
    _pendingPreflightKeyBuilder = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _scheduledUpdate?.cancel();
    _scheduledUpdate = null;
    _clearPendingBuilders();
  }
}
