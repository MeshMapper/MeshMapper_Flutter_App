package net.meshmapper.app.auto

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/// Process-wide meeting point between the Flutter engine and the car screens.
///
/// The CarAppService and MainActivity's FlutterEngine have independent
/// lifecycles: the car can connect before the phone app is opened, and the
/// activity can go away while the head unit is still showing MeshMapper. This
/// object outlives both, so either side can arrive first and the other picks
/// up the current state when it attaches. All access is on the main thread,
/// which is where both MethodChannel callbacks and car Screen callbacks run.
object CarStatusStore {
    fun interface Listener {
        fun onCarStatusChanged()
    }

    data class CommandOutcome(val success: Boolean, val message: String?)

    private val mainHandler = Handler(Looper.getMainLooper())
    private val listeners = LinkedHashSet<Listener>()
    private var channel: MethodChannel? = null

    /// Latest snapshot from Dart, or null before the first publish of this
    /// engine. Cleared when the engine detaches so the car never shows a
    /// session the phone has stopped reporting on.
    var snapshot: CarSnapshot? = null
        private set

    var carSessionActive: Boolean = false
        private set

    val isAppAttached: Boolean
        get() = channel != null

    fun addListener(listener: Listener) {
        listeners.add(listener)
    }

    fun removeListener(listener: Listener) {
        listeners.remove(listener)
    }

    // --- Flutter side -------------------------------------------------------

    fun attachChannel(newChannel: MethodChannel) {
        channel = newChannel
        notifyListeners()
    }

    fun detachChannel(oldChannel: MethodChannel) {
        if (channel !== oldChannel) return
        channel = null
        snapshot = null
        notifyListeners()
    }

    fun updateSnapshot(newSnapshot: CarSnapshot) {
        snapshot = newSnapshot
        notifyListeners()
    }

    // --- Car side -----------------------------------------------------------

    fun setCarSessionActive(active: Boolean) {
        if (carSessionActive == active) return
        carSessionActive = active
        channel?.invokeMethod("carSessionChanged", active)
    }

    /// Sends a session command to Dart and reports its real outcome.
    ///
    /// The command carries a fresh id so a host-side retry of the same tap is
    /// deduplicated by the Dart bridge, and the issue time lets Dart's shared
    /// age rule refuse a transmit that arrives too late to be safe.
    fun sendCommand(
        kind: String,
        mode: String? = null,
        sessionId: String? = null,
        onOutcome: (CommandOutcome) -> Unit,
    ) {
        val target = channel
        if (target == null) {
            onOutcome(CommandOutcome(false, "Open MeshMapper on your phone first"))
            return
        }
        val arguments = hashMapOf<String, Any?>(
            "id" to UUID.randomUUID().toString(),
            "source" to "androidAuto",
            "kind" to kind,
            "issuedAtMs" to System.currentTimeMillis(),
        )
        if (mode != null) arguments["mode"] = mode
        if (sessionId != null) arguments["sessionId"] = sessionId
        target.invokeMethod("command", arguments, object : MethodChannel.Result {
            override fun success(result: Any?) {
                val map = result as? Map<*, *>
                onOutcome(
                    CommandOutcome(
                        success = map?.get("success") == true,
                        message = (map?.get("message") as? String)?.takeIf { it.isNotBlank() },
                    ),
                )
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                onOutcome(CommandOutcome(false, errorMessage ?: "Command failed"))
            }

            override fun notImplemented() {
                onOutcome(CommandOutcome(false, "Update MeshMapper on your phone"))
            }
        })
    }

    private fun notifyListeners() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { notifyListeners() }
            return
        }
        for (listener in listeners.toList()) listener.onCarStatusChanged()
    }
}
