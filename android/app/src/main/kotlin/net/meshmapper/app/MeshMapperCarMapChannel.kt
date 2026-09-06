package net.meshmapper.app

import androidx.car.app.CarContext
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Dart's channel for the car map.
object MeshMapperCarMapChannel {
    private const val CHANNEL = "meshmapper/car_map"

    @Volatile
    private var renderer: MeshMapperCarMap? = null

    /// Installed into `FAASurfaceProvider.factory` by [MeshMapperApplication].
    fun create(carContext: CarContext): MeshMapperCarMap =
        MeshMapperCarMap(carContext).also { renderer = it }

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                val map = renderer
                when (call.method) {
                    // True if there is a car screen to draw on.
                    "isAttached" -> result.success(map != null)

                    "setCamera" -> {
                        val lat = call.argument<Double>("lat")
                        val lon = call.argument<Double>("lon")
                        if (lat == null || lon == null) {
                            result.error("bad_args", "lat and lon are required", null)
                        } else {
                            map?.setCamera(
                                lat,
                                lon,
                                call.argument<Double>("bearing"),
                                call.argument<Double>("heading"),
                                call.argument<Double>("zoom"),
                            )
                            result.success(map != null)
                        }
                    }

                    "setStyle" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrEmpty()) {
                            result.error("bad_args", "url is required", null)
                        } else {
                            map?.setStyle(url)
                            result.success(map != null)
                        }
                    }

                    "setCoverage" -> {
                        val tileUrl = call.argument<String>("tileUrl")
                        map?.setCoverage(
                            if (tileUrl.isNullOrEmpty()) {
                                null
                            } else {
                                CarMapCoverage(
                                    tileUrl = tileUrl,
                                    fillColorExpression =
                                        call.argument<String>("fillColor") ?: "",
                                    outlineColorExpression =
                                        call.argument<String>("outlineColor") ?: "",
                                    opacity =
                                        (call.argument<Double>("opacity") ?: 0.7).toFloat(),
                                    minZoom =
                                        (call.argument<Double>("minZoom") ?: 7.0).toFloat(),
                                    maxZoom =
                                        (call.argument<Double>("maxZoom") ?: 14.0).toFloat(),
                                )
                            },
                        )
                        result.success(map != null)
                    }

                    "setPositionMarker" -> {
                        val png = call.argument<ByteArray>("png")
                        if (png == null) {
                            result.error("bad_args", "png is required", null)
                        } else {
                            map?.setPositionMarker(
                                png,
                                call.argument<Boolean>("facesHeading") ?: true,
                            )
                            result.success(map != null)
                        }
                    }

                    "setPings" -> {
                        map?.setPings(call.argument<String>("geoJson") ?: "")
                        result.success(map != null)
                    }

                    "setTimer" -> {
                        val endsAt = (call.argument<Number>("endsAtMs"))?.toLong()
                        val duration = (call.argument<Number>("durationMs"))?.toLong()
                        val color = (call.argument<Number>("color"))?.toInt()
                        map?.setTimer(endsAt, duration, color)
                        result.success(map != null)
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
