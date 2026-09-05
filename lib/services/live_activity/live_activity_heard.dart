import '../../providers/app_state_provider.dart' show OverlayPingType;
import '../external_surfaces/geo/external_surface_geo_builder.dart';
import 'live_activity_models.dart';

/// The Live Activity's heard rows, read from the map's Top Heard box.
///
/// One source for the map, the watch and the Live Activity: [top] is the
/// latest ping's top three by SNR exactly as the map overlay stores them, and
/// [rxSlot] the best passive observation of the current interval. The order is
/// the map's too, ping rows first and the RX row trailing, never a global SNR
/// sort, so the card's first rows are always the box's first rows.
///
/// The one place this departs from the map is a repeater that is both a ping
/// row and the RX slot: the map draws it twice, this returns it once, because
/// the SwiftUI `ForEach` on the card identifies rows by id and cannot draw the
/// same id twice.
///
/// "Current" means refreshed since the latest send, [cycleStartedAt]. A ping
/// that hears nothing leaves the box alone, so its rows come back here marked
/// not current and the card dims them as last heard instead of wiping them.
/// A fresh RX observation during such a cycle is the only current thing, so it
/// is shown on its own.
({List<LiveActivityRepeater> repeaters, int totalCount, bool isCurrent})
    buildLiveActivityHeard({
  required List<({String repeaterId, double snr, OverlayPingType type})> top,
  required int topTotalCount,
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
  final includeTop = !hasCurrent || topIsCurrent;
  final includeRx = !hasCurrent || rxIsCurrent;

  final repeaters = <LiveActivityRepeater>[];
  final shown = <String>{};

  if (includeTop) {
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

  var totalCount = includeTop ? topTotalCount : 0;
  if (includeRx && rxSlot != null && rxSlot.snr.isFinite) {
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
    final pingHeardIt = top.any((row) => row.repeaterId.toUpperCase() == id);
    if (!pingHeardIt) totalCount++;
  }
  if (totalCount < repeaters.length) totalCount = repeaters.length;

  return (
    repeaters: List<LiveActivityRepeater>.unmodifiable(repeaters),
    totalCount: totalCount,
    isCurrent: hasCurrent,
  );
}
