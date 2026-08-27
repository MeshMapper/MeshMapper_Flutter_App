import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../utils/debug_logger_io.dart';
import '../external_surfaces/external_surface_publisher.dart';
import 'live_activity_models.dart';

typedef LiveActivitySnapshotBuilder = LiveActivitySnapshot? Function();

/// The urgent half of the next snapshot, resolved without building one.
///
/// Returns null when no activity should exist, which is how ending stays
/// immediate rather than waiting out the non-urgent floor.
typedef LiveActivityUrgencyKeyBuilder = String? Function();

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
        _unavailableRetryDelay = unavailableRetryDelay {
    _publisher =
        ExternalSurfacePublisher<LiveActivitySnapshot, Map<String, Object?>>(
      debounceDelay: _debounceDelay,
      minimumNonUrgentInterval: minimumNonUrgentInterval,
      isEnabled: () => isSupportedPlatform && !_hostCannotHostActivities,
      preflightPolicy: ExternalSurfacePreflightPolicy.throttleAgainstLastBuild,
      payloadBuilder: (snapshot) => snapshot.toMap(),
      fingerprintBuilder: (payload) {
        final fingerprint = Map<String, Object?>.from(payload)
          ..remove('updatedAt');
        return jsonEncode(fingerprint);
      },
      urgencyKeyBuilder: (snapshot) => snapshot.urgencyKey,
      publish: _publishSnapshot,
      clear: _endCurrentActivity,
      onQueueError: (error) {
        debugError('[LIVE ACTIVITY] Update queue failed: $error');
      },
    );
  }

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

  /// Native's answer when the host can never show a Live Activity — iOS below
  /// 16.2. Distinct from `false`, which means "not right now" and is what the
  /// authorization backoff exists for.
  static const String unsupportedHost = 'unsupported';

  final MethodChannel _channel;
  final Duration _unavailableRetryDelay;
  late final ExternalSurfacePublisher<LiveActivitySnapshot,
      Map<String, Object?>> _publisher;
  String? _unavailableSessionId;
  DateTime? _unavailableRetryAt;
  bool _disposed = false;

  /// Set once native reports a condition that cannot change while this process
  /// lives: an OS without ActivityKit, or a host with no such channel at all.
  ///
  /// Before this, both answered every 30 s retry with the same guaranteed
  /// failure, and kept doing it for the whole session — a timer, a build and a
  /// channel round trip apiece, on devices that were never going to show
  /// anything.
  bool _hostCannotHostActivities = false;

  bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  void schedule(
    LiveActivitySnapshotBuilder snapshotBuilder, {
    required LiveActivityUrgencyKeyBuilder urgencyKeyBuilder,
    bool immediate = false,
  }) {
    if (_disposed || !isSupportedPlatform || _hostCannotHostActivities) return;
    _publisher.schedule(
      snapshotBuilder,
      preflightKeyBuilder: urgencyKeyBuilder,
      immediate: immediate,
    );
  }

  Future<ExternalSurfacePublishResult> _publishSnapshot(
    ExternalSurfacePublication<LiveActivitySnapshot, Map<String, Object?>>
        publication,
  ) async {
    final snapshot = publication.snapshot;
    if (_unavailableSessionId == snapshot.sessionId) {
      final retryAt = _unavailableRetryAt;
      final now = DateTime.now();
      if (retryAt != null && now.isBefore(retryAt)) {
        // Authorization can be enabled in Settings while this session is
        // running. One scheduled retry makes that recover without asking
        // ActivityKit on every high-frequency provider notification.
        return ExternalSurfacePublishResult.rejected(
          retryAfter: retryAt.difference(now),
        );
      }
      _unavailableSessionId = null;
      _unavailableRetryAt = null;
    } else if (_unavailableSessionId != null) {
      _unavailableSessionId = null;
      _unavailableRetryAt = null;
    }

    try {
      final result =
          await _channel.invokeMethod<Object?>('sync', publication.payload);
      if (result == unsupportedHost) {
        _stopForUnsupportedHost('iOS 16.2 is required for Live Activities');
        return const ExternalSurfacePublishResult.disable();
      }
      if (result == false) {
        _unavailableSessionId = snapshot.sessionId;
        _unavailableRetryAt = DateTime.now().add(_unavailableRetryDelay);
        debugLog('[LIVE ACTIVITY] Live Activities are unavailable or disabled');
        return ExternalSurfacePublishResult.rejected(
          retryAfter: _unavailableRetryDelay,
        );
      }
      _unavailableSessionId = null;
      _unavailableRetryAt = null;
      return const ExternalSurfacePublishResult.published();
    } on MissingPluginException {
      // A host with no such channel — a non-iOS test host, or an iOS project
      // generated before this feature existed. Neither gains one at runtime,
      // so this is the same permanent condition as an OS below 16.2.
      _stopForUnsupportedHost('no Live Activity channel on this host');
      return const ExternalSurfacePublishResult.disable();
    } on PlatformException catch (error) {
      debugError(
        '[LIVE ACTIVITY] ActivityKit sync failed: '
        '${error.code}: ${error.message}',
      );
      return const ExternalSurfacePublishResult.rejected();
    } catch (error) {
      debugError('[LIVE ACTIVITY] Unexpected sync failure: $error');
      return const ExternalSurfacePublishResult.rejected();
    }
  }

  /// Stop asking, permanently. Nothing about the condition can change without
  /// the app being relaunched, at which point this starts out false again.
  void _stopForUnsupportedHost(String reason) {
    if (_hostCannotHostActivities) return;
    _hostCannotHostActivities = true;
    _publisher.disable();
    _unavailableSessionId = null;
    _unavailableRetryAt = null;
    debugLog('[LIVE ACTIVITY] Disabled for this session: $reason');
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
      _unavailableSessionId = null;
      _unavailableRetryAt = null;
    }
  }

  void dispose() {
    _disposed = true;
    _publisher.dispose();
    _unavailableRetryAt = null;
  }
}
