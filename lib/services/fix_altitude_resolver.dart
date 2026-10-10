import 'dart:async';
import 'dart:collection';

import 'package:geolocator/geolocator.dart';

import '../utils/debug_logger_io.dart';
import 'fix_altitude.dart';

/// One answer per fix, keyed by the fix's exact timestamp and coordinates.
typedef _FixKey = ({int timeMs, double lat, double lon});

_FixKey _keyOf(Position p) => (
      timeMs: p.timestamp.millisecondsSinceEpoch,
      lat: p.latitude,
      lon: p.longitude,
    );

/// Running counts of how the Android proof went, for one bounded summary
/// line and for the device check. Real Android fixes only: simulator fixes
/// and fixes with no altitude are unknown by rule, not by failure.
class AltitudeResolutionStats {
  int proved = 0;
  int unproved = 0;
  final Map<String, int> reasons = {};
}

/// Resolves and remembers [FixAltitude] for every fix the GPS service
/// accepts, so the send paths can read a finished answer later without
/// waiting for anything.
///
/// Nothing waits on this store. iOS, web and simulator fixes are answered
/// synchronously inside [track]. Android fixes need the native handler's
/// description of the provider's last fix, which is read in the background;
/// until it lands, [lookup] answers unknown. An entry is inserted (as
/// unknown) the moment the fix is ACCEPTED, so eviction follows acceptance
/// order and a late completion for an evicted fix is dropped rather than
/// resurrected. A source generation, bumped by [reset], discards late
/// completions from a fix source that has since restarted (watching
/// restarted, the simulator switched on or off).
///
/// Completion touches nothing else: no position is re-emitted, nothing is
/// notified and `mapRevision` is never bumped (Rule 9). Logging is one line
/// the first time a reference is resolved per generation, one throttled
/// warning when an Android fix could not be proved, and one summary line per
/// [summaryEvery] Android resolutions, never one line per fix.
class FixAltitudeResolver {
  FixAltitudeResolver({
    required this.platform,
    this.readNative,
    DateTime Function()? now,
    this.capacity = 128,
    this.nativeTimeout = const Duration(seconds: 2),
  }) : _now = now ?? DateTime.now;

  final AltitudePlatform platform;

  /// Reads the Android handler's description of the provider's last fix.
  /// Null on every platform but Android. Null answers mean "nothing proved".
  final Future<NativeAltitudeAnswer?> Function()? readNative;

  final DateTime Function() _now;
  final int capacity;
  final Duration nativeTimeout;

  static const Duration _warnSpacing = Duration(minutes: 1);

  /// One summary line per this many real Android resolutions.
  static const int summaryEvery = 50;

  final LinkedHashMap<_FixKey, FixAltitude> _store = LinkedHashMap();

  /// Keys whose native read is in flight, independent of cache eviction: a
  /// fix evicted and accepted again while its read is still out must not be
  /// read twice, counted twice, or have the older answer overwrite the newer.
  final Set<_FixKey> _inFlight = {};
  final Set<Future<void>> _pending = {};
  final AltitudeResolutionStats _stats = AltitudeResolutionStats();
  int _generation = 0;
  int? _androidSdk;
  bool _loggedFirst = false;
  DateTime? _lastWarn;

  int get generation => _generation;
  int get size => _store.length;
  AltitudeResolutionStats get stats => _stats;

  /// Completes once every native read started so far has settled. Tests only.
  Future<void> get idle => Future.wait(_pending.toList()).then((_) {});

  /// Forgets everything and invalidates every read in flight. Called whenever
  /// the fix source restarts.
  void reset() {
    _generation++;
    _store.clear();
    _inFlight.clear();
    _loggedFirst = false;
  }

