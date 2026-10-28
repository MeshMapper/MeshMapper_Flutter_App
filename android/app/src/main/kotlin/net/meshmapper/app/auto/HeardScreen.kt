package net.meshmapper.app.auto

import androidx.car.app.CarContext
import androidx.car.app.model.Action
import androidx.car.app.model.ItemList
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.Template
import java.util.Locale
import kotlin.math.roundToInt

/// Most recent repeater observations, newest first, as the snapshot lists
/// them. Read-only: there is nothing to tap on a row while driving.
class HeardScreen(carContext: CarContext) : CarStatusScreen(carContext) {
    override fun onGetTemplate(): Template {
        val snapshot = CarStatusStore.snapshot
        val template = ListTemplate.Builder()
            .setTitle("Recently heard")
            .setHeaderAction(Action.BACK)

        if (snapshot == null) {
            return template.setLoading(true).build()
        }

        val items = ItemList.Builder()
            .setNoItemsMessage("No repeaters heard yet")
        for (node in snapshot.recentHeard.take(MAX_LIST_ROWS)) {
            items.addItem(
                Row.Builder()
                    .setTitle(node.label)
                    .addText(describe(node))
                    .build(),
            )
        }
        return template.setSingleList(items.build()).build()
    }

    companion object {
        /// One-line summary of an observation: path, signal, distance, age.
        fun describe(
            node: CarSnapshot.HeardNode,
            nowMs: Long = System.currentTimeMillis(),
            includeDistance: Boolean = true,
        ): String {
            val parts = buildList {
                kindLabel(node.kind)?.let { add(it) }
                when {
                    node.direct -> add("Direct")
                    node.hopCount != null -> add("${node.hopCount} hop${if (node.hopCount == 1) "" else "s"}")
                }
                node.snr?.let { add(String.format(Locale.US, "SNR %.1f", it)) }
                    ?: node.rssi?.let { add("RSSI $it") }
                if (includeDistance) node.distanceM?.let { add(distanceLabel(it)) }
                if (node.observedAtMs > 0) add(ageLabel(nowMs - node.observedAtMs))
            }
            return parts.joinToString(" · ")
        }

        private fun kindLabel(kind: String?): String? = when (kind) {
            "txEcho" -> "Echo"
            "passiveRx" -> "RX"
            "discovery" -> "Discovery"
            "trace" -> "Trace"
            else -> null
        }

        private fun distanceLabel(meters: Double): String =
            if (meters < 1000) {
                "${meters.roundToInt()} m"
            } else {
                String.format(Locale.US, "%.1f km", meters / 1000)
            }

        private fun ageLabel(ageMs: Long): String {
            val seconds = (ageMs / 1000).coerceAtLeast(0)
            return when {
                seconds < 60 -> "just now"
                seconds < 3600 -> "${seconds / 60} min ago"
                else -> "${seconds / 3600} h ago"
            }
        }
    }
}
