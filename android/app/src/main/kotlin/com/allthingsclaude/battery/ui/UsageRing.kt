package com.allthingsclaude.battery.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.allthingsclaude.battery.core.UsageLevel
import kotlin.math.roundToInt

/**
 * The canonical usage ring — a faithful port of `ios/BatteryKit/UsageRing.swift`.
 *
 * Drawn with a Compose `Canvas` rather than the rasteriser in
 * [UsageRingRenderer]. The two exist for different callers and neither is
 * redundant: Glance widgets have no drawing primitive at all and must be handed
 * a `Bitmap`, while in-app this can animate, respond to theme changes, and stay
 * vector-sharp at any size. Both read their colours from the same [UsageLevel],
 * so they cannot drift in appearance.
 */
@Composable
fun UsageRing(
    utilization: Double,
    modifier: Modifier = Modifier,
    size: Dp = 132.dp,
    label: String? = null,
    caption: String? = null,
) {
    val level = UsageLevel.from(utilization)
    val target = (utilization / 100.0).coerceIn(0.0, 1.0).toFloat()

    // easeInOut over 0.5s, matching the desktop GaugeRingView. The animation is
    // what makes a poll feel like a measurement rather than a repaint.
    val fraction by animateFloatAsState(
        targetValue = target,
        animationSpec = tween(durationMillis = 500),
        label = "ring",
    )

    Box(modifier = modifier.size(size), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(size)) {
            val stroke = this.size.minDimension * STROKE_RATIO
            val inset = stroke / 2f
            val diameter = this.size.minDimension - stroke

            drawArc(
                // SwiftUI's `.quaternary`: the label colour at low alpha, not a
                // grey. It stays legible on both backgrounds without needing a
                // second palette entry.
                color = Color.Gray.copy(alpha = 0.22f),
                startAngle = 0f,
                sweepAngle = 360f,
                useCenter = false,
                topLeft = Offset(inset, inset),
                size = Size(diameter, diameter),
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )

            if (fraction > 0f) {
                drawArc(
                    color = Color(level.color),
                    // -90° puts zero at twelve o'clock; Swift does the same with
                    // a rotationEffect on the trimmed circle.
                    startAngle = -90f,
                    sweepAngle = 360f * fraction,
                    useCenter = false,
                    topLeft = Offset(inset, inset),
                    size = Size(diameter, diameter),
                    style = Stroke(width = stroke, cap = StrokeCap.Round),
                )
            }
        }

        androidx.compose.foundation.layout.Column(
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = label ?: "${utilization.roundToInt()}%",
                color = Color(level.color),
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Bold,
                fontSize = (size.value * TEXT_RATIO).sp,
            )
            caption?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                )
            }
        }
    }
}

private const val STROKE_RATIO = 0.11f
private const val TEXT_RATIO = 0.22f