  /// Resolves [position] if it is not already stored or in flight.
  void track(Position position, {bool simulated = false}) {
    final key = _keyOf(position);
    if (_store.containsKey(key)) return;
    if (_inFlight.contains(key)) {
      // Evicted while its read was out and now accepted again: re-reserve the
      // slot so the pending answer has somewhere to land, but do not read
      // again.
      _insert(key);
      return;
    }

    final needsNative = !simulated &&
        platform == AltitudePlatform.android &&
        readNative != null &&
        (_androidSdk == null || _androidSdk! >= kAndroidMslSdk);

    if (!needsNative) {
      final native = platform == AltitudePlatform.android && _androidSdk != null
          ? NativeAltitudeAnswer(sdk: _androidSdk!, fixes: const [])
          : null;
      _insert(key);
      _complete(
        key,
        resolveFixAltitude(
          platform: platform,
          position: position,
          simulated: simulated,
          native: native,
        ),
        simulated: simulated,
      );
      return;
    }

    // Reserve the slot now so eviction follows acceptance order; the answer
    // replaces the unknown placeholder when the read lands.
    _insert(key);
    _inFlight.add(key);
    final generation = _generation;
    late Future<void> work;
    work = _resolveNative(key, position, generation).whenComplete(() {
      _pending.remove(work);
    });
    _pending.add(work);
  }

  Future<void> _resolveNative(
      _FixKey key, Position position, int generation) async {
    NativeAltitudeAnswer? native;
    String? failure;
    try {
      native = await readNative!().timeout(nativeTimeout);
    } on TimeoutException {
      failure = 'native read timed out';
    } catch (e) {
      failure = 'native read threw: $e';
    }
    if (generation != _generation) return; // the fix source restarted
    _inFlight.remove(key);
    if (native != null) _androidSdk = native.sdk;
    final resolution = resolveFixAltitude(
      platform: platform,
      position: position,
      simulated: false,
      native: native,
    );
    if (!_store.containsKey(key)) {
      // Evicted while in flight: the read still happened, so it counts once
      // toward the proof stats, but it is never stored or resurrected.
      _count(resolution, simulated: false);
      return;
    }
    _complete(key, resolution, simulated: false, failure: failure);
  }

  /// The stored answer for [position], or unknown when none has landed.
  FixAltitude lookup(Position position) =>
      _store[_keyOf(position)] ?? const FixAltitude.unknown();

  void _insert(_FixKey key) {
    _store[key] = const FixAltitude.unknown();
    while (_store.length > capacity) {
      _store.remove(_store.keys.first);
    }
  }

  void _complete(_FixKey key, AltitudeResolution resolution,
      {required bool simulated, String? failure}) {
    _store[key] = resolution.altitude;
    _count(resolution, simulated: simulated);
    _log(resolution, simulated: simulated, failure: failure);
  }

  void _count(AltitudeResolution resolution, {required bool simulated}) {
    if (simulated ||
        platform != AltitudePlatform.android ||
        resolution.reason == 'no_altitude' ||
        resolution.reason == 'mocked') {
      return;
    }
    if (resolution.altitude.isKnown) {
      _stats.proved++;
    } else {
      _stats.unproved++;
      _stats.reasons.update(resolution.reason, (n) => n + 1,
          ifAbsent: () => 1);
    }
    final total = _stats.proved + _stats.unproved;
    if (total % summaryEvery == 0) {
      debugLog('[GPS] Altitude reference summary: ${_stats.proved} of $total '
          'fixes proved, unknown by reason: ${_stats.reasons}');
    }
  }

  void _log(AltitudeResolution resolution,
      {required bool simulated, String? failure}) {
    if (resolution.altitude.isKnown) {
      if (_loggedFirst) return;
      _loggedFirst = true;
      debugLog('[GPS] Altitude reference resolved: '
          '${resolution.altitude.wireReference} (${resolution.reason})');
      return;
    }
    // Only an Android fix that could not be proved is worth a warning. A
    // simulator fix, a fix with no altitude and a non-Android platform are
    // unknown by rule, not by failure.
    if (simulated ||
        platform != AltitudePlatform.android ||
        resolution.reason == 'no_altitude' ||
        resolution.reason == 'mocked') {
      return;
    }
    final now = _now();
    if (_lastWarn != null && now.difference(_lastWarn!) < _warnSpacing) return;
    _lastWarn = now;
    debugWarn('[GPS] Altitude reference unknown for this fix: '
        '${resolution.reason}${failure != null ? ' ($failure)' : ''}');
  }
}
