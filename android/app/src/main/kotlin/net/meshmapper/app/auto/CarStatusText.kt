package net.meshmapper.app.auto

/// The words on the car map's status card, the phone's status bar and
/// counter chips in short form.
object CarStatusText {
    data class Lines(val status: String, val chips: String?, val detail: String?)

    private val DISCOVERY = Regex("discovery", RegexOption.IGNORE_CASE)

    fun lines(snapshot: CarSnapshot?, appAttached: Boolean, nowMs: Long = System.currentTimeMillis()): Lines {
        if (!appAttached) {
            return Lines("Open MeshMapper on your phone", null, "This screen mirrors the phone")
        }
        if (snapshot == null) return Lines("Connecting to MeshMapper…", null, null)

        val status = when {
            !snapshot.isConnected -> "No companion connected"
            // The phase alone, as the phone's bar shows it ("Next disc 13s").
            snapshot.sessionActive ->
                snapshot.phaseTitle?.let(::shortPhase) ?: CarSnapshot.modeLabel(snapshot.mode)
            snapshot.sessionStarting -> "Starting…"
            else -> "Not wardriving"
        }
        val seconds = countdownSeconds(snapshot, nowMs)
        val chips = listOf(
            "↑${snapshot.txCount}",
            "↓${snapshot.rxCount}",
            "◎${snapshot.discoveryCount}",
            "⇅${snapshot.traceCount}",
            "☁${snapshot.queueSize}",
        ).joinToString("  ")
        val detail = when {
            snapshot.sessionActive -> snapshot.phaseDetail
            !snapshot.isConnected -> null
            !snapshot.canStart -> snapshot.startBlockedReason
            else -> snapshot.deviceName
        }
        return Lines(
            status = if (seconds != null) "$status  ${seconds}s" else status,
            chips = chips,
            detail = detail,
        )
    }

    /// Whole seconds left on the running phase, rounded up so the car never
    /// shows 0s while the phone still shows 1s. Null when nothing counts down.
    fun countdownSeconds(snapshot: CarSnapshot?, nowMs: Long = System.currentTimeMillis()): Long? {
        if (snapshot == null || !snapshot.sessionActive) return null
        val endsAt = snapshot.phaseEndsAtMs ?: return null
        val remainingMs = endsAt - nowMs
        if (remainingMs <= 0) return null
        return (remainingMs + 999) / 1000
    }

    /// "Discovery" becomes "disc" so the countdown fits on the line.
    fun shortPhase(title: String): String =
        DISCOVERY.replace(title) { if (it.value[0].isUpperCase()) "Disc" else "disc" }
}
