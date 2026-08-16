import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../utils/debug_logger_io.dart';
import 'live_activity_models.dart';

typedef LiveActivitySnapshotBuilder = LiveActivitySnapshot? Function();

/// Owns the Flutter-to-ActivityKit bridge and coalesces noisy app-state changes.
///
/// Timer ticks are represented by absolute phase deadlines, allowing SwiftUI to
/// render the countdown locally without an ActivityKit update every second.
class LiveActivityService {
  LiveActivityService({
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting
    Duration unavailableRetryDelay = const Duration(seconds: 30),
    @visibleForTesting
    Duration minimumNonUrgentInterval = defaultMinimumNonUrgentInterval,
  })  : _channel = channel ?? const MethodChannel('meshmapper/live_activity'),
        _unavailableRetryDelay = unavailableRetryDelay,
        _minimumNonUrgentInterval = minimumNonUrgentInterval;

  static const Duration _debounceDelay = Duration(milliseconds: 200);

  /// Floor between two updates that carry no change the wearer is waiting on.
  ///
  /// Counters, queue depth and the heard-repeater rows churn constantly in a
  /// busy session, and none of them is worth an ActivityKit round trip the
  /// moment it moves. Everything in [LiveActivitySnapshot.urgencyKey] — a phase
  /// change, a ping outcome, connection loss, leaving the zone — bypasses this
  /// entirely, so what it throttles is the noise and not the news.
  ///
  /// **This is a saving on both devices.** A locally generated ActivityKit
  /// update is synchronised to a paired Apple Watch for the Smart Stack and
  /// counts against *its* Live Activity budget, so the phone's update rate is
  /// also a wrist battery cost — on top of the snapshots the native watch app
  /// receives over WatchConnectivity, which are a separate channel entirely.
  ///
  /// Fifteen seconds takes the ceiling from 30 updates a minute to 4. The real
  /// reduction is smaller, because the payload fingerprint already suppresses
  /// updates that change nothing.
  static const Duration defaultMinimumNonUrgentInterval = Duration(seconds: 15);

  final MethodChannel _channel;
  final Duration _unavailableRetryDelay;
  final Duration _minimumNonUrgentInterval;

  Timer? _scheduledUpdate;
  LiveActivitySnapshotBuilder? _pendingSnapshotBuilder;
  String? _lastPayload;
  String? _lastUrgencyKey;
  DateTime? _lastSentAt;
  String? _unavailableSessionId;
  DateTime? _unavailableRetryAt;
  bool _disposed = false;
  bool _didReconcileNativeState = false;
  Future<void> _operationChain = Future<void>.value();

  bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  void schedule(
    LiveActivitySnapshotBuilder snapshotBuilder, {
    bool immediate = false,
  }) {
    if (_disposed || !isSupportedPlatform) return;

    _pendingSnapshotBuilder = snapshotBuilder;
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
        debugError('[LIVE ACTIVITY] Update queue failed: $error');
      },
    );
  }

  Future<void> _flush() async {
    _scheduledUpdate?.cancel();
    _scheduledUpdate = null;

    if (_disposed || !isSupportedPlatform) return;

    final snapshot = _pendingSnapshotBuilder?.call();
    if (snapshot == null) {
      if (_lastPayload == null && _didReconcileNativeState) return;
      await _endCurrentActivity(immediate: _lastPayload == null);
      return;
    }

    if (_unavailableSessionId == snapshot.sessionId) {
      final retryAt = _unavailableRetryAt;
      final now = DateTime.now();
      if (retryAt != null && now.isBefore(retryAt)) {
        // Authorization can be enabled in Settings while this session is
        // running. One scheduled retry makes that recover without asking
        // ActivityKit on every high-frequency provider notification.
        _scheduledUpdate = Timer(retryAt.difference(now), _enqueueFlush);
        return;
      }
      _unavailableSessionId = null;
      _unavailableRetryAt = null;
    } else if (_unavailableSessionId != null) {
      _unavailableSessionId = null;
      _unavailableRetryAt = null;
    }

    final payload = snapshot.toMap();
    // updatedAt is metadata for ActivityKit's stale date, not a visible state
    // change. Excluding it from the fingerprint prevents 500 ms countdown
    // timer ticks from causing native updates; SwiftUI renders countdowns from
    // the absolute phaseEndsAt deadline instead.
    final fingerprintPayload = Map<String, Object?>.from(payload)
      ..remove('updatedAt');
    final encoded = jsonEncode(fingerprintPayload);
    if (encoded == _lastPayload) return;

    final urgent = snapshot.urgencyKey != _lastUrgencyKey;
    final lastSentAt = _lastSentAt;
    if (!urgent && lastSentAt != null) {
      final elapsed = DateTime.now().difference(lastSentAt);
      if (elapsed < _minimumNonUrgentInterval) {
        _scheduledUpdate = Timer(
          _minimumNonUrgentInterval - elapsed,
          _enqueueFlush,
        );
        return;
      }
    }

    try {
      final result = await _channel.invokeMethod<Object?>('sync', payload);
      _didReconcileNativeState = true;
      if (result == false) {
        _unavailableSessionId = snapshot.sessionId;
        _unavailableRetryAt = DateTime.now().add(_unavailableRetryDelay);
        _scheduledUpdate = Timer(_unavailableRetryDelay, _enqueueFlush);
        debugLog('[LIVE ACTIVITY] Live Activities are unavailable or disabled');
        return;
      }
      _unavailableSessionId = null;
      _unavailableRetryAt = null;
      _lastPayload = encoded;
      _lastUrgencyKey = snapshot.urgencyKey;
      _lastSentAt = DateTime.now();
    } on MissingPluginException {
      // Expected on non-iOS test hosts and older generated iOS projects.
    } on PlatformException catch (error) {
      debugError(
        '[LIVE ACTIVITY] ActivityKit sync failed: '
        '${error.code}: ${error.message}',
      );
    } catch (error) {
      debugError('[LIVE ACTIVITY] Unexpected sync failure: $error');
    }
  }

  Future<void> _endCurrentActivity({required bool immediate}) async {
    try {
      await _channel.invokeMethod<void>(
        'end',
        {'immediate': immediate},
      );
    } on MissingPluginException {
      // Expected on non-iOS test hosts.
    } on PlatformException catch (error) {
      debugError(
        '[LIVE ACTIVITY] ActivityKit end failed: '
        '${error.code}: ${error.message}',
      );
    } catch (error) {
      debugError('[LIVE ACTIVITY] Unexpected end failure: $error');
    } finally {
      _didReconcileNativeState = true;
      _lastPayload = null;
      _lastUrgencyKey = null;
      _lastSentAt = null;
      _unavailableSessionId = null;
      _unavailableRetryAt = null;
    }
  }

  void dispose() {
    _disposed = true;
    _scheduledUpdate?.cancel();
    _scheduledUpdate = null;
    _pendingSnapshotBuilder = null;
    _unavailableRetryAt = null;
  }
}
