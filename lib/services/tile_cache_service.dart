import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../utils/debug_logger_io.dart';

/// Manages MapLibre's ambient tile cache — tiles opportunistically stored
/// during normal map use, separate from the explicitly downloaded offline
/// regions tracked by [OfflineMapService].
///
/// Routed through a platform MethodChannel on `meshmapper/tile_cache`:
/// - iOS handler: AppDelegate.swift (uses `MLNOfflineStorage.shared`)
/// - Android handler: MainActivity.kt (uses `OfflineManager.getInstance(ctx)`)
///
/// Both handlers operate on MapLibre's global offline storage singleton, so
/// they don't depend on any map widget being alive.
///
/// Size reporting reads the underlying cache database file directly. It
/// includes BOTH ambient cache and downloaded regions — MapLibre stores them
/// in the same SQLite file.
class TileCacheService {
  TileCacheService._();
  static final TileCacheService instance = TileCacheService._();

  static const _channel = MethodChannel('meshmapper/tile_cache');

  /// Total size in bytes of the MapLibre cache database. Includes both
  /// ambient cache and downloaded offline regions. Returns 0 on web or on
  /// unexpected channel errors.
  Future<int> getCacheSizeBytes() async {
    if (kIsWeb) return 0;
    try {
      final raw = await _channel.invokeMethod<dynamic>('getCacheSize');
      // iOS returns Int64 → Dart int; Android returns Long → Dart int.
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      return 0;
    } catch (e) {
      debugWarn('[OFFLINE_MAP] Cache size read failed: $e');
      return 0;
    }
  }

  Future<void> clearAmbientCache() async {
    if (kIsWeb) throw UnsupportedError('Not supported on web');
    await _channel.invokeMethod<void>('clearAmbientCache');
    debugLog('[OFFLINE_MAP] Ambient cache cleared');
  }

  Future<void> invalidateAmbientCache() async {
    if (kIsWeb) throw UnsupportedError('Not supported on web');
    await _channel.invokeMethod<void>('invalidateAmbientCache');
    debugLog('[OFFLINE_MAP] Ambient cache invalidated');
  }
}
