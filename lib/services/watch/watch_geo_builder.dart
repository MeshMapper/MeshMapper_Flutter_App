import '../../models/log_entry.dart';
import '../../models/ping_data.dart';
import '../../models/repeater.dart';
import '../../providers/app_state_provider.dart' show OverlayPingType;
import '../../utils/ping_colors.dart';
import 'watch_models.dart';

/// Pure builders for the geographic half of a [WatchSnapshot].
///
/// Kept free of provider and platform dependencies so the caps, decimation,
/// and colour resolution can be unit-tested directly — those are exactly the
/// rules that would otherwise only fail on a wrist, in a car, at speed.
class WatchGeoBuilder {
  WatchGeoBuilder._();

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

  static WatchColor _txPingColor(TxPing ping) {
    final success = ping.heardRepeaters.isNotEmpty;
    final hasDirectEcho =
        ping.heardRepeaters.any((repeater) => repeater.pathHops == null);
    final hasMultiHopOnly = !hasDirectEcho && success;
    // A multi-hop-only return is RX evidence, not proof that a repeater heard
    // the transmitter directly. This is the phone map's marker rule.
    return hasMultiHopOnly ? pingColor('rx', true) : pingColor('tx', success);
  }

  /// Outcome colour for the newest coverage event of any kind.
  ///
  /// Scanning the four bounded histories avoids constructing and sorting the
  /// map-marker list a second time merely to colour one dot.
  static WatchColor? latestPingColor({
    required List<TxPing> txPings,
    required List<RxPing> rxPings,
    required List<DiscLogEntry> discLogEntries,
    required List<TraceLogEntry> traceLogEntries,
  }) {
    DateTime? latestAt;
    WatchColor? latestColor;

    void consider(DateTime at, WatchColor color) {
      if (latestAt == null || at.isAfter(latestAt!)) {
        latestAt = at;
        latestColor = color;
      }
    }

    for (final ping in txPings) {
      consider(ping.timestamp, _txPingColor(ping));
    }
    for (final ping in rxPings) {
      consider(ping.timestamp, pingColor('rx', true));
    }
    for (final entry in discLogEntries) {
      consider(
        entry.timestamp,
        pingColor('disc', entry.discoveredNodes.isNotEmpty),
      );
    }
    for (final entry in traceLogEntries) {
      consider(entry.timestamp, pingColor('trace', entry.success));
    }
    return latestColor;
  }

  /// Colour for a repeater pin, matching the iOS map's `_repeaterStatusColor`.
  static WatchColor repeaterColor(Repeater repeater) {
    if (repeater.isDead) return WatchColor.fromColor(PingColors.repeaterDead);
    if (repeater.isNew) return WatchColor.fromColor(PingColors.repeaterNew);
    return WatchColor.fromColor(PingColors.repeaterActive);
  }

