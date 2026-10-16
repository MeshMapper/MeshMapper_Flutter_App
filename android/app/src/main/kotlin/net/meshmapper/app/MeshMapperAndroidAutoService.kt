package net.meshmapper.app

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import net.meshmapper.app.auto.CarSnapshot
import net.meshmapper.app.auto.CarStatusStore

/// Flutter end of the Android Auto bridge (`meshmapper/android_auto`).
///
/// Dart calls `attach` once to learn whether a car is already connected and
/// `publishSnapshot` whenever the dashboard state changes. Native calls back
/// with `carSessionChanged` and `command` through [CarStatusStore], which owns
/// the channel reference so the car screens never touch the engine directly.
class MeshMapperAndroidAutoService {
    private var channel: MethodChannel? = null

    fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        val newChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "meshmapper/android_auto",
        )
        newChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "attach" -> result.success(CarStatusStore.carSessionActive)
                "publishSnapshot" -> {
                    val snapshot = CarSnapshot.fromMap(call.arguments)
                    if (snapshot == null) {
                        result.error("bad_snapshot", "Snapshot was not a map", null)
                    } else {
                        CarStatusStore.updateSnapshot(snapshot)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        channel = newChannel
        CarStatusStore.attachChannel(newChannel)
    }

    fun dispose() {
        channel?.let {
            it.setMethodCallHandler(null)
            CarStatusStore.detachChannel(it)
        }
        channel = null
    }
}
