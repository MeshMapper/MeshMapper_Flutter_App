package com.oguzhnatly.flutter_android_auto

import android.content.Context
import androidx.car.app.CarAppService
import androidx.car.app.CarContext
import androidx.car.app.SurfaceCallback
import androidx.car.app.validation.HostValidator
import androidx.car.app.Session
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.FlutterEngineCache;

/// DELTA B from upstream 1.6.5.
///
/// Upstream unconditionally builds its own bare `FlutterEngine(this)` when the
/// cache is empty. In an app whose engine owns platform channels — MeshMapper's
/// USB serial and MapLibre tile cache both live on the engine, not on an
/// Activity — that headless engine is the wrong one: its isolate has none of
/// those channels, and if the Activity later builds the real engine the app ends
/// up with two, each with its own copy of every plugin, fighting over this
/// plugin's own static template state.
///
/// [FAAEngineProvider] lets the host app supply the engine instead. The default
/// path below is unchanged, so apps that do not set a factory behave exactly as
/// they did before.
object FAAEngineProvider {
    /// Set this before the car host can start the service — an Application
    /// subclass's onCreate is the only reliably early enough place, since
    /// Application.onCreate always precedes any Service.onCreate in the process.
    ///
    /// The factory must return a fully configured engine with Dart already
    /// running; this class will not call executeDartEntrypoint on it.
    var factory: ((Context) -> FlutterEngine)? = null
}

/// DELTA D from upstream 1.6.5.
///
/// A map template draws nothing by itself: the host hands the app a Surface and
/// the app renders onto it. That rendering is entirely app-specific — MeshMapper
/// puts a MapLibre map there — so rather than teach this plugin about any one
/// map SDK, let the host app supply the SurfaceCallback.
///
/// Leave [factory] null and nothing changes: no surface callback is registered
/// and the plugin behaves exactly as upstream.
object FAASurfaceProvider {
    /// Set from the host app before a car session starts. Registering the
    /// callback requires the androidx.car.app.ACCESS_SURFACE permission, which
    /// is why this is opt-in rather than always-on.
    var factory: ((CarContext) -> SurfaceCallback)? = null
}

class AndroidAutoService : CarAppService() {
    companion object {
        /// The Android Auto session that this service is handling.
        var session: AndroidAutoSession? = null
    }

    override fun onCreate() {
        super.onCreate()
        val engineCache = FlutterEngineCache.getInstance()
        val flutterEngineId = FAAConstants.flutterEngineId

        if (engineCache.get(flutterEngineId) != null) return;

        // DELTA B: give the host app first refusal on engine creation. It is
        // responsible for having started Dart; we only cache the result under
        // the id this plugin looks up.
        FAAEngineProvider.factory?.let { create ->
            engineCache.put(flutterEngineId, create(this))
            return
        }

        // Create new engine in headless mode
        val flutterEngine = FlutterEngine(this)
        flutterEngine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        // Cache the engine
        engineCache.put(flutterEngineId, flutterEngine)
    }


    /// DELTA C from upstream 1.6.5: upstream returns ALLOW_ALL_HOSTS_VALIDATOR
    /// unconditionally. Android's own documentation restricts that to debug
    /// builds — it lets *any* app on the device bind this service and drive the
    /// car surface — and shipping it is a Play review risk. Validate against the
    /// car-app library's bundled allowlist of known hosts in release builds, and
    /// keep the permissive behaviour only where the debug flag is set, which is
    /// what the Desktop Head Unit needs.
    override fun createHostValidator(): HostValidator =
        if ((applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            HostValidator.ALLOW_ALL_HOSTS_VALIDATOR
        } else {
            HostValidator.Builder(applicationContext)
                .addAllowedHosts(androidx.car.app.R.array.hosts_allowlist_sample)
                .build()
        }

    override fun onCreateSession(): Session {
        session = AndroidAutoSession()
        return session!!
    }
}
