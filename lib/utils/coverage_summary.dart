import 'dart:math' as math;

import '../models/repeater.dart';

// Client-side coverage aggregation, ported from the web client (dev/index.php)
// so the app's cell GRID SUMMARY and repeater totals stay in parity with the web.
//
// Both views fetch raw coverage points (map_data / repeater_coverage, via
// app_coverage.php) and aggregate here — exactly as generateSummaryContent
// (:13345) and renderRepeaterChart (:14063) do in the browser.
//
// Coverage status codes: 1=BIDIR, 2=TX, 5=RX, 3=DEAD, 0=DROP, 6|7=DISC.

// --- token + coord helpers (ports of the web equivalents) -------------------

/// Matches `hex(?)(snr)[lat,lon]` repeater path tokens. Groups: 1=hex, 2=`?`,
/// 3=snr, 4=`lat,lon`. Mirrors the web regex used in both functions.
final RegExp _tokenRe =
    RegExp(r'([a-f0-9]+)(\?)?(?:\((.*?)\))?(?:\[(.*?)\])?', caseSensitive: false);
final RegExp _hexOnlyRe = RegExp(r'[^a-fA-F0-9]');
final RegExp _snrParenRe = RegExp(r'\(([\d.-]+)\)');
final RegExp _coordBracketRe = RegExp(r'\[([\d.-]+),([\d.-]+)\]');

double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0; // same earth radius as Leaflet map.distance + coordsWithin100m
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// Port of `coordsWithin100m` (`dev/index.php:6198`).
bool _within100m(double lat1, double lon1, double lat2, double lon2) =>
    _haversineMeters(lat1, lon1, lat2, lon2) <= 100;

int _toInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? -999;
  return -999;
}

double? _toDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// The coverage grid cell containing a coordinate, plus helpers to snap the
/// cell-summary fetch to the cell centre and filter pings to the cell — so the
/// summary is identical no matter where inside the cell the user taps (parity
/// with the web's `lazyShowPingsAt`). Steps come from `kCoverageGridSteps`
/// (mvt_cells.dart), byte-identical to the server grid (dev/coverage_cells.php).
class GridCell {
  final int i;
  final int j;
  final double latStep;
  final double lonStep;
  const GridCell(this.i, this.j, this.latStep, this.lonStep);

  factory GridCell.containing(
          double lat, double lon, double latStep, double lonStep) =>
      GridCell(
          (lat / latStep).floor(), (lon / lonStep).floor(), latStep, lonStep);

  double get centerLat => (i + 0.5) * latStep;
  double get centerLon => (j + 0.5) * lonStep;

  bool contains(double lat, double lon) =>
      (lat / latStep).floor() == i && (lon / lonStep).floor() == j;

  /// Keep only points whose own cell is this one (parses lat/lon from the raw map).
  List<Map<String, dynamic>> filter(List<Map<String, dynamic>> points) {
    return points.where((p) {
      final la = _toDouble(p['lat']);
      final lo = _toDouble(p['lon']);
      return la != null && lo != null && contains(la, lo);
    }).toList();
  }

  // The coverage tile smears each ping over a (2·blob+1)² block of cells
  // (server `$blob`: Detailed 100 m = 1 → 3×3, Simplified 300 m = 0 → 1×1). So a
  // green cell can be coloured by a ping up to [blob] cells away. These two
  // helpers mirror the web's `lazyShowPingsAt` (dev/index.php) so the app fetches
  // and keeps exactly the pings that coloured the tapped cell — otherwise a
  // blob-painted neighbour cell falsely reads "no coverage data here". blob=0
  // collapses both back to the own-cell behaviour, unchanged.

  /// Metres from the cell centre to the far corner of the ±[blob] cell block —
  /// the fetch radius that reaches every ping whose blob can colour this cell.
  /// Floored at [minMeters] (the active gridSize) so blob=0 keeps the old radius.
  double blobFetchRadiusMeters(int blob, double minMeters) {
    final latM = (blob + 0.5) * latStep * 111000;
    final lonM =
        (blob + 0.5) * lonStep * 111000 * math.cos(centerLat * math.pi / 180);
    final corner = math.sqrt(latM * latM + lonM * lonM).ceilToDouble() + 5;
    return math.max(corner, minMeters);
  }

