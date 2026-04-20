package net.meshmapper.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.maplibre.android.offline.OfflineManager
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
}
