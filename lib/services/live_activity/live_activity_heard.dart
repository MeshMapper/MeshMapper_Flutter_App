import '../../providers/app_state_provider.dart' show OverlayPingType;
import '../external_surfaces/geo/external_surface_geo_builder.dart';
import 'live_activity_models.dart';

/// The Live Activity's heard rows, read from the map's Top Heard box.
///
/// One source for the map, the watch and the Live Activity: [top] is the first
/// three of the latest ping's rows by SNR, in the order the map overlay stores
/// them (the in-app box may show more of that list), and [rxSlot] the best
/// passive observation of the current interval. The order is the map's too,
/// ping rows first and the RX row trailing, never a global SNR sort, so the
/// card's first rows are always the box's first rows.
///
/// The one place this departs from the map is a repeater that is both a ping
/// row and the RX slot: the map draws it twice, this returns it once, because
/// the SwiftUI `ForEach` on the card identifies rows by id and cannot draw the
/// same id twice.
///
/// "Current" means refreshed since the latest send, [cycleStartedAt].
/// [cycleStartedAt] is advanced at window close (not at ping send), so the
/// previous cycle's results stay visible while the new window listens. A ping
/// that hears nothing shows no rows at all: the card is empty rather than
/// dimmed, so a silent ping never reads as an old result left on screen.
/// A fresh RX observation during such a cycle is the only current thing, so it
/// is shown on its own.
///
/// [topHeardIds] is every repeater the latest ping heard (upper-case display
/// IDs), not only the [top] rows shown. The "HEARD NOW" total counts them, plus
/// the RX repeater only when the ping did not hear it, so an RX repeater the
/// ping ranked below the shown rows is not counted twice.
({List<LiveActivityRepeater> repeaters, int totalCount, bool isCurrent})
    buildLiveActivityHeard({
  required List<({String repeaterId, double snr, OverlayPingType type})> top,
  required Set<String> topHeardIds,
  required ({String repeaterId, double snr})? rxSlot,
  required DateTime? topAt,
  required DateTime? rxAt,
  required DateTime? cycleStartedAt,
  required String? Function(String id) nameFor,
}) {
  final topIsCurrent = cycleStartedAt != null &&
      topAt != null &&
      !topAt.isBefore(cycleStartedAt);
  final rxIsCurrent =
      cycleStartedAt != null && rxAt != null && !rxAt.isBefore(cycleStartedAt);
  final hasCurrent = topIsCurrent || rxIsCurrent;

  if (!hasCurrent) {
    return (
      repeaters: const <LiveActivityRepeater>[],
      totalCount: 0,
      isCurrent: false,
    );
  }

  final repeaters = <LiveActivityRepeater>[];
  final shown = <String>{};

  if (topIsCurrent) {
    for (final row in top) {
      if (!row.snr.isFinite) continue;
      final id = row.repeaterId.toUpperCase();
      if (!shown.add(id)) continue;
      repeaters.add(LiveActivityRepeater(
        id: id,
        name: nameFor(id),
        snr: row.snr,
        typeColor: ExternalSurfaceGeoBuilder.overlayTypeColor(row.type),
        snrColor: ExternalSurfaceGeoBuilder.snrColor(row.snr),
      ));
    }
  }

  var totalCount = topIsCurrent ? topHeardIds.length : 0;
  if (rxIsCurrent && rxSlot != null && rxSlot.snr.isFinite) {
    final id = rxSlot.repeaterId.toUpperCase();
    if (shown.add(id)) {
      repeaters.add(LiveActivityRepeater(
        id: id,
        name: nameFor(id),
        snr: rxSlot.snr,
        typeColor:
            ExternalSurfaceGeoBuilder.overlayTypeColor(OverlayPingType.rx),
        snrColor: ExternalSurfaceGeoBuilder.snrColor(rxSlot.snr),
      ));
    }
    final pingCountedIt = topIsCurrent && topHeardIds.contains(id);
    if (!pingCountedIt) totalCount++;
  }
  if (totalCount < repeaters.length) totalCount = repeaters.length;

  return (
    repeaters: List<LiveActivityRepeater>.unmodifiable(repeaters),
    totalCount: totalCount,
    isCurrent: hasCurrent,
  );
}
