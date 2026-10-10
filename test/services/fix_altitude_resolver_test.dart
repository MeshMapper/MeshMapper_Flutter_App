import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_mapper/services/fix_altitude.dart';
import 'package:mesh_mapper/services/fix_altitude_resolver.dart';

/// The store remembers one answer per exact fix (timestamp, latitude,
/// longitude) under a source generation, resolves Android fixes in the
/// background, and answers unknown for anything it has not finished.

Position _pos({
  double lat = 45.0,
  double lon = -75.0,
  int timeMs = 1760000000000,
  double altitude = 120.0,
  double altitudeAccuracy = 6.0,
}) =>
    Position(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timeMs, isUtc: true),
      accuracy: 5.0,
      altitude: altitude,
      altitudeAccuracy: altitudeAccuracy,
      heading: 0.0,
      headingAccuracy: 1.0,
      speed: 0.0,
      speedAccuracy: 0.0,
    );

NativeAltitudeAnswer _matching(Position p) => NativeAltitudeAnswer(sdk: 34, fixes: [
      NativeFixDescription(
        source: 'fused',
        timeMs: p.timestamp.millisecondsSinceEpoch,
        lat: p.latitude,
        lon: p.longitude,
        hasAltitude: true,
        altitude: p.altitude,
        hasVerticalAccuracy: true,
        verticalAccuracy: p.altitudeAccuracy,
        hasMsl: false,
        msl: 0.0,
        hasMslAccuracy: false,
        mslAccuracy: 0.0,
        isMock: false,
      ),
    ]);

