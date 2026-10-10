import 'package:geolocator/geolocator.dart';

/// The vertical reference an altitude is measured from.
///
/// iOS always reports height above mean sea level. Android reports height
/// above the WGS84 ellipsoid, except that on Android 14 and later the location
/// plugin swaps in a sea level value whenever the fix object carries one. The
/// two differ by the local geoid separation, tens of meters in most places,
/// which is why an altitude is only uploaded together with its reference. The
/// server contract is documented in `MeshMapper_Server/docs/APP_API.md`.
enum AltitudeReference {
  /// Height above mean sea level.
  msl('msl'),

  /// Height above the WGS84 ellipsoid.
  ellipsoid('ellipsoid');

  const AltitudeReference(this.wireName);

  /// The value sent as `altitude_ref`.
  final String wireName;
}

/// A fix's altitude as the app is willing to report it: the meters, the
/// reference they are measured from and the vertical accuracy, or nothing at
/// all. An altitude is never reported without its reference.
class FixAltitude {
  /// Meters, null when unknown.
  final double? meters;

  /// The reference [meters] is measured from, null when unknown.
  final AltitudeReference? reference;

  /// Vertical accuracy in meters (about one standard deviation on both phone
  /// platforms), null when the fix did not carry one or it was not usable.
  final double? accuracy;

  const FixAltitude.unknown()
      : meters = null,
        reference = null,
        accuracy = null;

  FixAltitude.known({
    required double this.meters,
    required AltitudeReference this.reference,
    double? accuracy,
  }) : accuracy = sanitizeAccuracy(accuracy);

  bool get isKnown => meters != null && reference != null;

  /// The `altitude_ref` wire value, null when unknown.
  String? get wireReference => reference?.wireName;

  /// An accuracy is usable when it is a finite number above zero. geolocator
  /// reports a missing accuracy as 0.0, and Android permits a known zero, so
  /// zero is treated as unknown on purpose.
  static double? sanitizeAccuracy(double? value) {
    if (value == null || !value.isFinite || value <= 0) return null;
    return value;
  }

  @override
  String toString() => isKnown
      ? 'FixAltitude(${meters}m ${reference!.wireName}'
          '${accuracy != null ? ' ±${accuracy}m' : ''})'
      : 'FixAltitude(unknown)';
}

/// The altitude a fix actually carries, or null when the platform had none.
///
/// geolocator reports a missing altitude as 0.0 with 0.0 accuracy on both
/// platforms. Android also omits the accuracy on fixes that DO carry an
/// altitude, so the accuracy alone cannot decide; only the 0/0 pair means
/// unknown. A non-finite altitude is unknown too.
double? reportedAltitudeOrNull(Position position) {
  if (position.altitude == 0.0 && position.altitudeAccuracy == 0.0) {
    return null;
  }
  if (!position.altitude.isFinite) return null;
  return position.altitude;
}

/// Which labelling rule applies. Decided once from the running platform.
enum AltitudePlatform { ios, android, web, other }

/// The first Android SDK whose fixes can carry a sea level altitude
/// (Android 14, `Build.VERSION_CODES.UPSIDE_DOWN_CAKE`).
const int kAndroidMslSdk = 34;

/// One fix object as the Android handler read it off the location provider.
/// Field names mirror `android.location.Location`: [altitude] is the
/// ellipsoid height, [msl] the sea level height when [hasMsl].
class NativeFixDescription {
  final String source;
  final int timeMs;
  final double lat;
  final double lon;
  final bool hasAltitude;
  final double altitude;
  final bool hasVerticalAccuracy;
  final double verticalAccuracy;
  final bool hasMsl;
  final double msl;
  final bool hasMslAccuracy;
  final double mslAccuracy;
  final bool isMock;

