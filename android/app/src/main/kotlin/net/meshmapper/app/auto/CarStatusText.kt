package net.meshmapper.app.auto

/// The words on the car map's status card, the phone's status bar and
/// counter chips in short form.
///
/// Two lines only. The phone's phase detail ("Waiting for a square with no
/// recent mapping") is left out: it changes with every phase, and a card
/// sized to fit it widened and shrank every few seconds.
object CarStatusText {
    data class Lines(val status: String, val chips: String?)

    private val DISCOVERY = Regex("discovery", RegexOption.IGNORE_CASE)

    fun lines(snapshot: CarSnapshot?, appAttached: Boolean, nowMs: Long = System.currentTimeMillis()): Lines {
        if (!appAttached) {
            return Lines("Open MeshMapper on your phone", null)
        }
        if (snapshot == null) return Lines("Connecting to MeshMapper…", null)

        val status = when {
            !snapshot.isConnected -> "No companion connected"
            // The phase alone, as the phone's bar shows it ("Next disc 13s").
            snapshot.sessionActive ->
                snapshot.phaseTitle?.let(::shortPhase) ?: CarSnapshot.modeLabel(snapshot.mode)
            snapshot.sessionStarting -> "Starting…"
            // Idle with Start unavailable: the reason is the only explanation
            // the car gives for the missing button.
            !snapshot.canStart -> snapshot.startBlockedReason ?: "Not wardriving"
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
        return Lines(
            status = if (seconds != null) "$status  ${seconds}s" else status,
            chips = chips,
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
