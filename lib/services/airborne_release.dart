import '../utils/distance_formatter.dart';
import 'gps_service.dart';

/// What an airborne session end tells the user and the server.
///
/// [detail] is the error-log line in the user's units. [extras] rides on the
/// session release call (`reason` stays `disconnect`): `airborne_gate` is the
/// test that fired and `airborne_value` its reading (raw meters for altitude,
/// km/h for speed), while `airborne_alt_m` and `airborne_speed_kmh` are BOTH
/// readings of the fix that set the latch, each omitted when the platform did
/// not know it. Prod holds 151 flagged sessions in the 250 to 400 km/h band in
/// high-speed-rail regions; a speed-gate fire that carries only its speed
/// cannot be told from a train, one that carries the altitude too can. Metric
/// ints regardless of the unit setting: the server range-gates and casts.
({String detail, Map<String, dynamic> extras}) airborneReleaseInfo({
  required AirborneGate gate,
  required double? altitudeMeters,
  required double? speedMetersPerSecond,
  required bool isImperial,
}) {
  final kmh = speedMetersPerSecond == null ? null : speedMetersPerSecond * 3.6;
  final altitudeText = altitudeMeters == null
      ? null
      : formatMeters(altitudeMeters, isImperial: isImperial);
  final speedText = kmh == null ? null : formatSpeed(kmh, isImperial: isImperial);

  final String detail;
  final int value;
  switch (gate) {
    case AirborneGate.altitude:
      // The altitude gate fired on this reading, so it is never unknown; the
      // fallback only keeps the types simple.
      value = (altitudeMeters ?? 0).round();
      detail = speedText == null
          ? 'Altitude ${altitudeText ?? 'unknown'}'
          : 'Altitude ${altitudeText ?? 'unknown'}, speed $speedText';
    case AirborneGate.speed:
      value = (kmh ?? 0).round();
      detail = altitudeText == null
          ? 'Speed ${speedText ?? 'unknown'}'
          : 'Speed ${speedText ?? 'unknown'}, altitude $altitudeText';
  }

  return (
    detail: detail,
    extras: <String, dynamic>{
      'disconnect_cause': 'airborne',
      'airborne_gate': gate.name,
      'airborne_value': value,
      if (altitudeMeters != null) 'airborne_alt_m': altitudeMeters.round(),
      if (kmh != null) 'airborne_speed_kmh': kmh.round(),
    },
  );
}
