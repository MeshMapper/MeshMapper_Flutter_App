package net.meshmapper.app.auto

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.car.app.CarContext
import androidx.car.app.CarToast
import androidx.car.app.Screen
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner

/// Base for screens that redraw from [CarStatusStore].
///
/// Listens only while visible, and coalesces store updates so the template is
/// rebuilt at most once per [MIN_REFRESH_INTERVAL_MS]. A busy session notifies
/// several times a second; hosts throttle template updates anyway, and asking
/// for more than they accept just drops frames.
abstract class CarStatusScreen(carContext: CarContext) : Screen(carContext) {
    private val handler = Handler(Looper.getMainLooper())
    private var lastInvalidateAt = 0L
    private var refreshPending = false

    private val refresh = Runnable {
        refreshPending = false
        lastInvalidateAt = SystemClock.uptimeMillis()
        invalidate()
    }

    private val listener = CarStatusStore.Listener { scheduleRefresh() }

    init {
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                CarStatusStore.addListener(listener)
                // State may have moved while another screen was on top.
                scheduleRefresh()
            }

            override fun onStop(owner: LifecycleOwner) {
                CarStatusStore.removeListener(listener)
                handler.removeCallbacks(refresh)
                refreshPending = false
            }
        })
    }

    private fun scheduleRefresh() {
        if (refreshPending) return
        refreshPending = true
        val wait = MIN_REFRESH_INTERVAL_MS - (SystemClock.uptimeMillis() - lastInvalidateAt)
        handler.postDelayed(refresh, wait.coerceAtLeast(0L))
    }

    /// Sends a command and toasts its outcome. Success messages come from the
    /// phone ("MeshMapper started in Passive mode."), so the driver gets the
    /// same words Siri would speak.
    protected fun runCommand(
        kind: String,
        mode: String? = null,
        sessionId: String? = null,
        fallbackSuccess: String,
    ) {
        CarStatusStore.sendCommand(kind, mode, sessionId) { outcome ->
            val text = outcome.message ?: if (outcome.success) fallbackSuccess else "Command failed"
            CarToast.makeText(carContext, text, CarToast.LENGTH_LONG).show()
        }
    }

    companion object {
        const val MIN_REFRESH_INTERVAL_MS = 1000L

        /// Rows shown in a list while driving. Hosts guarantee at least six.
        const val MAX_LIST_ROWS = 6
    }
}
