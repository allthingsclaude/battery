import SwiftUI

/// Account switcher + management: tap to switch, swipe to rename/remove, and
/// "Add Account" runs the same OAuth flow. Reached from the header account chip.
struct AccountsView: View {
    @ObservedObject var service: UsageService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var auth = AuthService()

    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var errorMessage: String?
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(service.accounts) { account in
                        accountRow(account)
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Tap to switch. Swipe an account to rename or remove it — each keeps its own sign-in.")
                }

                Section {
                    Button(action: addAccount) {
                        if isAdding {
                            HStack(spacing: 8) { ProgressView(); Text("Signing in…") }
                        } else {
                            Label("Add Account", systemImage: "plus.circle.fill")
                        }
                    }
                    .disabled(isAdding)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(BatteryPalette.warn)
                    }
                }
            }
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(BatteryPalette.brand)
        .sheet(isPresented: $auth.isPresentingAuth, onDismiss: { auth.cancelIfPending() }) {
            if let url = auth.authURL {
                AuthSafariView(url: url).ignoresSafeArea()
            }
        }
        .alert("Rename Account", isPresented: renameShown) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingID = nil }
            Button("Save") {
                if let id = renamingID { service.renameAccount(id, to: renameText) }
                renamingID = nil
            }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        let isSelected = account.id == service.selectedAccountID
        return Button {
            service.selectAccount(account.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? BatteryPalette.brand : Color.secondary)
                Text(account.name).foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { service.removeAccount(account.id) } label: {
                Label("Remove", systemImage: "trash")
            }
            Button { startRename(account) } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.gray)
        }
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })
    }

    private func startRename(_ account: Account) {
        renameText = account.name
        renamingID = account.id
    }

    private func addAccount() {
        errorMessage = nil
        isAdding = true
        auth.startLogin { result in
            isAdding = false
            switch result {
            case .success(let tokens):
                service.addAccount(tokens)
            case .failure(let error):
                guard (error as? AuthService.AuthError) != .cancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}
