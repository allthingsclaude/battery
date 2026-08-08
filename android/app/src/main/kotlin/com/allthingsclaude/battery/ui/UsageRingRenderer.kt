package com.allthingsclaude.battery.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import com.allthingsclaude.battery.core.UsageLevel
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
 * Widget rings are rendered fresh per update rather than cached: at those sizes
 * the draw is well under a millisecond, and a cache would need invalidation on
 * utilization, size bucket *and* theme — three keys to get wrong in exchange for
 * nothing measurable. The notification badge is the exception, and [renderBadge]
 * explains why.
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
        strokeRatio: Float = STROKE_RATIO,
        textRatio: Float = TEXT_RATIO,
        /**
         * Track colour, or null to derive one from [dark]. Passed explicitly by
         * callers whose background they cannot know — see [renderBadge].
         */
        trackColor: Int? = null,
    ): Bitmap {
        val size = sizePx.coerceAtLeast(MIN_SIZE_PX)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        val level = UsageLevel.from(utilization)
        val stroke = size * strokeRatio
        val inset = stroke / 2f
        val bounds = RectF(inset, inset, size - inset, size - inset)

        val track = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = stroke
            strokeCap = Paint.Cap.ROUND
            // The desktop and iOS rings use `.quaternary`, which is the label
            // colour at low alpha rather than a grey — it keeps the track
            // readable on both backgrounds without a second palette entry.
            color = trackColor
                ?: if (dark) Color.argb(46, 255, 255, 255) else Color.argb(38, 0, 0, 0)
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
                textSize = size * textRatio
            }
            // drawText places the baseline, not the centre; without this the
            // numeral sits visibly low inside the ring.
            val baseline = size / 2f - (text.descent() + text.ascent()) / 2f
            canvas.drawText(label, size / 2f, baseline, text)
        }

        return bitmap
    }

    /**
     * A ring for the notification's large-icon badge — the circle at the top
     * right of the expanded lock-screen card and the shade entry.
     *
     * **The slot is the system's, not ours.** Its size and its position in the
     * header row are fixed by the notification template; there is no API to
     * enlarge it or move it, and the platform rescaled a 192px bitmap to 113px
     * on an S24 Ultra regardless of what was supplied. What this can control is
     * how much of that circle the drawing actually uses, and at badge size the
     * widget proportions read as a thin hairline with a small numeral floating
     * inside it. Half again the stroke and a numeral nearly half the diameter
     * survive the downscale; the widget ratios do not.
     *
     * The track colour is passed rather than derived because this one bitmap is
     * composited onto two different backgrounds — a light shade in light mode
     * and a dark lock-screen card — and there is no signal saying which. The
     * level colour at low alpha is legible on both, where a black-on-light or
     * white-on-dark track vanishes on one of them.
     */
    fun renderBadge(utilization: Double, sizePx: Int = BADGE_SIZE_PX): Bitmap {
        // Cached, unlike the widget rings, because this one is on a hot path the
        // widgets are not: the notification is rebuilt on every poll *and* on
        // every service start, which now means every app resume, and each rebuild
        // was allocating 196 KiB on the main thread inside onStartCommand —
        // before startForeground, whose deadline is the thing most likely to kill
        // the process.
        //
        // One key, and it is exact rather than approximate: the ring only ever
        // changes when the rounded percentage does, since that is both the arc's
        // resolution and the numeral. The bitmap is handed to setLargeIcon and
        // never mutated, so sharing one instance across notifications is safe.
        val key = utilization.roundToInt() to sizePx
        badgeCache?.let { (cachedKey, bitmap) -> if (cachedKey == key) return bitmap }

        val bitmap = render(
            utilization = utilization,
            sizePx = sizePx,
            // Unused: trackColor is supplied, and the arc and numeral take the
            // level colour, which is the same on either background.
            dark = false,
            showLabel = true,
            strokeRatio = BADGE_STROKE_RATIO,
            textRatio = BADGE_TEXT_RATIO,
            trackColor = (UsageLevel.from(utilization).color and 0x00FFFFFF) or (56 shl 24),
        )
        badgeCache = key to bitmap
        return bitmap
    }

    @Volatile
    private var badgeCache: Pair<Pair<Int, Int>, Bitmap>? = null

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
     * Badge proportions. Deliberately heavier than the widget's — see
     * [renderBadge]. Rendered at 2× the slot's measured 113px so the downscale
     * has something to work with.
     */
    private const val BADGE_STROKE_RATIO = 0.16f
    private const val BADGE_TEXT_RATIO = 0.44f
    private const val BADGE_SIZE_PX = 224

    /**
     * Below this the arc's round caps overlap into a blob and the numeral is
     * unreadable, so a caller asking for something smaller gets this instead of
     * something misleading.
     */
    private const val MIN_SIZE_PX = 48
}
