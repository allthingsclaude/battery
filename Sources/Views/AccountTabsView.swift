import SwiftUI

/// Tab-style account switcher pinned inside the panel header. The selected
/// account reads as a browser-style tab attached to the header's bottom
/// divider (top corners rounded, flush with the hairline below).
struct AccountTabsView: View {
    let accounts: [Account]
    let selectedAccountId: UUID?
    let onSelect: (UUID) -> Void
    let onAddAccount: () -> Void

    private let maxAccounts = 5

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(accounts) { account in
                tab(for: account)
            }

            if accounts.count < maxAccounts {
                Button(action: onAddAccount) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Add account")
            }

            Spacer(minLength: 0)
        }
    }

    private func tab(for account: Account) -> some View {
        let isSelected = account.id == (selectedAccountId ?? accounts.first?.id)
        return Button(action: { onSelect(account.id) }) {
            Text(account.name)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 7,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 7,
                            style: .continuous
                        )
                        .fill(.quaternary)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(account.name)
    }
}
