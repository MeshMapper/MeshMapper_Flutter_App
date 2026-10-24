import 'dart:async';
import 'dart:convert';

import 'package:hive/hive.dart';

import '../utils/debug_logger_io.dart';

/// Region border polygons as `/border` sends them: `{code, polygon}` maps.
typedef BorderPolygons = List<Map<String, dynamic>>;

/// Where the last border set per context survives an app restart.
abstract class BorderCacheStore {
  /// The polygons saved for [contextKey], or null when none were saved under
  /// that exact [borderHash].
  Future<BorderPolygons?> read(String contextKey, String borderHash);

  Future<void> write(
      String contextKey, String borderHash, BorderPolygons polygons);
}

/// Hive-backed [BorderCacheStore]. A lazy box, so a multi-megabyte group
/// border is only read from disk when a zone check asks for it, and one
/// entry per context, the oldest dropped past [maxContexts].
class HiveBorderCacheStore implements BorderCacheStore {
  static const String boxName = 'region_borders';
  static const int maxContexts = 4;

  LazyBox<dynamic>? _box;

  Future<LazyBox<dynamic>?> _open() async {
    if (_box != null && _box!.isOpen) return _box;
    try {
      _box = await Hive.openLazyBox(boxName)
          .timeout(const Duration(seconds: 5));
      return _box;
    } catch (e) {
      debugWarn('[BORDER] Border cache unavailable: $e');
      return null;
    }
  }

  @override
  Future<BorderPolygons?> read(String contextKey, String borderHash) async {
    try {
      final box = await _open();
      final entry = await box?.get(contextKey);
      if (entry is! Map || entry['hash'] != borderHash) return null;
      final decoded = json.decode(entry['json'] as String);
      if (decoded is! List) return null;
      return decoded
          .whereType<Map>()
          .map((p) => Map<String, dynamic>.from(p))
          .toList();
    } catch (e) {
      debugWarn('[BORDER] Border cache read failed: $e');
      return null;
    }
  }

  @override
  Future<void> write(
      String contextKey, String borderHash, BorderPolygons polygons) async {
    try {
      final box = await _open();
      if (box == null) return;
      await box.put(contextKey, {
        'hash': borderHash,
        'json': json.encode(polygons),
        'saved_at': DateTime.now().millisecondsSinceEpoch,
      });
      final keys = box.keys.toList();
      if (keys.length <= maxContexts) return;
      final savedAt = <dynamic, int>{};
      for (final key in keys) {
        final entry = await box.get(key);
        savedAt[key] = entry is Map ? (entry['saved_at'] as int? ?? 0) : 0;
      }
      keys.sort((a, b) => savedAt[a]!.compareTo(savedAt[b]!));
      await box.deleteAll(keys.take(keys.length - maxContexts));
    } catch (e) {
      debugWarn('[BORDER] Border cache write failed: $e');
    }
  }
}

/// Decides when the app asks `/border` for the region polygons.
///
/// Borders are display only, and a group's answer can run to megabytes, so:
/// one request at a time (the in-flight guard holds until the request has
/// really ended), at most one load per context and `border_hash`, a growing
/// pause after a failed or empty answer, and a cache keyed on the
/// `border_hash` that `/status` sends in its zone object (see
/// MeshMapper_Server/docs/APP_API.md). A server that sends no hash gets one
/// load per context.
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

  /// The context whose borders were last handed out, or null.
  String? get loadedKey => _loadedKey;

  bool get fetchInProgress => _inFlight;

  /// When the next request is allowed after a failure, or null.
  DateTime? get retryAt => _retryAt;

  /// Forget what is displayed (offline mode, out of zone). The disk cache and
  /// any running request stay.
  void forget() {
    _loadedKey = null;
    _loadedHash = null;
  }

  /// Polygons to display for [contextKey], or null when nothing changes.
  ///
  /// [fetch] makes the `/border` request and returns null on failure.
  /// [onStale] runs just before a request for a context other than the one
  /// displayed, so the caller can clear borders that no longer belong.
  Future<BorderPolygons?> ensure({
    required String contextKey,
    String? borderHash,
    required Future<BorderPolygons?> Function() fetch,
    void Function()? onStale,
  }) async {
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
      if (borderHash != null && _cache != null) {
        final cached = await _cache.read(contextKey, borderHash);
        if (cached != null && cached.isNotEmpty) {
          _markLoaded(contextKey, borderHash);
          debugLog('[BORDER] Using ${cached.length} cached polygon(s) for '
              '$contextKey (hash $borderHash)');
          return cached;
        }
      }

      final retryAt = _retryAt;
      if (retryAt != null && _now().isBefore(retryAt)) return null;

      if (_loadedKey != contextKey) onStale?.call();

      final result = await fetch();
      if (result == null || result.isEmpty) {
        final pause = backoffSchedule[
            _failures < backoffSchedule.length
                ? _failures
                : backoffSchedule.length - 1];
        _failures++;
        _retryAt = _now().add(pause);
        debugWarn('[BORDER] No polygons for $contextKey; next try in '
            '${pause.inMinutes} min');
        return null;
      }

      _markLoaded(contextKey, borderHash);
      if (borderHash != null) {
        await _cache?.write(contextKey, borderHash, result);
      }
      return result;
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
