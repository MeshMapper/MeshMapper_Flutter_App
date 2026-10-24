import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../utils/debug_logger_io.dart';

/// Region border polygons as `/border` sends them: `{code, polygon}` maps.
typedef BorderPolygons = List<Map<String, dynamic>>;

/// One `/border` answer.
class BorderAnswer {
  final BorderPolygons polygons;

  /// The body's top-level `border_hash`. The server sends it only when every
  /// polygon in the answer is real, so only an answer carrying it is saved
  /// to disk. Null on a degraded answer and on older servers.
  final String? borderHash;

  const BorderAnswer(this.polygons, {this.borderHash});
}

/// Whether [polygons] belong where the phone is: they must include
/// [zoneCode], and inside a group every code must be a member (or the zone
/// itself). A `/border` answer for another place, for instance from a fix
/// that moved on since `/status`, fails this and is never shown or saved.
bool bordersFitZone(
  BorderPolygons polygons, {
  required String zoneCode,
  List<String>? groupMembers,
}) {
  final codes = polygons
      .map((p) => p['code'])
      .whereType<String>()
      .map((c) => c.toUpperCase())
      .toSet();
  final zone = zoneCode.toUpperCase();
  if (!codes.contains(zone)) return false;
  if (groupMembers == null || groupMembers.isEmpty) return true;
  final allowed = {zone, ...groupMembers.map((m) => m.toUpperCase())};
  return codes.every(allowed.contains);
}

/// Where the last border set per context survives an app restart.
abstract class BorderCacheStore {
  /// The hash saved for [contextKey], or null. Cheap: never reads polygons.
  Future<String?> hashFor(String contextKey);

  /// The polygons saved for [contextKey], or null when none were saved under
  /// that exact [borderHash].
  Future<BorderPolygons?> read(String contextKey, String borderHash);

  Future<void> write(
      String contextKey, String borderHash, BorderPolygons polygons);
}

String _encodePolygons(BorderPolygons polygons) => json.encode(polygons);

BorderPolygons? _decodePolygons(String raw) {
  final decoded = json.decode(raw);
  if (decoded is! List) return null;
  return decoded
      .whereType<Map>()
      .map((p) => Map<String, dynamic>.from(p))
      .toList();
}

/// Hive-backed [BorderCacheStore], one entry per context, the oldest dropped
/// past [maxContexts].
///
/// The polygons (a group's run to megabytes) sit in a lazy box and are read
/// only on a hash match. The hash and save time per context sit in a small
/// index box held in memory, so checking for a hit and choosing what to
/// evict never touches the polygons. JSON work runs off the UI isolate.
class HiveBorderCacheStore implements BorderCacheStore {
  static const String boxName = 'region_borders';
  static const String indexBoxName = 'region_borders_index';
  static const int maxContexts = 4;

  final DateTime Function() _now;

  HiveBorderCacheStore({DateTime Function()? now})
      : _now = now ?? DateTime.now;

  LazyBox<dynamic>? _box;
  Box<dynamic>? _index;

  Future<bool> _open() async {
    if (_box != null && _box!.isOpen && _index != null && _index!.isOpen) {
      return true;
    }
    try {
      _box = await Hive.openLazyBox(boxName)
          .timeout(const Duration(seconds: 5));
      _index = await Hive.openBox(indexBoxName)
          .timeout(const Duration(seconds: 5));
      // Polygons with no index entry can never be served or evicted.
      final orphans =
          _box!.keys.where((k) => !_index!.containsKey(k)).toList();
      if (orphans.isNotEmpty) {
        await _box!.deleteAll(orphans);
        await _box!.compact();
      }
      return true;
    } catch (e) {
      debugWarn('[BORDER] Border cache unavailable: $e');
      return false;
    }
  }

  @override
  Future<String?> hashFor(String contextKey) async {
    try {
      if (!await _open()) return null;
      final entry = _index!.get(contextKey);
      final hash = entry is Map ? entry['hash'] : null;
      return hash is String ? hash : null;
    } catch (e) {
      debugWarn('[BORDER] Border cache index read failed: $e');
      return null;
    }
  }

  @override
  Future<BorderPolygons?> read(String contextKey, String borderHash) async {
    try {
      if (!await _open()) return null;
      final entry = await _box!.get(contextKey);
      if (entry is! Map || entry['hash'] != borderHash) return null;
      final raw = entry['json'];
      if (raw is! String) return null;
      return await compute(_decodePolygons, raw);
    } catch (e) {
      debugWarn('[BORDER] Border cache read failed: $e');
      return null;
    }
  }

  @override
  Future<void> write(
      String contextKey, String borderHash, BorderPolygons polygons) async {
    try {
      if (!await _open()) return;
      final box = _box!;
      final index = _index!;
      final encoded = await compute(_encodePolygons, polygons);
      final replaced = box.containsKey(contextKey);
      await box.put(contextKey, {'hash': borderHash, 'json': encoded});
      await index.put(contextKey, {
        'hash': borderHash,
        'saved_at': _now().millisecondsSinceEpoch,
      });

      var evicted = false;
      final keys = index.keys.toList();
      if (keys.length > maxContexts) {
        // A missing or malformed save time sorts oldest, so it is evicted
        // first instead of stopping eviction.
        int savedAt(dynamic key) {
          final entry = index.get(key);
          final value = entry is Map ? entry['saved_at'] : null;
          return value is int ? value : 0;
        }

        keys.sort((a, b) => savedAt(a).compareTo(savedAt(b)));
        final drop = keys.take(keys.length - maxContexts).toList();
        await index.deleteAll(drop);
        await box.deleteAll(drop);
        evicted = true;
      }
      // Hive appends, so a replaced or deleted multi-megabyte entry stays in
      // the file until compacted.
      if (replaced || evicted) await box.compact();
    } catch (e) {
      debugWarn('[BORDER] Border cache write failed: $e');
    }
  }
}

