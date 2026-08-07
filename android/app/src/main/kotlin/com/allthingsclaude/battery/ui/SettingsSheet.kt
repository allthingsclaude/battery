package com.allthingsclaude.battery.ui

import androidx.compose.foundation.background
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.allthingsclaude.battery.BuildConfig
import com.allthingsclaude.battery.core.SessionPolicy
import com.allthingsclaude.battery.data.Account
import com.allthingsclaude.battery.data.Settings
import com.allthingsclaude.battery.data.subtitle
import com.allthingsclaude.battery.data.title

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
