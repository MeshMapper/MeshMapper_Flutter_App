import 'dart:async';
import 'dart:math' as math;

import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/debug_logger_io.dart';
import 'tile_cache_service.dart';

/// A pending download waiting in the FIFO queue.
class _QueuedDownload {
  final String name;
  final LatLngBounds bounds;
  final String styleUrl;
  final String styleName;
  final double minZoom;
  final double maxZoom;
  final int estBytes;
  final Completer<OfflineMapRegion?> completer;

  _QueuedDownload({
    required this.name,
    required this.bounds,
    required this.styleUrl,
    required this.styleName,
    required this.minZoom,
    required this.maxZoom,
    required this.estBytes,
    required this.completer,
  });
}

/// Metadata keys stored with each offline region.
class _MetaKeys {
  _MetaKeys._();
  static const name = 'name';
  static const styleName = 'styleName';
  static const createdAt = 'createdAt';

  /// Estimated size in bytes (rough heuristic based on tile count).
  static const estimatedBytes = 'estimatedBytes';
}

/// A user-friendly wrapper around a raw [OfflineRegion].
class OfflineMapRegion {
  final int id;
  final String name;
  final String styleName;
  final LatLngBounds bounds;
  final double minZoom;
  final double maxZoom;
  final DateTime createdAt;

  /// Heuristic size from tile count × 20 KB, captured at download time.
  /// Used as a fallback when the native SDK hasn't reported actual bytes yet.
  final int estimatedBytes;

  /// Real bytes consumed by this region as reported by the native MapLibre
  /// SDK (`MLNOfflinePack.progress.countOfTileBytesCompleted` on iOS,
  /// `OfflineRegionStatus.completedResourceSize` on Android). `null` when
  /// the native map hasn't reported a size for this region yet.
  final int? actualBytes;

  const OfflineMapRegion({
    required this.id,
    required this.name,
    required this.styleName,
    required this.bounds,
    required this.minZoom,
    required this.maxZoom,
    required this.createdAt,
    required this.estimatedBytes,
    this.actualBytes,
  });

  factory OfflineMapRegion.fromOfflineRegion(
    OfflineRegion region, {
    int? actualBytes,
  }) {
    final meta = region.metadata;
    return OfflineMapRegion(
      id: region.id,
      name: (meta[_MetaKeys.name] as String?) ?? 'Region ${region.id}',
      styleName: (meta[_MetaKeys.styleName] as String?) ?? 'Unknown',
      bounds: region.definition.bounds,
      minZoom: region.definition.minZoom,
      maxZoom: region.definition.maxZoom,
      createdAt:
          DateTime.tryParse((meta[_MetaKeys.createdAt] as String?) ?? '') ??
              DateTime.now(),
      // Platform channel JSON round-trip can return int as num, double, or
      // (on some Android paths) a stringified form. Tolerate all three.
      estimatedBytes: switch (meta[_MetaKeys.estimatedBytes]) {
        final num n => n.toInt(),
        final String s => int.tryParse(s) ?? 0,
        _ => 0,
      },
      actualBytes: actualBytes,
    );
  }

  /// Size to show in the UI — real bytes when the native SDK has reported
  /// them, falling back to the download-time estimate otherwise.
  int get sizeBytes => actualBytes ?? estimatedBytes;

