package net.meshmapper.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.maplibre.android.offline.OfflineManager
import org.maplibre.android.offline.OfflineRegion
import org.maplibre.android.offline.OfflineRegionStatus
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // MapLibre tile cache management. Mirrors AppDelegate.swift's iOS
        // implementation. Called from Dart's TileCacheService by the Offline
        // Maps screen's Tile Cache card.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "meshmapper/tile_cache")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCacheSize" -> {
                        val dbFile = File(applicationContext.getDatabasePath("mbgl-offline.db").absolutePath)
                        result.success(if (dbFile.exists()) dbFile.length() else 0L)
                    }
                    "getRegionSizes" -> {
                        getRegionSizes(result)
                    }
                    "clearAmbientCache" -> {
                        OfflineManager.getInstance(applicationContext).clearAmbientCache(
                            object : OfflineManager.FileSourceCallback {
                                override fun onSuccess() = result.success(null)
                                override fun onError(message: String) =
                                    result.error("clear_failed", message, null)
                            }
                        )
                    }
                    "invalidateAmbientCache" -> {
                        OfflineManager.getInstance(applicationContext).invalidateAmbientCache(
                            object : OfflineManager.FileSourceCallback {
                                override fun onSuccess() = result.success(null)
                                override fun onError(message: String) =
                                    result.error("invalidate_failed", message, null)
                            }
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Per-region downloaded byte counts, keyed by OfflineRegion.getID() which
    /// is the same long ID the maplibre_gl plugin returns to Dart. Reads each
    /// region's completedResourceSize (the tile+resource byte total for that
    /// region as tracked by the SDK). Responds on the main thread with a
    /// Map<Long, Long> over the platform channel.
    private fun getRegionSizes(result: MethodChannel.Result) {
        OfflineManager.getInstance(applicationContext).listOfflineRegions(
            object : OfflineManager.ListOfflineRegionsCallback {
                override fun onList(regions: Array<OfflineRegion>?) {
                    val list = regions ?: emptyArray()
                    if (list.isEmpty()) {
                        result.success(HashMap<Long, Long>())
                        return
                    }
                    val sizes = HashMap<Long, Long>()
                    var remaining = list.size
                    for (region in list) {
                        region.getStatus(object : OfflineRegion.OfflineRegionStatusCallback {
                            override fun onStatus(status: OfflineRegionStatus?) {
                                if (status != null) {
                                    sizes[region.id] = status.completedResourceSize
                                }
                                remaining -= 1
                                if (remaining == 0) {
                                    result.success(sizes)
                                }
                            }
                            override fun onError(error: String?) {
                                remaining -= 1
                                if (remaining == 0) {
                                    result.success(sizes)
                                }
                            }
                        })
                    }
                }
                override fun onError(error: String) {
                    result.error("region_sizes_failed", error, null)
                }
            }
        )
    }
}
