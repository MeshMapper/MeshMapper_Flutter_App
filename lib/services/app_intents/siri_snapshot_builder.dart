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

  /// Stable identity a Siri entity is keyed on.
  ///
  /// The heard entity and the catalogue entity are joined on this string, so
  /// both sides must derive it the same way. [Repeater.iata] is nullable, and a
  /// repeater without one would otherwise be filed under two different keys and
  /// lose its name, zone and coordinates on the heard side.
  ///
  /// **This string must never depend on session state.** Shortcuts persists a
  /// chosen RepeaterEntity by its identifier and resolves it back by exact
  /// match, so an id that folded in the live session's zone would flip between
  /// connects and zones (`SEA|x` one drive, `GLOBAL|x` the next) and silently
  /// break every saved shortcut that named that repeater.
  static String repeaterEntityId(Repeater repeater) =>
      '${repeater.iata ?? 'GLOBAL'}|${repeater.id}';

  static SiriRecentHeard buildRecentHeard({
    required List<TxLogEntry> txEntries,
    required List<RxLogEntry> rxEntries,
    required List<DiscLogEntry> discoveryEntries,
    required List<TraceLogEntry> traceEntries,
    required List<Repeater> repeaters,
    int? hopBytes,
    DateTime? now,
  }) {
    final cutoff = (now ?? DateTime.now()).subtract(maximumObservationAge);
    final candidates = <_SiriObservationCandidate>[];
    final repeaterCache = <String, Repeater?>{};

    // The catalogue scan is the expensive part, and the same repeater is heard
    // over and over, so the lookup is memoised on the candidate's raw identity.
    Repeater? lookup(_SiriObservationCandidate candidate) {
      final cacheKey = _identityKey(candidate);
      if (repeaterCache.containsKey(cacheKey)) return repeaterCache[cacheKey];
      final found = (candidate.identity == null
              ? null
              : ExternalSurfaceGeoBuilder.resolveRepeater(
                  repeaters: repeaters,
                  id: candidate.identity!,
                  hopBytes: hopBytes,
                )) ??
          ExternalSurfaceGeoBuilder.resolveRepeater(
            repeaters: repeaters,
            id: candidate.displayId.toUpperCase(),
            hopBytes: hopBytes,
          );
      repeaterCache[cacheKey] = found;
      return found;
    }

    SiriRepeaterObservation resolve(_SiriObservationCandidate candidate) {
      final normalizedId = candidate.displayId.toUpperCase();
      final repeater = lookup(candidate);
      final resolved = repeater != null;
      final hasDistance = resolved &&
          repeater.hasLocation &&
          repeater.lat.isFinite &&
          repeater.lon.isFinite &&
          candidate.latitude.isFinite &&
          candidate.longitude.isFinite;
      return SiriRepeaterObservation(
        entityId: resolved ? repeaterEntityId(repeater) : null,
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

    // One row per distinct raw identity, carrying that repeater's most recent
    // sighting. Collapsing the candidates before resolving keeps the catalogue
    // scan proportional to the number of repeaters rather than the number of
    // observations, and it is what lets the session count see past the
    // [maximumObservations] newest events without walking the whole history
    // again.
    final newestByIdentity = <String, _SiriObservationCandidate>{};
    for (final candidate in candidates) {
      final key = _identityKey(candidate);
      final existing = newestByIdentity[key];
      if (existing == null ||
          existing.observedAt.isBefore(candidate.observedAt)) {
        newestByIdentity[key] = candidate;
      }
    }

    // The count only needs an identity and a timestamp, so the distinct roll-up
    // stays lightweight: no names, no coordinates and above all no haversine
    // per row, none of which any caller of it reads. Resolution comes from the
    // same memo the wire list uses, so nothing is looked up twice.
    final resolvedHeard = <String, Repeater>{};
    final unresolvedHeard = <String, _SiriObservationCandidate>{};
    for (final entry in newestByIdentity.entries) {
      final repeater = lookup(entry.value);
      if (repeater != null) {
        resolvedHeard[entry.key] = repeater;
      } else {
        unresolvedHeard[entry.key] = entry.value;
      }
    }

    // A repeater met by discovery carries a full public key and resolves; the
    // same repeater met by TX echo or passive RX carries only a short path
    // hash, which is ambiguous against the whole catalogue and so resolves to
    // nothing. Counted raw that is one repeater twice. Re-run the same prefix
    // relation against only the repeaters actually heard in this set: that
    // narrower field is usually unambiguous, and where it is not the row stays
    // on its own rather than being attached to a guess.
    final heardRepeaters = <String, Repeater>{};
    for (final repeater in resolvedHeard.values) {
      heardRepeaters[repeater.id] = repeater;
    }
    final heardList = heardRepeaters.values.toList(growable: false);

    final distinct = <SiriHeardIdentity>[
      for (final entry in resolvedHeard.entries)
        SiriHeardIdentity(
          key: repeaterEntityId(entry.value),
          observedAt: newestByIdentity[entry.key]!.observedAt,
        ),
      for (final entry in unresolvedHeard.entries)
        SiriHeardIdentity(
          key: _collapsedKey(
                candidate: entry.value,
                heardRepeaters: heardList,
                hopBytes: hopBytes,
              ) ??
              'unresolved:${entry.value.displayId.toUpperCase()}',
          observedAt: entry.value.observedAt,
        ),
    ];

    candidates.sort((a, b) => b.observedAt.compareTo(a.observedAt));
    return SiriRecentHeard(
      observations: candidates.take(maximumObservations).map(resolve).toList(
            growable: false,
          ),
      distinctHeard: List<SiriHeardIdentity>.unmodifiable(distinct),
    );
  }

  /// The entity id of the already-heard repeater this row unambiguously
  /// belongs to, or null when nothing in the heard set claims it outright.
  static String? _collapsedKey({
    required _SiriObservationCandidate candidate,
    required List<Repeater> heardRepeaters,
    required int? hopBytes,
  }) {
    if (heardRepeaters.isEmpty) return null;
    final match = (candidate.identity == null
            ? null
            : ExternalSurfaceGeoBuilder.resolveRepeater(
                repeaters: heardRepeaters,
                id: candidate.identity!,
                hopBytes: hopBytes,
              )) ??
        ExternalSurfaceGeoBuilder.resolveRepeater(
          repeaters: heardRepeaters,
          id: candidate.displayId.toUpperCase(),
          hopBytes: hopBytes,
        );
    return match == null ? null : repeaterEntityId(match);
  }

  /// Counts distinct repeaters heard since [sessionStartedAt].
  ///
  /// Feed this [SiriRecentHeard.distinctHeard], not the snapshot's
  /// [SiriRecentHeard.observations]: that list is capped at
  /// [maximumObservations] for the wire, and counting it would cap the spoken
  /// total at the 64 newest events instead of the whole session.
  ///
  /// [maximumObservationAge] bounds the cache, not a session: a two-hour
  /// history routinely spans several sessions, so counting all of it would let
  /// a session that has heard nothing report the previous one's repeaters.
  /// A null start means no session is running, which counts as none.
  static int countUniqueRepeatersHeard(
    List<SiriHeardIdentity> heard,
    DateTime? sessionStartedAt,
  ) {
    if (sessionStartedAt == null) return 0;
    return heard
        .where((item) => !item.observedAt.isBefore(sessionStartedAt))
        .map((item) => item.key)
        .toSet()
        .length;
  }

  static String _identityKey(_SiriObservationCandidate candidate) =>
      '${candidate.identity?.toUpperCase() ?? ''}|'
      '${candidate.displayId.toUpperCase()}';

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
          id: repeaterEntityId(repeater),
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

/// The two views of the same heard history the snapshot needs.
///
/// [observations] is what ships to the watch and to Siri, bounded so the App
/// Group payload stays small. [distinctHeard] is the unbounded roll-up used for
/// counting, so a long session's total is not silently capped at that bound.
class SiriRecentHeard {
  const SiriRecentHeard({
    required this.observations,
    required this.distinctHeard,
  });

  /// Newest first, capped at [SiriSnapshotBuilder.maximumObservations].
  final List<SiriRepeaterObservation> observations;

  /// One entry per distinct repeater, carrying its most recent sighting.
  final List<SiriHeardIdentity> distinctHeard;
}

/// One distinct repeater heard, reduced to what the session count reads.
///
/// Deliberately not a [SiriRepeaterObservation]: this list is unbounded, it is
/// rebuilt on every snapshot publish, and nothing downstream reads a name, a
/// signal figure or a distance from it. Resolving those (a haversine per row)
/// for a number that only needs distinct identities was pure waste.
class SiriHeardIdentity {
  const SiriHeardIdentity({required this.key, required this.observedAt});

  /// The repeater's entity id, or `unresolved:<hex>` when the catalogue and
  /// the rest of the heard set both fail to claim the hash.
  final String key;

  final DateTime observedAt;
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