  /// Keep the points whose blob covers this cell: own cell ±[blob] in each axis
  /// (blob=0 reduces to own-cell-only, i.e. [filter]).
  List<Map<String, dynamic>> filterWithinBlob(
      List<Map<String, dynamic>> points, int blob) {
    return points.where((p) {
      final la = _toDouble(p['lat']);
      final lo = _toDouble(p['lon']);
      if (la == null || lo == null) return false;
      return ((la / latStep).floor() - i).abs() <= blob &&
          ((lo / lonStep).floor() - j).abs() <= blob;
    }).toList();
  }

  /// The closed outer ring (`[lon, lat]` pairs, GeoJSON order) of the
  /// (2·[blob]+1)² block of cells centred on this cell — the 3×3 highlight
  /// block in Detailed (blob = 1), the single cell in Simplified (blob = 0).
  /// The cell itself is always the middle, so a tap highlights a block centred
  /// on the tapped tile (parity with the web's clicked-tile-centred highlight).
  List<List<double>> blockRing(int blob) {
    final minLat = (i - blob) * latStep;
    final maxLat = (i + blob + 1) * latStep;
    final minLon = (j - blob) * lonStep;
    final maxLon = (j + blob + 1) * lonStep;
    return [
      [minLon, minLat],
      [maxLon, minLat],
      [maxLon, maxLat],
      [minLon, maxLat],
      [minLon, minLat],
    ];
  }

  /// One closed ring (`[lon, lat]` pairs) per individual cell in the
  /// (2·[blob]+1)² block centred on this cell — nine cells in Detailed
  /// (blob = 1), one in Simplified (blob = 0). Used to fill the tapped footprint
  /// as a grid of bordered cells, matching the web's nine `L.rectangle`s.
  List<List<List<double>>> blockCellPolygons(int blob) {
    final rings = <List<List<double>>>[];
    for (var di = -blob; di <= blob; di++) {
      for (var dj = -blob; dj <= blob; dj++) {
        final minLat = (i + di) * latStep;
        final maxLat = (i + di + 1) * latStep;
        final minLon = (j + dj) * lonStep;
        final maxLon = (j + dj + 1) * lonStep;
        rings.add([
          [minLon, minLat],
          [maxLon, minLat],
          [maxLon, maxLat],
          [minLon, maxLat],
          [minLon, minLat],
        ]);
      }
    }
    return rings;
  }
}

/// The single dominant coverage `st` category (1..6) across [points], or null
/// when empty. Port of the web's `highlightSpotCoverage` colour pick: each ping
/// maps to a status bucket, and the highest-priority one present wins
/// (green < cyan < orange < purple < grey < red, i.e. the lowest st). Because
/// the caller passes only the pings whose blob covers the tapped cell, this is
/// the "intentional smear" — a green-looking neighbour repaints to the local
/// dominant when its green came from a ping outside the blob.
int? dominantCoverageStatus(List<Map<String, dynamic>> points) {
  int? best;
  for (final p in points) {
    final st = _pointStatusCategory(p);
    if (best == null || st < best) best = st;
  }
  return best;
}

/// A single ping's coverage `st` category (1=green, 2=cyan, 3=orange,
/// 4=purple, 5=grey, 6=red). Mirrors `highlightSpotCoverage` /
/// `coverageStatusColor`: status 1 (BIDIR) is green either way, so the
/// repeats check only documents the web's branch.
int _pointStatusCategory(Map<String, dynamic> p) {
  final status = _toInt(p['status']);
  final hr = p['heard_repeats'];
  final dh = p['direct_heard'];
  final hasRepeats = (hr is String && hr.isNotEmpty && hr != 'None') ||
      (dh is String && dh.isNotEmpty && dh != 'None');
  if (status == 1 && hasRepeats) return 1; // green
  if (status == 2) return 3; // orange (TX)
  if (status == 5) return 4; // purple (RX)
  if (status == 6 || status == 7) return 2; // cyan (DISC/TRACE)
  if (status == 1) return 1; // green (BIDIR)
  if (status == 3) return 5; // grey (dead)
  return 6; // red (drop / unknown)
}

