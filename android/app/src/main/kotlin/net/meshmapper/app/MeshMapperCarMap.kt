package net.meshmapper.app

import android.app.Presentation
import android.content.Context
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.os.Bundle
import android.util.Log
import android.view.Display
import android.view.Gravity
import android.view.Surface
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.car.app.CarContext
import androidx.car.app.SurfaceCallback
import androidx.car.app.SurfaceContainer
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapLibreMapOptions
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression
import org.maplibre.android.style.layers.FillLayer
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.TileSet
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.android.style.sources.VectorSource

/// Renders MeshMapper's map onto the android auto display
class MeshMapperCarMap(private val carContext: CarContext) : SurfaceCallback {

    private companion object {
        const val TAG = "MeshMapperCarMap"

        /// The car reports its own density; this is only the fallback when a
        /// SurfaceContainer arrives without one.
        const val FALLBACK_DPI = 160

        const val DEFAULT_ZOOM = 14.0

        const val COVERAGE_SOURCE_ID = "meshmapper-car-coverage"
        const val COVERAGE_LAYER_ID = "meshmapper-car-coverage-layer"

        /// The layer name inside the vector tiles vector_tile.php emits.
        const val COVERAGE_SOURCE_LAYER = "coverage"

        const val PINGS_SOURCE_ID = "meshmapper-car-pings"
        const val PINGS_LAYER_ID = "meshmapper-car-pings-layer"

        /// Big enough to see at a glance from the driver's seat, small enough
        /// that a dense run does not become one solid blob.
        const val PING_RADIUS_DP = 12.0f
        const val PING_STROKE_DP = 1.5f
        const val PING_STROKE_OPACITY = 0.6f

        const val POSITION_SOURCE_ID = "meshmapper-car-position"
        const val POSITION_LAYER_ID = "meshmapper-car-position-layer"
        const val POSITION_IMAGE_ID = "meshmapper-car-position-icon"
    }

    private var virtualDisplay: VirtualDisplay? = null
    private var presentation: MapPresentation? = null

    private var pendingCamera: CameraPosition? = null
    private var pendingStyleUrl: String? = null
    private var appliedStyleUrl: String? = null
    private var pendingCoverage: CarMapCoverage? = null
    private var pendingPings: String? = null
    private var pendingTimer: Triple<Long, Long, Int?>? = null
    private var pendingMarker: Bitmap? = null
    private var pendingMarkerFacesHeading = true
    private var pendingHeading: Double? = null

    // ---------------------------------------------------------------- surface

    override fun onSurfaceAvailable(container: SurfaceContainer) {
        val surface = container.surface
        if (surface == null || container.width <= 0 || container.height <= 0) {
            Log.w(TAG, "Surface available with nothing to draw on")
            return
        }
        tearDown()

        val dpi = if (container.dpi > 0) container.dpi else FALLBACK_DPI
        val display = DisplayManager::class.java.let {
            (carContext.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager)
                .createVirtualDisplay(
                    "MeshMapperCarMap",
                    container.width,
                    container.height,
                    dpi,
                    surface,
                    // PRESENTATION marks it as a display we intend to show a presentation on.
                    // OWN_CONTENT_ONLY keeps the phone from being mirrored to the car screen.
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION or
                        DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY,
                )
        }
        if (display == null) {
            Log.e(TAG, "Could not create a virtual display for the car surface")
            return
        }
        virtualDisplay = display

        presentation = MapPresentation(carContext, display.display).also {
            it.show()
            pendingMarker?.let { bmp ->
                it.setPositionMarker(bmp, pendingMarkerFacesHeading)
            }
            it.applyPending(pendingStyleUrl, pendingCamera, pendingCoverage, pendingPings)
            pendingCamera?.let { cam ->
                it.setPosition(cam.target!!.latitude, cam.target!!.longitude, pendingHeading)
            }
            pendingTimer.let { t -> it.setTimer(t?.first, t?.second, t?.third) }
        }
        Log.i(TAG, "Car map attached (${container.width}x${container.height} @ ${dpi}dpi)")
    }

    override fun onSurfaceDestroyed(container: SurfaceContainer) {
        Log.i(TAG, "Car map detached")
        tearDown()
    }

