package net.meshmapper.app.auto

import androidx.car.app.model.Action
import androidx.car.app.model.ItemList
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.Template
import androidx.car.app.CarContext

/// Lets the driver pick a transmit mode. Only modes the phone currently allows
/// are listed; the list empties itself (and the screen closes) once a session
/// is running, so a second tap cannot be aimed at a stale choice.
class StartModeScreen(carContext: CarContext) : CarStatusScreen(carContext) {
    override fun onGetTemplate(): Template {
        val snapshot = CarStatusStore.snapshot
        val template = ListTemplate.Builder()
            .setTitle("Start wardriving")
            .setHeaderAction(Action.BACK)

        if (snapshot == null) return template.setLoading(true).build()

        val items = ItemList.Builder()
            .setNoItemsMessage(
                when {
                    snapshot.sessionActive -> "A session is already running"
                    else -> snapshot.startBlockedReason ?: "No modes available right now"
                },
            )
        if (!snapshot.sessionActive && !snapshot.sessionStarting) {
            for (mode in snapshot.availableStartModes) {
                items.addItem(
                    Row.Builder()
                        .setTitle(CarSnapshot.modeLabel(mode))
                        .addText(describe(mode))
                        .setOnClickListener {
                            runCommand(
                                kind = "startSession",
                                mode = mode,
                                fallbackSuccess = "Started",
                            )
                            finish()
                        }
                        .build(),
                )
            }
        }
        return template.setSingleList(items.build()).build()
    }

    private fun describe(mode: String): String = when (mode) {
        "passive" -> "Listen only, never transmits"
        "active" -> "Pings as you move and logs repeater echoes"
        "hybrid" -> "Alternates discovery and active pings"
        else -> ""
    }
}
