package net.meshmapper.app

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.View

/// A thin  bar down the right edge of the car map, counting to the next ping.
class CarMapTimerBar(context: Context) : View(context) {

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(60, 0, 0, 0)
    }

    private var endsAtMs: Long = 0
    private var durationMs: Long = 0

    /// Set the phase being counted down, or clear it.
    /// Null means the phase is idle or disconnected.
    fun setPhase(endsAtMs: Long?, durationMs: Long?, color: Int?) {
        if (endsAtMs == null || durationMs == null || durationMs <= 0) {
            this.endsAtMs = 0
            this.durationMs = 0
            visibility = GONE
            return
        }
        this.endsAtMs = endsAtMs
        this.durationMs = durationMs
        paint.color = color ?: Color.WHITE
        visibility = VISIBLE
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (durationMs <= 0) return

        val remaining = endsAtMs - System.currentTimeMillis()
        val fraction = (remaining.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f)

        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), trackPaint)
        canvas.drawRect(0f, 0f, width.toFloat(), height * fraction, paint)

        if (remaining > 0) postInvalidateOnAnimation()
    }
}