  /// Most recent pings, newest first, capped at [WatchWire.maxPings].
  ///
  /// Every coverage source is merged before the recency cap is applied.
  ///
  /// Applying the cap to source-ordered batches could let a busy TX history
  /// erase discovery or trace markers. Sorting the complete candidate set
  /// first makes the wire carry the latest drive history regardless of type.
  static List<WatchPing> buildPings({
    required List<TxPing> txPings,
    required List<RxPing> rxPings,
    required List<DiscLogEntry> discLogEntries,
    required List<TraceLogEntry> traceLogEntries,
    int cap = WatchWire.maxPings,
  }) {
    final pings = <WatchPing>[];

    // Identity must not depend on a marker's position in its source list.
    // These histories insert at the front and trim from the back, so a
    // positional id renames every surviving marker whenever one arrives, and
    // SwiftUI then tears down and rebuilds all sixty annotations to show one
    // new dot. Timestamps are intrinsic to the event and survive both.
    final seen = <String, int>{};
    String stableId(String kind, DateTime at) {
      final base = '$kind-${at.millisecondsSinceEpoch}';
      final n = seen.update(base, (v) => v + 1, ifAbsent: () => 0);
      // Two events of one kind inside the same millisecond are the only case
      // needing a discriminator, and it stays put because it counts within the
      // colliding group rather than across the whole list.
      return n == 0 ? base : '$base~$n';
    }

    for (final tx in txPings) {
      pings.add(WatchPing(
        id: stableId('tx', tx.timestamp),
        lat: tx.latitude,
        lon: tx.longitude,
        kind: 'tx',
        color: _txPingColor(tx),
        at: tx.timestamp,
      ));
    }

    for (final rx in rxPings) {
      pings.add(WatchPing(
        id: stableId('rx', rx.timestamp),
        lat: rx.latitude,
        lon: rx.longitude,
        kind: 'rx',
        color: pingColor('rx', true),
        at: rx.timestamp,
      ));
    }

    for (final entry in discLogEntries) {
      pings.add(WatchPing(
        id: stableId('disc', entry.timestamp),
        lat: entry.latitude,
        lon: entry.longitude,
        kind: 'disc',
        color: pingColor('disc', entry.discoveredNodes.isNotEmpty),
        at: entry.timestamp,
      ));
    }

    for (final entry in traceLogEntries) {
      pings.add(WatchPing(
        id: stableId('trace', entry.timestamp),
        lat: entry.latitude,
        lon: entry.longitude,
        kind: 'trace',
        color: pingColor('trace', entry.success),
        at: entry.timestamp,
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
    final heardRepeaters = resolveUniqueHexPrefixes(
      repeaters: repeaters,
      prefixes: heardThisCycle,
    ).values.map((repeater) => repeater.id).toSet();

    if (lat != null && lon != null) {
      // Distance is computed once per repeater rather than inside the
      // comparator: this runs on every rebuild during an active session, and
      // a zone can hold hundreds of repeaters.
      final ranked = located
          .map((r) => (
                repeater: r,
                distance: WatchWire.distanceMeters(lat, lon, r.lat, r.lon),
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
              hexId: r.hexId,
              name: r.name,
              lat: r.lat,
              lon: r.lon,
              color: repeaterColor(r),
              heardThisCycle: heardRepeaters.contains(r.id),
            ))
        .toList();
  }

  /// Resolve path-hash prefixes only when the full repeater catalogue proves
  /// the match unique. Applying this before the wrist's nearest-20 cap matters:
  /// a second matching repeater outside that cap still makes a line or ring a
  /// guess, and a confidently wrong relationship is worse than none.
  static Map<String, Repeater> resolveUniqueHexPrefixes({
    required List<Repeater> repeaters,
    required Iterable<String> prefixes,
  }) {
    final normalized = prefixes
        .map((prefix) => prefix.toUpperCase())
        .where((prefix) => prefix.isNotEmpty)
        .toSet();
    final resolved = <String, Repeater>{};

    for (final length in normalized.map((prefix) => prefix.length).toSet()) {
      final index = indexByHexPrefix(repeaters, length);
      for (final prefix
          in normalized.where((prefix) => prefix.length == length)) {
        final repeater = index[prefix];
        if (repeater != null) resolved[prefix] = repeater;
      }
    }
    return resolved;
  }

  /// Resolve one identifier to a repeater, or null when it is not unambiguous.
  ///
  /// Tries exact identity first — the catalogue's short ID, its hex ID, or the
  /// hex truncated to the zone's hop width, which is the form an overlay row is
  /// labelled with — and only then a unique prefix relation.
  ///
  /// **A repeater with no `hexId` is never a prefix candidate.** The API omits
  /// `hex_id` often enough that `Repeater.fromJson` defaults it to the empty
  /// string, and `id.startsWith('')` is true for every id, so a single such
  /// entry silently made every prefix lookup ambiguous and every name vanish.
  static Repeater? resolveRepeater({
    required List<Repeater> repeaters,
    required String id,
    int? hopBytes,
  }) {
    final needle = id.toUpperCase();
    if (needle.isEmpty) return null;

    final exact = repeaters.where((repeater) {
      return repeater.id.toUpperCase() == needle ||
          repeater.hexId.toUpperCase() == needle ||
          repeater.displayHexId(overrideHopBytes: hopBytes).toUpperCase() ==
              needle;
    }).toList(growable: false);
    if (exact.length == 1) return exact.single;
    if (exact.isNotEmpty || needle.length < 2) return null;

    final prefixed = repeaters.where((repeater) {
      final hexId = repeater.hexId.toUpperCase();
      if (hexId.isEmpty) return false;
      return hexId.startsWith(needle) || needle.startsWith(hexId);
    }).toList(growable: false);
    return prefixed.length == 1 ? prefixed.single : null;
  }

  /// Resolve overlay display hashes to repeaters, preferring the fuller
  /// identity the ping actually carried.
  ///
  /// A path hash is 1–3 bytes, so in a busy zone it routinely matches several
  /// repeaters and [resolveUniqueHexPrefixes] correctly refuses to name any of
  /// them. But the phone often knows exactly who answered: a discovery response
  /// carries the responder's full 64-character public key, and a trace carries
  /// its 4-byte target. Resolving from the truncated hash threw that away, and
  /// left the wrist reading "Name unresolved" for a node the phone could have
  /// named precisely.
  ///
  /// [identities] maps a display hash to the longest identity known for the row
  /// shown under it. It must describe the **current** rows only: a hash that
  /// meant one repeater in a discovery response says nothing about who a later
  /// TX echo under the same hash was, and carrying it over would turn a refusal
  /// to guess into a confident wrong answer.
  ///
  /// Uniqueness is still required. A longer identity makes a collision
  /// vanishingly unlikely rather than impossible, and a confidently wrong name
  /// stays worse than none.
  static Map<String, Repeater> resolveOverlayRepeaters({
    required List<Repeater> repeaters,
    required Iterable<String> displayIds,
    Map<String, String> identities = const {},
  }) {
    final resolved = <String, Repeater>{};
    final unresolved = <String>[];

    for (final rawId in displayIds) {
      final displayId = rawId.toUpperCase();
      if (displayId.isEmpty) continue;

      final identity = identities[displayId]?.toUpperCase();
      if (identity == null || identity.isEmpty) {
        unresolved.add(displayId);
        continue;
      }

      // Both values are the leading hex of the same public key, so whichever
      // is shorter is a prefix of the other.
      final matches = repeaters.where((repeater) {
        final hexId = repeater.hexId.toUpperCase();
        if (hexId.isEmpty) return false;
        return hexId.startsWith(identity) || identity.startsWith(hexId);
      }).toList(growable: false);

      if (matches.length == 1) {
        resolved[displayId] = matches.single;
      } else {
        // No match at all means the catalogue simply has no hex for this
        // repeater; more than one means the fuller identity did not help.
        // Either way the ordinary prefix rules get their turn.
        unresolved.add(displayId);
      }
    }

    resolved.addAll(resolveUniqueHexPrefixes(
      repeaters: repeaters,
      prefixes: unresolved,
    ));
    return resolved;
  }

  /// Dot colour for an overlay row, mirroring `_overlayTypeColor` on the map.
  static WatchColor overlayTypeColor(OverlayPingType type) => switch (type) {
        OverlayPingType.tx => WatchColor.fromColor(PingColors.txSuccess),
        OverlayPingType.disc => WatchColor.fromColor(PingColors.discSuccess),
        OverlayPingType.trace => WatchColor.fromColor(PingColors.traceSuccess),
        OverlayPingType.rx => WatchColor.fromColor(PingColors.rx),
      };

  /// SNR quality colour shared by every native glance surface.
  static WatchColor snrColor(double snr) =>
      WatchColor.fromColor(PingColors.snrColor(snr));

  /// The "Top Heard" overlay rows: up to three top-SNR repeaters from the
  /// latest ping, then the current RX slot.
  ///
  /// Order is deliberate rather than a global SNR sort — it matches the map
  /// overlay, where the RX slot is a distinct trailing row rather than a
  /// competitor for the top three.
  static List<WatchHeardNode> buildHeard({
    required List<({String repeaterId, double snr, OverlayPingType type})> top,
    ({String repeaterId, double snr})? rxSlot,
    required Map<String, Repeater> repeaterByHex,
    required DateTime? topAt,
    required DateTime? rxAt,
    double? lat,
    double? lon,
  }) {
    final rows = <WatchHeardNode>[];

    // Missing time means the provider cannot truthfully say when this set was
    // heard. Omitting such a row is safer than presenting a plausible lie in
    // Node Detail; every production mutation records its timestamp atomically.
    for (final entry in top.where((_) => topAt != null)) {
      rows.add(_row(
        id: entry.repeaterId,
        snr: entry.snr,
        type: entry.type,
        repeaterByHex: repeaterByHex,
        at: topAt!,
        lat: lat,
        lon: lon,
      ));
    }

    if (rxSlot != null && rxAt != null) {
      rows.add(_row(
        id: rxSlot.repeaterId,
        snr: rxSlot.snr,
        type: OverlayPingType.rx,
        repeaterByHex: repeaterByHex,
        at: rxAt,
        lat: lat,
        lon: lon,
      ));
    }

    return rows.length > WatchWire.maxHeard
        ? rows.sublist(0, WatchWire.maxHeard)
        : rows;
  }

  static WatchHeardNode _row({
    required String id,
    required double snr,
    required OverlayPingType type,
    required Map<String, Repeater> repeaterByHex,
    required DateTime at,
    double? lat,
    double? lon,
  }) {
    final hex = id.toUpperCase();
    final repeater = repeaterByHex[hex];

    double? distance;
    if (lat != null &&
        lon != null &&
        repeater != null &&
        repeater.hasLocation) {
      distance = WatchWire.distanceMeters(lat, lon, repeater.lat, repeater.lon);
    }

    return WatchHeardNode(
      id: hex,
      // Null rather than a guess: a short path hash can match several
      // repeaters, and a confidently wrong name is worse than none.
      name: repeater?.name,
      snr: snr,
      at: at,
      distanceM: distance,
      snrColor: snrColor(snr),
      typeColor: overlayTypeColor(type),
    );
  }

  /// Index repeaters by the hex prefix an overlay row would carry.
  ///
  /// Only unambiguous prefixes are kept: if two repeaters share the leading
  /// hex at that length, neither is resolvable, which is exactly the condition
  /// the app flags as ambiguous rather than papering over.
  static Map<String, Repeater> indexByHexPrefix(
    List<Repeater> repeaters,
    int length,
  ) {
    final counts = <String, int>{};
    final index = <String, Repeater>{};

    for (final repeater in repeaters) {
      if (repeater.hexId.length < length) continue;
      final prefix = repeater.hexId.substring(0, length).toUpperCase();
      counts[prefix] = (counts[prefix] ?? 0) + 1;
      index[prefix] = repeater;
    }

    index.removeWhere((prefix, _) => (counts[prefix] ?? 0) > 1);
    return index;
  }
}
