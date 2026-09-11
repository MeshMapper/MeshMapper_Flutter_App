import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../utils/coverage_summary.dart';
import '../utils/debug_logger_io.dart';
import '../utils/mvt_cells.dart';

/// Smart Pinging's answer for one fix.
enum RecentCoverage {
  /// The cell has a bidir or disc result inside the window (server tile or
  /// this session). Auto mode skips the send.
  covered,

  /// The cell is known and has no such result, or the feature is inactive.
  /// Send.
  clear,

  /// No tile has loaded for this spot yet. Send.
  unknown,
}

/// Zoom of the tiles the service fetches. One z13 tile is about 4.9 km wide
/// at the equator and 3.5 km at 45 degrees: several minutes of driving per
/// fetch, and a filtered body of at most a few thousand cells.
const int kRecentCoverageZoom = 13;

/// Every tile within this distance of the fix is kept loaded, so the next
/// tile is fetched shortly before the phone crosses into it.
const double kRecentCoveragePrefetchMeters = 500.0;

/// A loaded tile is refetched after this long (the server's tile max-age).
const Duration kRecentCoverageTileTtl = Duration(minutes: 5);

/// A failed fetch is not retried sooner than this.
const Duration kRecentCoverageRetryAfter = Duration(seconds: 30);

/// Positions closer than this to the last evaluated one are ignored.
const double kRecentCoverageMoveThresholdMeters = 100.0;

/// Shape of [ApiService.fetchRecentCoverageTile]: tile bytes on 200, an
/// empty list on 204, null on failure.
typedef RecentTileFetch = Future<Uint8List?> Function({
  required String zone,
  required int x,
  required int y,
  required int gsize,
  required int days,
});

/// The z13 slippy tile containing a fix.
({int x, int y}) recentCoverageTile(double lat, double lon) =>
    _tileAt(lat, lon, kRecentCoverageZoom);

/// Every z13 tile under a box that reaches [meters] in each direction from
/// the fix, so 2 * [meters] across. It samples the four corners, which is
/// exact as long as the box is narrower than one tile (true of the 500 m
/// prefetch at z13 below about 78 degrees of latitude).
Set<({int x, int y})> recentCoverageTilesWithin(
    double lat, double lon, double meters) {
  final dLat = meters / 111000.0;
  final dLon = meters / (111000.0 * math.cos(lat * math.pi / 180.0));
  final tiles = <({int x, int y})>{};
  for (final la in [lat - dLat, lat + dLat]) {
    for (final lo in [lon - dLon, lon + dLon]) {
      tiles.add(_tileAt(la, lo, kRecentCoverageZoom));
    }
  }
  return tiles;
}

({int x, int y}) _tileAt(double lat, double lon, int z) {
  final n = 1 << z;
  var x = (((lon + 180.0) / 360.0) * n).floor();
  final latRad = lat * math.pi / 180.0;
  final t = math.tan(latRad);
  final asinh = math.log(t + math.sqrt(t * t + 1));
  var y = ((1.0 - asinh / math.pi) / 2.0 * n).floor();
  x = x < 0 ? 0 : (x >= n ? n - 1 : x);
  y = y < 0 ? 0 : (y >= n ? n - 1 : y);
  return (x: x, y: y);
}

