package com.allthingsclaude.battery.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.allthingsclaude.battery.data.Account

/**
 * The account switcher, in the header, always visible.
 *
 * A port of `Sources/Views/AccountTabsView.swift` — and a correction. macOS put
 * account tabs in the panel header from the start; iOS put a list in a settings
 * sheet, and Android copied iOS. So switching here cost five interactions
 * (launch, gear, row, wait, back), three of them pure navigation, for an app
 * whose entire purpose is a glance.
 *
 * A settings sheet is also the wrong information scent: "settings" reads as
 * configuration you set once, and the active account is a mode you change
 * several times a day.
 *
 * Not a Material `SegmentedButton`, despite that being the component whose
 * documented cardinality (2–5, mutually exclusive, "switch views") fits best.
 * Segmented buttons are sized for a form row and would either double the height
 * of a header built to stay out of the way, or force the plan badge and the
 * status pill onto separate lines. These carry the same semantics —
 * [Role.Tab], single-select, immediate effect — at the size the header already
 * uses for the account name they replace.
 */
@Composable
fun AccountTabs(
    accounts: List<Account>,
    selectedAccountId: String?,
    onSelect: (String) -> Unit,
    onAdd: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        accounts.forEach { account ->
            // Falling back to the first account rather than showing nothing
            // selected: the repository resolves an absent selection the same
            // way, so the header would otherwise disagree with the number
            // underneath it.
            val selected = account.id == (selectedAccountId ?: accounts.firstOrNull()?.id)
            Tab(
                name = account.name,
                selected = selected,
                onClick = { if (!selected) onSelect(account.id) },
            )
        }

        if (accounts.size < MAX_ACCOUNTS) {
            Tab(name = "+", selected = false, onClick = onAdd)
        }
    }
}

@Composable
private fun Tab(name: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        name,
        modifier = Modifier
            // Keeps the tappable area at the platform minimum without inflating
            // the pill that is drawn — these sit in a header measured in a few
            // dp, and a 48dp visual chip would dominate it.
            .minimumInteractiveComponentSize()
            .clip(RoundedCornerShape(50))
            .selectable(selected = selected, role = Role.Tab, onClick = onClick)
            .background(
                if (selected) {
                    MaterialTheme.colorScheme.primary.copy(alpha = 0.16f)
                } else {
                    androidx.compose.ui.graphics.Color.Transparent
                }
            )
            .padding(horizontal = 10.dp, vertical = 3.dp),
        style = MaterialTheme.typography.labelMedium,
        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
        color = if (selected) {
            MaterialTheme.colorScheme.onSurface
        } else {
            MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
        },
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

/**
 * Matching `AccountTabsView.maxAccounts`. Past this the row stops offering to
 * add, because the tabs stop fitting a phone header long before the app runs out
 * of anything else.
 */
private const val MAX_ACCOUNTS = 5