// --- repeater lookup (ports repObj / repeaterByHex / repeaterByFullHex) ------

class _RepInfo {
  final String id; // short hex id, lowercased
  final String hexId; // full hex, cleaned + lowercased
  final double lat;
  final double lon;
  final int status; // enabled: 1 active, 2 ambiguous/excluded
  final bool hidden;
  const _RepInfo(this.id, this.hexId, this.lat, this.lon, this.status, this.hidden);
}

/// Indexes the loaded repeaters the same three ways the web does: by id
/// (`repeaterLocs`), by full hex (`repeaterByFullHex`), and by short-hex bucket
/// (`repeaterByHex`), plus `narrowCandidates`/`prefixLen` for token resolution.
class RepeaterLookup {
  final int prefixLen;
  final Map<String, _RepInfo> _byId = {};
  final Map<String, _RepInfo> _byFullHex = {};
  final Map<String, List<_RepInfo>> _byShortHex = {};

  RepeaterLookup._(this.prefixLen);

  /// [hopBytes] is the region path width (web `hopBytes`); `prefixLen = hopBytes*2`.
  factory RepeaterLookup.fromRepeaters(Iterable<Repeater> repeaters,
      {required int hopBytes}) {
    final prefixLen = math.max(2, hopBytes * 2);
    final lk = RepeaterLookup._(prefixLen);
    for (final r in repeaters) {
      // web adds enabled IN (1,2) to the lookup
      if (r.enabled != 1 && r.enabled != 2) continue;
      if (r.lat.isNaN || r.lon.isNaN) continue;
      // Web parity (index.php:10231 `if (rep.lat && rep.lon && rep.id)`): a 0
      // lat/lon is the "location not published" sentinel — exclude it, or MAX
      // DIST / max range would be computed to (0,0) (~8900 km from Ottawa).
      if (r.lat == 0 || r.lon == 0 || r.id.isEmpty) continue;
      final cleanHex = r.hexId.replaceAll(_hexOnlyRe, '').toLowerCase();
      final id = r.id.toLowerCase();
      // Web parity (index.php:10239): hidden only when the 🚫 marker is at the
      // start or end of the name — NOT anywhere in the middle.
      final hidden = r.name.startsWith('🚫') || r.name.endsWith('🚫');
      final info = _RepInfo(id, cleanHex, r.lat, r.lon, r.enabled, hidden);
      lk._byId[id] = info;
      final shortHex =
          cleanHex.length >= prefixLen ? cleanHex.substring(0, prefixLen) : cleanHex;
      if (shortHex.length >= 2) {
        (lk._byShortHex[shortHex] ??= <_RepInfo>[]).add(info);
        final firstByte = cleanHex.length >= 2 ? cleanHex.substring(0, 2) : '';
        if (firstByte.length == 2 && firstByte != shortHex) {
          (lk._byShortHex[firstByte] ??= <_RepInfo>[]).add(info);
        }
      }
      if (cleanHex.isNotEmpty) lk._byFullHex[cleanHex] = info;
    }
    return lk;
  }

  /// Port of `narrowCandidates` (`dev/index.php:9709`): greedy narrowing on a
  /// longer id, backward-compat widening on a shorter id.
  List<_RepInfo> _narrowCandidates(List<_RepInfo> candidates, String id) {
    final idLower = id.toLowerCase();
    if (candidates.length > 1 && id.length > prefixLen) {
      final narrowed = candidates
          .where((rep) =>
              rep.hexId.length >= id.length &&
              rep.hexId.substring(0, id.length) == idLower)
          .toList();
      if (narrowed.isNotEmpty) return narrowed;
    }
    if (candidates.isEmpty && id.isNotEmpty && id.length < prefixLen) {
      final results = <_RepInfo>[];
      _byShortHex.forEach((key, reps) {
        if (key.length >= idLower.length &&
            key.substring(0, idLower.length) == idLower) {
          for (final rep in reps) {
            if (!results.contains(rep)) results.add(rep);
          }
        }
      });
      if (results.isNotEmpty) return results;
    }
    return candidates;
  }

