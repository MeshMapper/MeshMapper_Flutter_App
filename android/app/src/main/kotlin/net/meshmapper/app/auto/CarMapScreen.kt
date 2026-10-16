package net.meshmapper.app.auto

import androidx.car.app.AppManager
import androidx.car.app.CarContext
import androidx.car.app.model.Action
import androidx.car.app.model.ActionStrip
import androidx.car.app.model.CarColor
import androidx.car.app.model.CarIcon
import androidx.car.app.model.Template
import androidx.car.app.navigation.model.NavigationTemplate
import androidx.core.graphics.drawable.IconCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import net.meshmapper.app.R

/// The car's home screen: the phone's Map tab, laid out for a head unit.
///
/// Android Auto gives a navigation app a full-screen map plus fixed slots, so
/// the phone's layout maps onto them:
///  - the map itself (base style, coverage squares, live session cells,
///    heard repeaters, position arrow) is drawn by [CarMapRenderer];
///  - the top counter chips (TX, RX, discovery, trace, upload queue) and the
///    status bar become a status card drawn on the map, top left;
///  - the right-hand map buttons become the map action strip (pan, zoom,
///    recentre);
///  - the controls panel becomes the action strip (Start/Stop, Ping, map
///    style, and More for the dashboard with the other modes and heard list).
class CarMapScreen(carContext: CarContext) : CarStatusScreen(carContext) {
    private val renderer = CarMapRenderer(carContext)

    private val mapListener = CarStatusStore.Listener {
        val snapshot = CarStatusStore.snapshot
        if (snapshot != null) renderer.update(snapshot) else renderer.refreshStatus()
    }

    init {
        renderer.onModeChanged = { invalidate() }
        carContext.getCarService(AppManager::class.java).setSurfaceCallback(renderer)
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onCreate(owner: LifecycleOwner) {
                // The map follows every snapshot even while another screen is
                // pushed on top, so it is current when the driver comes back.
                CarStatusStore.addListener(mapListener)
            }

            override fun onDestroy(owner: LifecycleOwner) {
                CarStatusStore.removeListener(mapListener)
                renderer.dispose()
            }
        })
    }

    /// The status card (phase and countdown, counters, detail) is drawn on
    /// the map by [CarMapRenderer] rather than as the host's navigation info,
    /// so its type size and layout match the phone instead of the host's.
    override fun onGetTemplate(): Template {
        val snapshot = CarStatusStore.snapshot
        return NavigationTemplate.Builder()
            .setActionStrip(actionStrip(snapshot))
            .setMapActionStrip(mapActionStrip())
            .setBackgroundColor(CarColor.createCustom(0xFF1E293B.toInt(), 0xFF1E293B.toInt()))
            .build()
    }

    private fun actionStrip(snapshot: CarSnapshot?): ActionStrip {
        val strip = ActionStrip.Builder()
        if (snapshot != null && !snapshot.sessionStarting) {
            when {
                snapshot.sessionActive && snapshot.canStop -> strip.addAction(
                    Action.Builder()
                        .setTitle("Stop")
                        .setOnClickListener {
                            runCommand(
                                kind = "stopSession",
                                sessionId = snapshot.sessionId,
                                fallbackSuccess = "Stopped",
                            )
                        }
                        .build(),
                )
                !snapshot.sessionActive && snapshot.canStart &&
                    "passive" in snapshot.availableStartModes -> strip.addAction(
                    Action.Builder()
                        .setTitle("Start")
                        .setOnClickListener {
                            runCommand(
                                kind = "startSession",
                                mode = "passive",
                                fallbackSuccess = "Started",
                            )
                        }
                        .build(),
                )
            }
            if (snapshot.canManualPing) {
                strip.addAction(
                    Action.Builder()
                        .setTitle("Ping")
                        .setOnClickListener {
                            runCommand(kind = "manualPing", fallbackSuccess = "Ping sent")
                        }
                        .build(),
                )
            }
        }
        strip.addAction(iconAction(R.drawable.ic_car_layers) { renderer.cycleStyle() })
        strip.addAction(
            iconAction(R.drawable.ic_car_more) { screenManager.push(DashboardScreen(carContext)) },
        )
        return strip.build()
    }

    private fun mapActionStrip(): ActionStrip =
        ActionStrip.Builder()
            .addAction(Action.PAN)
            .addAction(iconAction(R.drawable.ic_car_zoom_in) { renderer.zoomIn() })
            .addAction(iconAction(R.drawable.ic_car_zoom_out) { renderer.zoomOut() })
            .addAction(iconAction(centreIcon()) { renderer.centreButtonTapped() })
            .build()

    /// Re-centre after panning; otherwise the mode a tap switches to
    /// shows as the current one, as Google Maps' compass button does.
    private fun centreIcon(): Int = when {
        !renderer.isFollowing -> R.drawable.ic_car_my_location
        renderer.headingUp -> R.drawable.ic_car_heading_up
        else -> R.drawable.ic_car_north_up
    }

    private fun iconAction(icon: Int, onClick: () -> Unit): Action =
        Action.Builder()
            .setIcon(CarIcon.Builder(IconCompat.createWithResource(carContext, icon)).build())
            .setOnClickListener { onClick() }
            .build()
}