double _metersBetween(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180.0;
  final p2 = lat2 * math.pi / 180.0;
  final dp = (lat2 - lat1) * math.pi / 180.0;
  final dl = (lon2 - lon1) * math.pi / 180.0;
  final a = math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

class _Tile {
  /// 'i,j' keys of the covered cells. Null until the first successful fetch.
  Set<String>? cells;
  DateTime? fetchedAt;
  DateTime? lastAttemptAt;
  bool loading = false;

  bool get loaded => cells != null;
}

/// Keeps the recently covered grid cells around the phone and answers
/// [isCovered] synchronously. See DEVELOPMENT.md "Smart Pinging".
///
/// Fail open by design: [RecentCoverage.unknown] is returned whenever the
/// answer is not known, and a fetch failure never clears a loaded tile.
class RecentCoverageService {
  RecentCoverageService({
    required RecentTileFetch fetchTile,
    DateTime Function()? now,
  })  : _fetchTile = fetchTile,
        _now = now ?? DateTime.now;

  final RecentTileFetch _fetchTile;
  final DateTime Function() _now;

  String? _zone;
  int _gridSize = 300;
  int _days = 14;
  String? _radioKey;
  bool _enabled = false;

  final Map<String, _Tile> _tiles = {}; // 'x/y'
  final Set<String> _sessionCells = {}; // 'i,j'

  /// Squares already reported as deferred this API session, on the fixed
  /// 300 m grid whatever the user's Coverage Grid setting. The server dedupes
  /// on the same grid per session; this keeps the queue from carrying a
  /// DEFER every interval tick from a parked car, and a Detailed-grid user
  /// from queueing nine per real square.
  final Set<String> _deferredCells = {}; // 'i,j' on the 300 m grid
  final List<({int x, int y})> _queue = [];
  bool _draining = false;
  ({double lat, double lon})? _lastEvaluated;

  /// True when the feature is on and a zone is known.
  bool get isActive => _enabled && _zone != null && _zone!.isNotEmpty;

  /// Loaded (successfully fetched) tiles. Test hook.
  int get loadedTileCount => _tiles.values.where((t) => t.loaded).length;

  /// Apply the effective settings. Any change of zone, grid, window or radio
  /// preset drops the cache, since the cells it holds answer a different
  /// question. [radioKey] is `radioFilterKey(...)` from
  /// `lib/utils/radio_filter.dart` (the fetch itself carries the filter
  /// through ApiService; this only decides when loaded tiles go stale).
  ///
  /// Called on every zone check (every 100 m while disconnected), so an
  /// identical reconfigure is silent: it logs only when the zone, grid,
  /// window, preset or the active state actually moved.
  void configure({
    required String? zone,
    required int gridSize,
    required int days,
    required bool enabled,
    String? radioKey,
  }) {
    final wasActive = isActive;
    final changed = zone != _zone ||
        gridSize != _gridSize ||
        days != _days ||
        radioKey != _radioKey;
    _zone = zone;
    _gridSize = gridSize;
    _days = days;
    _radioKey = radioKey;
    _enabled = enabled;
    if (changed || !isActive) {
      clear();
    }
    if (changed || isActive != wasActive) {
      debugLog(
          '[COVERAGE] Smart pinging ${isActive ? 'active' : 'inactive'}: zone=${zone ?? '-'} grid=${gridSize}m window=${days}d preset=${radioKey ?? 'any'} enabled=$enabled');
    }
  }

  /// Drop every tile, session mark and deferral mark.
  void clear() {
    _tiles.clear();
    _sessionCells.clear();
    _deferredCells.clear();
    _queue.clear();
    _lastEvaluated = null;
  }

  /// The covered cell of a result this session got (a heard TX, an answered
  /// discovery), so the phone does not wait for the server tile to catch up.
  void markCovered(double lat, double lon) {
    if (!isActive) return;
    final key = _cellKey(lat, lon);
    if (_sessionCells.add(key)) {
      debugLog('[COVERAGE] Session covered cell $key');
    }
  }

  /// Record that smart pinging held a ping on this fix's fixed 300 m square.
  /// True the first time the square is seen this session, so the caller
  /// queues one DEFER per square; false after. Not gated on [isActive]: by
  /// the time a deferral happens the lookup was active, and a stale answer
  /// here costs one extra DEFER the server drops anyway.
  bool markDeferred(double lat, double lon) =>
      _deferredCells.add(_cellKey300(lat, lon));

  /// Forget the deferral marks and nothing else. Called when the API session
  /// id changes under a kept queue (auto-reconnect that re-auths to a fresh
  /// session), because the server credits one square per session id.
  void clearDeferred() => _deferredCells.clear();

  /// Whether the cell under this fix is recently covered.
  RecentCoverage isCovered(double lat, double lon) {
    if (!isActive) return RecentCoverage.clear;
    final key = _cellKey(lat, lon);
    if (_sessionCells.contains(key)) return RecentCoverage.covered;
    final t = recentCoverageTile(lat, lon);
    final tile = _tiles['${t.x}/${t.y}'];
    if (tile == null || !tile.loaded) return RecentCoverage.unknown;
    return tile.cells!.contains(key)
        ? RecentCoverage.covered
        : RecentCoverage.clear;
  }

  /// Keep every tile within 500 m of the fix loaded and fresh. Cheap when the
  /// phone has not moved 100 m since the last call. Fetches run one at a
  /// time; the returned future completes when the queue drains.
  Future<void> onPosition(double lat, double lon) async {
    if (!isActive) return;
    final last = _lastEvaluated;
    if (last != null &&
        _metersBetween(last.lat, last.lon, lat, lon) <
            kRecentCoverageMoveThresholdMeters) {
      return;
    }
    _lastEvaluated = (lat: lat, lon: lon);

    final wanted =
        recentCoverageTilesWithin(lat, lon, kRecentCoveragePrefetchMeters);
    final wantedKeys = wanted.map((t) => '${t.x}/${t.y}').toSet();
    _tiles.removeWhere((key, _) => !wantedKeys.contains(key));
    _queue.removeWhere((t) => !wantedKeys.contains('${t.x}/${t.y}'));

    final now = _now();
    for (final t in wanted) {
      final key = '${t.x}/${t.y}';
      final tile = _tiles.putIfAbsent(key, _Tile.new);
      if (tile.loading || _queue.contains(t)) continue;
      final fetchedAt = tile.fetchedAt;
      final fresh = fetchedAt != null &&
          now.difference(fetchedAt) < kRecentCoverageTileTtl;
      if (fresh) continue;
      final attempt = tile.lastAttemptAt;
      final held = attempt != null &&
          now.difference(attempt) < kRecentCoverageRetryAfter;
      if (held) continue;
      _queue.add(t);
    }
    await _drain();
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final t = _queue.removeAt(0);
        final key = '${t.x}/${t.y}';
        final tile = _tiles[key];
        if (tile == null) continue; // evicted while queued
        final zone = _zone;
        if (zone == null) return;
        tile.loading = true;
        tile.lastAttemptAt = _now();
        try {
          final body = await _fetchTile(
              zone: zone, x: t.x, y: t.y, gsize: _gridSize, days: _days);
          if (!_tiles.containsKey(key)) continue; // evicted or cleared
          if (body == null) {
            debugWarn(
                '[COVERAGE] Recent tile $key unavailable, keeping ${tile.loaded ? 'the previous set' : 'nothing'}');
            continue;
          }
          final cells =
              body.isEmpty ? const <CoverageCell>[] : decodeCoverageCells(body);
          // The tile is asked for green and cyan only, so an honoured filter
          // cannot answer with anything else. A region server that predates
          // the f_* filters serves the whole cached tile with a 200 instead,
          // and taking those cells as covered would stop auto pings across
          // the region. Leave the tile unloaded so the lookup stays unknown
          // and the ping goes out. The retry hold above already applies.
          if (cells.any((c) => c.st > 2)) {
            debugWarn(
                '[COVERAGE] Recent tile $key came back unfiltered (a cell that is not green or cyan), ignoring it');
            continue;
          }
          tile.cells = cells.map((c) => '${c.i},${c.j}').toSet();
          tile.fetchedAt = _now();
          debugLog(
              '[COVERAGE] Recent tile $key loaded: ${tile.cells!.length} covered cells');
        } catch (e) {
          // The fetch is injected and the decode reads a foreign body, so
          // either can throw. This lane runs off a GPS listener during a
          // wardrive: it must never throw into its caller. Same outcome as a
          // null answer, including the retry hold already stamped above.
          debugWarn(
              '[COVERAGE] Recent tile $key failed, keeping ${tile.loaded ? 'the previous set' : 'nothing'}: $e');
        } finally {
          tile.loading = false;
        }
      }
    } finally {
      _draining = false;
    }
  }

  String _cellKey(double lat, double lon) {
    final steps = kCoverageGridSteps[_gridSize] ?? kCoverageGridSteps[300]!;
    final cell = GridCell.containing(lat, lon, steps[0], steps[1]);
    return '${cell.i},${cell.j}';
  }

  /// The cell key on the fixed 300 m grid, independent of [_gridSize].
  String _cellKey300(double lat, double lon) {
    final steps = kCoverageGridSteps[300]!;
    final cell = GridCell.containing(lat, lon, steps[0], steps[1]);
    return '${cell.i},${cell.j}';
  }
}
