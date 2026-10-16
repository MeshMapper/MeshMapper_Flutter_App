package net.meshmapper.app.auto

import android.app.Presentation
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Point
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
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
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.FillLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.android.style.sources.TileSet
import org.maplibre.android.style.sources.VectorSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.Point as GeoPoint
import org.maplibre.geojson.Polygon
import net.meshmapper.app.R
import kotlin.math.ln

/// Draws MeshMapper's map onto the car display.
///
/// Android Auto hands navigation apps a Surface and nothing else, so the map
/// is a real MapLibre [MapView] hosted in a [Presentation] on a private
/// [VirtualDisplay] backed by that Surface. It paints what the phone's Map tab
/// paints, from the snapshot Dart publishes: the user's base style, the vector
/// coverage overlay with the same palette, the session's freshly patched
/// cells on top, recently heard repeaters, and the position arrow.
///
/// The camera follows the driver until they pan; [recenter] resumes following.
class CarMapRenderer(private val carContext: CarContext) : SurfaceCallback {
    private var virtualDisplay: VirtualDisplay? = null
    private var presentation: Presentation? = null
    private var mapView: MapView? = null
    private var batteryBadge: LinearLayout? = null
    private var statusCard: LinearLayout? = null

    /// Re-renders the status card once a second so the countdown ticks
    /// between snapshots, the way the phone's status bar does.
    private val tickHandler = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            if (statusCard == null) return
            refreshStatus()
            tickHandler.postDelayed(this, 1000L)
        }
    }
    private var map: MapLibreMap? = null
    private var loadedStyle: String? = null
    private var styleReady = false

    private var surfaceWidth = 0
    private var surfaceHeight = 0
    private var visibleArea: Rect? = null

    private var zoom = DEFAULT_ZOOM
    private var following = true

    /// Heading-up (the direction of travel points up, like Google Maps while
    /// driving) or north-up. Heading-up is the default.
    var headingUp = true
        private set

    /// The last bearing the camera used, kept while the car is stopped and
    /// GPS reports no heading, so the map does not snap back to north.
    private var lastBearing = 0.0

    /// Told when following or orientation changes, so the screen can swap
    /// the centre button's icon.
    var onModeChanged: (() -> Unit)? = null

    val isFollowing: Boolean
        get() = following

    /// A style picked on the car, overriding the phone's until the session
    /// ends. Null follows the phone's preference.
    private var styleOverride: String? = null

    private var appliedCoverage: CoverageKey? = null
    private var appliedPatchVersion = -1

    private data class CoverageKey(val tiles: String, val palette: List<Pair<String, String>>)

    // --- SurfaceCallback ----------------------------------------------------

    override fun onSurfaceAvailable(surfaceContainer: SurfaceContainer) {
        val surface = surfaceContainer.surface ?: return
        teardown()
        surfaceWidth = surfaceContainer.width
        surfaceHeight = surfaceContainer.height

        MapLibre.getInstance(carContext.applicationContext)
        val displayManager = carContext.getSystemService(DisplayManager::class.java)
        val display = displayManager.createVirtualDisplay(
            "MeshMapperCarMap",
            surfaceContainer.width,
            surfaceContainer.height,
            surfaceContainer.dpi,
            surface,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY,
        )
        virtualDisplay = display

        val shown = Presentation(carContext, display.display)
        val options = MapLibreMapOptions.createFromAttributes(shown.context)
            .textureMode(true)
            .compassEnabled(false)
            .logoEnabled(false)
            .attributionEnabled(true)
        val view = MapView(shown.context, options)
        val badge = createHeaderBadge(shown.context)
        val root = FrameLayout(shown.context).apply {
            addView(view, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ))
            addView(badge, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.END,
            ))
        }
        batteryBadge = badge
        val card = createStatusCard(shown.context)
        root.addView(card, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.START,
        ))
        statusCard = card
        layoutBatteryBadge()
        layoutStatusCard()
        refreshStatus()
        tickHandler.removeCallbacks(tick)
        tickHandler.postDelayed(tick, 1000L)
        shown.setContentView(root)
        view.onCreate(null)
        shown.show()
        view.onStart()
        view.onResume()
        presentation = shown
        mapView = view

        view.getMapAsync { mapLibreMap ->
            if (mapView !== view) return@getMapAsync
            map = mapLibreMap
            mapLibreMap.uiSettings.apply {
                isRotateGesturesEnabled = false
                isTiltGesturesEnabled = false
            }
            mapLibreMap.setMinZoomPreference(MIN_ZOOM)
            mapLibreMap.setMaxZoomPreference(MAX_ZOOM)
            CarStatusStore.snapshot?.let { update(it) } ?: loadStyle(CarSnapshot.CarMap.DEFAULT_STYLE)
        }
    }

    override fun onVisibleAreaChanged(visibleArea: Rect) {
        this.visibleArea = visibleArea
        layoutBatteryBadge()
        layoutStatusCard()
        CarStatusStore.snapshot?.let { moveCamera(it.map, animate = false) }
    }

    override fun onStableAreaChanged(stableArea: Rect) = Unit

    override fun onSurfaceDestroyed(surfaceContainer: SurfaceContainer) {
        teardown()
    }

    override fun onScroll(distanceX: Float, distanceY: Float) {
        val target = map ?: return
        if (following) {
            following = false
            onModeChanged?.invoke()
        }
        target.scrollBy(-distanceX, -distanceY, 0)
    }

    override fun onScale(focusX: Float, focusY: Float, scaleFactor: Float) {
        val target = map ?: return
        val focus = if (focusX < 0 || focusY < 0) null else Point(focusX.toInt(), focusY.toInt())
        val delta = ln(scaleFactor.toDouble()) / ln(2.0)
        target.moveCamera(
            if (focus == null) CameraUpdateFactory.zoomBy(delta) else CameraUpdateFactory.zoomBy(delta, focus),
        )
        zoom = target.cameraPosition.zoom
    }

    // --- Controls -----------------------------------------------------------

    fun zoomIn() = zoomBy(1.0)

    fun zoomOut() = zoomBy(-1.0)

    /// The centre button, Google Maps style: re-centres when the driver has
    /// panned away, otherwise switches between heading-up and north-up.
    fun centreButtonTapped() {
        if (following) {
            headingUp = !headingUp
        } else {
            following = true
            zoom = DEFAULT_ZOOM
        }
        onModeChanged?.invoke()
        CarStatusStore.snapshot?.let { moveCamera(it.map, animate = true) }
    }

    /// Cycles Liberty → Dark → Bright → Satellite on the car only, the phone's
    /// own cycle order, starting from whatever the phone is using.
    fun cycleStyle() {
        val current = styleOverride ?: CarStatusStore.snapshot?.map?.style ?: CarSnapshot.CarMap.DEFAULT_STYLE
        val index = STYLE_CYCLE.indexOfFirst { it == current }
        styleOverride = STYLE_CYCLE[(index + 1).mod(STYLE_CYCLE.size)]
        CarStatusStore.snapshot?.let { update(it) }
    }

    private fun zoomBy(delta: Double) {
        val target = map ?: return
        zoom = (target.cameraPosition.zoom + delta).coerceIn(MIN_ZOOM, MAX_ZOOM)
        target.easeCamera(CameraUpdateFactory.zoomTo(zoom), 300)
    }

    // --- Snapshot -----------------------------------------------------------

    fun update(snapshot: CarSnapshot) {
        updateBatteryBadge(snapshot)
        refreshStatus()
        val target = map ?: return
        val wanted = styleOverride ?: snapshot.map.style
        if (wanted != loadedStyle) {
            loadStyle(wanted)
            return
        }
        val style = target.style ?: return
        if (!styleReady || !style.isFullyLoaded) return

        applyCoverage(style, snapshot.map)
        applyPatch(style, snapshot.map)
        applyRepeaters(style, snapshot)
        applyPuck(style, snapshot.map)
        moveCamera(snapshot.map, animate = true)
    }

    private fun loadStyle(style: String) {
        val target = map ?: return
        loadedStyle = style
        styleReady = false
        appliedCoverage = null
        appliedPatchVersion = -1
        val builder = if (style.trimStart().startsWith("{")) {
            Style.Builder().fromJson(style)
        } else {
            Style.Builder().fromUri(style)
        }
        target.setStyle(builder) { loaded ->
            if (loadedStyle != style) return@setStyle
            loaded.addImage(PUCK_IMAGE, puckBitmap())
            styleReady = true
            CarStatusStore.snapshot?.let { update(it) }
        }
    }

    private fun applyCoverage(style: Style, carMap: CarSnapshot.CarMap) {
        val tiles = carMap.coverageTiles
        val key = tiles?.let { CoverageKey(it, carMap.palette) }
        if (key != appliedCoverage) {
            style.removeLayer(COVERAGE_LAYER)
            style.removeSource(COVERAGE_SOURCE)
            appliedCoverage = null
            if (key != null) {
                val tileSet = TileSet("2.1.0", key.tiles).apply {
                    setMinZoom(2f)
                    setMaxZoom(14f)
                }
                style.addSource(VectorSource(COVERAGE_SOURCE, tileSet))
                val layer = FillLayer(COVERAGE_LAYER, COVERAGE_SOURCE).withSourceLayer("coverage")
                layer.setProperties(
                    PropertyFactory.fillColor(paletteExpression(carMap.palette, border = false)),
                    PropertyFactory.fillOutlineColor(paletteExpression(carMap.palette, border = true)),
                )
                addBelowOverlays(style, layer)
                appliedCoverage = key
            }
        }
        style.getLayer(COVERAGE_LAYER)?.setProperties(PropertyFactory.fillOpacity(carMap.coverageOpacity))
    }

    /// The session's own freshly scored cells, painted over the base overlay
    /// with the same styling, as the phone's patch layer does.
    private fun applyPatch(style: Style, carMap: CarSnapshot.CarMap) {
        val features = carMap.patch.map { cell ->
            val (lat0, lon0, latStep, lonStep, st) = cell
            val ring = listOf(
                GeoPoint.fromLngLat(lon0, lat0),
                GeoPoint.fromLngLat(lon0 + lonStep, lat0),
                GeoPoint.fromLngLat(lon0 + lonStep, lat0 + latStep),
                GeoPoint.fromLngLat(lon0, lat0 + latStep),
                GeoPoint.fromLngLat(lon0, lat0),
            )
            Feature.fromGeometry(Polygon.fromLngLats(listOf(ring))).apply {
                addNumberProperty("st", st.toInt())
            }
        }
        val collection = FeatureCollection.fromFeatures(features)
        val source = style.getSourceAs<GeoJsonSource>(PATCH_SOURCE)
        if (source == null) {
            style.addSource(GeoJsonSource(PATCH_SOURCE, collection))
            val layer = FillLayer(PATCH_LAYER, PATCH_SOURCE)
            addBelowOverlays(style, layer)
        } else if (carMap.patchVersion != appliedPatchVersion) {
            source.setGeoJson(collection)
        }
        appliedPatchVersion = carMap.patchVersion
        style.getLayer(PATCH_LAYER)?.setProperties(
            PropertyFactory.fillColor(paletteExpression(carMap.palette, border = false)),
            PropertyFactory.fillOutlineColor(paletteExpression(carMap.palette, border = true)),
            PropertyFactory.fillOpacity(if (carMap.coverageTiles == null) 0f else carMap.coverageOpacity),
        )
    }

    private fun applyRepeaters(style: Style, snapshot: CarSnapshot) {
        val features = snapshot.recentHeard
            .distinctBy { it.key }
            .filter { it.hasLocation }
            .map { node ->
                Feature.fromGeometry(GeoPoint.fromLngLat(node.longitude!!, node.latitude!!)).apply {
                    addStringProperty("label", node.label)
                    addBooleanProperty("direct", node.direct)
                }
            }
        val collection = FeatureCollection.fromFeatures(features)
        val source = style.getSourceAs<GeoJsonSource>(REPEATER_SOURCE)
        if (source != null) {
            source.setGeoJson(collection)
            return
        }
        style.addSource(GeoJsonSource(REPEATER_SOURCE, collection))
        style.addLayer(
            CircleLayer(REPEATER_DOT_LAYER, REPEATER_SOURCE).withProperties(
                PropertyFactory.circleRadius(7f),
                PropertyFactory.circleColor(
                    Expression.switchCase(
                        Expression.get("direct"),
                        Expression.color(Color.parseColor("#1e7e34")),
                        Expression.color(Color.parseColor("#2196F3")),
                    ),
                ),
                PropertyFactory.circleStrokeColor(Color.WHITE),
                PropertyFactory.circleStrokeWidth(2f),
            ),
        )
        style.addLayer(
            SymbolLayer(REPEATER_LABEL_LAYER, REPEATER_SOURCE).withProperties(
                PropertyFactory.textField(Expression.get("label")),
                PropertyFactory.textFont(arrayOf("Noto Sans Regular")),
                PropertyFactory.textSize(13f),
                PropertyFactory.textOffset(arrayOf(0f, 1.3f)),
                PropertyFactory.textColor(Color.WHITE),
                PropertyFactory.textHaloColor(Color.BLACK),
                PropertyFactory.textHaloWidth(1.5f),
                PropertyFactory.textAllowOverlap(false),
            ),
        )
    }

    private fun applyPuck(style: Style, carMap: CarSnapshot.CarMap) {
        val lat = carMap.latitude
        val lon = carMap.longitude
        val features = if (lat == null || lon == null) {
            emptyList()
        } else {
            listOf(
                Feature.fromGeometry(GeoPoint.fromLngLat(lon, lat)).apply {
                    addNumberProperty("heading", carMap.heading ?: 0.0)
                },
            )
        }
        val collection = FeatureCollection.fromFeatures(features)
        val source = style.getSourceAs<GeoJsonSource>(PUCK_SOURCE)
        if (source != null) {
            source.setGeoJson(collection)
            return
        }
        style.addSource(GeoJsonSource(PUCK_SOURCE, collection))
        style.addLayer(
            SymbolLayer(PUCK_LAYER, PUCK_SOURCE).withProperties(
                PropertyFactory.iconImage(PUCK_IMAGE),
                PropertyFactory.iconRotate(Expression.get("heading")),
                PropertyFactory.iconRotationAlignment(Property.ICON_ROTATION_ALIGNMENT_MAP),
                PropertyFactory.iconAllowOverlap(true),
                PropertyFactory.iconIgnorePlacement(true),
            ),
        )
    }

    /// Coverage and patch sit beneath the repeater and puck layers, which are
    /// added after them, but above every layer of the base style.
    private fun addBelowOverlays(style: Style, layer: FillLayer) {
        val anchor = listOf(REPEATER_DOT_LAYER, PUCK_LAYER).firstOrNull { style.getLayer(it) != null }
        if (anchor != null) style.addLayerBelow(layer, anchor) else style.addLayer(layer)
        // The patch must stay above the base overlay whichever was added first.
        if (layer.id == COVERAGE_LAYER && style.getLayer(PATCH_LAYER) != null) {
            style.removeLayer(COVERAGE_LAYER)
            style.addLayerBelow(layer, PATCH_LAYER)
        }
    }

    private fun moveCamera(carMap: CarSnapshot.CarMap, animate: Boolean) {
        val target = map ?: return
        if (!following) return
        val lat = carMap.latitude ?: return
        val lon = carMap.longitude ?: return
        val area = visibleArea
        val heading = carMap.heading
        if (heading != null) lastBearing = heading
        val bearing = if (headingUp) lastBearing else 0.0
        val builder = CameraPosition.Builder()
            .target(LatLng(lat, lon))
            .zoom(zoom)
            .bearing(bearing)
        if (area != null && surfaceWidth > 0 && surfaceHeight > 0) {
            // Heading-up puts the car in the lower part of the view, as a
            // navigation map does, so more of the road ahead is visible.
            val ahead = if (headingUp) area.height() * HEADING_UP_LOOK_AHEAD else 0.0
            builder.padding(
                area.left.toDouble(),
                area.top.toDouble() + ahead,
                (surfaceWidth - area.right).toDouble().coerceAtLeast(0.0),
                (surfaceHeight - area.bottom).toDouble().coerceAtLeast(0.0),
            )
        }
        val update = CameraUpdateFactory.newCameraPosition(builder.build())
        if (animate) target.easeCamera(update, 900) else target.moveCamera(update)
    }

    /// The phone header's two readings, noise floor and companion battery,
    /// in one box at the top right of the map, under the host's buttons.
    /// Drawn on our surface rather than by the host, so it stays inside the
    /// visible area the host reports.
    private fun createHeaderBadge(context: android.content.Context): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            val padH = dp(context, 12f)
            val padV = dp(context, 8f)
            setPadding(padH, padV, padH, padV)
            background = GradientDrawable().apply {
                cornerRadius = dp(context, 12f).toFloat()
                setColor(Color.argb(230, 0x1E, 0x29, 0x3B))
            }
            // [speaker][-115dBm]  [battery][97%], each icon centred on its text.
            addView(headerIcon(context))
            addView(headerText(context))
            addView(headerIcon(context).apply {
                (layoutParams as LinearLayout.LayoutParams).marginStart = dp(context, 14f)
            })
            addView(headerText(context))
            visibility = android.view.View.GONE
        }

    private fun headerIcon(context: android.content.Context): android.widget.ImageView =
        android.widget.ImageView(context).apply {
            val size = dp(context, HEADER_ICON_DP)
            layoutParams = LinearLayout.LayoutParams(size, size).apply {
                gravity = Gravity.CENTER_VERTICAL
                marginEnd = dp(context, 4f)
            }
            scaleType = android.widget.ImageView.ScaleType.FIT_CENTER
        }

    private fun headerText(context: android.content.Context): TextView =
        TextView(context).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { gravity = Gravity.CENTER_VERTICAL }
            gravity = Gravity.CENTER_VERTICAL
            // Same size as the status card's top line.
            setTextSize(TypedValue.COMPLEX_UNIT_SP, HEADER_TEXT_SP)
            typeface = Typeface.DEFAULT_BOLD
            includeFontPadding = false
        }

    private fun layoutBatteryBadge() {
        val badge = batteryBadge ?: return
        val params = badge.layoutParams as? FrameLayout.LayoutParams ?: return
        val margin = dp(badge.context, 10f)
        val area = visibleArea
        params.gravity = Gravity.TOP or Gravity.END
        params.topMargin = margin + (area?.top ?: 0).coerceAtLeast(0)
        params.rightMargin = margin +
            if (area != null && surfaceWidth > 0) (surfaceWidth - area.right).coerceAtLeast(0) else 0
        badge.layoutParams = params
    }

    private fun updateBatteryBadge(snapshot: CarSnapshot) {
        val badge = batteryBadge ?: return
        if (!snapshot.isConnected) {
            badge.visibility = android.view.View.GONE
            return
        }
        val context = badge.context
        val iconSize = dp(context, HEADER_ICON_DP)

        val noiseColor = snapshot.noiseFloorColor ?: Color.GRAY
        (badge.getChildAt(0) as android.widget.ImageView).apply {
            setImageResource(R.drawable.ic_car_volume_up)
            setColorFilter(noiseColor)
        }
        (badge.getChildAt(1) as TextView).apply {
            text = snapshot.noiseFloor?.let { "${it}dBm" } ?: "--dBm"
            setTextColor(noiseColor)
        }

        val percent = snapshot.batteryPercent
        val batteryColor = when {
            percent == null -> Color.GRAY
            percent >= 50 -> Color.parseColor("#4CAF50")
            percent >= 20 -> Color.parseColor("#FF9800")
            else -> Color.parseColor("#F44336")
        }
        (badge.getChildAt(2) as android.widget.ImageView)
            .setImageBitmap(batteryBitmap(iconSize, percent, batteryColor))
        (badge.getChildAt(3) as TextView).apply {
            text = percent?.let { "$it%" } ?: "--%"
            setTextColor(batteryColor)
        }

        badge.visibility = android.view.View.VISIBLE
    }

    /// A vertical battery like the phone header's, filled to the level.
    private fun batteryBitmap(size: Int, percent: Int?, color: Int): Bitmap {
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val unit = size / 24f
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
        // Terminal nub, then the body outline.
        canvas.drawRect(9.5f * unit, 2f * unit, 14.5f * unit, 4f * unit, paint)
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 1.6f * unit
        canvas.drawRoundRect(7f * unit, 4f * unit, 17f * unit, 22f * unit, 1.5f * unit, 1.5f * unit, paint)
        // Fill from the bottom, in proportion to the charge.
        val level = ((percent ?: 0).coerceIn(0, 100)) / 100f
        if (level > 0f) {
            paint.style = Paint.Style.FILL
            val top = 21f - 16f * level
            canvas.drawRect(8.6f * unit, top * unit, 15.4f * unit, 20.4f * unit, paint)
        }
        return bitmap
    }

    /// The phone's status bar and counter chips, drawn top left: the phase
    /// with its countdown, then the counters.
    private fun createStatusCard(context: android.content.Context): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            val padH = dp(context, 12f)
            val padV = dp(context, 8f)
            setPadding(padH, padV, padH, padV)
            background = GradientDrawable().apply {
                cornerRadius = dp(context, 12f).toFloat()
                setColor(Color.argb(230, 0x1E, 0x29, 0x3B))
            }
            addView(cardLine(context, 17f * CARD_SCALE, bold = true, color = Color.WHITE))
            addView(cardLine(context, 15f * CARD_SCALE, bold = false, color = Color.parseColor("#CBD5E1")))
        }

    private fun cardLine(context: android.content.Context, sizeSp: Float, bold: Boolean, color: Int): TextView =
        TextView(context).apply {
            // Each line is only as wide as its own text, so the card shrinks
            // back when a long line goes away instead of keeping its width.
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
            if (bold) typeface = Typeface.DEFAULT_BOLD
            setTextColor(color)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            // Box hugs the text: no extra space above and below each line.
            includeFontPadding = false
            setPadding(0, dp(context, 1f), 0, dp(context, 1f))
        }

    private fun layoutStatusCard() {
        val card = statusCard ?: return
        val params = card.layoutParams as? FrameLayout.LayoutParams ?: return
        val margin = dp(card.context, 10f)
        val area = visibleArea
        params.leftMargin = margin + (area?.left ?: 0).coerceAtLeast(0)
        params.topMargin = margin + (area?.top ?: 0).coerceAtLeast(0)
        // Never run under the header box on the right.
        val width = if (area != null) area.width() else surfaceWidth
        if (width > 0) card.maxWidthFor((width * 0.6f).toInt())
        card.layoutParams = params
    }

    private fun LinearLayout.maxWidthFor(px: Int) {
        for (i in 0 until childCount) (getChildAt(i) as? TextView)?.maxWidth = px
    }

    /// Redraws the status card from the latest snapshot.
    fun refreshStatus() {
        val card = statusCard ?: return
        val lines = CarStatusText.lines(CarStatusStore.snapshot, CarStatusStore.isAppAttached)
        val values = listOf(lines.status, lines.chips)
        values.forEachIndexed { index, value ->
            val view = card.getChildAt(index) as TextView
            view.text = value ?: ""
            view.visibility = if (value.isNullOrBlank()) android.view.View.GONE else android.view.View.VISIBLE
        }
        card.requestLayout()
    }

    private fun dp(context: android.content.Context, value: Float): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, context.resources.displayMetrics).toInt()

    private fun teardown() {
        tickHandler.removeCallbacks(tick)
        statusCard = null
        batteryBadge = null
        map = null
        styleReady = false
        loadedStyle = null
        appliedCoverage = null
        appliedPatchVersion = -1
        mapView?.let {
            try {
                it.onPause()
                it.onStop()
                it.onDestroy()
            } catch (error: RuntimeException) {
                Log.w(TAG, "MapView teardown failed", error)
            }
        }
        mapView = null
        presentation?.dismiss()
        presentation = null
        virtualDisplay?.release()
        virtualDisplay = null
    }

    fun dispose() = teardown()

    companion object {
        private const val TAG = "MeshMapperCarMap"

        /// Type size of the header box (noise floor and battery).
        private const val HEADER_TEXT_SP = 17f

        /// The status card's type, scaled up from the header's sizes.
        private const val CARD_SCALE = 1.4f
        private const val HEADER_ICON_DP = 20f

        /// Share of the visible height added above the car in heading-up mode.
        private const val HEADING_UP_LOOK_AHEAD = 0.35

        /// The phone map's "closer zoom for driving".
        const val DEFAULT_ZOOM = 15.0
        private const val MIN_ZOOM = 3.0
        private const val MAX_ZOOM = 16.999

        private const val COVERAGE_SOURCE = "meshmapper-car-coverage"
        private const val COVERAGE_LAYER = "meshmapper-car-coverage-layer"
        private const val PATCH_SOURCE = "meshmapper-car-patch"
        private const val PATCH_LAYER = "meshmapper-car-patch-layer"
        private const val REPEATER_SOURCE = "meshmapper-car-repeaters"
        private const val REPEATER_DOT_LAYER = "meshmapper-car-repeater-dots"
        private const val REPEATER_LABEL_LAYER = "meshmapper-car-repeater-labels"
        private const val PUCK_SOURCE = "meshmapper-car-puck"
        private const val PUCK_LAYER = "meshmapper-car-puck-layer"
        private const val PUCK_IMAGE = "meshmapper-car-puck-arrow"

        private val STYLE_CYCLE = listOf(
            "https://tiles.openfreemap.org/styles/liberty",
            "https://tiles.openfreemap.org/styles/dark",
            "https://tiles.openfreemap.org/styles/bright",
            SATELLITE_STYLE_JSON,
        )

        /// Same inline style as lib/utils/map_style_urls.dart, kept in step
        /// so the car's own style cycle can reach satellite.
        private const val SATELLITE_STYLE_JSON =
            "{\"version\":8,\"glyphs\":\"https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf\"," +
                "\"sources\":{\"satellite\":{\"type\":\"raster\",\"tiles\":[\"https://server.arcgisonline.com/" +
                "ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}\"],\"tileSize\":256," +
                "\"maxzoom\":17}},\"layers\":[{\"id\":\"satellite-layer\",\"type\":\"raster\",\"source\":\"satellite\"}]}"

        /// `match(get("st"), 1, c1, … 5, c5, c6)`: st 6 doubles as the default
        /// so unknown codes paint red, as CoverageTilePalette does in Dart.
        private fun paletteExpression(palette: List<Pair<String, String>>, border: Boolean): Expression {
            val colors = (1..6).map { st ->
                val pair = palette.getOrNull(st - 1) ?: FALLBACK_PALETTE[st - 1]
                parse(if (border) pair.second else pair.first)
            }
            return Expression.match(
                Expression.toNumber(Expression.get("st")),
                Expression.color(colors[5]),
                *(0 until 5).map { Expression.stop(it + 1, Expression.color(colors[it])) }.toTypedArray(),
            )
        }

        private val FALLBACK_PALETTE = listOf(
            "#1e7e34" to "#14522d",
            "#17a2b8" to "#117a8b",
            "#fd7e14" to "#d96b0c",
            "#6f42c1" to "#59359a",
            "#6c757d" to "#545b62",
            "#bd2130" to "#8b101b",
        )

        private fun parse(hex: String): Int =
            try {
                Color.parseColor(hex)
            } catch (_: IllegalArgumentException) {
                Color.GRAY
            }

        /// The phone's default arrow puck: a blue arrow inside a white outline.
        private fun puckBitmap(): Bitmap {
            val size = 48
            val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            canvas.translate(size / 2f, size / 2f)
            canvas.scale(size / 24f, size / 24f)
            val outline = Path().apply {
                moveTo(0f, -11f); lineTo(8f, 9f); lineTo(0f, 4f); lineTo(-8f, 9f); close()
            }
            val arrow = Path().apply {
                moveTo(0f, -9f); lineTo(6f, 7f); lineTo(0f, 3f); lineTo(-6f, 7f); close()
            }
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            paint.color = Color.WHITE
            canvas.drawPath(outline, paint)
            paint.color = Color.parseColor("#2196F3")
            canvas.drawPath(arrow, paint)
            return bitmap
        }
    }
}