  /// Human-readable size string.
  String get sizeDisplay {
    final b = sizeBytes;
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Short bounds description (e.g. "49.2°N, 123.1°W").
  String get boundsDisplay {
    final sw = bounds.southwest;
    final ne = bounds.northeast;
    final latCenter = (sw.latitude + ne.latitude) / 2;
    final lngCenter = (sw.longitude + ne.longitude) / 2;
    final latDir = latCenter >= 0 ? 'N' : 'S';
    final lngDir = lngCenter >= 0 ? 'E' : 'W';
    return '${latCenter.abs().toStringAsFixed(2)}°$latDir, '
        '${lngCenter.abs().toStringAsFixed(2)}°$lngDir';
  }
}

/// Manages offline map tile downloads, listing, deletion, and storage limits.
///
/// Lives at the app level (provided via [ChangeNotifierProvider] in main.dart)
/// so downloads continue when the user navigates away from the Offline Maps
/// screen. A system notification shows real-time progress.
///
/// Not available on web (maplibre_gl offline APIs are mobile-only).
class OfflineMapService extends ChangeNotifier {
  static const _storageLimitKey = 'offline_map_storage_limit_mb';
  static const int defaultStorageLimitMb = 500;
  static const int minStorageLimitMb = 50;
  static const int maxStorageLimitMb = 5000;

  // ── Notification constants ──
  static const String _notifChannelId = 'meshmapper_offline_maps';
  static const String _notifChannelName = 'Offline Map Downloads';
  static const int _progressNotifId = 889;
  static const int _completeNotifId = 890;

  final FlutterLocalNotificationsPlugin _notifPlugin =
      FlutterLocalNotificationsPlugin();
  bool _notifInitialized = false;

  // ── Region state ──
  List<OfflineMapRegion> _regions = [];
  List<OfflineMapRegion> get regions => List.unmodifiable(_regions);

  int _storageLimitMb = defaultStorageLimitMb;
  int get storageLimitMb => _storageLimitMb;
  int get storageLimitBytes => _storageLimitMb * 1024 * 1024;

  /// Actual on-disk cache.db size as reported by the native platform
  /// (MapLibre stores downloaded regions and ambient tiles in one SQLite
  /// file). Refreshed alongside [refreshRegions].
  int _totalCacheBytes = 0;

  /// Actual bytes used by downloaded regions alone (sum of per-region sizes
  /// from the native SDK). The difference between this and [_totalCacheBytes]
  /// is the ambient/auto-cached tile portion.
  int _downloadsBytes = 0;

  /// Total on-disk cache size (downloads + ambient, bytes).
  int get totalUsedBytes => _totalCacheBytes;

  /// Bytes attributed to explicit offline downloads.
  int get downloadsBytes => _downloadsBytes;

  /// Bytes attributed to tiles cached opportunistically while panning/zooming
  /// the map (total minus explicit downloads, clamped ≥ 0 because the two
  /// numbers come from different native queries and can briefly diverge).
  int get ambientBytes =>
      (_totalCacheBytes - _downloadsBytes).clamp(0, _totalCacheBytes);

  double get usageRatio {
    if (storageLimitBytes == 0) return 0;
    return (totalUsedBytes / storageLimitBytes).clamp(0.0, 1.0);
  }

  /// Ratio of the storage bar filled by each bucket. Both clamp to [0,1] and
  /// are computed against the limit so they visually add up against the same
  /// denominator as [usageRatio].
  double get downloadsRatio {
    if (storageLimitBytes == 0) return 0;
    return (_downloadsBytes / storageLimitBytes).clamp(0.0, 1.0);
  }

  double get ambientRatio {
    if (storageLimitBytes == 0) return 0;
    return (ambientBytes / storageLimitBytes).clamp(0.0, 1.0);
  }

  String get totalUsedDisplay => _formatBytes(totalUsedBytes);
  String get downloadsDisplay => _formatBytes(_downloadsBytes);
  String get ambientDisplay => _formatBytes(ambientBytes);
  String get storageLimitDisplay => '$_storageLimitMb MB';

  // ── Download state ──

  /// Currently active download progress (null if idle).
  double? _downloadProgress;
  double? get downloadProgress => _downloadProgress;

  String? _downloadingRegionName;
  String? get downloadingRegionName => _downloadingRegionName;

  bool get isDownloading => _downloadProgress != null;

  /// ID of the region currently being downloaded. Set right after MapLibre
  /// accepts the download; null when idle. Used by [cancelActiveDownload] to
  /// delete the partial region via `deleteOfflineRegion`.
  int? _activeRegionId;

