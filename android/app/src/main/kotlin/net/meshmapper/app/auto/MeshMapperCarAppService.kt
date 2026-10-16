package net.meshmapper.app.auto

import android.content.Intent
import android.content.pm.ApplicationInfo
import androidx.car.app.CarAppService
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.car.app.validation.HostValidator
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner

/// Entry point Android Auto binds to when MeshMapper is opened on the car.
///
/// The car is a remote control and status display for the wardriving session
/// running on the phone. Nothing here talks to the radio, GPS or API: every
/// fact comes from the Dart snapshot and every action goes back through the
/// same admission the phone's buttons use.
class MeshMapperCarAppService : CarAppService() {
    override fun createHostValidator(): HostValidator {
        // Debug builds accept any host so the Desktop Head Unit works without
        // extra setup. Release builds accept only the known Android Auto and
        // Automotive hosts published by the car app library.
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            return HostValidator.ALLOW_ALL_HOSTS_VALIDATOR
        }
        return HostValidator.Builder(applicationContext)
            .addAllowedHosts(androidx.car.app.R.array.hosts_allowlist_sample)
            .build()
    }

    override fun onCreateSession(): Session = MeshMapperCarSession()
}

class MeshMapperCarSession : Session() {
    init {
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onCreate(owner: LifecycleOwner) {
                CarStatusStore.setCarSessionActive(true)
            }

            override fun onDestroy(owner: LifecycleOwner) {
                CarStatusStore.setCarSessionActive(false)
            }
        })
    }

    override fun onCreateScreen(intent: Intent): Screen = CarMapScreen(carContext)
}
