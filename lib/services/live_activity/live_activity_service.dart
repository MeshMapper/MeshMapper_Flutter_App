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
  static const MethodChannel _channel =
      MethodChannel('meshmapper/live_activity');
  static const Duration _debounceDelay = Duration(milliseconds: 200);
  static const Duration _minimumNonUrgentInterval = Duration(seconds: 2);

  Timer? _scheduledUpdate;
  LiveActivitySnapshotBuilder? _pendingSnapshotBuilder;
  String? _lastPayload;
  String? _lastUrgencyKey;
  DateTime? _lastSentAt;
  String? _unavailableSessionId;
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

    if (_unavailableSessionId == snapshot.sessionId) return;
    if (_unavailableSessionId != null) {
      _unavailableSessionId = null;
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
        debugLog('[LIVE ACTIVITY] Live Activities are unavailable or disabled');
        return;
      }
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
    }
  }

  void dispose() {
    _disposed = true;
    _scheduledUpdate?.cancel();
    _scheduledUpdate = null;
    _pendingSnapshotBuilder = null;
  }
}
