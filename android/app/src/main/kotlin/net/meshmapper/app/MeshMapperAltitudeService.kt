package net.meshmapper.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.Build
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.location.LocationServices
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Describes the location provider's most recent fix object to Dart, so the
/// app can prove whether the altitude the location plugin delivered was the
/// fix's sea level value or its ellipsoid value. Android 14 is the first
/// version whose fixes can carry a sea level altitude, so below it nothing is
/// read and only the SDK is answered.
///
/// This service converts nothing, does no disk I/O and logs nothing: the Dart
/// resolver owns the one throttled warning. It reads one cached fix from the
/// fused provider (or, without Google services, the last known fix of each
/// enabled location manager provider) and answers exactly once, on the main
/// thread, with an empty fix list on any failure. It holds the application
/// context, never the activity.
class MeshMapperAltitudeService(private val context: Context) {
    private companion object {
        const val METHOD_CHANNEL = "meshmapper/altitude"
        const val MSL_SDK = Build.VERSION_CODES.UPSIDE_DOWN_CAKE
    }

    fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "describeLastFix" -> describeLastFix(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun answer(sdk: Int, fixes: List<Map<String, Any?>>): Map<String, Any?> =
        mapOf("sdk" to sdk, "fixes" to fixes)

    /// Answers exactly once. Every branch, including the asynchronous fused
    /// callbacks, is wrapped: an exception anywhere answers an empty list.
    private fun describeLastFix(result: MethodChannel.Result) {
        val sdk = Build.VERSION.SDK_INT
        val empty = answer(sdk, emptyList())
        try {
            if (sdk < MSL_SDK || !hasLocationPermission()) {
                result.success(empty)
                return
            }
            if (!playServicesAvailable()) {
                result.success(answer(sdk, managerFixes()))
                return
            }
            LocationServices.getFusedLocationProviderClient(context).lastLocation
                .addOnSuccessListener { location ->
                    val reply = try {
                        if (location == null) empty else answer(sdk, listOf(describe("fused", location)))
                    } catch (e: Exception) {
                        empty
                    }
                    result.success(reply)
                }
                .addOnFailureListener { result.success(empty) }
        } catch (e: Exception) {
            // SecurityException, a missing Play services class, anything else.
            result.success(empty)
        }
    }

    private fun hasLocationPermission(): Boolean =
        context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /// The same test geolocator makes before choosing its fused client.
    private fun playServicesAvailable(): Boolean = try {
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) ==
            ConnectionResult.SUCCESS
    } catch (e: NoClassDefFoundError) {
        false
    }

    // Only reached when SDK_INT >= MSL_SDK (checked once in describeLastFix),
    // which is what makes the Android 14 Location getters below safe.
    private fun managerFixes(): List<Map<String, Any?>> {
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val fixes = mutableListOf<Map<String, Any?>>()
        for (provider in manager.getProviders(true)) {
            try {
                manager.getLastKnownLocation(provider)?.let { fixes.add(describe("manager:$provider", it)) }
            } catch (e: Exception) {
                // A provider this app may not read contributes nothing.
            }
        }
        return fixes
    }

    private fun describe(source: String, l: Location): Map<String, Any?> = mapOf(
        "source" to source,
        "timeMs" to l.time,
        "lat" to l.latitude,
        "lon" to l.longitude,
        "hasAltitude" to l.hasAltitude(),
        "altitude" to l.altitude,
        "hasVerticalAccuracy" to l.hasVerticalAccuracy(),
        "verticalAccuracy" to l.verticalAccuracyMeters.toDouble(),
        "hasMsl" to l.hasMslAltitude(),
        "msl" to (if (l.hasMslAltitude()) l.mslAltitudeMeters else 0.0),
        "hasMslAccuracy" to l.hasMslAltitudeAccuracy(),
        "mslAccuracy" to (if (l.hasMslAltitudeAccuracy()) l.mslAltitudeAccuracyMeters.toDouble() else 0.0),
        "isMock" to l.isMock,
    )
}