  /// Resolve a token hex to candidate repeaters, mirroring the web order:
  /// full-hex, else narrowed short-hex bucket, else `repeaterLocs[id]`.
  List<_RepInfo> _candidatesFor(String rid) {
    final full = _byFullHex[rid];
    if (full != null) return <_RepInfo>[full];
    final short = rid.length >= prefixLen ? rid.substring(0, prefixLen) : rid;
    final cands = _narrowCandidates(_byShortHex[short] ?? const <_RepInfo>[], rid);
    if (cands.isEmpty) {
      final loc = _byId[rid];
      if (loc != null) return <_RepInfo>[loc];
    }
    return cands;
  }

  /// Resolve a token hex (any width — old narrow OR new 4-byte-capped) to its single repeater,
  /// or null. Mirrors the web `repObjForToken`: full-hex, else a UNIQUE short-hex/narrowed match,
  /// else the legacy id key. Tokens normalize WIDER than `repeater.id`, so a bare `_byId[token]`
  /// lookup misses — the cell MAX-DIST must resolve by full-hex.
  _RepInfo? _repForToken(String rid) {
    final full = _byFullHex[rid];
    if (full != null) return full;
    final short = rid.length >= prefixLen ? rid.substring(0, prefixLen) : rid;
    final cands = _narrowCandidates(_byShortHex[short] ?? const <_RepInfo>[], rid);
    if (cands.length == 1) return cands.first;
    return _byId[rid];
  }
}

// --- cell GRID SUMMARY -------------------------------------------------------

/// Aggregated stats for a clicked map cell. Port of `generateSummaryContent`
/// (`dev/index.php:13345-13521`).
class GridSummary {
  final int total;
  final int bidir;
  final int tx;
  final int rx;
  final int disc;
  final int dead;
  final int drop;
  final double? avgSnr; // null = N/A
  final int? avgNoise; // rounded dBm; null = N/A
  final double? maxDistMeters; // null = N/A

  const GridSummary({
    required this.total,
    required this.bidir,
    required this.tx,
    required this.rx,
    required this.disc,
    required this.dead,
    required this.drop,
    required this.avgSnr,
    required this.avgNoise,
    required this.maxDistMeters,
  });

  /// Signal bucket driving the AVG SNR icon/colour: `good` (>5), `medium` (>=-1),
  /// `bad` (<-1), or null when AVG SNR is N/A (web thresholds at `:13456`).
  String? get snrBucket {
    if (avgSnr == null) return null;
    final v = double.parse(avgSnr!.toStringAsFixed(1));
    if (v > 5) return 'good';
    if (v >= -1) return 'medium';
    return 'bad';
  }

