import '../models/repeater.dart';
import '../utils/repeater_collision.dart';

/// Immutable repeater cache value. AppStateProvider owns every replacement.
class RepeaterListState {
  final List<Repeater> repeaters;
  final String? zone;
  final String? preset;
  final DateTime? loadedAt;

  const RepeaterListState()
      : repeaters = const [],
        zone = null,
        preset = null,
        loadedAt = null;

  RepeaterListState._(
      List<Repeater> fetched, this.zone, this.preset, this.loadedAt)
      : repeaters = rcComputeExclusions(fetched);

  /// Clear incompatible markers immediately, before the next read completes.
  RepeaterListState forContext(String? currentZone, String? currentPreset) {
    if (loadedAt == null || (zone == currentZone && preset == currentPreset)) {
      return this;
    }
    return const RepeaterListState();
  }

  /// Failures and stale replies cannot replace a valid cache or revive an old
  /// region. Empty successful reads retain the existing refresh behavior.
  RepeaterListState afterFetch({
    required List<Repeater>? fetched,
    required String requestedZone,
    required String? requestedPreset,
    required String? currentZone,
    required String? currentPreset,
    required DateTime now,
  }) {
    final retained = forContext(currentZone, currentPreset);
    if (fetched == null ||
        fetched.isEmpty ||
        requestedZone != currentZone ||
        requestedPreset != currentPreset) {
      return retained;
    }
    return RepeaterListState._(fetched, requestedZone, requestedPreset, now);
  }
}
