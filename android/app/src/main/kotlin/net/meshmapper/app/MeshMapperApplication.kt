package net.meshmapper.app

import android.app.Application
import com.oguzhnatly.flutter_android_auto.FAAEngineProvider
import com.oguzhnatly.flutter_android_auto.FAASurfaceProvider

class MeshMapperApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        FAAEngineProvider.factory = { context -> MeshMapperEngine.obtain(context) }
        FAASurfaceProvider.factory = { carContext -> MeshMapperCarMapChannel.create(carContext) }
    }
}