  const NativeFixDescription({
    required this.source,
    required this.timeMs,
    required this.lat,
    required this.lon,
    required this.hasAltitude,
    required this.altitude,
    required this.hasVerticalAccuracy,
    required this.verticalAccuracy,
    required this.hasMsl,
    required this.msl,
    required this.hasMslAccuracy,
    required this.mslAccuracy,
    required this.isMock,
  });

  /// Parses one entry of the channel's `fixes` list. Returns null when the
  /// entry is not a map, when a required field is missing or mistyped, when
  /// the timestamp is not an integer, or when an altitude flag is true but
  /// its value is absent or not finite. Nothing is invented: a value the
  /// handler did not send cannot prove anything. An accuracy is different:
  /// it never proves the reference, so a missing or non-finite accuracy
  /// only clears its flag and the altitude can still be proved without it.
  static NativeFixDescription? tryFromMap(Object? raw) {
    if (raw is! Map) return null;
    double? d(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
    bool? b(Object? v) => v is bool ? v : null;
    final timeMs = raw['timeMs'];
    final lat = d(raw['lat']);
    final lon = d(raw['lon']);
    final hasAltitude = b(raw['hasAltitude']);
    final hasVerticalAccuracy = b(raw['hasVerticalAccuracy']);
    final hasMsl = b(raw['hasMsl']);
    final hasMslAccuracy = b(raw['hasMslAccuracy']);
    final isMock = b(raw['isMock']);
    if (timeMs is! int ||
        lat == null ||
        lon == null ||
        hasAltitude == null ||
        hasVerticalAccuracy == null ||
        hasMsl == null ||
        hasMslAccuracy == null ||
        isMock == null) {
      return null;
    }
    final altitude = d(raw['altitude']);
    final verticalAccuracy = d(raw['verticalAccuracy']);
    final msl = d(raw['msl']);
    final mslAccuracy = d(raw['mslAccuracy']);
    if ((hasAltitude && altitude == null) || (hasMsl && msl == null)) {
      return null;
    }
    return NativeFixDescription(
      source: raw['source'] is String ? raw['source'] as String : 'unknown',
      timeMs: timeMs,
      lat: lat,
      lon: lon,
      hasAltitude: hasAltitude,
      altitude: altitude ?? 0.0,
      hasVerticalAccuracy: hasVerticalAccuracy && verticalAccuracy != null,
      verticalAccuracy: verticalAccuracy ?? 0.0,
      hasMsl: hasMsl,
      msl: msl ?? 0.0,
      hasMslAccuracy: hasMslAccuracy && mslAccuracy != null,
      mslAccuracy: mslAccuracy ?? 0.0,
      isMock: isMock,
    );
  }
}

/// What the Android handler answered: the SDK it runs on and the fix objects
/// it could read (empty below Android 14, where no read is performed).
class NativeAltitudeAnswer {
  final int sdk;
  final List<NativeFixDescription> fixes;

  const NativeAltitudeAnswer({required this.sdk, required this.fixes});

  /// Null unless [raw] is a map whose `sdk` is a positive integer. A missing
  /// or zero SDK must never be read as "below Android 14": that would label
  /// every later fix ellipsoid on the strength of a malformed answer.
  static NativeAltitudeAnswer? tryFromMap(Object? raw) {
    if (raw is! Map) return null;
    final sdkRaw = raw['sdk'];
    if (sdkRaw is! int || sdkRaw <= 0) return null;
    final fixesRaw = raw['fixes'];
    return NativeAltitudeAnswer(
      sdk: sdkRaw,
      fixes: fixesRaw is List
          ? fixesRaw
              .map(NativeFixDescription.tryFromMap)
              .whereType<NativeFixDescription>()
              .toList(growable: false)
          : const [],
    );
  }
}

/// The rule's answer plus a short token saying which branch decided it, for
/// the resolver's (throttled) logging and for the tests.
class AltitudeResolution {
  final FixAltitude altitude;
  final String reason;
  const AltitudeResolution(this.altitude, this.reason);

