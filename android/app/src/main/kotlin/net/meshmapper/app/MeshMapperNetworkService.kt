package net.meshmapper.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

/// Reports whether the device's active default network is a bandwidth-constrained
/// link (e.g. satellite), per Android's constrained-networks API introduced in
/// API 36 (Android 16):
/// https://developer.android.com/develop/connectivity/satellite/constrained-networks
///
/// Older OS versions have no notion of NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED,
/// so every network on them reports the bit unset. Treating its absence as
/// "constrained" would flag every pre-16 network as constrained. We only run
/// the check on API 36+ and otherwise always report "not constrained".
class MeshMapperNetworkService(private val context: Context) {
    private companion object {
        const val EVENT_CHANNEL = "meshmapper/network_state"
        const val LOG_TAG = "MeshMapperNetwork"
        const val MIN_SDK_FOR_CONSTRAINED_CHECK = 36
    }

    private val connectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private var handlerThread: HandlerThread? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    @Volatile private var eventSink: EventChannel.EventSink? = null

    fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                        eventSink = events
                        startMonitoring()
                    }
                    override fun onCancel(arguments: Any?) {
                        stopMonitoring()
                        eventSink = null
                    }
                },
            )
    }

    fun dispose() {
        stopMonitoring()
    }

    private fun startMonitoring() {
        if (Build.VERSION.SDK_INT < MIN_SDK_FOR_CONSTRAINED_CHECK) {
            emit(stateMap(constrained = false, satellite = false))
            return
        }

        val thread = HandlerThread("MeshMapperNetworkMonitor").also { it.start() }
        handlerThread = thread
        val handler = Handler(thread.looper)

        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED)
            .build()

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(
                network: Network,
                capabilities: NetworkCapabilities,
            ) {
                emitFrom(capabilities)
            }

            override fun onLost(network: Network) {
                emit(stateMap(constrained = false, satellite = false))
            }
        }
        networkCallback = callback
        try {
            connectivityManager.registerBestMatchingNetworkCallback(request, callback, handler)
        } catch (error: RuntimeException) {
            networkCallback = null
            handlerThread?.quitSafely()
            handlerThread = null
            Log.w(LOG_TAG, "[NETWORK] Failed to monitor constrained networks", error)
            emit(stateMap(constrained = false, satellite = false))
        }
    }

    private fun emitFrom(capabilities: NetworkCapabilities) {
        val satellite = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_SATELLITE)
        val constrained =
            satellite ||
                !capabilities.hasCapability(
                    NetworkCapabilities.NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED,
                )
        emit(stateMap(constrained, satellite))
    }

    private fun stateMap(constrained: Boolean, satellite: Boolean): Map<String, Any> =
        mapOf("constrained" to constrained, "satellite" to satellite)

    /// EventSink.success() must run on the main thread; NetworkCallback
    /// methods fire on the HandlerThread registered for them.
    private fun emit(state: Map<String, Any>) {
        mainHandler.post { eventSink?.success(state) }
    }

    private fun stopMonitoring() {
        networkCallback?.let {
            try {
                connectivityManager.unregisterNetworkCallback(it)
            } catch (_: IllegalArgumentException) {
            }
        }
        networkCallback = null
        handlerThread?.quitSafely()
        handlerThread = null
    }
}