    /// The region the host guarantees is available.
    override fun onVisibleAreaChanged(visibleArea: Rect) {
        val map = presentation?.map ?: return
        val view = presentation?.mapView ?: return
        if (visibleArea.isEmpty) return

        val rightInset = (view.width - visibleArea.right).coerceAtLeast(0)
        map.setPadding(
            visibleArea.left,
            visibleArea.top,
            rightInset,
            (view.height - visibleArea.bottom).coerceAtLeast(0),
        )
        presentation?.setTimerInsets(
            right = rightInset,
            top = visibleArea.top.coerceAtLeast(0),
            bottom = (view.height - visibleArea.bottom).coerceAtLeast(0),
        )
    }

    override fun onStableAreaChanged(stableArea: Rect) {
        // NO-OP
    }

    // --------------------------------------------------------------- gestures

    override fun onScroll(distanceX: Float, distanceY: Float) {
        presentation?.map?.let { it.scrollBy(-distanceX, -distanceY) }
    }

    override fun onScale(focusX: Float, focusY: Float, scaleFactor: Float) {
        val map = presentation?.map ?: return
        val zoom = map.cameraPosition.zoom + kotlin.math.log2(scaleFactor.toDouble())
        map.moveCamera(CameraUpdateFactory.zoomTo(zoom))
    }

    override fun onFling(velocityX: Float, velocityY: Float) {
        // NO-OP
    }

    // ------------------------------------------------------------------- data

    /// Called from Dart via [MeshMapperCarMapChannel].
    fun setCamera(
        lat: Double,
        lon: Double,
        bearing: Double?,
        heading: Double?,
        zoom: Double?,
    ) {
        val position = CameraPosition.Builder()
            .target(LatLng(lat, lon))
            .zoom(zoom ?: DEFAULT_ZOOM)
            .apply { bearing?.let { bearing(it) } }
            .build()
        pendingCamera = position
        pendingHeading = heading
        presentation?.map?.moveCamera(CameraUpdateFactory.newCameraPosition(position))
        presentation?.setPosition(lat, lon, heading)
    }

    fun setPositionMarker(png: ByteArray, facesHeading: Boolean) {
        val bitmap = BitmapFactory.decodeByteArray(png, 0, png.size) ?: run {
            Log.e(TAG, "Could not decode the position marker")
            return
        }
        pendingMarker = bitmap
        pendingMarkerFacesHeading = facesHeading
        presentation?.setPositionMarker(bitmap, facesHeading)
    }

    /// The style the phone map is currently using
    fun setStyle(url: String) {
        if (url == appliedStyleUrl) return
        pendingStyleUrl = url
        presentation?.setStyle(url) { appliedStyleUrl = url }
    }

    /// The coverage overlay, the same vector tiles the phone map draws.
    fun setCoverage(coverage: CarMapCoverage?) {
        if (coverage == pendingCoverage) return
        pendingCoverage = coverage
        presentation?.setCoverage(coverage)
    }

    /// The ping markers, a GeoJSON FeatureCollection built by Dart.
    fun setPings(geoJson: String) {
        if (geoJson == pendingPings) return
        pendingPings = geoJson
        presentation?.setPings(geoJson)
    }

    /// The next-ping countdown. Null will clear it.
    fun setTimer(endsAtMs: Long?, durationMs: Long?, color: Int?) {
        pendingTimer = if (endsAtMs != null && durationMs != null) {
            Triple(endsAtMs, durationMs, color)
        } else {
            null
        }
        presentation?.setTimer(endsAtMs, durationMs, color)
    }

    private fun tearDown() {
        presentation?.let {
            runCatching { it.dismiss() }
        }
        presentation = null
        virtualDisplay?.release()
        virtualDisplay = null
    }

    /// The window that actually lives on the car display.
    private class MapPresentation(
        context: Context,
        display: Display,
    ) : Presentation(context, display) {

        var mapView: MapView? = null
            private set
        var map: MapLibreMap? = null
            private set

        private var styleUrl: String? = null
        private var camera: CameraPosition? = null
        private var onStyleLoaded: (() -> Unit)? = null
        private var coverage: CarMapCoverage? = null
        private var pings: String? = null
        private var timerBar: CarMapTimerBar? = null
        private var markerBitmap: Bitmap? = null
        private var markerFacesHeading = true
        private var position: Triple<Double, Double, Double?>? = null

        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)