  static const _unknown = FixAltitude.unknown();
  const AltitudeResolution.unknown(this.reason) : altitude = _unknown;
}

/// Decides what altitude, if any, a fix may be uploaded with.
///
/// Pure. [simulated] is true for a GPS simulator fix. [native] is the Android
/// handler's answer for the moment this fix was accepted, null on every other
/// platform or when the read failed. The Android 14 proof is exact equality:
/// same timestamp, same coordinates, and the altitude the plugin delivered
/// equals the fix's sea level value or its ellipsoid value. Nearness is never
/// accepted, since two fixes a few seconds apart can carry different
/// altitudes and different references.
AltitudeResolution resolveFixAltitude({
  required AltitudePlatform platform,
  required Position position,
  required bool simulated,
  NativeAltitudeAnswer? native,
}) {
  if (simulated) return const AltitudeResolution.unknown('simulated');
  if (position.isMocked) return const AltitudeResolution.unknown('mocked');
  final meters = reportedAltitudeOrNull(position);
  if (meters == null) return const AltitudeResolution.unknown('no_altitude');

  switch (platform) {
    case AltitudePlatform.ios:
      return AltitudeResolution(
        FixAltitude.known(
            meters: meters,
            reference: AltitudeReference.msl,
            accuracy: position.altitudeAccuracy),
        'ios',
      );
    case AltitudePlatform.web:
      // The browser reports a 95% confidence figure while the phones report
      // about one sigma, so the web accuracy is withheld.
      return AltitudeResolution(
        FixAltitude.known(meters: meters, reference: AltitudeReference.ellipsoid),
        'web',
      );
    case AltitudePlatform.other:
      return const AltitudeResolution.unknown('other_platform');
    case AltitudePlatform.android:
      if (native == null) return const AltitudeResolution.unknown('no_native');
      if (native.sdk < kAndroidMslSdk) {
        // With this app's location settings (NMEA sea level off) the plugin
        // can only have delivered the ellipsoid height here.
        return AltitudeResolution(
          FixAltitude.known(
              meters: meters,
              reference: AltitudeReference.ellipsoid,
              accuracy: position.altitudeAccuracy),
          'android_legacy',
        );
      }
      if (native.fixes.isEmpty) return const AltitudeResolution.unknown('no_fix');
      // Every candidate is examined: the location manager path can answer
      // several providers, and a non-matching or mock candidate must not
      // hide a genuine match beside it. The sea level value is tried first;
      // an exact ellipsoid match is accepted whether or not the fix also
      // carries sea level, because the plugin only swaps in sea level when
      // the fix object has extras, which the location manager path may not.
      final timeMs = position.timestamp.millisecondsSinceEpoch;
      var sawTime = false;
      var sawCoord = false;
      var sawMock = false;
      for (final fix in native.fixes) {
        if (fix.timeMs != timeMs) continue;
        sawTime = true;
        if (fix.lat != position.latitude || fix.lon != position.longitude) {
          continue;
        }
        sawCoord = true;
        if (fix.isMock) {
          sawMock = true;
          continue;
        }
        if (fix.hasMsl && meters == fix.msl) {
          return AltitudeResolution(
            FixAltitude.known(
                meters: meters,
                reference: AltitudeReference.msl,
                accuracy: fix.hasMslAccuracy ? fix.mslAccuracy : null),
            'android_msl',
          );
        }
        if (fix.hasAltitude && meters == fix.altitude) {
          return AltitudeResolution(
            FixAltitude.known(
                meters: meters,
                reference: AltitudeReference.ellipsoid,
                accuracy: fix.hasVerticalAccuracy ? fix.verticalAccuracy : null),
            'android_ellipsoid',
          );
        }
      }
      if (!sawTime) return const AltitudeResolution.unknown('time_differs');
      if (!sawCoord) return const AltitudeResolution.unknown('coord_differs');
      if (sawMock) return const AltitudeResolution.unknown('native_mock');
      return const AltitudeResolution.unknown('value_differs');
  }
}