  /// Completer tied to the currently-active download. Resolved when
  /// [_onDownloadEvent] sees Success or Error, or when the download is
  /// cancelled.
  Completer<OfflineMapRegion?>? _activeCompleter;

  /// Estimated total bytes for the currently-active download, used by the
  /// quota pre-check so queued jobs can't jointly bust the limit.
  int _activeEstBytes = 0;

  /// Rolling window of recent (timestamp, progress 0-1) samples used to
  /// compute smoothed download speed and ETA. Oldest-first. Cleared on
  /// download start/end/cancel.
  final List<({DateTime at, double progress})> _progressSamples = [];
  static const int _progressWindowSize = 5;

  /// Instantaneous download speed in bytes/sec, computed over the last few
  /// progress events. Null until at least two samples are available.
  double? get downloadBytesPerSecond {
    if (_progressSamples.length < 2 || _activeEstBytes <= 0) return null;
    final first = _progressSamples.first;
    final last = _progressSamples.last;
    final seconds = last.at.difference(first.at).inMilliseconds / 1000.0;
    if (seconds <= 0) return null;
    final deltaBytes = (last.progress - first.progress) * _activeEstBytes;
    if (deltaBytes <= 0) return null;
    return deltaBytes / seconds;
  }

  /// Estimated time remaining based on the current smoothed speed. Null if
  /// no speed data yet, or if the download is effectively stalled.
  /// Capped at 99 minutes to keep the display sane during warm-up wobbles.
  Duration? get downloadEta {
    final bps = downloadBytesPerSecond;
    final progress = _downloadProgress;
    if (bps == null || bps <= 0 || progress == null) return null;
    final remainingBytes = (1.0 - progress) * _activeEstBytes;
    if (remainingBytes <= 0) return Duration.zero;
    final seconds = (remainingBytes / bps).round();
    return Duration(seconds: seconds.clamp(0, 99 * 60));
  }

  /// FIFO queue of pending downloads. Drained one at a time after the
  /// current download finishes (or is cancelled).
  final List<_QueuedDownload> _queue = [];
  int get queueLength => _queue.length;

  String? _lastError;
  String? get lastError => _lastError;

  /// Read [lastError] and clear it. Use this in UI that displays the error
  /// once (banner, toast) so it doesn't linger after dismissal.
  String? consumeLastError() {
    final e = _lastError;
    _lastError = null;
    return e;
  }

  /// Name of the most recently completed download (for one-shot UI toast).
  /// Call [consumeLastCompletedName] to read and clear.
  String? _lastCompletedName;
  String? consumeLastCompletedName() {
    final name = _lastCompletedName;
    _lastCompletedName = null;
    return name;
  }

  bool _initialized = false;
  bool get initialized => _initialized;

  // ── Initialization ──

  /// Initialize: create notification channel, load storage limit, refresh list.
  /// Safe to call multiple times — subsequent calls are no-ops.
  Future<void> initialize() async {
    if (kIsWeb) return;
    if (_initialized) return;
    try {
      await _initNotifications();
      final prefs = await SharedPreferences.getInstance();
      _storageLimitMb = prefs.getInt(_storageLimitKey) ?? defaultStorageLimitMb;
      await refreshRegions();
      _initialized = true;
      notifyListeners();
    } catch (e) {
      debugError('[OFFLINE_MAP] Init error: $e');
      notifyListeners();
    }
  }

  /// Set up the Android notification channel for download progress.
  Future<void> _initNotifications() async {
    if (_notifInitialized) return;
    try {
      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        _notifChannelId,
        _notifChannelName,
        description: 'Shows progress when downloading offline map tiles',
        importance: Importance.low, // No sound/vibration
        showBadge: false,
      );

      await _notifPlugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);

