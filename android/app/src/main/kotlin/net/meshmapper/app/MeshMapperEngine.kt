package net.meshmapper.app

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor


object MeshMapperEngine {

    const val ENGINE_ID = "meshmapper_main"

    private var usbService: MeshMapperUsbService? = null

    @Synchronized
    fun obtain(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val app = context.applicationContext
        val engine = FlutterEngine(app)
        registerAppScopedChannels(app, engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    private fun registerAppScopedChannels(app: Context, engine: FlutterEngine) {
        usbService = MeshMapperUsbService(app).also { it.configureFlutterEngine(engine) }
        MeshMapperCarMapChannel.register(engine)
    }
}