            MapLibre.getInstance(context)

            val options = MapLibreMapOptions.createFromAttributes(context)
                .compassEnabled(false)
                .logoEnabled(false)
                .attributionEnabled(false)
                .rotateGesturesEnabled(false)
                .scrollGesturesEnabled(false)
                .tiltGesturesEnabled(false)
                .zoomGesturesEnabled(false)

            val view = MapView(context, options)
            mapView = view
            view.onCreate(savedInstanceState)
            view.onStart()
            view.onResume()
            view.getMapAsync { ready ->
                map = ready
                camera?.let { ready.moveCamera(CameraUpdateFactory.newCameraPosition(it)) }
                styleUrl?.let { url ->
                    val loaded = onStyleLoaded
                    ready.setStyle(styleBuilder(url)) { style ->
                        applyOverlays(style)
                        loaded?.invoke()
                    }
                }
            }

            val bar = CarMapTimerBar(context).apply { visibility = View.GONE }
            timerBar = bar

            setContentView(
                FrameLayout(context).apply {
                    layoutParams = ViewGroup.LayoutParams(MATCH, MATCH)
                    addView(view, FrameLayout.LayoutParams(MATCH, MATCH, Gravity.CENTER))
                    addView(
                        bar,
                        FrameLayout.LayoutParams(
                            (TIMER_BAR_DP * context.resources.displayMetrics.density).toInt(),
                            MATCH,
                            Gravity.END,
                        ),
                    )
                },
            )
        }

        fun applyPending(
            style: String?,
            position: CameraPosition?,
            pendingCoverage: CarMapCoverage?,
            pendingPings: String?,
        ) {
            coverage = pendingCoverage
            pings = pendingPings
            position?.let {
                camera = it
                map?.moveCamera(CameraUpdateFactory.newCameraPosition(it))
            }
            style?.let { setStyle(it, onStyleLoaded) }
        }

        fun setStyle(url: String, onLoaded: (() -> Unit)? = null) {
            styleUrl = url
            onStyleLoaded = onLoaded
            map?.setStyle(styleBuilder(url)) { style ->
                applyOverlays(style)
                onLoaded?.invoke()
            }
        }

        private fun styleBuilder(style: String): Style.Builder {
            val trimmed = style.trimStart()
            return if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
                Style.Builder().fromJson(style)
            } else {
                Style.Builder().fromUri(style)
            }
        }

        fun setCoverage(next: CarMapCoverage?) {
            coverage = next
            map?.style?.let { applyOverlays(it) }
        }

        fun setTimer(endsAtMs: Long?, durationMs: Long?, color: Int?) {
            timerBar?.setPhase(endsAtMs, durationMs, color)
        }

        /// Keep the bar inside the area the host is not drawing over.
        fun setTimerInsets(right: Int, top: Int, bottom: Int) {
            val bar = timerBar ?: return
            val params = bar.layoutParams as? FrameLayout.LayoutParams ?: return
            if (params.rightMargin == right &&
                params.topMargin == top &&
                params.bottomMargin == bottom
            ) {
                return
            }
            params.rightMargin = right
            params.topMargin = top
            params.bottomMargin = bottom
            bar.layoutParams = params
        }

        fun setPositionMarker(bitmap: Bitmap, facesHeading: Boolean) {
            markerBitmap = bitmap
            markerFacesHeading = facesHeading
            map?.style?.let { applyOverlays(it) }
        }

        fun setPosition(lat: Double, lon: Double, heading: Double?) {
            position = Triple(lat, lon, heading)
            val style = map?.style ?: return
            val source = style.getSourceAs<GeoJsonSource>(POSITION_SOURCE_ID)
            if (source == null) {
                applyOverlays(style)
                return
            }
            source.setGeoJson(positionGeoJson(lat, lon))
            style.getLayerAs<SymbolLayer>(POSITION_LAYER_ID)
                ?.setProperties(PropertyFactory.iconRotate(markerRotation(heading)))
        }

        private fun markerRotation(heading: Double?): Float {
            if (!markerFacesHeading || heading == null) return 0f
            val bearing = map?.cameraPosition?.bearing ?: 0.0
            return ((heading - bearing).toFloat() % 360f + 360f) % 360f
        }

        private fun positionGeoJson(lat: Double, lon: Double): String =
            """{"type":"Feature","geometry":{"type":"Point","coordinates":[$lon,$lat]}}"""

        fun setPings(next: String) {
            pings = next
            val source = map?.style?.getSourceAs<GeoJsonSource>(PINGS_SOURCE_ID)
            if (source != null) source.setGeoJson(next) else map?.style?.let { applyOverlays(it) }
        }

        private fun applyOverlays(style: Style) {
            applyCoverage(style)
            applyPings(style)
            applyPositionMarker(style)
        }

        private fun applyPositionMarker(style: Style) {
            style.getLayer(POSITION_LAYER_ID)?.let { style.removeLayer(it) }
            style.getSource(POSITION_SOURCE_ID)?.let { style.removeSource(it) }

            val bitmap = markerBitmap ?: return
            val here = position ?: return
            try {
                style.addImage(POSITION_IMAGE_ID, bitmap)
                style.addSource(
                    GeoJsonSource(POSITION_SOURCE_ID, positionGeoJson(here.first, here.second)),
                )
                val layer = SymbolLayer(POSITION_LAYER_ID, POSITION_SOURCE_ID)
                layer.setProperties(
                    PropertyFactory.iconImage(POSITION_IMAGE_ID),
                    PropertyFactory.iconRotate(markerRotation(here.third)),
                    PropertyFactory.iconAllowOverlap(true),
                    PropertyFactory.iconIgnorePlacement(true),
                )
                style.addLayer(layer)
            } catch (e: Exception) {
                Log.e(TAG, "Could not apply the position marker", e)
            }
        }

        /// Ping markers, above the coverage.
        private fun applyPings(style: Style) {
            style.getLayer(PINGS_LAYER_ID)?.let { style.removeLayer(it) }
            style.getSource(PINGS_SOURCE_ID)?.let { style.removeSource(it) }

            val data = pings ?: return
            try {
                style.addSource(GeoJsonSource(PINGS_SOURCE_ID, data))
                val layer = CircleLayer(PINGS_LAYER_ID, PINGS_SOURCE_ID)
                layer.setProperties(
                    PropertyFactory.circleColor(Expression.get("color")),
                    PropertyFactory.circleRadius(PING_RADIUS_DP),
                    PropertyFactory.circleStrokeWidth(PING_STROKE_DP),
                    PropertyFactory.circleStrokeColor("#000000"),
                    PropertyFactory.circleStrokeOpacity(PING_STROKE_OPACITY),
                )
                style.addLayer(layer)
            } catch (e: Exception) {
                Log.e(TAG, "Could not apply the ping markers", e)
            }
        }

        private fun applyCoverage(style: Style) {
            style.getLayer(COVERAGE_LAYER_ID)?.let { style.removeLayer(it) }
            style.getSource(COVERAGE_SOURCE_ID)?.let { style.removeSource(it) }

            val config = coverage ?: return
            try {
                style.addSource(
                    VectorSource(
                        COVERAGE_SOURCE_ID,
                        TileSet(TILEJSON_VERSION, config.tileUrl).apply {
                            minZoom = config.minZoom
                            maxZoom = config.maxZoom
                        },
                    ),
                )

                val layer = FillLayer(COVERAGE_LAYER_ID, COVERAGE_SOURCE_ID)
                    .withSourceLayer(COVERAGE_SOURCE_LAYER)
                layer.setProperties(
                    PropertyFactory.fillColor(
                        Expression.Converter.convert(config.fillColorExpression),
                    ),
                    PropertyFactory.fillOutlineColor(
                        Expression.Converter.convert(config.outlineColorExpression),
                    ),
                    PropertyFactory.fillOpacity(config.opacity),
                )

                style.addLayer(layer)
            } catch (e: Exception) {
                Log.e(TAG, "Could not apply the coverage overlay", e)
            }
        }

        override fun onStop() {
            mapView?.let {
                it.onPause()
                it.onStop()
                it.onDestroy()
            }
            mapView = null
            map = null
            super.onStop()
        }

        private companion object {
            const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
            const val TILEJSON_VERSION = "2.2.0"
            const val TIMER_BAR_DP = 8
        }
    }
}
