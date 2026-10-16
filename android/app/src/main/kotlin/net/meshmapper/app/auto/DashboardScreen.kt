package net.meshmapper.app.auto

import androidx.car.app.CarContext
import androidx.car.app.model.Action
import androidx.car.app.model.ActionStrip
import androidx.car.app.model.CarColor
import androidx.car.app.model.Pane
import androidx.car.app.model.PaneTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.Template

/// The car's home screen: companion, session, counters and the last repeater
/// heard, with the one or two actions that make sense right now.
///
/// Action choice follows the snapshot's own controls block, which Dart builds
/// from the same gates as the phone's buttons. Showing an action is only a
/// hint: Dart re-checks every tap, so a stale template can never transmit.
class DashboardScreen(carContext: CarContext) : CarStatusScreen(carContext) {
    override fun onGetTemplate(): Template {
        val snapshot = CarStatusStore.snapshot
        val pane = Pane.Builder()

        when {
            !CarStatusStore.isAppAttached -> pane
                .addRow(
                    Row.Builder()
                        .setTitle("Open MeshMapper on your phone")
                        .addText("Wardriving runs on the phone. This screen mirrors it.")
                        .build(),
                )
            snapshot == null -> pane.setLoading(true)
            else -> buildDashboard(pane, snapshot)
        }

        return PaneTemplate.Builder(pane.build())
            .setTitle("MeshMapper")
            .setHeaderAction(Action.APP_ICON)
            .setActionStrip(
                ActionStrip.Builder()
                    .addAction(
                        Action.Builder()
                            .setTitle("Heard")
                            .setOnClickListener {
                                screenManager.push(HeardScreen(carContext))
                            }
                            .build(),
                    )
                    .build(),
            )
            .build()
    }

    private fun buildDashboard(pane: Pane.Builder, snapshot: CarSnapshot) {
        pane.addRow(connectionRow(snapshot))
        pane.addRow(sessionRow(snapshot))
        pane.addRow(countsRow(snapshot))
        snapshot.recentHeard.firstOrNull()?.let { pane.addRow(lastHeardRow(it)) }

        for (action in actionsFor(snapshot)) pane.addAction(action)
    }

    private fun connectionRow(snapshot: CarSnapshot): Row {
        val row = Row.Builder()
        if (!snapshot.isConnected) {
            row.setTitle("No companion connected")
            row.addText("Connect a MeshCore companion in the phone app")
            return row.build()
        }
        row.setTitle("Connected to ${snapshot.deviceName ?: "companion"}")
        val details = listOfNotNull(
            snapshot.batteryPercent?.let { "Battery $it%" },
            gpsLabel(snapshot.gpsStatus),
        )
        if (details.isNotEmpty()) row.addText(details.joinToString(" · "))
        return row.build()
    }

    private fun sessionRow(snapshot: CarSnapshot): Row {
        val row = Row.Builder()
        when {
            snapshot.sessionActive -> {
                val mode = CarSnapshot.modeLabel(snapshot.mode)
                row.setTitle(
                    listOfNotNull("$mode mode", snapshot.phaseTitle).joinToString(" · "),
                )
                val detail = listOfNotNull(
                    snapshot.phaseDetail,
                    snapshot.zoneCode?.let { "Zone $it" },
                )
                if (detail.isNotEmpty()) row.addText(detail.joinToString(" · "))
            }
            snapshot.sessionStarting -> row.setTitle("Starting…")
            else -> {
                row.setTitle("Not wardriving")
                val reason = if (snapshot.canStart) null else snapshot.startBlockedReason
                row.addText(reason ?: "Ready to start")
            }
        }
        return row.build()
    }

    private fun countsRow(snapshot: CarSnapshot): Row {
        val counts = buildList {
            add("TX ${snapshot.txCount}")
            add("RX ${snapshot.rxCount}")
            if (snapshot.discoveryCount > 0) add("Disc ${snapshot.discoveryCount}")
            if (snapshot.traceCount > 0) add("Trace ${snapshot.traceCount}")
        }
        val row = Row.Builder().setTitle(counts.joinToString(" · "))
        val heard = snapshot.uniqueRepeatersHeard
        val detail = buildList {
            add("$heard repeater${if (heard == 1) "" else "s"} heard")
            if (snapshot.queueSize > 0) add("${snapshot.queueSize} waiting to upload")
        }
        row.addText(detail.joinToString(" · "))
        return row.build()
    }

    private fun lastHeardRow(node: CarSnapshot.HeardNode): Row =
        Row.Builder()
            .setTitle("Last heard: ${node.label}")
            .addText(HeardScreen.describe(node))
            .build()

    private fun actionsFor(snapshot: CarSnapshot): List<Action> {
        if (snapshot.sessionStarting) return emptyList()

        if (snapshot.sessionActive) {
            return buildList {
                if (snapshot.canStop) {
                    add(
                        Action.Builder()
                            .setTitle("Stop")
                            .setBackgroundColor(CarColor.RED)
                            .setOnClickListener {
                                runCommand(
                                    kind = "stopSession",
                                    sessionId = snapshot.sessionId,
                                    fallbackSuccess = "Stopped",
                                )
                            }
                            .build(),
                    )
                }
                if (snapshot.canManualPing) add(pingAction())
            }
        }

        val modes = snapshot.availableStartModes
        if (!snapshot.canStart || modes.isEmpty()) {
            return if (snapshot.canManualPing) listOf(pingAction()) else emptyList()
        }
        // Passive never transmits, so it is the one-tap start. Transmit modes
        // sit one step deeper, behind an explicit choice.
        val primary = if ("passive" in modes) "passive" else modes.first()
        return buildList {
            add(
                Action.Builder()
                    .setTitle("Start ${CarSnapshot.modeLabel(primary)}")
                    .setBackgroundColor(CarColor.GREEN)
                    .setOnClickListener {
                        runCommand(
                            kind = "startSession",
                            mode = primary,
                            fallbackSuccess = "Started",
                        )
                    }
                    .build(),
            )
            if (modes.size > 1) {
                add(
                    Action.Builder()
                        .setTitle("Other modes")
                        .setOnClickListener {
                            screenManager.push(StartModeScreen(carContext))
                        }
                        .build(),
                )
            } else if (snapshot.canManualPing) {
                add(pingAction())
            }
        }
    }

    private fun pingAction(): Action =
        Action.Builder()
            .setTitle("Ping")
            .setOnClickListener {
                runCommand(kind = "manualPing", fallbackSuccess = "Ping sent")
            }
            .build()

    private fun gpsLabel(status: String?): String? = when (status) {
        null -> null
        "locked" -> "GPS locked"
        "searching" -> "GPS searching"
        "disabled" -> "GPS off"
        "permissionDenied" -> "No location permission"
        else -> "GPS ${status.lowercase()}"
    }
}
