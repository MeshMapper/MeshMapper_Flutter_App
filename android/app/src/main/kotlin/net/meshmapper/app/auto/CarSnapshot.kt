package net.meshmapper.app.auto

/// Typed view of the snapshot Dart publishes on `meshmapper/android_auto`.
///
/// The map is the Siri projection built by AppStateProvider
/// (`_buildAndroidAutoSnapshotMap`), so the keys here must track
/// siri_snapshot_models.dart. Every read is defensive: a missing or mistyped
/// field renders as unknown instead of crashing the car session.
data class CarSnapshot(
    val isConnected: Boolean,
    val deviceName: String?,
    val batteryPercent: Int?,
    val gpsStatus: String?,
    /// The phone header's noise floor in dBm, and its colour (ARGB).
    val noiseFloor: Int?,
    val noiseFloorColor: Int?,
    val sessionId: String?,
    val sessionActive: Boolean,
    val sessionStarting: Boolean,
    val mode: String,
    val phaseTitle: String?,
    val phaseDetail: String?,
    /// When the current phase's countdown ends (wall clock), or null.
    val phaseEndsAtMs: Long?,
    val zoneCode: String?,
    val txCount: Int,
    val rxCount: Int,
    val discoveryCount: Int,
    val traceCount: Int,
    val queueSize: Int,
    val uniqueRepeatersHeard: Int,
    val availableStartModes: List<String>,
    val canStart: Boolean,
    val startBlockedReason: String?,
    val canStop: Boolean,
    val canManualPing: Boolean,
    val manualPingBlockedReason: String?,
    val recentHeard: List<HeardNode>,
    val map: CarMap,
) {
    /// Everything the car's own MapLibre map draws, resolved in Dart by
    /// android_auto_map_projection.dart so it matches the phone's map.
    data class CarMap(
        val latitude: Double?,
        val longitude: Double?,
        val heading: Double?,
        /// Style URL, or inline style JSON when it starts with `{`.
        val style: String,
        /// Vector coverage tile URL template, or null for no overlay.
        val coverageTiles: String?,
        val coverageOpacity: Float,
        /// `[fill, border]` hex for coverage status 1..6.
        val palette: List<Pair<String, String>>,
        val patchVersion: Int,
        /// `[lat0, lon0, latStep, lonStep, st]` per freshly patched cell.
        val patch: List<DoubleArray>,
    ) {
        val hasPosition: Boolean
            get() = latitude != null && longitude != null

        companion object {
            const val DEFAULT_STYLE = "https://tiles.openfreemap.org/styles/liberty"

            fun fromMap(raw: Any?): CarMap {
                val map = raw as? Map<*, *> ?: emptyMap<Any, Any>()
                val palette = (map["palette"] as? List<*>).orEmpty().mapNotNull { entry ->
                    val pair = entry as? List<*> ?: return@mapNotNull null
                    val fill = pair.getOrNull(0) as? String ?: return@mapNotNull null
                    val border = pair.getOrNull(1) as? String ?: fill
                    fill to border
                }
                val patch = (map["patch"] as? List<*>).orEmpty().mapNotNull { entry ->
                    val cell = entry as? List<*> ?: return@mapNotNull null
                    if (cell.size < 5) return@mapNotNull null
                    val values = cell.take(5).map { (it as? Number)?.toDouble() }
                    if (values.any { it == null || !it.isFinite() }) return@mapNotNull null
                    values.map { it!! }.toDoubleArray()
                }
                return CarMap(
                    latitude = (map["lat"] as? Number)?.toDouble(),
                    longitude = (map["lon"] as? Number)?.toDouble(),
                    heading = (map["heading"] as? Number)?.toDouble(),
                    style = (map["style"] as? String)?.takeIf { it.isNotBlank() } ?: DEFAULT_STYLE,
                    coverageTiles = (map["coverageTiles"] as? String)?.takeIf { it.isNotBlank() },
                    coverageOpacity = ((map["coverageOpacity"] as? Number)?.toFloat() ?: 0.7f)
                        .coerceIn(0f, 1f),
                    palette = palette,
                    patchVersion = (map["patchVersion"] as? Number)?.toInt() ?: 0,
                    patch = patch,
                )
            }
        }
    }

    data class HeardNode(
        val entityId: String?,
        val name: String?,
        val displayHexId: String?,
        val observedAtMs: Long,
        val kind: String?,
        val direct: Boolean,
        val hopCount: Int?,
        val snr: Double?,
        val rssi: Int?,
        val distanceM: Double?,
        val latitude: Double?,
        val longitude: Double?,
    ) {
        /// Stable identity for collapsing repeat observations of one repeater.
        val key: String
            get() = entityId ?: displayHexId ?: label

        val hasLocation: Boolean
            get() = latitude != null && longitude != null &&
                latitude in -90.0..90.0 && longitude in -180.0..180.0 &&
                !(latitude == 0.0 && longitude == 0.0)

        val label: String
            get() = name?.takeIf { it.isNotBlank() } ?: displayHexId ?: "Unknown repeater"
    }

    companion object {
        fun fromMap(raw: Any?): CarSnapshot? {
            val map = raw as? Map<*, *> ?: return null
            val connection = map["connection"] as? Map<*, *> ?: emptyMap<Any, Any>()
            val session = map["session"] as? Map<*, *> ?: emptyMap<Any, Any>()
            val controls = map["controls"] as? Map<*, *> ?: emptyMap<Any, Any>()
            val header = map["header"] as? Map<*, *> ?: emptyMap<Any, Any>()
            val heard = (map["recentHeard"] as? List<*>).orEmpty().mapNotNull { item ->
                val node = item as? Map<*, *> ?: return@mapNotNull null
                HeardNode(
                    entityId = node.string("entityId"),
                    name = node.string("name"),
                    displayHexId = node.string("displayHexId"),
                    observedAtMs = node.long("observedAtMs") ?: 0L,
                    kind = node.string("kind"),
                    direct = node["direct"] == true,
                    hopCount = node.int("hopCount"),
                    snr = node.double("snr"),
                    rssi = node.int("rssi"),
                    distanceM = node.double("distanceM"),
                    latitude = node.double("repeaterLat"),
                    longitude = node.double("repeaterLon"),
                )
            }
            return CarSnapshot(
                isConnected = connection["isConnected"] == true,
                deviceName = connection.string("deviceName"),
                batteryPercent = connection.int("batteryPercent"),
                gpsStatus = connection.string("gpsStatus"),
                noiseFloor = header.int("noiseFloor"),
                noiseFloorColor = (header["noiseFloorColor"] as? Number)?.toLong()?.toInt(),
                sessionId = session.string("id"),
                sessionActive = session["active"] == true,
                sessionStarting = session["starting"] == true,
                mode = session.string("mode") ?: "idle",
                phaseTitle = session.string("phaseTitle"),
                phaseDetail = session.string("phaseDetail"),
                phaseEndsAtMs = session.long("phaseEndsAtMs"),
                zoneCode = session.string("zoneCode"),
                txCount = session.int("txCount") ?: 0,
                rxCount = session.int("rxCount") ?: 0,
                discoveryCount = session.int("discoveryCount") ?: 0,
                traceCount = session.int("traceCount") ?: 0,
                queueSize = session.int("queueSize") ?: 0,
                uniqueRepeatersHeard = session.int("uniqueRepeatersHeard") ?: 0,
                availableStartModes = (controls["availableStartModes"] as? List<*>)
                    .orEmpty().filterIsInstance<String>(),
                canStart = controls["canStart"] == true,
                startBlockedReason = controls.string("startBlockedReason"),
                canStop = controls["canStop"] == true,
                canManualPing = controls["canManualPing"] == true,
                manualPingBlockedReason = controls.string("manualPingBlockedReason"),
                recentHeard = heard,
                map = CarMap.fromMap(map["map"]),
            )
        }

        /// Display name for a wire mode, matching AutoMode.displayName in Dart.
        fun modeLabel(mode: String): String = when (mode) {
            "active" -> "Active"
            "passive" -> "Passive"
            "hybrid" -> "Hybrid"
            "targeted" -> "Trace"
            else -> mode.replaceFirstChar { it.uppercase() }
        }

        private fun Map<*, *>.string(key: String): String? =
            (this[key] as? String)?.takeIf { it.isNotEmpty() }

        private fun Map<*, *>.int(key: String): Int? = (this[key] as? Number)?.toInt()

        private fun Map<*, *>.long(key: String): Long? = (this[key] as? Number)?.toLong()

        private fun Map<*, *>.double(key: String): Double? = (this[key] as? Number)?.toDouble()
    }
}
