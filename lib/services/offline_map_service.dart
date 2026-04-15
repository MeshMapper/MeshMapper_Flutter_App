import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  final int estimatedBytes;

  const OfflineMapRegion({
    required this.id,
    required this.name,
    required this.styleName,
    required this.bounds,
    required this.minZoom,
    required this.maxZoom,
    required this.createdAt,
    required this.estimatedBytes,
  });

  factory OfflineMapRegion.fromOfflineRegion(OfflineRegion region) {
    final meta = region.metadata;
    return OfflineMapRegion(
      id: region.id,
      name: (meta[_MetaKeys.name] as String?) ?? 'Region ${region.id}',
      styleName: (meta[_MetaKeys.styleName] as String?) ?? 'Unknown',
      bounds: region.definition.bounds,
      minZoom: region.definition.minZoom,
      maxZoom: region.definition.maxZoom,
      createdAt: DateTime.tryParse(
              (meta[_MetaKeys.createdAt] as String?) ?? '') ??
          DateTime.now(),
      // Platform channel JSON round-trip can return int as num/double.
      estimatedBytes: (meta[_MetaKeys.estimatedBytes] as num?)?.toInt() ?? 0,
    );
  }

  /// Human-readable size string.
  String get sizeDisplay {
    if (estimatedBytes < 1024) return '$estimatedBytes B';
    if (estimatedBytes < 1024 * 1024) {
      return '${(estimatedBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(estimatedBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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

  /// Total estimated bytes across all downloaded regions.
  int get totalUsedBytes =>
      _regions.fold(0, (sum, r) => sum + r.estimatedBytes);

  double get usageRatio {
    if (storageLimitBytes == 0) return 0;
    return (totalUsedBytes / storageLimitBytes).clamp(0.0, 1.0);
  }

  String get totalUsedDisplay => _formatBytes(totalUsedBytes);
  String get storageLimitDisplay => '$_storageLimitMb MB';

  // ── Download state ──

  /// Currently active download progress (null if idle).
  double? _downloadProgress;
  double? get downloadProgress => _downloadProgress;

  String? _downloadingRegionName;
  String? get downloadingRegionName => _downloadingRegionName;

  bool get isDownloading => _downloadProgress != null;

  String? _lastError;
  String? get lastError => _lastError;

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
      _storageLimitMb =
          prefs.getInt(_storageLimitKey) ?? defaultStorageLimitMb;
      await refreshRegions();
      _initialized = true;
      notifyListeners();
    } catch (e) {
      debugPrint('[OFFLINE_MAP] Init error: $e');
      _initialized = true;
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
      debugPrint('[OFFLINE_MAP] Notification init error: $e');
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
      debugPrint('[OFFLINE_MAP] Failed to show progress notification: $e');
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
      debugPrint('[OFFLINE_MAP] Failed to show complete notification: $e');
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
      debugPrint('[OFFLINE_MAP] Failed to show error notification: $e');
    }
  }

  Future<void> _dismissProgressNotification() async {
    try {
      await _notifPlugin.cancel(_progressNotifId);
    } catch (e) {
      debugPrint('[OFFLINE_MAP] Failed to dismiss notification: $e');
    }
  }

  // ── Region queries ──

  /// Refresh the list of downloaded regions from MapLibre native storage.
  Future<void> refreshRegions() async {
    if (kIsWeb) return;
    try {
      final rawRegions = await getListOfRegions();
      final parsed = <OfflineMapRegion>[];
      for (final r in rawRegions) {
        try {
          parsed.add(OfflineMapRegion.fromOfflineRegion(r));
        } catch (e) {
          debugPrint('[OFFLINE_MAP] Failed to parse region ${r.id}: $e');
        }
      }
      _regions = parsed;
      _regions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      notifyListeners();
    } catch (e) {
      debugPrint('[OFFLINE_MAP] Failed to list regions: $e');
    }
  }

  // ── Storage limit ──

  /// Update the storage limit (in MB) and persist it.
  Future<void> setStorageLimit(int limitMb) async {
    _storageLimitMb = limitMb.clamp(minStorageLimitMb, maxStorageLimitMb);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_storageLimitKey, _storageLimitMb);
    } catch (e) {
      debugPrint('[OFFLINE_MAP] Failed to save storage limit: $e');
    }
    notifyListeners();
  }

  // ── Tile estimation ──

  /// Estimate tile count for a region (rough heuristic).
  /// Uses the standard 2^z tile count formula for each zoom level.
  static int estimateTileCount(
      LatLngBounds bounds, double minZoom, double maxZoom) {
    int total = 0;
    for (int z = minZoom.floor(); z <= maxZoom.ceil(); z++) {
      final tilesPerSide = 1 << z; // 2^z
      final lonFraction = (bounds.northeast.longitude -
              bounds.southwest.longitude)
          .abs() /
          360.0;
      final latFraction =
          (bounds.northeast.latitude - bounds.southwest.latitude).abs() /
              180.0;
      final xTiles = (lonFraction * tilesPerSide).ceil().clamp(1, tilesPerSide);
      final yTiles = (latFraction * tilesPerSide).ceil().clamp(1, tilesPerSide);
      total += xTiles * yTiles;
    }
    return total;
  }

  /// Rough estimate of download size in bytes from tile count.
  /// Vector tiles average ~15-25 KB each; raster tiles ~20-40 KB.
  /// We use 20 KB as a middle estimate.
  static int estimateSizeBytes(int tileCount) => tileCount * 20 * 1024;

  /// Check if downloading a region of [estimatedBytes] would exceed the limit.
  bool wouldExceedLimit(int estimatedBytes) =>
      (totalUsedBytes + estimatedBytes) > storageLimitBytes;

  // ── Download ──

  /// Download an offline region.
  ///
  /// The download runs in MapLibre's native layer, so it survives Flutter
  /// screen navigation. This service (kept alive by the app-level Provider)
  /// receives progress callbacks and forwards them to both [notifyListeners]
  /// and a system notification.
  ///
  /// Returns the new [OfflineMapRegion] on success, null on failure.
  Future<OfflineMapRegion?> downloadRegion({
    required String name,
    required LatLngBounds bounds,
    required String styleUrl,
    required String styleName,
    double minZoom = 0,
    double maxZoom = 14,
  }) async {
    if (kIsWeb) return null;
    if (isDownloading) {
      _lastError = 'A download is already in progress';
      notifyListeners();
      return null;
    }

    final tileCount = estimateTileCount(bounds, minZoom, maxZoom);
    final estBytes = estimateSizeBytes(tileCount);

    if (wouldExceedLimit(estBytes)) {
      _lastError =
          'Download would exceed storage limit (${_formatBytes(estBytes)} needed, '
          '${_formatBytes(storageLimitBytes - totalUsedBytes)} remaining)';
      notifyListeners();
      return null;
    }

    _downloadProgress = 0;
    _downloadingRegionName = name;
    _lastError = null;
    _lastCompletedName = null;
    notifyListeners();
    _showProgressNotification(name, 0);

    try {
      final definition = OfflineRegionDefinition(
        bounds: bounds,
        mapStyleUrl: styleUrl,
        minZoom: minZoom,
        maxZoom: maxZoom,
      );

      final metadata = {
        _MetaKeys.name: name,
        _MetaKeys.styleName: styleName,
        _MetaKeys.createdAt: DateTime.now().toIso8601String(),
        _MetaKeys.estimatedBytes: estBytes,
      };

      final region = await downloadOfflineRegion(
        definition,
        metadata: metadata,
        onEvent: _onDownloadEvent,
      );

      // downloadOfflineRegion resolves once the native download is queued,
      // not necessarily when it finishes. The _onDownloadEvent callback
      // handles completion. But if progress is already null (Success fired
      // synchronously), the download completed inline.
      if (_downloadProgress != null) {
        // Still in progress — the event callback will finalize.
        return null;
      }

      // Completed synchronously (small region / cached tiles)
      _downloadProgress = null;
      _downloadingRegionName = null;
      _lastCompletedName = name;
      await refreshRegions();
      _showCompleteNotification(name);
      return _regions.firstWhere((r) => r.id == region.id,
          orElse: () => OfflineMapRegion.fromOfflineRegion(region));
    } catch (e) {
      _downloadProgress = null;
      _downloadingRegionName = null;
      _lastError = 'Download failed: $e';
      notifyListeners();
      _showErrorNotification(name);
      return null;
    }
  }

  void _onDownloadEvent(DownloadRegionStatus status) {
    if (status is Success) {
      final name = _downloadingRegionName ?? 'Region';
      _downloadProgress = null;
      _downloadingRegionName = null;
      _lastCompletedName = name;
      notifyListeners(); // Immediately clear progress state
      _showCompleteNotification(name);
      // Small delay lets the native DB commit before we query it.
      Future.delayed(const Duration(milliseconds: 500), () {
        refreshRegions();
      });
    } else if (status is InProgress) {
      _downloadProgress = status.progress / 100.0;
      notifyListeners();
      // Throttle notification updates to every 2% to avoid flooding
      final percent = status.progress.round();
      if (percent % 2 == 0) {
        _showProgressNotification(
            _downloadingRegionName ?? 'Region', percent);
      }
    } else {
      // Error status
      final name = _downloadingRegionName ?? 'Region';
      _downloadProgress = null;
      _downloadingRegionName = null;
      _lastError = 'Download error occurred';
      _showErrorNotification(name);
      notifyListeners();
    }
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
      debugPrint('[OFFLINE_MAP] Delete failed: $e');
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
        debugPrint('[OFFLINE_MAP] Failed to delete region $id: $e');
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
      debugPrint('[OFFLINE_MAP] Failed to cleanup orphaned notification: $e');
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