  factory GridSummary.fromPoints(
      List<Map<String, dynamic>> points, RepeaterLookup lookup) {
    int bidir = 0, tx = 0, rx = 0, dead = 0, drop = 0, disc = 0;
    double totalSnr = 0;
    int countSnr = 0;
    double totalNoise = 0;
    int countNoise = 0;
    double maxDist = 0;

    for (final p in points) {
      final s = _toInt(p['status']);
      if (s == 1) {
        bidir++;
      } else if (s == 2) {
        tx++;
      } else if (s == 5) {
        rx++;
      } else if (s == 3) {
        dead++;
      } else if (s == 0) {
        drop++;
      } else if (s == 6 || s == 7) {
        disc++;
      }

      // SNR: local_snr, else max SNR parsed from heard_repeats "(x)" tokens.
      double? pingSnr = _toDouble(p['local_snr']);
      if (pingSnr == null) {
        final hr = p['heard_repeats'];
        if (hr is String && hr.isNotEmpty && hr != 'None') {
          double maxS = -999;
          bool found = false;
          for (final part in hr.split(',')) {
            final m = _snrParenRe.firstMatch(part);
            if (m != null) {
              final v = double.tryParse(m.group(1)!);
              if (v != null) {
                if (v > maxS) maxS = v;
                found = true;
              }
            }
          }
          if (found) pingSnr = maxS;
        }
      }
      if (pingSnr != null && !pingSnr.isNaN) {
        totalSnr += pingSnr;
        countSnr++;
      }

      // Noise.
      final nf = _toDouble(p['noisefloor']);
      if (nf != null && !nf.isNaN) {
        totalNoise += nf;
        countNoise++;
      }

      // Max range: token coords matched to a repeater (by id) within 100 m.
      final ids = <String>[];
      final pLat = _toDouble(p['lat']);
      final pLon = _toDouble(p['lon']);

      void collectFrom(String text) {
        for (final m in _tokenRe.allMatches(text)) {
          if (m.group(2) == '?' || m.group(4) == null) continue;
          final c = m.group(4)!.split(',');
          if (c.length < 2) continue;
          final tLat = double.tryParse(c[0]);
          final tLon = double.tryParse(c[1]);
          final rID = m.group(1)!.toLowerCase();
          final loc = lookup._repForToken(rID);
          if (loc != null &&
              tLat != null &&
              tLon != null &&
              _within100m(loc.lat, loc.lon, tLat, tLon)) {
            ids.add(m.group(1)!);
          }
        }
      }

      final hr = p['heard_repeats'];
      if (hr is String && hr.isNotEmpty && hr != 'None') collectFrom(hr);

      final via = p['via'];
      if (via is String &&
          via.isNotEmpty &&
          via != 'Direct' &&
          !via.contains('Wardriving')) {
        final cleanVia = via
            .replaceAll(RegExp(r'\bDirect\b', caseSensitive: false), '')
            .replaceAll(RegExp(r'\bNone\b', caseSensitive: false), '')
            .replaceAll(RegExp(r'\bN/A\b', caseSensitive: false), '');
        collectFrom(cleanVia);
      }

      // DISC full-id check via public_key.
      if (s == 6 && p['public_key'] is String) {
        final pkClean =
            (p['public_key'] as String).replaceAll(_hexOnlyRe, '').toLowerCase();
        final targetRep = lookup._byFullHex[pkClean];
        if (targetRep != null) {
          final hrStr = hr is String ? hr : '';
          final cm = _coordBracketRe.firstMatch(hrStr);
          if (cm != null) {
            final tLat = double.tryParse(cm.group(1)!);
            final tLon = double.tryParse(cm.group(2)!);
            if (tLat != null &&
                tLon != null &&
                _within100m(targetRep.lat, targetRep.lon, tLat, tLon)) {
              ids.add(targetRep.id);
            }
          }
        }
      }

      for (final rID in ids) {
        final loc = lookup._repForToken(rID.toLowerCase());
        if (loc == null) continue;
        if (loc.status == 2 || loc.hidden) continue;
        if (pLat != null && pLon != null) {
          final d = _haversineMeters(pLat, pLon, loc.lat, loc.lon);
          if (d > maxDist) maxDist = d;
        }
      }
    }

    return GridSummary(
      total: points.length,
      bidir: bidir,
      tx: tx,
      rx: rx,
      disc: disc,
      dead: dead,
      drop: drop,
      avgSnr: countSnr > 0 ? totalSnr / countSnr : null,
      avgNoise: countNoise > 0 ? (totalNoise / countNoise).round() : null,
      maxDistMeters: maxDist > 0 ? maxDist : null,
    );
  }
}

// --- per-repeater totals -----------------------------------------------------

/// Per-repeater BIDIR/TX/RX/DISC/DEAD counts + max range. Port of the attribution
/// in `renderRepeaterChart` (`dev/index.php:14063-14322`).
class RepeaterStats {
  final int bidir;
  final int tx;
  final int rx;
  final int disc;
  final int dead;
  final double? maxRangeMeters;