      // Initialize the plugin (required before showing notifications).
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosInit = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _notifPlugin.initialize(
        const InitializationSettings(android: androidInit, iOS: iosInit),
      );
      _notifInitialized = true;
    } catch (e) {
      debugError('[OFFLINE_MAP] Notification init error: $e');
    }
  }

  // ── Notifications ──

  Future<void> _showProgressNotification(String regionName, int percent) async {
    if (!_notifInitialized) return;
    try {
      final androidDetails = AndroidNotificationDetails(
        _notifChannelId,
        _notifChannelName,
        channelDescription: 'Shows progress when downloading offline map tiles',
        importance: Importance.low,
        priority: Priority.low,
        showProgress: true,
        maxProgress: 100,
        progress: percent,
        ongoing: true, // Non-dismissable while downloading
        autoCancel: false,
        onlyAlertOnce: true, // Don't buzz on every update
        icon: '@mipmap/ic_launcher',
      );

      await _notifPlugin.show(
        _progressNotifId,
        'Downloading "$regionName"',
        '$percent% complete',
        NotificationDetails(android: androidDetails),
      );
    } catch (e) {
      debugWarn('[OFFLINE_MAP] Failed to show progress notification: $e');
    }
  }

  Future<void> _showCompleteNotification(String regionName) async {
    await _dismissProgressNotification();
    if (!_notifInitialized) return;
    try {
      const androidDetails = AndroidNotificationDetails(
        _notifChannelId,
        _notifChannelName,
        channelDescription: 'Shows progress when downloading offline map tiles',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        icon: '@mipmap/ic_launcher',
      );

      await _notifPlugin.show(
        _completeNotifId,
        'Download Complete',
        '"$regionName" is ready for offline use',
        const NotificationDetails(android: androidDetails),
      );
    } catch (e) {
      debugWarn('[OFFLINE_MAP] Failed to show complete notification: $e');
    }
  }

  Future<void> _showErrorNotification(String regionName) async {
    await _dismissProgressNotification();
    if (!_notifInitialized) return;
    try {
      const androidDetails = AndroidNotificationDetails(
        _notifChannelId,
        _notifChannelName,
        channelDescription: 'Shows progress when downloading offline map tiles',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        icon: '@mipmap/ic_launcher',
      );

      await _notifPlugin.show(
        _completeNotifId,
        'Download Failed',
        'Failed to download "$regionName"',
        const NotificationDetails(android: androidDetails),
      );
    } catch (e) {
      debugWarn('[OFFLINE_MAP] Failed to show error notification: $e');
    }
  }

  Future<void> _dismissProgressNotification() async {
    try {
      await _notifPlugin.cancel(_progressNotifId);
    } catch (e) {
      debugWarn('[OFFLINE_MAP] Failed to dismiss notification: $e');
    }
  }

  // ── Region queries ──

  /// Refresh the list of downloaded regions from MapLibre native storage,
  /// along with per-region byte counts and the overall on-disk cache size.
  Future<void> refreshRegions() async {
    if (kIsWeb) return;
    try {
      final rawRegions = await getListOfRegions();
      // Pull sizes and the total cache footprint in parallel. Both come from
      // our platform channel so they share the same round-trip cost.
      final results = await Future.wait([
        TileCacheService.instance.getRegionSizes(),
        TileCacheService.instance.getCacheSizeBytes(),
      ]);
      final sizes = results[0] as Map<int, int>;
      final totalBytes = results[1] as int;

      final parsed = <OfflineMapRegion>[];
      int downloadsSum = 0;
      for (final r in rawRegions) {
        try {
          final actual = sizes[r.id];
          parsed.add(
              OfflineMapRegion.fromOfflineRegion(r, actualBytes: actual));
          downloadsSum += actual ?? 0;
        } catch (e) {
          debugWarn('[OFFLINE_MAP] Failed to parse region ${r.id}: $e');
        }
      }
      _regions = parsed;
      _regions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _totalCacheBytes = totalBytes;
      _downloadsBytes = downloadsSum;
      notifyListeners();
    } catch (e) {
      debugError('[OFFLINE_MAP] Failed to list regions: $e');
    }
  }

  /// Refresh only the overall cache size (fast path, no region enumeration).
  /// Useful after ambient cache operations that don't change region state.
  Future<void> refreshCacheSize() async {
    if (kIsWeb) return;
    _totalCacheBytes = await TileCacheService.instance.getCacheSizeBytes();
    notifyListeners();
  }

  // ── Storage limit ──

  /// Update the storage limit (in MB) and persist it.
  Future<void> setStorageLimit(int limitMb) async {
    _storageLimitMb = limitMb.clamp(minStorageLimitMb, maxStorageLimitMb);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_storageLimitKey, _storageLimitMb);
    } catch (e) {
      debugError('[OFFLINE_MAP] Failed to save storage limit: $e');
    }
    notifyListeners();
  }

  // ── Tile estimation ──

  /// Native max zoom of the OpenFreeMap vector tileset. z15+ in the slider is
  /// reachable but it's pure overzoom — MapLibre rasterizes z14 source tiles
  /// for higher zooms without fetching new data. Capping the estimator loop
  /// here keeps overzoom from being counted as additional downloads.
  static const int _vectorTilesetMaxZoom = 14;

  /// Web Mercator clamps latitude to ±~85.0511° (atan(sinh(π))); beyond that
  /// the projection diverges. Using the literal here keeps the tile-Y math
  /// stable if a user drags a corner near a pole.
  static const double _mercatorLatLimit = 85.0511;

  /// Average bytes per OpenFreeMap vector tile (MVT/PBF). Empirically ~2.4 KB
  /// globally; we round up to 3 KB to leave a small margin without grossly
  /// overestimating. Raster tiles would need a higher number (20–40 KB) but
  /// the app only offers vector styles for offline download — if that ever
  /// changes, this needs to be style-aware.
  static const int _bytesPerVectorTile = 3 * 1024;

  /// Estimate tile count for a region using proper Web Mercator tile math.
  /// Iterates over each zoom level the SDK will actually fetch source tiles
  /// for (capped at the tileset's native max zoom).
  static int estimateTileCount(
      LatLngBounds bounds, double minZoom, double maxZoom) {
    final zMin = minZoom.floor();
    final zMax = math.min(maxZoom.ceil(), _vectorTilesetMaxZoom);
    if (zMax < zMin) return 0;

    final latMin =
        bounds.southwest.latitude.clamp(-_mercatorLatLimit, _mercatorLatLimit);
    final latMax =
        bounds.northeast.latitude.clamp(-_mercatorLatLimit, _mercatorLatLimit);
    final lngMin = bounds.southwest.longitude;
    final lngMax = bounds.northeast.longitude;

    int total = 0;
    for (int z = zMin; z <= zMax; z++) {
      final n = 1 << z;
      final x0 = ((lngMin + 180.0) / 360.0 * n).floor().clamp(0, n - 1);
      final x1 = ((lngMax + 180.0) / 360.0 * n).floor().clamp(0, n - 1);
      final xTiles = (x1 - x0 + 1).clamp(1, n);
      // North latitude → smaller tile Y in Mercator, so yNorth uses latMax.
      final yNorth = _mercatorTileY(latMax, n);
      final ySouth = _mercatorTileY(latMin, n);
      final yTiles = (ySouth - yNorth + 1).clamp(1, n);
      total += xTiles * yTiles;
    }
    return total;
  }

  /// Web Mercator tile-Y index for a given latitude at zoom level `2^z = n`.
  static int _mercatorTileY(double latDeg, int n) {
    final latRad = latDeg * math.pi / 180.0;
    final y = (1 -
            math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
        2 *
        n;
    return y.floor().clamp(0, n - 1);
  }

  /// Estimate download size in bytes from tile count.
  static int estimateSizeBytes(int tileCount) =>
      tileCount * _bytesPerVectorTile;

  /// Check if downloading a region of [estimatedBytes] would exceed the
  /// limit. Accounts for the currently-active download and any queued jobs
  /// so the UI's pre-check agrees with the service's internal validation.
  bool wouldExceedLimit(int estimatedBytes) {
    final pending = (isDownloading ? _activePendingBytes : 0) +
        _queue.fold<int>(0, (sum, q) => sum + q.estBytes);
    return (totalUsedBytes + pending + estimatedBytes) > storageLimitBytes;
  }

  /// Rough bytes remaining in the currently-active download. We don't know
  /// the real size until completion — use the job's estimate as a proxy by
  /// subtracting progress.
  int get _activePendingBytes {
    final progress = _downloadProgress ?? 0;
    return ((1 - progress) * _activeEstBytes)
        .clamp(0, _activeEstBytes)
        .toInt();
  }

  // ── Download ──

  /// Download an offline region.
  ///
  /// The download runs in MapLibre's native layer, so it survives Flutter
  /// screen navigation. This service (kept alive by the app-level Provider)
  /// receives progress callbacks and forwards them to both [notifyListeners]
  /// and a system notification.
  ///
  /// If another download is already active, the request is appended to a
  /// FIFO queue and will start automatically when the current one finishes
  /// or is cancelled.
  ///
  /// Returns the new [OfflineMapRegion] on success, null on failure or if
  /// validation rejects the request (quota, free space, antimeridian, etc.).
  /// The returned future resolves once the region's native download fully
  /// completes — not when it's merely queued.
  Future<OfflineMapRegion?> downloadRegion({
    required String name,
    required LatLngBounds bounds,
    required String styleUrl,
    required String styleName,
    double minZoom = 0,
    double maxZoom = 14,
  }) async {
    if (kIsWeb) return null;

    final tileCount = estimateTileCount(bounds, minZoom, maxZoom);
    final estBytes = estimateSizeBytes(tileCount);

    if (wouldExceedLimit(estBytes)) {
      _lastError =
          'Download would exceed storage limit (${_formatBytes(estBytes)} '
          'needed)';
      notifyListeners();
      return null;
    }

    // Device free-space check. The app-level quota above only caps estimated
    // tile usage across our regions — the device itself may be nearly full
    // regardless. We require 1.5× the estimate to leave headroom for the
    // heuristic being low. Failures of the platform call fall through to
    // the existing quota logic.
    try {
      final freeMb = await DiskSpacePlus().getFreeDiskSpace;
      if (freeMb != null) {
        final freeBytes = (freeMb * 1024 * 1024).toInt();
        final required = (estBytes * 1.5).toInt();
        if (freeBytes < required) {
          _lastError = 'Not enough free space on device '
              '(${_formatBytes(required)} needed, '
              '${_formatBytes(freeBytes)} free)';
          notifyListeners();
          return null;
        }
      }
    } catch (e) {
      debugWarn('[OFFLINE_MAP] Free-space check failed: $e');
    }

    final job = _QueuedDownload(
      name: name,
      bounds: bounds,
      styleUrl: styleUrl,
      styleName: styleName,
      minZoom: minZoom,
      maxZoom: maxZoom,
      estBytes: estBytes,
      completer: Completer<OfflineMapRegion?>(),
    );

    if (isDownloading) {
      _queue.add(job);
      debugLog('[OFFLINE_MAP] Queued "$name" '
          '(position ${_queue.length} in queue)');
      notifyListeners();
    } else {
      unawaited(_startJob(job));
    }

    return job.completer.future;
  }

  /// Start a queued job. Also invoked recursively from [_onDownloadEvent]
  /// after the active download finishes, to drain the queue.
  Future<void> _startJob(_QueuedDownload job) async {
    _downloadProgress = 0;
    _downloadingRegionName = job.name;
    _activeCompleter = job.completer;
    _activeEstBytes = job.estBytes;
    _progressSamples.clear();
    _lastError = null;
    _lastCompletedName = null;
    notifyListeners();
    _showProgressNotification(job.name, 0);

    try {
      final definition = OfflineRegionDefinition(
        bounds: job.bounds,
        mapStyleUrl: job.styleUrl,
        minZoom: job.minZoom,
        maxZoom: job.maxZoom,
      );

      final metadata = {
        _MetaKeys.name: job.name,
        _MetaKeys.styleName: job.styleName,
        _MetaKeys.createdAt: DateTime.now().toIso8601String(),
        _MetaKeys.estimatedBytes: job.estBytes,
      };

      final region = await downloadOfflineRegion(
        definition,
        metadata: metadata,
        onEvent: _onDownloadEvent,
      );
      _activeRegionId = region.id;

      // downloadOfflineRegion resolves once MapLibre has accepted the job;
      // progress and completion are delivered via _onDownloadEvent.
      // In the rare case Success already fired synchronously before this
      // returns, _downloadProgress will be null — resolve the completer now
      // so the caller doesn't hang waiting for an event that already fired.
      if (_downloadProgress == null && !job.completer.isCompleted) {
        final finalized = _regions.firstWhere((r) => r.id == region.id,
            orElse: () => OfflineMapRegion.fromOfflineRegion(region));
        job.completer.complete(finalized);
      }
    } catch (e) {
      debugError('[OFFLINE_MAP] downloadRegion threw: $e');
      _downloadProgress = null;
      _downloadingRegionName = null;
      _activeRegionId = null;
      _activeCompleter = null;
      _activeEstBytes = 0;
      _progressSamples.clear();
      _lastError = 'Download failed (${e.runtimeType}): $e';
      notifyListeners();
      _showErrorNotification(job.name);
      if (!job.completer.isCompleted) job.completer.complete(null);
      _drainQueue();
    }
  }

  /// Start the next queued download if any, once the current one has
  /// finished, errored, or been cancelled.
  void _drainQueue() {
    if (_queue.isEmpty) return;
    final next = _queue.removeAt(0);
    unawaited(_startJob(next));
  }

  void _onDownloadEvent(DownloadRegionStatus status) {
    if (status is Success) {
      final name = _downloadingRegionName ?? 'Region';
      final completer = _activeCompleter;
      final regionId = _activeRegionId;
      _downloadProgress = null;
      _downloadingRegionName = null;
      _activeRegionId = null;
      _activeCompleter = null;
      _activeEstBytes = 0;
      _progressSamples.clear();
      _lastCompletedName = name;
      notifyListeners();
      _showCompleteNotification(name);
      // Small delay lets the native DB commit before we query it.
      Future.delayed(const Duration(milliseconds: 500), () async {
        await refreshRegions();
        if (completer != null && !completer.isCompleted) {
          OfflineMapRegion? finalized;
          if (regionId != null) {
            for (final r in _regions) {
              if (r.id == regionId) {
                finalized = r;
                break;
              }
            }
          }
          completer.complete(finalized);
        }
        _drainQueue();
      });
    } else if (status is InProgress) {
      final progress = status.progress / 100.0;
      _downloadProgress = progress;
      _progressSamples.add((at: DateTime.now(), progress: progress));
      if (_progressSamples.length > _progressWindowSize) {
        _progressSamples.removeAt(0);
      }
      notifyListeners();
      // Throttle notification updates to every 2% to avoid flooding
      final percent = status.progress.round();
      if (percent % 2 == 0) {
        _showProgressNotification(_downloadingRegionName ?? 'Region', percent);
      }
    } else {
      // DownloadRegionStatus is sealed to Success / InProgress / Error. The
      // concrete Error class is named `Error` in maplibre_gl, which collides
      // with dart:core.Error — so rather than `status is Error` we reach the
      // `cause` field dynamically. `cause` is a PlatformException with
      // code/message/details we can surface to the user.
      final name = _downloadingRegionName ?? 'Region';
      final completer = _activeCompleter;
      String detail = 'unknown error';
      try {
        final cause = (status as dynamic).cause;
        if (cause != null) {
          final msg = (cause as dynamic).message;
          final code = (cause as dynamic).code;
          if (msg is String && msg.isNotEmpty) {
            detail = msg;
          } else if (code is String && code.isNotEmpty) {
            detail = code;
          } else {
            detail = cause.toString();
          }
        }
      } catch (_) {
        // Swallow — keep the generic 'unknown error' fallback.
      }
      debugError('[OFFLINE_MAP] Download failed: $detail');
      _downloadProgress = null;
      _downloadingRegionName = null;
      _activeRegionId = null;
      _activeCompleter = null;
      _activeEstBytes = 0;
      _progressSamples.clear();
      _lastError = 'Download failed: $detail';
      _showErrorNotification(name);
      notifyListeners();
      if (completer != null && !completer.isCompleted) {
        completer.complete(null);
      }
      _drainQueue();
    }
  }

  /// Cancel the currently-active download, if any. Deletes the partial
  /// region from MapLibre's cache. Queued downloads are left in place —
  /// the next one will start automatically. Call [clearQueue] to discard
  /// queued jobs too.
  Future<bool> cancelActiveDownload() async {
    if (kIsWeb) return false;
    final regionId = _activeRegionId;
    final completer = _activeCompleter;
    final name = _downloadingRegionName;
    if (regionId == null && !isDownloading) return false;

    debugLog('[OFFLINE_MAP] Cancelling active download'
        '${name != null ? " \"$name\"" : ""}');

    if (regionId != null) {
      try {
        await deleteOfflineRegion(regionId);
      } catch (e) {
        debugWarn('[OFFLINE_MAP] Cancel delete failed: $e');
      }
    }

    _downloadProgress = null;
    _downloadingRegionName = null;
    _activeRegionId = null;
    _activeCompleter = null;
    _activeEstBytes = 0;
    _progressSamples.clear();
    await _dismissProgressNotification();
    notifyListeners();

    if (completer != null && !completer.isCompleted) {
      completer.complete(null);
    }

    await refreshRegions();
    _drainQueue();
    return true;
  }

  /// Discard all queued (but not yet active) downloads. Does not affect
  /// the active download; call [cancelActiveDownload] for that.
  void clearQueue() {
    if (_queue.isEmpty) return;
    for (final job in _queue) {
      if (!job.completer.isCompleted) job.completer.complete(null);
    }
    _queue.clear();
    notifyListeners();
  }

  // ── Deletion ──

  /// Delete a downloaded region by ID.
  Future<bool> deleteRegion(int regionId) async {
    if (kIsWeb) return false;
    try {
      await deleteOfflineRegion(regionId);
      await refreshRegions();
      return true;
    } catch (e) {
      debugError('[OFFLINE_MAP] Delete failed: $e');
      _lastError = 'Failed to delete region: $e';
      notifyListeners();
      return false;
    }
  }

  /// Delete all downloaded regions.
  Future<void> deleteAllRegions() async {
    if (kIsWeb) return;
    final ids = _regions.map((r) => r.id).toList();
    for (final id in ids) {
      try {
        await deleteOfflineRegion(id);
      } catch (e) {
        debugError('[OFFLINE_MAP] Failed to delete region $id: $e');
      }
    }
    await refreshRegions();
  }

  // ── Cleanup ──

  /// Cancel any stale progress notification from a previous session.
  /// Called at app startup (mirrors BackgroundServiceManager.cleanupOrphanedService).
  Future<void> cleanupOrphanedNotification() async {
    if (kIsWeb) return;
    try {
      await _initNotifications();
      await _notifPlugin.cancel(_progressNotifId);
    } catch (e) {
      debugWarn('[OFFLINE_MAP] Failed to cleanup orphaned notification: $e');
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
