package com.allthingsclaude.battery.ui

import androidx.annotation.ColorRes
import androidx.annotation.DrawableRes
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.GenericShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.allthingsclaude.battery.BuildConfig
import com.allthingsclaude.battery.R
import com.allthingsclaude.battery.core.ReleaseFeed
import com.allthingsclaude.battery.core.SessionPolicy
import com.allthingsclaude.battery.data.Account
import com.allthingsclaude.battery.data.Settings
import com.allthingsclaude.battery.data.subtitle
import com.allthingsclaude.battery.data.title
import com.allthingsclaude.battery.launcher.AppIcon
import com.allthingsclaude.battery.live.NowBarGate

/**
 * Settings.
 *
 * Everything that is a setting lives here, which was not true of the first cut:
 * sign-out sat in the bottom bar next to navigation, the account list existed in
 * `UsageRepository` with no UI at all, and the Phase 0 diagnostics harness had a
 * permanent tab in a shipping app. All three were wrong in the same way — the
 * bottom bar is for getting around, not for actions and not for dev tools.
 */
@Composable
fun SettingsSheet(
    accounts: List<Account>,
    selectedAccountId: String?,
    onCardModeChanged: (SessionPolicy.Mode) -> Unit,
    onSelectAccount: (String) -> Unit,
    onRenameAccount: (String, String) -> Unit,
    onRemoveAccount: (String) -> Unit,
    onAddAccount: () -> Unit,
    onSignOut: () -> Unit,
    onOpenDiagnostics: () -> Unit,
    updateState: UpdateUiState,
    appIcon: AppIcon,
    onAppIconChange: (AppIcon) -> Unit,
) {
    val context = LocalContext.current
    val settings = remember { Settings(context) }
    var cardMode by remember { mutableStateOf(settings.cardMode) }
    var renaming by remember { mutableStateOf<Account?>(null) }
    var confirmSignOut by remember { mutableStateOf(false) }

    Column(
        Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        SectionHeader("Accounts")
        accounts.forEach { account ->
            AccountRow(
                account = account,
                selected = account.id == selectedAccountId,
                onSelect = { onSelectAccount(account.id) },
                onRename = { renaming = account },
                onRemove = { onRemoveAccount(account.id) },
                canRemove = accounts.size > 1,
            )
        }
        ActionRow("Add account", "Sign in to another Claude account", onAddAccount)

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

        SectionHeader("Now Bar")
        val gate = remember { NowBarGate.state(context) }
        when (gate) {
            NowBarGate.State.ENABLED -> StatusNote(
                "Enabled — the session card appears on the Now Bar, the lock " +
                    "screen and the status bar."
            )
            NowBarGate.State.NOT_APPLICABLE -> StatusNote(
                "Not applicable on this device. The lock-screen card and widgets " +
                    "work regardless."
            )
            else -> NowBarGate.advice(gate)?.let { advice ->
                StatusNote(advice.body)
                ActionRow(
                    title = advice.action,
                    subtitle = "Samsung keeps this outside app settings",
                    onClick = { NowBarGate.settingsIntent(gate)?.let(context::startActivity) },
                )
            }
        }

        SectionHeader("Widgets")
        Text(
            "Opacity and colours live on each widget: long-press it on the home " +
                "screen and tap the gear. Per-widget rather than app-wide, because " +
                "one setting rarely suits a widget on a dark page and one on a light one.",
            Modifier.padding(horizontal = 4.dp, vertical = 4.dp),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
        )

        // Debug builds only. It's the Phase 0 harness — useful while the Now Bar
        // questions in android/NOW_BAR.md are open, and no business shipping.
        // iOS gates its equivalent (demo mode) the same way.
        if (BuildConfig.DEBUG) {
            SectionHeader("Developer")
            ActionRow("Diagnostics", "Post a test card, inspect promotion state", onOpenDiagnostics)
        }

        SectionHeader("App icon")
        IconPicker(appIcon, onAppIconChange)

        SectionHeader("About")
        UpdateRow(updateState)

        SectionHeader("Account")
        ActionRow(
            "Sign out",
            "Removes every account and its stored credentials",
            { confirmSignOut = true },
            destructive = true,
        )
    }

    renaming?.let { account ->
        RenameDialog(
            account = account,
            onDismiss = { renaming = null },
            onConfirm = { newName ->
                onRenameAccount(account.id, newName)
                renaming = null
            },
        )
    }

    if (confirmSignOut) {
        AlertDialog(
            onDismissRequest = { confirmSignOut = false },
            title = { Text("Sign out?") },
            text = {
                Text(
                    "This removes every account and its stored credentials from " +
                        "this device. You'll need to sign in again."
                )
            },
            confirmButton = {
                TextButton(onClick = { confirmSignOut = false; onSignOut() }) {
                    Text("Sign out", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmSignOut = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun RenameDialog(account: Account, onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
    var text by remember { mutableStateOf(account.name) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename account") },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                singleLine = true,
                label = { Text("Name") },
            )
        },
        confirmButton = { TextButton(onClick = { onConfirm(text) }) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun AccountRow(
    account: Account,
    selected: Boolean,
    onSelect: () -> Unit,
    onRename: () -> Unit,
    onRemove: () -> Unit,
    canRemove: Boolean,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(
                if (selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.10f)
                else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            )
            .clickable(onClick = onSelect)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = onSelect)
        Text(
            account.name,
            Modifier.padding(start = 4.dp).weight(1f),
            style = MaterialTheme.typography.bodyMedium,
        )
        TextButton(onClick = onRename) { Text("Rename") }
        // Removing the only account is what "Sign out" is for; offering both
        // would leave the app in a signed-out state reached two different ways.
        if (canRemove) {
            TextButton(onClick = onRemove) {
                Text("Remove", color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

@Composable
private fun ActionRow(
    title: String,
    subtitle: String,
    onClick: () -> Unit,
    destructive: Boolean = false,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Text(
            title,
            style = MaterialTheme.typography.bodyMedium,
            color = if (destructive) MaterialTheme.colorScheme.error
            else MaterialTheme.colorScheme.onSurface,
        )
        Text(
            subtitle,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
        )
    }
}

/**
 * Everything the About row needs, owned by the caller.
 *
 * Not held inside the row, which is where it started. A `rememberCoroutineScope`
 * in this sheet dies when the sheet closes, so closing Settings while a check was
 * in flight threw the answer away; and a result kept in the row's own state
 * reached neither the status line nor the next opening of Settings. Both are
 * things a check exists to feed, so the state belongs to something that outlives
 * one sheet.
 *
 * [known] is an update the app is already sure of, from any earlier check.
 * [check] is the last outcome, which is what the row reports when there is no
 * update to offer.
 */
class UpdateUiState(
    val currentVersion: String,
    val known: ReleaseFeed.Release?,
    val check: ReleaseFeed.Check?,
    val checking: Boolean,
    val onCheck: () -> Unit,
    val onOpen: (ReleaseFeed.Release) -> Unit,
)

/**
 * The manual half of the updater.
 *
 * Loud where the launch check is silent. The user asked, so every outcome gets
 * an answer here — including the failures the automatic check swallows, because
 * rendering "couldn't reach GitHub" as "up to date" would rebuild, one layer up,
 * the exact silence [ReleaseFeed.findNewer] returns four distinct answers to
 * avoid.
 */
@Composable
private fun UpdateRow(state: UpdateUiState) {
    val available = state.known

    ActionRow(
        title = when {
            state.checking -> "Checking…"
            available != null -> "Update to ${available.version}"
            else -> "Check for updates"
        },
        subtitle = when {
            state.checking -> "Version ${state.currentVersion}"
            available != null -> "Tap to open the release page"
            else -> "Version ${state.currentVersion}" + outcomeSuffix(state.check)
        },
        onClick = {
            when {
                available != null -> state.onOpen(available)
                // Guarded: five sequential requests are slow enough to tap twice.
                state.checking -> Unit
                else -> state.onCheck()
            }
        },
    )
}

/** The tail of the subtitle. Empty when there is nothing to report yet. */
private fun outcomeSuffix(state: ReleaseFeed.Check?): String = when (state) {
    null, is ReleaseFeed.Check.Available -> ""
    ReleaseFeed.Check.UpToDate -> " — up to date"
    // Not "up to date": the feed said nothing about this build either way.
    ReleaseFeed.Check.NoRelease -> " — no Android release published yet"
    is ReleaseFeed.Check.Failed -> when (state.reason) {
        ReleaseFeed.Check.Reason.OFFLINE -> " — couldn't reach GitHub, tap to retry"
        ReleaseFeed.Check.Reason.RATE_LIMITED -> " — GitHub rate limit reached, try again later"
        ReleaseFeed.Check.Reason.SERVER -> " — GitHub returned an error, tap to retry"
    }
}

/**
 * The launcher-icon picker: three tiles rather than three [ChoiceRow]s.
 *
 * This is a choice about how something *looks*, so it shows the thing. A radio
 * row would describe three icons in words next to a swatch too small to read,
 * which is the one case where the sheet's usual pattern is the wrong one.
 *
 * No confirmation and no toast. The tile is the state — it fills in, and the
 * home screen has already changed by the time the user gets there.
 */
@Composable
private fun IconPicker(selected: AppIcon, onSelect: (AppIcon) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(top = 2.dp, bottom = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        AppIcon.entries.forEach { icon ->
            IconTile(
                icon = icon,
                selected = icon == selected,
                modifier = Modifier.weight(1f),
                onClick = { if (icon != selected) onSelect(icon) },
            )
        }
    }
}

@Composable
private fun IconTile(
    icon: AppIcon,
    selected: Boolean,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    Column(
        modifier
            .clip(RoundedCornerShape(14.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier
                .border(
                    BorderStroke(
                        2.dp,
                        if (selected) MaterialTheme.colorScheme.primary else Color.Transparent,
                    ),
                    IconTileShape,
                )
                .padding(4.dp)
        ) {
            Box(
                Modifier
                    .size(52.dp)
                    .clip(IconTileShape)
                    // A hairline edge, or the light tile has none: the sheet's
                    // own surface is #FAF8F4, the same colour as that icon's
                    // background, so without this it reads as a mark floating on
                    // the page rather than an icon, and makes the dark tile look
                    // like pure black by contrast.
                    .border(
                        BorderStroke(1.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = 0.18f)),
                        IconTileShape,
                    )
            ) { IconFaces(icon, 52.dp) }
        }
        Text(
            icon.label,
            Modifier.padding(top = 6.dp),
            style = MaterialTheme.typography.bodySmall,
            textAlign = TextAlign.Center,
            color = if (selected) MaterialTheme.colorScheme.primary
            else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
        )
    }
}

@Composable
private fun IconFaces(icon: AppIcon, size: Dp) {
    when (icon) {
        AppIcon.LIGHT ->
            Face(R.mipmap.ic_launcher_fg_light, R.color.ic_launcher_background_light, size)
        AppIcon.DARK ->
            Face(R.mipmap.ic_launcher_fg_dark, R.color.ic_launcher_background_dark, size)
        // Diagonally split, light in the upper left. Every desktop appearance
        // picker splits this way, so it reads as "both, depending" without a
        // legend — which a vertical split or a half-and-half swatch does not.
        AppIcon.AUTO -> {
            Face(R.mipmap.ic_launcher_fg_light, R.color.ic_launcher_background_light, size)
            Box(Modifier.size(size).clip(LowerRightHalf)) {
                Face(R.mipmap.ic_launcher_fg_dark, R.color.ic_launcher_background_dark, size)
            }
        }
    }
}

/**
 * One icon, framed the way a launcher frames it.
 *
 * The foreground layer is a 108dp canvas drawn into a 72dp window, so the
 * preview scales it by 108/72 and clips. Without that the mark would sit at
 * two-thirds the size it has on the home screen, and the tile would be
 * answering a different question than the one being asked.
 */
@Composable
private fun Face(@DrawableRes foreground: Int, @ColorRes background: Int, size: Dp) {
    Box(
        Modifier.size(size).background(colorResource(background)),
        contentAlignment = Alignment.Center,
    ) {
        Image(
            painter = painterResource(foreground),
            contentDescription = null,
            modifier = Modifier.size(size * (108f / 72f)),
        )
    }
}

/** Roughly One UI's squircle; near enough that the preview is not a lie. */
private val IconTileShape = RoundedCornerShape(percent = 28)

private val LowerRightHalf = GenericShape { size, _ ->
    moveTo(size.width, 0f)
    lineTo(size.width, size.height)
    lineTo(0f, size.height)
    close()
}

private val AppIcon.label: String
    get() = when (this) {
        AppIcon.AUTO -> "Auto"
        AppIcon.LIGHT -> "Light"
        AppIcon.DARK -> "Dark"
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

@Composable
private fun StatusNote(text: String) {
    Text(
        text,
        Modifier.padding(horizontal = 4.dp, vertical = 4.dp),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
    )
}
