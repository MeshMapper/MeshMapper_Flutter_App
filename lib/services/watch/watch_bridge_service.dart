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
  WatchBridgeService({
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting Duration debounceDelay = defaultDebounceDelay,
    @visibleForTesting
    Duration minimumNonUrgentInterval = defaultMinimumNonUrgentInterval,
    @visibleForTesting
    Duration mapGeoClaimFreshFor = defaultMapGeoClaimFreshFor,
  })  : _channel = channel ?? const MethodChannel(_channelName),
        _debounceDelay = debounceDelay,
        _minimumNonUrgentInterval = minimumNonUrgentInterval,
        _mapGeoClaimFreshFor = mapGeoClaimFreshFor;

  static const String _channelName = 'meshmapper/watch';

  /// How many wrist commands may wait for Dart to start listening.
  ///
  /// A queued command can wake a phone app that was not running, and
  /// `didReceiveUserInfo` fires as soon as WatchConnectivity has it — which can
  /// be well before [attachCommandHandler] runs, since that happens partway
  /// through the provider's asynchronous initialization. `transferUserInfo`
  /// hands each command over exactly once, so anything dropped in that window
  /// is gone: the wrist shows a spinner, times out after ten seconds, and says
  /// nothing about why.
  ///
  /// Flutter already buffers platform messages sent before a handler exists,
  /// but only one deep by default, so a wearer who tapped twice lost the first
  /// tap. Eight is well past any plausible burst — the wearer has one Start and
  /// one Ping button — while still bounded, because these are intents that go
  /// through the age window and the ID cache on arrival, not state to replay.
  static const int _commandQueueDepth = 8;

  /// Reserve that room. Must run before the first command can arrive, which in
  /// practice means the top of `main()`.
  ///
  /// This narrows the window rather than closing it. Messages that arrive
  /// before Dart's entrypoint executes at all are still governed by the default
  /// depth of one — resizing upward keeps whatever is already queued, so that
  /// one survives, but a burst landing in the gap between engine start and this
  /// call cannot. Closing it completely means buffering natively and handshaking
  /// a ready signal, which is a lot of moving parts for a smaller window than
  /// the one this covers.
  static void reserveCommandQueue() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    ServicesBinding.instance.channelBuffers
        .resize(_channelName, _commandQueueDepth);
  }

  /// The three durations a test may shorten.
  ///
  /// Without a seam here every throttle assertion had to wait out the real
  /// interval, so one group of them spent ~35 s of wall clock and raced a live
  /// timer on loaded CI — and the ten-minute lease expiry simply could not be
  /// covered at all. [LiveActivityService] already took its intervals this way;
  /// this closes the gap between the two.
  ///
  /// Deliberately *not* injectable: [_maximumCommandAge] and [_clockTolerance]
  /// are compared against timestamps a test can choose freely, so shortening
  /// them would buy nothing and would let a test pass against a window the
  /// wire does not actually use.
  static const Duration defaultDebounceDelay = Duration(milliseconds: 200);
  static const Duration defaultMinimumNonUrgentInterval = Duration(seconds: 2);
  static const Duration defaultMapGeoClaimFreshFor = Duration(minutes: 10);

  static const Duration _maximumCommandAge = Duration(seconds: 30);

  /// Residual slack after the watch's own clock-offset correction, not the
  /// whole budget for two devices disagreeing about the time. A watch that has
  /// measured the offset sends it with every command, so what has to fit inside
  /// this is transit and measurement error — not the skew itself.
  static const Duration _clockTolerance = Duration(seconds: 5);

  final MethodChannel _channel;
  final Duration _debounceDelay;
  final Duration _minimumNonUrgentInterval;
  final Duration _mapGeoClaimFreshFor;

  Timer? _scheduledUpdate;
  WatchSnapshotBuilder? _pendingSnapshotBuilder;
  WatchUrgencyKeyBuilder? _pendingUrgencyKeyBuilder;
  WatchCommandHandler? _commandHandler;
  WatchCommandRefusalHandler? _commandRefusalHandler;
  WatchAvailabilityHandler? _availabilityHandler;

  String? _lastPayload;

  /// The delivered payload with the fix removed, plus the fix that went with
  /// it. Together they answer "did anything but our position change?", which is
  /// what the movement gate needs and the whole-payload fingerprint cannot say.
  String? _lastPayloadWithoutFix;
  ({double lat, double lon})? _lastSentFix;
  String? _lastUrgencyKey;
  DateTime? _lastSentAt;
  DateTime? _lastBuiltAt;
  bool _disposed = false;
  bool _didReconcileNativeState = false;

  /// A refresh the watch asked for, which dedupe must not answer with silence.
  ///
  /// The phone only forgets its delivered-payload fingerprint when
  /// WatchConnectivity reports a state change, and relaunching the watch app is
  /// not one: pairing and installation are unchanged, so the phone still
  /// believes the watch holds this exact payload. It does — but only as a
  /// retained context whose age is now shown honestly, which is precisely the
  /// state the wearer is asking to be rid of. Answering "nothing changed" with
  /// nothing at all leaves that state stale until something unrelated moves.
  ///
  /// Survives a deferred flush so the radio throttle can still delay the
  /// refresh, and is cleared only once a payload is actually delivered.
  bool _forceDelivery = false;
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

  /// Outcome of every command already handled, keyed by ID, so redelivery
  /// cannot fire a second transmit — and is answered with what actually
  /// happened rather than a blanket acceptance. Null means accepted.
  final Map<String, String?> _handledCommandOutcomes = <String, String?>{};

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
      // Only a push that says native dropped its own application-context cache
      // invalidates ours. Reachability flips on every wrist raise and lower,
      // and treating those as cache invalidation forced a full
      // `updateApplicationContext` resend per glance and silently voided the
      // map-geo lease — the two costs this bridge exists to avoid.
      final args = call.arguments;
      final nativeCacheCleared =
          args is Map && args['nativeCacheCleared'] == true;
      _applyAvailability(args, refreshNativeState: nativeCacheCleared);
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
    //
    // Answered with the outcome recorded the first time. Replying "accepted"
    // to the redelivery of something this bridge refused would describe a
    // transmit that never happened, and be wrong in exactly the case the
    // caller most needs the truth.
    if (_handledCommandOutcomes.containsKey(id)) {
      final refusal = _handledCommandOutcomes[id];
      return {'id': id, 'accepted': refusal == null, 'reason': refusal};
    }

    final kind = WatchCommandKind.fromWire(rawKind);
    if (kind == null) {
      return {'id': id, 'accepted': false, 'reason': 'Unsupported command'};
    }

    final handler = _commandHandler;
    if (handler == null) {
      return {'id': id, 'accepted': false, 'reason': 'App not ready'};
    }

    _rememberCommand(id);

    final rawIssuedAtMs = args['issuedAtMs'];
    final issuedAtMs = rawIssuedAtMs is num ? rawIssuedAtMs.toDouble() : null;

    // The two devices do not share a clock. `issuedAtMs` is stamped in the
    // watch's, and the watch tells us how far that runs from ours when it has
    // been able to measure it — from a live `sendMessage`, whose transit is
    // milliseconds. Correcting by it means the age below is a real elapsed
    // time rather than an elapsed time plus however far the clocks disagree,
    // which used to turn any skew past `_clockTolerance` into "every command
    // refused" instead of a slightly wider margin.
    //
    // Absent from older watch builds, and from a watch that has not yet seen a
    // live delivery. Zero then, which is exactly the previous behaviour.
    final rawClockOffsetMs = args['clockOffsetMs'];
    final clockOffsetMs =
        rawClockOffsetMs is num ? rawClockOffsetMs.toDouble() : 0.0;
    final ageMs = issuedAtMs == null
        ? null
        : DateTime.now().millisecondsSinceEpoch - (issuedAtMs + clockOffsetMs);
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
    // Stopping is exempt for the same reason as requestSnapshot: the window
    // exists so a late command cannot put a transmit on air from the wrong
    // place, and a stop takes the radio *off* air. Refusing a queued stop that
    // was slow to arrive — the phone out of range, the watch suspended mid
    // transfer — leaves the session transmitting after the wearer asked it to
    // end, which is the failure the window is supposed to prevent.
    const ageExemptKinds = {
      WatchCommandKind.requestSnapshot,
      WatchCommandKind.stopSession,
    };
    if (!ageExemptKinds.contains(kind) && issuedAtMs != null) {
      // Both bounds matter. Too old is the obvious case; too far in the future
      // is the same bug wearing a disguise, because a watch clock running fast
      // makes `ageMs` negative and would otherwise extend the window by however
      // far the clocks disagree. The tolerance matches the map-geo check above.
      if (ageMs! > _maximumCommandAge.inMilliseconds ||
          ageMs < -_clockTolerance.inMilliseconds) {
        const reason = 'Took too long to reach iPhone';
        // This window is about correctness, not queue housekeeping: executing
        // a transmit after the vehicle has moved attributes it to the wrong
        // place. Missing timestamps remain accepted for older watch builds.
        _rememberCommand(id, refusal: reason);
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
        id: id,
        issuedAt: issuedAtMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (issuedAtMs + clockOffsetMs).round(),
              ),
        mode: args['mode'] as String?,
        mapGeoNeeded: effectiveMapGeoNeeded,
        forceRefresh: args['forceRefresh'] == true,
        sessionId: args['sessionId'] as String?,
      ));
      final refusal =
          admission is Future<String?> ? await admission : admission;
      _rememberCommand(id, refusal: refusal);
      if (refusal != null) {
        _commandRefusalHandler?.call(refusal);
        // An untimestamped command cannot be aged, so it is also the one whose
        // sender may legitimately retry it under changed conditions. Queued,
        // timestamped commands must stay remembered: redelivery after
        // conditions change must never turn yesterday's tap into a transmit.
        if (issuedAtMs == null) _handledCommandOutcomes.remove(id);
      }
      return {'id': id, 'accepted': refusal == null, 'reason': refusal};
    } catch (error) {
      debugError('[WATCH] Command $rawKind failed: $error');
      const reason = 'Command failed';
      _rememberCommand(id, refusal: reason);
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

    // Native forgets its application-context cache when WatchConnectivity
    // reports a *watch-state* change. Forget ours on the same notification even
    // when availability remains true, or an installed replacement watch could
    // wait forever for state whose fingerprint Dart still considers delivered.
    if (!available || refreshNativeState) {
      _mapGeoSuppressedAt = null;
      _lastMapGeoClaimIssuedAtMs = null;
      _lastPayload = null;
      _lastPayloadWithoutFix = null;
      _lastSentFix = null;
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

  /// Record a command and, once known, what it resolved to.
  ///
  /// Called before admission so a re-entrant redelivery cannot slip past the
  /// dedupe, then again with the outcome. Updating an existing key leaves the
  /// insertion order alone, so the bound below still evicts the oldest.
  void _rememberCommand(String id, {String? refusal}) {
    _handledCommandOutcomes[id] = refusal;
    // Unbounded growth would leak across a long session.
    if (_handledCommandOutcomes.length > 64) {
      _handledCommandOutcomes.remove(_handledCommandOutcomes.keys.first);
    }
  }

  /// - Parameter forceDelivery: send even when the payload is byte-identical to
  ///   the last delivered one. Reserved for a refresh the watch explicitly
  ///   asked for; ordinary immediate updates stay deduplicatable, because most
  ///   of them are urgent precisely because something did change.
  void schedule(
    WatchSnapshotBuilder snapshotBuilder, {
    required WatchUrgencyKeyBuilder urgencyKeyBuilder,
    bool immediate = false,
    bool forceDelivery = false,
  }) {
    if (_disposed || !canSync) return;

    _pendingSnapshotBuilder = snapshotBuilder;
    _pendingUrgencyKeyBuilder = urgencyKeyBuilder;
    if (forceDelivery) _forceDelivery = true;
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
    // A forced refresh is answered with the payload as it stands, identical or
    // not. Only the fresher updatedAt distinguishes it, and that is the whole
    // point: it is what proves the phone is still there.
    final force = _forceDelivery;
    if (!force && encoded == _lastPayload) return;

    // The movement gate. A stationary GPS jitters by a few metres for as long
    // as the phone is switched on, and forwarding that would keep the watch
    // radio busy for a puck that never visibly moves.
    //
    // It is deliberately expressed as "nothing but the fix changed, and the fix
    // did not move far enough" rather than as a stale position in the payload,
    // which is where it used to live. Those are the same suppression and a very
    // different packet: a new ping defeats the dedupe by itself, and the older
    // arrangement then sent that ping alongside a puck up to 15 m behind it —
    // visibly so once the watch's zoom floor reached ~22 m of latitude.
    final fix = _fixOf(fingerprint);
    final withoutFix = _encodeWithoutFix(fingerprint);
    if (!force &&
        withoutFix == _lastPayloadWithoutFix &&
        !_fixMovedEnough(fix)) {
      return;
    }

    // The throttle still applies. It delays a forced refresh by at most the
    // non-urgent interval and `_forceDelivery` outlives the deferral, so the
    // refresh still arrives — while a watch asking repeatedly cannot turn this
    // into an unmetered path to the radio.
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
      // Cleared here rather than at the dedupe check: a send the native side
      // refused leaves the fingerprint in place, so an obligation dropped
      // earlier would dedupe against that same payload and strand the wearer
      // exactly as before.
      _forceDelivery = false;
      _lastPayload = encoded;
      // Anchored to what the watch actually received, so a refused or dropped
      // send cannot quietly consume the wearer's next 15 m of movement.
      _lastPayloadWithoutFix = withoutFix;
      _lastSentFix = fix;
      _lastUrgencyKey = snapshot.urgencyKey;
      final sentAt = DateTime.now();
      _lastSentAt = sentAt;
      _lastSuccessfulSendAt = sentAt;
      _lastSendDelivered = true;
      _publishDiagnostics();
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
      _lastPayloadWithoutFix = null;
      _lastSentFix = null;
      _lastUrgencyKey = null;
      _lastSentAt = null;
      _lastBuiltAt = null;
    }
  }

  /// Whether the fix has moved far enough to be worth a send on its own.
  ///
  /// Measured against the fix the watch last *received*, not the last one the
  /// phone computed, so a parked phone's jitter can never accumulate its way
  /// past the threshold one sub-threshold step at a time.
  bool _fixMovedEnough(({double lat, double lon})? fix) {
    final last = _lastSentFix;
    if (fix == null || last == null) return true;
    return WatchWire.movedEnough(
      lastLat: last.lat,
      lastLon: last.lon,
      lat: fix.lat,
      lon: fix.lon,
    );
  }

  static Map<String, Object?>? _geoOf(Map<String, Object?> fingerprint) {
    final geo = fingerprint['geo'];
    return geo is Map ? Map<String, Object?>.from(geo) : null;
  }

  static ({double lat, double lon})? _fixOf(Map<String, Object?> fingerprint) {
    final you = _geoOf(fingerprint)?['you'];
    if (you is! Map) return null;
    final lat = you['lat'];
    final lon = you['lon'];
    if (lat is! num || lon is! num) return null;
    return (lat: lat.toDouble(), lon: lon.toDouble());
  }

  /// The payload with the wearer's position taken out, so two of them can be
  /// compared for "did anything else change?".
  ///
  /// The whole `you` object goes, not just its coordinates: heading, accuracy
  /// and fix time all drift on a phone that has not moved, and treating any of
  /// them as a reason to send would defeat the gate they are travelling with.
  static String _encodeWithoutFix(Map<String, Object?> fingerprint) {
    final geo = _geoOf(fingerprint);
    if (geo == null) return jsonEncode(fingerprint);
    return jsonEncode(
      Map<String, Object?>.from(fingerprint)..['geo'] = (geo..remove('you')),
    );
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
    _mapGeoSuppressedAt = null;
    _lastMapGeoClaimIssuedAtMs = null;
    _diagnostics.dispose();
  }
}
