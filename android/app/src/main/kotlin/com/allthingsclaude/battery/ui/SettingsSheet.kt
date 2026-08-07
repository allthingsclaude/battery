package com.allthingsclaude.battery.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.allthingsclaude.battery.core.SessionPolicy
import com.allthingsclaude.battery.data.Settings
import com.allthingsclaude.battery.data.subtitle
import com.allthingsclaude.battery.data.title
import com.allthingsclaude.battery.widget.WidgetBackground

/**
 * Settings. Two choices that actually change behaviour, and nothing else —
 * every other iOS preference either has no Android equivalent (the app-icon
 * picker) or was cut on purpose (Material You).
 */
@Composable
fun SettingsSheet(
    onCardModeChanged: (SessionPolicy.Mode) -> Unit,
    onWidgetBackgroundChanged: () -> Unit,
) {
    val context = LocalContext.current
    val settings = remember { Settings(context) }
    var cardMode by remember { mutableStateOf(settings.cardMode) }
    var widgetBackground by remember { mutableStateOf(WidgetBackground.current(context)) }

    Column(
        Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        SectionHeader("Lock-screen card")
        SessionPolicy.Mode.entries.forEach { mode ->
            ChoiceRow(
                title = mode.title,
                subtitle = mode.subtitle,
                selected = mode == cardMode,
                onClick = {
                    cardMode = mode
                    settings.cardMode = mode
                    onCardModeChanged(mode)
                },
            )
        }

        SectionHeader("Widget background")
        // The launcher's light/dark setting is not the wallpaper. A black
        // wallpaper in light mode is exactly where "follow the system" gives you
        // dark text on black, so the ink is chosen here rather than inferred.
        WidgetBackground.entries.forEach { option ->
            ChoiceRow(
                title = option.title,
                subtitle = option.subtitle,
                selected = option == widgetBackground,
                onClick = {
                    widgetBackground = option
                    WidgetBackground.set(context, option)
                    onWidgetBackgroundChanged()
                },
            )
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text.uppercase(),
        Modifier.padding(top = 18.dp, bottom = 4.dp),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
    )
}

@Composable
private fun ChoiceRow(title: String, subtitle: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(
                if (selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.10f)
                else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = onClick)
        Column(Modifier.padding(start = 4.dp)) {
            Text(title, style = MaterialTheme.typography.bodyMedium)
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
            )
        }
    }
}
