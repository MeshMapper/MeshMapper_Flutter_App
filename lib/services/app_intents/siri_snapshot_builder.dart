import '../../models/log_entry.dart';
import '../../models/repeater.dart';
import '../external_surfaces/geo/external_surface_geo_builder.dart';
import '../watch/watch_models.dart';
import 'siri_snapshot_models.dart';

class SiriSnapshotBuilder {
  const SiriSnapshotBuilder._();

  static const int maximumObservations = 64;
  static const int maximumRepeaters = 64;
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
    final candidates = <_SiriObservationCandidate>[];

    SiriRepeaterObservation resolve(_SiriObservationCandidate candidate) {
      final normalizedId = candidate.displayId.toUpperCase();
      final repeater = (candidate.identity == null
              ? null
              : ExternalSurfaceGeoBuilder.resolveRepeater(
                  repeaters: repeaters,
                  id: candidate.identity!,
                  hopBytes: hopBytes,
                )) ??
          ExternalSurfaceGeoBuilder.resolveRepeater(
            repeaters: repeaters,
            id: normalizedId,
            hopBytes: hopBytes,
          );
      final resolved = repeater != null;
      final hasDistance = resolved &&
          repeater.hasLocation &&
          repeater.lat.isFinite &&
          repeater.lon.isFinite &&
          candidate.latitude.isFinite &&
          candidate.longitude.isFinite;
      return SiriRepeaterObservation(
        entityId: resolved
            ? '${repeater.iata ?? zoneCode ?? 'GLOBAL'}|${repeater.id}'
            : null,
        displayHexId: normalizedId,
        name: resolved && repeater.name != 'Unknown' ? repeater.name : null,
        observedAt: candidate.observedAt,
        kind: candidate.kind,
        direct: candidate.direct,
        hopCount: candidate.hopCount,
        snr: candidate.snr?.isFinite == true ? candidate.snr : null,
        rssi: candidate.rssi,
        distanceM: hasDistance
            ? WatchWire.distanceMeters(
                candidate.latitude,
                candidate.longitude,
                repeater.lat,
                repeater.lon,
              )
            : null,
        repeaterLat: resolved &&
                repeater.hasLocation &&
                repeater.lat.isFinite &&
                repeater.lon.isFinite
            ? repeater.lat
            : null,
        repeaterLon: resolved &&
                repeater.hasLocation &&
                repeater.lat.isFinite &&
                repeater.lon.isFinite
            ? repeater.lon
            : null,
        resolved: resolved,
      );
    }

    for (final entry in txEntries) {
      if (entry.timestamp.isBefore(cutoff)) continue;
      for (final event in entry.events) {
        candidates.add(_SiriObservationCandidate(
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
        candidates.add(_SiriObservationCandidate(
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
      candidates.add(_SiriObservationCandidate(
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
        candidates.add(_SiriObservationCandidate(
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
      candidates.add(_SiriObservationCandidate(
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

    // Identity resolution scans the zone catalogue. Rank and bound the cheap
    // raw candidates first so a busy two-hour log pays that cost at most 64
    // times rather than once per observation across all four histories.
    candidates.sort((a, b) => b.observedAt.compareTo(a.observedAt));
    return candidates.take(maximumObservations).map(resolve).toList(
          growable: false,
        );
  }

  /// Counts distinct repeaters heard since [sessionStartedAt].
  ///
  /// [maximumObservationAge] bounds the cache, not a session: a two-hour
  /// history routinely spans several sessions, so counting all of it would let
  /// a session that has heard nothing report the previous one's repeaters.
  /// A null start means no session is running, which counts as none.
  static int countUniqueRepeatersHeard(
    List<SiriRepeaterObservation> observations,
    DateTime? sessionStartedAt,
  ) {
    if (sessionStartedAt == null) return 0;
    return observations
        .where((item) => !item.observedAt.isBefore(sessionStartedAt))
        .map((item) => item.entityId ?? 'unresolved:${item.displayHexId}')
        .toSet()
        .length;
  }

  static List<SiriRepeaterEntitySnapshot> buildRepeaterCatalog(
    List<Repeater> repeaters,
  ) {
    final ranked = List<Repeater>.of(repeaters)
      ..sort((a, b) {
        final active = (b.isActive ? 1 : 0).compareTo(a.isActive ? 1 : 0);
        if (active != 0) return active;
        final heard = b.lastHeard.compareTo(a.lastHeard);
        return heard != 0 ? heard : a.id.compareTo(b.id);
      });
    return ranked.take(maximumRepeaters).map(
      (repeater) {
        final hasFiniteLocation = repeater.hasLocation &&
            repeater.lat.isFinite &&
            repeater.lon.isFinite;
        return SiriRepeaterEntitySnapshot(
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
          latitude: hasFiniteLocation ? repeater.lat : null,
          longitude: hasFiniteLocation ? repeater.lon : null,
        );
      },
    ).toList(growable: false);
  }
}

class _SiriObservationCandidate {
  const _SiriObservationCandidate({
    required this.displayId,
    this.identity,
    required this.observedAt,
    required this.kind,
    required this.direct,
    required this.hopCount,
    required this.latitude,
    required this.longitude,
    this.snr,
    this.rssi,
  });

  final String displayId;
  final String? identity;
  final DateTime observedAt;
  final SiriObservationKind kind;
  final bool direct;
  final int hopCount;
  final double latitude;
  final double longitude;
  final double? snr;
  final int? rssi;
}