  const RepeaterStats({
    required this.bidir,
    required this.tx,
    required this.rx,
    required this.disc,
    required this.dead,
    required this.maxRangeMeters,
  });

  int get totalMatched => bidir + tx + rx + disc + dead;

  factory RepeaterStats.fromCoverage(
      List<Map<String, dynamic>> points, Repeater target, RepeaterLookup lookup,
      {bool disableDupLogic = false}) {
    final repId = target.id.toLowerCase();
    final repLat = target.lat;
    final repLon = target.lon;
    int bidir = 0, tx = 0, rx = 0, disc = 0, dead = 0;
    double maxRange = 0;

    bool tokenMatchesTarget(RegExpMatch m) {
      if (!disableDupLogic && m.group(2) == '?') return false;
      final rID = m.group(1)!.toLowerCase();
      final candidates = lookup._candidatesFor(rID);
      if (!candidates.any((c) => c.id == repId)) return false;
      final coords = m.group(4);
      if (coords != null) {
        final c = coords.split(',');
        if (c.length < 2) return false;
        final cLat = double.tryParse(c[0]);
        final cLon = double.tryParse(c[1]);
        return cLat != null &&
            cLon != null &&
            _within100m(repLat, repLon, cLat, cLon);
      }
      return disableDupLogic; // no coords: only valid when dup-logic disabled
    }

    for (final p in points) {
      final pLat = _toDouble(p['lat']);
      final pLon = _toDouble(p['lon']);
      if (pLat == null || pLon == null) continue;

      final status = _toInt(p['status']);
      final String type;
      if (status == 1) {
        type = 'BIDIR';
      } else if (status == 2) {
        type = 'TX';
      } else if (status == 5) {
        type = 'RX';
      } else if (status == 6 || status == 7) {
        type = 'DISC';
      } else if (status == 3) {
        type = 'DEAD';
      } else {
        continue; // DROP / unknown -> skip (matches web)
      }

      bool matched = false;

      final hr = p['heard_repeats'];
      if (hr is String && hr.isNotEmpty && hr != 'None') {
        for (final m in _tokenRe.allMatches(hr)) {
          if (tokenMatchesTarget(m)) matched = true;
        }
      }

      final via = p['via'];
      if (via is String &&
          via.isNotEmpty &&
          via != 'Direct' &&
          !via.contains('Wardriving')) {
        final cleanVia = via
            .replaceAll(RegExp(r'\bDirect\b', caseSensitive: false), '')
            .replaceAll(RegExp(r'\bNone\b', caseSensitive: false), '')
            .replaceAll(RegExp(r'\bN/A\b', caseSensitive: false), '');
        for (final m in _tokenRe.allMatches(cleanVia)) {
          if (tokenMatchesTarget(m)) matched = true;
        }
      }

      if (status == 6 && p['public_key'] is String) {
        final pk =
            (p['public_key'] as String).replaceAll(_hexOnlyRe, '').toLowerCase();
        final tr = lookup._byFullHex[pk];
        if (tr != null && tr.id == repId) {
          final hrStr = hr is String ? hr : '';
          final cm = _coordBracketRe.firstMatch(hrStr);
          if (cm != null) {
            final cLat = double.tryParse(cm.group(1)!);
            final cLon = double.tryParse(cm.group(2)!);
            if (cLat != null &&
                cLon != null &&
                _within100m(repLat, repLon, cLat, cLon)) {
              matched = true;
            }
          }
        }
      }

      if (matched) {
        switch (type) {
          case 'BIDIR':
            bidir++;
            break;
          case 'TX':
            tx++;
            break;
          case 'RX':
            rx++;
            break;
          case 'DISC':
            disc++;
            break;
          case 'DEAD':
            dead++;
            break;
        }
        final d = _haversineMeters(pLat, pLon, repLat, repLon);
        if (d > maxRange) maxRange = d;
      }
    }

    return RepeaterStats(
      bidir: bidir,
      tx: tx,
      rx: rx,
      disc: disc,
      dead: dead,
      maxRangeMeters: maxRange > 0 ? maxRange : null,
    );
  }
}