void main() {
  group('synchronous platforms', () {
    test('iOS is stored and looked up at once', () {
      final r = FixAltitudeResolver(platform: AltitudePlatform.ios);
      final p = _pos();
      r.track(p);
      expect(r.lookup(p).reference, AltitudeReference.msl);
      expect(r.lookup(p).meters, 120.0);
    });

    test('a fix never tracked is unknown', () {
      final r = FixAltitudeResolver(platform: AltitudePlatform.ios);
      expect(r.lookup(_pos()).isKnown, isFalse);
    });

    test('a simulated fix is stored as unknown, no native read', () async {
      var reads = 0;
      final r = FixAltitudeResolver(
          platform: AltitudePlatform.android,
          readNative: () async {
            reads++;
            return null;
          });
      final p = _pos();
      r.track(p, simulated: true);
      await r.idle;
      expect(r.lookup(p).isKnown, isFalse);
      expect(reads, 0);
    });

    test('two fixes with the same timestamp and different coordinates '
        'are two entries', () {
      final r = FixAltitudeResolver(platform: AltitudePlatform.ios);
      final a = _pos(lat: 45.0, altitude: 100);
      final b = _pos(lat: 46.0, altitude: 200);
      r.track(a);
      r.track(b);
      expect(r.lookup(a).meters, 100);
      expect(r.lookup(b).meters, 200);
      expect(r.size, 2);
    });

    test('the store is capped and evicts the oldest', () {
      final r = FixAltitudeResolver(platform: AltitudePlatform.ios, capacity: 3);
      final fixes = [for (var i = 0; i < 4; i++) _pos(timeMs: 1000 * (i + 1))];
      for (final f in fixes) {
        r.track(f);
      }
      expect(r.size, 3);
      expect(r.lookup(fixes[0]).isKnown, isFalse);
      expect(r.lookup(fixes[3]).isKnown, isTrue);
    });
  });

  group('Android', () {
    test('a fix is unknown until the native answer lands, then known '
        '(Review Focus 4)', () async {
      final gate = Completer<NativeAltitudeAnswer?>();
      final p = _pos();
      final r = FixAltitudeResolver(
          platform: AltitudePlatform.android, readNative: () => gate.future);
      r.track(p);
      expect(r.lookup(p).isKnown, isFalse, reason: 'nothing waits');
      gate.complete(_matching(p));
      await r.idle;
      expect(r.lookup(p).reference, AltitudeReference.ellipsoid);
    });

    test('a native read already in flight for the same fix is not repeated',
        () async {
      var reads = 0;
      final gate = Completer<NativeAltitudeAnswer?>();
      final p = _pos();
      final r = FixAltitudeResolver(
          platform: AltitudePlatform.android,
          readNative: () {
            reads++;
            return gate.future;
          });
      r.track(p);
      r.track(p);
      expect(reads, 1);
      gate.complete(_matching(p));
      await r.idle;
      r.track(p);
      expect(reads, 1, reason: 'a stored fix is not re-read either');
    });

    test('a native read that throws leaves the fix unknown', () async {
      final p = _pos();
      final r = FixAltitudeResolver(
          platform: AltitudePlatform.android,
          readNative: () async => throw StateError('channel down'));
      r.track(p);
      await r.idle;
      expect(r.lookup(p).isKnown, isFalse);
    });

    test('a native read that hangs is cut off by the timeout', () async {
      final p = _pos();
      final r = FixAltitudeResolver(
          platform: AltitudePlatform.android,
          readNative: () => Completer<NativeAltitudeAnswer?>().future,
          nativeTimeout: const Duration(milliseconds: 20));
      r.track(p);
      await r.idle;
      expect(r.lookup(p).isKnown, isFalse);
    });

    test('below Android 14 the SDK is remembered and later fixes skip the read',
        () async {
      var reads = 0;
      final r = FixAltitudeResolver(
          platform: AltitudePlatform.android,
          readNative: () async {
            reads++;
            return const NativeAltitudeAnswer(sdk: 33, fixes: []);
          });
      final a = _pos(timeMs: 1000);
      final b = _pos(timeMs: 2000);
      r.track(a);
      await r.idle;
      r.track(b);
      await r.idle;
      expect(reads, 1);
      expect(r.lookup(a).reference, AltitudeReference.ellipsoid);
      expect(r.lookup(b).reference, AltitudeReference.ellipsoid);
    });

    test('a completion for an older generation is dropped (Review Focus 5)',
        () async {
      final gate = Completer<NativeAltitudeAnswer?>();
      final p = _pos();
      final r = FixAltitudeResolver(
          platform: AltitudePlatform.android, readNative: () => gate.future);
      r.track(p);
      r.reset();
      gate.complete(_matching(p));
      await r.idle;
      expect(r.lookup(p).isKnown, isFalse);
      expect(r.size, 0);
    });

    test('reset clears simulator entries so a real fix with the same key '
        'is resolved afresh (Review Focus 5)', () async {
      final p = _pos();
      final r = FixAltitudeResolver(
          platform: AltitudePlatform.android,
          readNative: () async => _matching(p));
      r.track(p, simulated: true);
      expect(r.lookup(p).isKnown, isFalse);
      r.reset();
      r.track(p);
      await r.idle;
      expect(r.lookup(p).isKnown, isTrue);
      expect(r.generation, 1);
    });

    test('eviction follows acceptance order even when reads finish out of '
        'order', () async {
      final gates = <int, Completer<NativeAltitudeAnswer?>>{};
      var calls = 0;
      final fixes = [for (var i = 0; i < 3; i++) _pos(timeMs: 1000 * (i + 1))];
      final r = FixAltitudeResolver(
          platform: AltitudePlatform.android,
          capacity: 2,
          readNative: () {
            final c = Completer<NativeAltitudeAnswer?>();
            gates[calls++] = c;
            return c.future;
          });
      for (final f in fixes) {
        r.track(f); // A, B, C accepted in this order
      }
      expect(r.size, 2, reason: 'A was evicted the moment C was accepted');
      // Complete C, then B, then A.
      gates[2]!.complete(_matching(fixes[2]));
      gates[1]!.complete(_matching(fixes[1]));
      gates[0]!.complete(_matching(fixes[0]));
      await r.idle;
      expect(r.lookup(fixes[0]).isKnown, isFalse,
          reason: 'a late completion never resurrects an evicted fix');
      expect(r.lookup(fixes[1]).isKnown, isTrue);
      expect(r.lookup(fixes[2]).isKnown, isTrue);
      expect(r.size, 2);
    });

    test('a fix evicted while its read is out and accepted again is read '
        'once and stored once', () async {
      final gates = <int, Completer<NativeAltitudeAnswer?>>{};
      var calls = 0;
      final fixes = [for (var i = 0; i < 3; i++) _pos(timeMs: 1000 * (i + 1))];
      final r = FixAltitudeResolver(
          platform: AltitudePlatform.android,
          capacity: 2,
          readNative: () {
            final c = Completer<NativeAltitudeAnswer?>();
            gates[calls++] = c;
            return c.future;
          });
      r.track(fixes[0]); // A
      r.track(fixes[1]); // B
      r.track(fixes[2]); // C evicts A
      r.track(fixes[0]); // A accepted again, read still out
      expect(calls, 3, reason: 'A is not read a second time');
      for (var i = 0; i < 3; i++) {
        gates[i]!.complete(_matching(fixes[i]));
      }
      await r.idle;
      expect(r.lookup(fixes[0]).isKnown, isTrue,
          reason: 'the pending answer lands in the re-reserved slot');
      expect(r.stats.proved + r.stats.unproved, 3, reason: 'counted once each');
    });

    test('a malformed answer followed by a good one never poisons the SDK',
        () async {
      var calls = 0;
      final a = _pos(timeMs: 1000);
      final b = _pos(timeMs: 2000);
      final r = FixAltitudeResolver(
          platform: AltitudePlatform.android,
          readNative: () async => calls++ == 0 ? null : _matching(b));
      r.track(a);
      await r.idle;
      expect(r.lookup(a).isKnown, isFalse);
      r.track(b);
      await r.idle;
      expect(calls, 2, reason: 'a null answer caches no SDK, so b is read');
      expect(r.lookup(b).isKnown, isTrue);
    });

    test('stats count real Android fixes only', () async {
      final known = _pos(timeMs: 1000);
      final unknown = _pos(timeMs: 2000);
      final r = FixAltitudeResolver(
          platform: AltitudePlatform.android,
          readNative: () async => _matching(known));
      r.track(known);
      r.track(unknown); // its native answer describes a different fix
      r.track(_pos(timeMs: 3000), simulated: true);
      await r.idle;
      expect(r.stats.proved, 1);
      expect(r.stats.unproved, 1);
      expect(r.stats.reasons, {'time_differs': 1});
    });
  });
}
