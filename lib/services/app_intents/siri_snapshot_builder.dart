import '../../models/log_entry.dart';
import '../../models/repeater.dart';
import '../watch/watch_geo_builder.dart';
import '../watch/watch_models.dart';
import 'siri_snapshot_models.dart';

class SiriSnapshotBuilder {
  const SiriSnapshotBuilder._();

  static const int maximumObservations = 64;
  static const Duration maximumObservationAge = Duration(hours: 2);

  static List<SiriRepeaterObservation> buildRecentHeard({
    required List<TxLogEntry> txEntries,
    required List<RxLogEntry> rxEntries,
    required List<DiscLogEntry> discoveryEntries,
    required List<TraceLogEntry> traceEntries,
    required List<Repeater> repeaters,
    required String? zoneCode,
    int? hopBytes,
    DateTime? now,
  }) {
    final cutoff = (now ?? DateTime.now()).subtract(maximumObservationAge);
    final observations = <SiriRepeaterObservation>[];

    SiriRepeaterObservation observation({
      required String displayId,
      String? identity,
      required DateTime observedAt,
      required SiriObservationKind kind,
      required bool direct,
      required int hopCount,
      required double latitude,
      required double longitude,
      double? snr,
      int? rssi,
    }) {
      final normalizedId = displayId.toUpperCase();
      final repeater = (identity == null
              ? null
              : WatchGeoBuilder.resolveRepeater(
                  repeaters: repeaters,
                  id: identity,
                  hopBytes: hopBytes,
                )) ??
          WatchGeoBuilder.resolveRepeater(
            repeaters: repeaters,
            id: normalizedId,
            hopBytes: hopBytes,
          );
      final resolved = repeater != null;
      final hasDistance = resolved &&
          repeater.hasLocation &&
          latitude.isFinite &&
          longitude.isFinite;
      return SiriRepeaterObservation(
        entityId: resolved
            ? '${repeater.iata ?? zoneCode ?? 'GLOBAL'}|${repeater.id}'
            : null,
        displayHexId: normalizedId,
        name: resolved && repeater.name != 'Unknown' ? repeater.name : null,
        observedAt: observedAt,
        kind: kind,
        direct: direct,
        hopCount: hopCount,
        snr: snr,
        rssi: rssi,
        distanceM: hasDistance
            ? WatchWire.distanceMeters(
                latitude,
                longitude,
                repeater.lat,
                repeater.lon,
              )
            : null,
        repeaterLat: resolved && repeater.hasLocation ? repeater.lat : null,
        repeaterLon: resolved && repeater.hasLocation ? repeater.lon : null,
        resolved: resolved,
      );
    }

    for (final entry in txEntries) {
      if (entry.timestamp.isBefore(cutoff)) continue;
      for (final event in entry.events) {
        observations.add(observation(
          displayId: event.repeaterId,
          observedAt: entry.timestamp,
          kind: SiriObservationKind.txEcho,
          direct: true,
          hopCount: 1,
          latitude: entry.latitude,
          longitude: entry.longitude,
          snr: event.snr,
          rssi: event.rssi,
        ));
      }
      for (final event in entry.multiHopEvents) {
        observations.add(observation(
          displayId: event.repeaterId,
          observedAt: entry.timestamp,
          kind: SiriObservationKind.txEcho,
          direct: false,
          hopCount: event.pathHops.isEmpty ? 2 : event.pathHops.length,
          latitude: entry.latitude,
          longitude: entry.longitude,
          snr: event.snr,
          rssi: event.rssi,
        ));
      }
    }

    for (final entry in rxEntries) {
      if (entry.timestamp.isBefore(cutoff)) continue;
      observations.add(observation(
        displayId: entry.repeaterId,
        observedAt: entry.timestamp,
        kind: SiriObservationKind.passiveRx,
        direct: entry.pathLength <= 1,
        hopCount: entry.pathLength,
        latitude: entry.latitude,
        longitude: entry.longitude,
        snr: entry.snr,
        rssi: entry.rssi,
      ));
    }

    for (final entry in discoveryEntries) {
      if (entry.timestamp.isBefore(cutoff)) continue;
      for (final node in entry.discoveredNodes
          .where((node) => node.nodeType == 'REPEATER')) {
        observations.add(observation(
          displayId: node.repeaterId,
          identity: node.pubkeyHex,
          observedAt: entry.timestamp,
          kind: SiriObservationKind.discovery,
          direct: true,
          hopCount: 1,
          latitude: entry.latitude,
          longitude: entry.longitude,
          snr: node.localSnr,
          rssi: node.localRssi,
        ));
      }
    }

    for (final entry in traceEntries.where((entry) => entry.success)) {
      if (entry.timestamp.isBefore(cutoff)) continue;
      observations.add(observation(
        displayId: entry.targetRepeaterId,
        identity: entry.targetRepeaterId,
        observedAt: entry.timestamp,
        kind: SiriObservationKind.trace,
        direct: true,
        hopCount: 0,
        latitude: entry.latitude,
        longitude: entry.longitude,
        snr: entry.localSnr,
        rssi: entry.localRssi,
      ));
    }

    observations.sort((a, b) => b.observedAt.compareTo(a.observedAt));
    return observations.length > maximumObservations
        ? observations.sublist(0, maximumObservations)
        : observations;
  }

  static List<SiriRepeaterEntitySnapshot> buildRepeaterCatalog(
    List<Repeater> repeaters,
  ) =>
      repeaters
          .map(
            (repeater) => SiriRepeaterEntitySnapshot(
              id: '${repeater.iata ?? 'GLOBAL'}|${repeater.id}',
              name: repeater.name,
              hexId: repeater.hexId.toUpperCase(),
              zoneCode: repeater.iata,
              isActive: repeater.isActive,
              isNew: repeater.isNew,
              serverLastHeard: repeater.lastHeard == 0
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(
                      repeater.lastHeard * 1000,
                    ),
              latitude: repeater.hasLocation ? repeater.lat : null,
              longitude: repeater.hasLocation ? repeater.lon : null,
            ),
          )
          .toList(growable: false);
}
