import 'dart:math' as math;

import '../../models/ping_data.dart';
import '../../models/repeater.dart';
import '../../utils/ping_colors.dart';
import 'watch_models.dart';

/// Pure builders for the geographic half of a [WatchSnapshot].
///
/// Kept free of provider and platform dependencies so the caps, decimation,
/// and colour resolution can be unit-tested directly — those are exactly the
/// rules that would otherwise only fail on a wrist, in a car, at speed.
class WatchGeoBuilder {
  WatchGeoBuilder._();

  /// Great-circle distance in metres.
  ///
  /// Local rather than `Geolocator.distanceBetween` to keep this file free of
  /// plugin imports; the maths is identical.
  static double distanceMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadius = 6371000.0;
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _toRadians(double degrees) => degrees * math.pi / 180.0;

  /// Colour for a ping marker, matching the iOS map's `_coverageStatusColor`.
  static WatchColor pingColor(String kind, bool success) {
    switch (kind) {
      case 'tx':
        return WatchColor.fromColor(
          success ? PingColors.txSuccess : PingColors.txFail,
        );
      case 'rx':
        return WatchColor.fromColor(PingColors.rx);
      case 'disc':
        return WatchColor.fromColor(
          success ? PingColors.discSuccess : PingColors.discFail,
        );
      case 'trace':
        return WatchColor.fromColor(
          success ? PingColors.traceSuccess : PingColors.noResponse,
        );
      default:
        return WatchColor.fromColor(PingColors.noResponse);
    }
  }

  /// Colour for a repeater pin, matching the iOS map's `_repeaterStatusColor`.
  static WatchColor repeaterColor(Repeater repeater) {
    if (repeater.isDead) return WatchColor.fromColor(PingColors.repeaterDead);
    if (repeater.isNew) return WatchColor.fromColor(PingColors.repeaterNew);
    return WatchColor.fromColor(PingColors.repeaterActive);
  }

  /// Most recent pings, newest first, capped at [WatchWire.maxPings].
  ///
  /// TX and RX are merged into one time-ordered stream because the watch map
  /// shows them together; a TX that nobody answered is drawn as a failure.
  static List<WatchPing> buildPings({
    required List<TxPing> txPings,
    required List<RxPing> rxPings,
    int cap = WatchWire.maxPings,
  }) {
    final pings = <WatchPing>[];

    for (var i = 0; i < txPings.length; i++) {
      final tx = txPings[i];
      final success = tx.heardRepeaters.isNotEmpty;
      pings.add(WatchPing(
        id: 'tx-${tx.timestamp.millisecondsSinceEpoch}-$i',
        lat: tx.latitude,
        lon: tx.longitude,
        kind: 'tx',
        color: pingColor('tx', success),
        at: tx.timestamp,
      ));
    }

    for (var i = 0; i < rxPings.length; i++) {
      final rx = rxPings[i];
      pings.add(WatchPing(
        id: 'rx-${rx.timestamp.millisecondsSinceEpoch}-$i',
        lat: rx.latitude,
        lon: rx.longitude,
        kind: 'rx',
        color: pingColor('rx', true),
        at: rx.timestamp,
      ));
    }

    pings.sort((a, b) => b.at.compareTo(a.at));
    if (pings.length <= cap) return pings;
    return pings.sublist(0, cap);
  }

  /// Repeaters nearest [lat]/[lon], capped at [WatchWire.maxRepeaters].
  ///
  /// Repeaters at the API's `(0, 0)` "location unknown" sentinel are excluded:
  /// plotting them would drop a pin in the Gulf of Guinea.
  static List<WatchRepeater> buildRepeaters({
    required List<Repeater> repeaters,
    required Set<String> heardThisCycle,
    double? lat,
    double? lon,
    int cap = WatchWire.maxRepeaters,
  }) {
    final located = repeaters.where((r) => r.hasLocation).toList();

    if (lat != null && lon != null) {
      // Distance is computed once per repeater rather than inside the
      // comparator: this runs on every rebuild during an active session, and
      // a zone can hold hundreds of repeaters.
      final ranked = located
          .map((r) => (
                repeater: r,
                distance: distanceMeters(lat, lon, r.lat, r.lon),
              ))
          .toList()
        ..sort((a, b) => a.distance.compareTo(b.distance));
      located
        ..clear()
        ..addAll(ranked.map((e) => e.repeater));
    }

    final limited = located.length > cap ? located.sublist(0, cap) : located;

    return limited
        .map((r) => WatchRepeater(
              id: r.id,
              name: r.name,
              lat: r.lat,
              lon: r.lon,
              color: repeaterColor(r),
              heardThisCycle:
                  heardThisCycle.contains(r.id) ||
                      heardThisCycle.contains(r.hexId),
            ))
        .toList();
  }

  /// Recently-responded rows, strongest SNR first, capped at
  /// [WatchWire.maxHeard].
  ///
  /// The cap is what the payload carries, not what the watch displays — the
  /// view renders as many as fit legibly at the wearer's text size and
  /// scrolls for the rest.
  static List<WatchHeardNode> buildHeard({
    required List<HeardRepeater> heard,
    required Map<String, Repeater> repeaterById,
    required DateTime at,
    double? lat,
    double? lon,
    int cap = WatchWire.maxHeard,
  }) {
    final sorted = List<HeardRepeater>.from(heard)
      ..sort((a, b) => (b.snr ?? -999).compareTo(a.snr ?? -999));

    final limited = sorted.length > cap ? sorted.sublist(0, cap) : sorted;

    return limited.map((h) {
      final repeater = repeaterById[h.repeaterId];
      double? distance;
      if (lat != null &&
          lon != null &&
          repeater != null &&
          repeater.hasLocation) {
        distance = distanceMeters(lat, lon, repeater.lat, repeater.lon);
      }

      return WatchHeardNode(
        id: h.repeaterId,
        name: repeater?.name ?? h.repeaterId.toUpperCase(),
        snr: h.snr,
        rssi: h.rssi,
        hops: h.pathHops?.length,
        seenCount: h.seenCount,
        at: at,
        distanceM: distance,
        snrColor: h.snr == null
            ? null
            : WatchColor.fromColor(PingColors.snrColor(h.snr!)),
      );
    }).toList();
  }

  /// True when the fix moved far enough to be worth an update.
  ///
  /// A stationary GPS jitters by a few metres indefinitely; without this gate
  /// a parked phone would keep the watch radio busy for no visible change.
  static bool movedEnough({
    required double? lastLat,
    required double? lastLon,
    required double lat,
    required double lon,
    double thresholdMeters = WatchWire.minMoveMeters,
  }) {
    if (lastLat == null || lastLon == null) return true;
    return distanceMeters(lastLat, lastLon, lat, lon) >= thresholdMeters;
  }
}
