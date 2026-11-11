import '../models/api_queue_item.dart';

/// Whether an uploaded item of [type] can change a coverage tile.
///
/// A DEFER is kept in a server table nothing renders, and a SCOPES is a
/// repeater's answer about its scopes, not a coverage row. Neither moves a
/// cell, so neither is worth a fresh-tile check.
bool changesCoverage(String type) => type != 'DEFER' && type != 'SCOPES';

/// What an uploaded batch asks of the post-upload fresh-tile check:
/// whether it arms one at all, and which fixes to add to the pending list
/// (at most [cap] in total, counting the [alreadyPending] ones).
({bool armsRefresh, List<List<double>> coords}) coverageRefreshFor(
  Iterable<ApiQueueItem> items, {
  required int alreadyPending,
  int cap = 16,
}) {
  var arms = false;
  final coords = <List<double>>[];
  for (final item in items) {
    if (!changesCoverage(item.type)) continue;
    arms = true;
    if (alreadyPending + coords.length >= cap) continue;
    coords.add([item.latitude, item.longitude]);
  }
  return (armsRefresh: arms, coords: coords);
}