/// Decides when the app asks `/border` for the region polygons.
///
/// Borders are display only, and a group's answer can run to megabytes, so:
/// one request at a time (the in-flight guard holds until the request has
/// really ended), at most one load per context and `/status` `border_hash`,
/// a growing pause after a failed, empty or misplaced answer, and a disk
/// cache (see MeshMapper_Server/docs/APP_API.md). Only an answer whose body
/// carries its own `border_hash` is saved, under that hash; the `/status`
/// hash only decides whether the saved copy is still current. A server that
/// sends no hash gets one load per context.
class BorderLoader {
  /// Pause before asking again after the Nth failure in a row; the last
  /// entry repeats.
  static const List<Duration> backoffSchedule = [
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(minutes: 30),
  ];

  final BorderCacheStore? _cache;
  final DateTime Function() _now;

  BorderLoader({BorderCacheStore? cache, DateTime Function()? now})
      : _cache = cache,
        _now = now ?? DateTime.now;

  String? _loadedKey;
  String? _loadedHash;
  bool _inFlight = false;

  String? _failedKey;
  String? _failedHash;
  int _failures = 0;
  DateTime? _retryAt;

  /// (context, hash) pairs the disk cache is known not to hold, so a zone
  /// check during a backoff does not read it again.
  final Set<String> _knownMisses = {};

  /// The context whose borders were last handed out, or null.
  String? get loadedKey => _loadedKey;

  bool get fetchInProgress => _inFlight;

  /// When the next request is allowed after a failure, or null.
  DateTime? get retryAt => _retryAt;

  /// Forget what is displayed (offline mode, out of zone, borders cleared).
  /// The disk cache and any running request stay.
  void forget() {
    _loadedKey = null;
    _loadedHash = null;
  }

  /// Polygons to display for [contextKey], or null when nothing changes.
  ///
  /// [borderHash] is the `/status` zone hash. [fetch] makes the `/border`
  /// request and returns null on failure. [accept] rejects an answer that
  /// does not belong to the zone (see [bordersFitZone]); a rejected answer
  /// counts as a failure. [onStale] runs just before a request for a
  /// context other than the one displayed, so the caller can clear borders
  /// that no longer belong; the loader then counts nothing as displayed.
  Future<BorderPolygons?> ensure({
    required String contextKey,
    String? borderHash,
    required Future<BorderAnswer?> Function() fetch,
    bool Function(BorderPolygons polygons)? accept,
    void Function()? onStale,
  }) async {
    if (borderHash != null && borderHash.isEmpty) borderHash = null;
    if (_inFlight) return null;
    if (_loadedKey == contextKey && _loadedHash == borderHash) return null;

    if (_failedKey != contextKey || _failedHash != borderHash) {
      _failedKey = contextKey;
      _failedHash = borderHash;
      _failures = 0;
      _retryAt = null;
    }

    _inFlight = true;
    try {
      final cache = _cache;
      final missKey = '$contextKey\n$borderHash';
      if (borderHash != null &&
          cache != null &&
          !_knownMisses.contains(missKey)) {
        BorderPolygons? cached;
        if (await cache.hashFor(contextKey) == borderHash) {
          cached = await cache.read(contextKey, borderHash);
        }
        if (cached != null && cached.isNotEmpty) {
          _markLoaded(contextKey, borderHash);
          debugLog('[BORDER] Using ${cached.length} cached polygon(s) for '
              '$contextKey (hash $borderHash)');
          return cached;
        }
        _knownMisses.add(missKey);
      }

      final retryAt = _retryAt;
      if (retryAt != null && _now().isBefore(retryAt)) return null;

      if (_loadedKey != contextKey) {
        // Whatever was displayed belongs elsewhere and is cleared here, so
        // a later return to that context must load it again.
        forget();
        onStale?.call();
      }

      final answer = await fetch();
      final polygons = answer?.polygons;
      String? problem;
      if (polygons == null || polygons.isEmpty) {
        problem = 'No polygons';
      } else if (accept != null && !accept(polygons)) {
        problem = 'Polygons for another place';
      }
      if (problem != null) {
        final pause = backoffSchedule[
            _failures < backoffSchedule.length
                ? _failures
                : backoffSchedule.length - 1];
        _failures++;
        _retryAt = _now().add(pause);
        debugWarn('[BORDER] $problem for $contextKey; next try in '
            '${pause.inMinutes} min');
        return null;
      }

      _markLoaded(contextKey, borderHash);
      final bodyHash = answer!.borderHash;
      if (bodyHash != null && bodyHash.isNotEmpty && cache != null) {
        await cache.write(contextKey, bodyHash, polygons!);
        _knownMisses.remove('$contextKey\n$bodyHash');
      }
      return polygons;
    } finally {
      _inFlight = false;
    }
  }

  void _markLoaded(String contextKey, String? borderHash) {
    _loadedKey = contextKey;
    _loadedHash = borderHash;
    _failures = 0;
    _retryAt = null;
  }
}
