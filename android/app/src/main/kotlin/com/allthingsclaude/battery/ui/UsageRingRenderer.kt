package com.allthingsclaude.battery.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import com.allthingsclaude.battery.core.UsageLevel
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Draws the canonical usage ring into a [Bitmap].
 *
 * Glance has no `Canvas` primitive and cannot draw an arc, so the one shared
 * visual identity from `ios/BatteryKit/UsageRing.swift` — a round-capped arc
 * rotated to twelve o'clock over a quaternary track, with a monospaced numeral
 * at the centre — has to be rasterised and handed over as an `ImageProvider`.
 * This is the single largest porting cost in the widget work, and it is worth
 * paying: the alternative is a linear bar in the widgets and a ring everywhere
 * else, which would make the two platforms visibly different products.
 *
 * Rendered fresh per widget update rather than cached. At these sizes the draw
 * is well under a millisecond, and caching would need invalidation on
 * utilization, size bucket, *and* theme — three keys to get wrong in exchange
 * for nothing measurable.
 */
object UsageRingRenderer {

    /**
     * @param sizePx the square edge, in pixels. Callers pass the widget's
     *   measured size times density; passing dp produces a ring that is correct
     *   on exactly one device.
     * @param dark whether to draw for a dark background. Widgets follow the
     *   system, so the caller resolves this from the configuration rather than
     *   from any in-app theme preference.
     */
    fun render(
        utilization: Double,
        sizePx: Int,
        dark: Boolean,
        showLabel: Boolean = true,
    ): Bitmap {
        val size = sizePx.coerceAtLeast(MIN_SIZE_PX)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        val level = UsageLevel.from(utilization)
        val stroke = size * STROKE_RATIO
        val inset = stroke / 2f
        val bounds = RectF(inset, inset, size - inset, size - inset)

        val track = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = stroke
            strokeCap = Paint.Cap.ROUND
            // The desktop and iOS rings use `.quaternary`, which is the label
            // colour at low alpha rather than a grey — it keeps the track
            // readable on both backgrounds without a second palette entry.
            color = if (dark) Color.argb(46, 255, 255, 255) else Color.argb(38, 0, 0, 0)
        }
        canvas.drawArc(bounds, 0f, 360f, false, track)

        val fraction = (utilization / 100.0).coerceIn(0.0, 1.0)
        if (fraction > 0) {
            val arc = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = stroke
                strokeCap = Paint.Cap.ROUND
                color = level.color
            }
            // -90° starts at twelve o'clock; the Swift version achieves the same
            // with a .rotationEffect(-90°) on the trimmed circle.
            canvas.drawArc(bounds, START_ANGLE, (360.0 * fraction).toFloat(), false, arc)
        }

        if (showLabel) {
            val label = "${utilization.roundToInt()}"
            val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = level.color
                textAlign = Paint.Align.CENTER
                // Monospaced so the numeral doesn't jitter as it ticks — the
                // same reason every figure in the iOS app is monospacedDigit().
                typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
                textSize = size * TEXT_RATIO
            }
            // drawText places the baseline, not the centre; without this the
            // numeral sits visibly low inside the ring.
            val baseline = size / 2f - (text.descent() + text.ascent()) / 2f
            canvas.drawText(label, size / 2f, baseline, text)
        }

        return bitmap
    }

    /** A ring sized for a widget cell, given dp and display density. */
    fun renderForDp(
        utilization: Double,
        sizeDp: Int,
        density: Float,
        dark: Boolean,
        showLabel: Boolean = true,
    ): Bitmap = render(utilization, (sizeDp * density).roundToInt(), dark, showLabel)

    private const val START_ANGLE = -90f
    private const val STROKE_RATIO = 0.11f
    private const val TEXT_RATIO = 0.30f

    /**
     * Below this the arc's round caps overlap into a blob and the numeral is
     * unreadable, so a caller asking for something smaller gets this instead of
     * something misleading.
     */
    private const val MIN_SIZE_PX = 48

    /** Exposed for tests and callers that need to keep layout in step. */
    fun strokeWidthPx(sizePx: Int): Float = min(sizePx, sizePx) * STROKE_RATIO
}
