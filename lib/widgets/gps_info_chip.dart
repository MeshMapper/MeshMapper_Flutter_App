import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../services/gps_service.dart';
import '../utils/distance_formatter.dart';
import '../utils/ping_colors.dart';

/// The readings the map's GPS chip shows, compared by value.
///
/// The chip sits inside the map widget, which by design does not rebuild on
/// GPS ticks (Critical Rule 9), so the map wraps the chip in a Selector on
/// this value: the provider notifies on every fix, the chip rebuilds only when
/// a displayed reading changes, and the map itself never relayouts for it.
class GpsChipReadings {
  final bool hasGps;
  final double accuracy;

  /// Altitude in meters, null when the fix did not know it.
  final double? altitude;

  /// Distance since the last ping of any type, null before the first.
  final double? distanceFromLastPing;
  final bool isImperial;

  const GpsChipReadings({
    required this.hasGps,
    required this.accuracy,
    required this.altitude,
    required this.distanceFromLastPing,
    required this.isImperial,
  });

  factory GpsChipReadings.from({
    required Position? position,
    required double? distanceFromLastPing,
    required bool isImperial,
  }) =>
      GpsChipReadings(
        hasGps: position != null,
        accuracy: position?.accuracy ?? 0,
        altitude: position == null ? null : GpsService.altitudeOrNull(position),
        distanceFromLastPing: distanceFromLastPing,
        isImperial: isImperial,
      );

  @override
  bool operator ==(Object other) =>
      other is GpsChipReadings &&
      other.hasGps == hasGps &&
      other.accuracy == accuracy &&
      other.altitude == altitude &&
      other.distanceFromLastPing == distanceFromLastPing &&
      other.isImperial == isImperial;

  @override
  int get hashCode =>
      Object.hash(hasGps, accuracy, altitude, distanceFromLastPing, isImperial);
}

/// GPS info chip (top-left of the map): fix accuracy, distance since the last
/// ping, and the fix's altitude when known. See [GpsChipReadings].
class GpsInfoChip extends StatelessWidget {
  final GpsChipReadings readings;

  const GpsInfoChip({super.key, required this.readings});

  static Color accuracyColor(double accuracy) {
    if (accuracy <= 10) return PingColors.signalGood;
    if (accuracy <= 30) return PingColors.signalMedium;
    return PingColors.signalBad;
  }

  @override
  Widget build(BuildContext context) {
    final hasGps = readings.hasGps;
    final distance = readings.distanceFromLastPing;
    final altitude = readings.altitude;
    final statusColor =
        hasGps ? accuracyColor(readings.accuracy) : Colors.grey;
    const dimStyle = TextStyle(
      fontSize: 11,
      fontFamily: 'monospace',
      color: Colors.white70,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasGps ? Icons.gps_fixed : Icons.gps_off,
            size: 14,
            color: statusColor,
          ),
          const SizedBox(width: 6),
          Text(
            hasGps
                ? formatMeters(readings.accuracy, isImperial: readings.isImperial)
                : 'No GPS',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: statusColor,
            ),
          ),
          if (hasGps && distance != null) ...[
            const SizedBox(width: 12),
            const Icon(Icons.straighten, size: 12, color: Colors.white70),
            const SizedBox(width: 4),
            Text(formatMeters(distance, isImperial: readings.isImperial),
                style: dimStyle),
          ],
          if (altitude != null) ...[
            const SizedBox(width: 12),
            const Icon(Icons.height, size: 12, color: Colors.white70),
            const SizedBox(width: 4),
            Text(formatMeters(altitude, isImperial: readings.isImperial),
                style: dimStyle),
          ],
        ],
      ),
    );
  }
}
