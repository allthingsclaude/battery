import SwiftUI

/// Signed-out gate. Kicks off the same OAuth PKCE flow the desktop app uses,
/// wrapped in a premium, on-brand welcome.
struct LoginView: View {
    @StateObject private var auth = AuthService()
    @ObservedObject var service: UsageService
    let onSignedIn: (StoredTokens) -> Void

    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        ZStack {
            BatteryPalette.surface.ignoresSafeArea()
            // A soft brand wash behind the hero.
            RadialGradient(colors: [BatteryPalette.brand.opacity(0.18), .clear],
                           center: .top, startRadius: 8, endRadius: 360)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()
                hero
                Spacer()
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(BatteryPalette.warn)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
                signInButton
                Text("Uses the same login as Claude Code. Nothing leaves your device.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                #if DEBUG
                Button("Preview with demo data") { service.toggleDemo() }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(BatteryPalette.brandDark)
                #endif
            }
            .padding(28)
        }
        .sheet(isPresented: $auth.isPresentingAuth, onDismiss: { auth.cancelIfPending() }) {
            if let url = auth.authURL {
                AuthSafariView(url: url).ignoresSafeArea()
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(BatteryPalette.brand.opacity(0.12))
                    .frame(width: 132, height: 132)
                UsageRing(utilization: 68, size: 116, lineWidth: 10,
                          showsLabel: false, gradientStroke: true)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(BatteryPalette.brandGradient)
            }
            VStack(spacing: 8) {
                Text("Battery")
                    .font(BatteryFont.heading(34, relativeTo: .largeTitle))
                Text("Your Claude Code usage —\nwidgets, Lock Screen, and all.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var signInButton: some View {
        Button(action: signIn) {
            HStack(spacing: 8) {
                if isWorking { ProgressView().tint(.white) }
                Text("Sign in with Claude").font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(BatteryPalette.brandGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(.white)
            .shadow(color: BatteryPalette.brand.opacity(0.35), radius: 14, y: 8)
        }
        .disabled(isWorking)
    }

    private func signIn() {
        withAnimation { errorMessage = nil; isWorking = true }
        auth.startLogin { result in
            withAnimation { isWorking = false }
            switch result {
            case .success(let tokens):
                onSignedIn(tokens)
            case .failure(let error):
                // A user-cancelled sheet isn't an error worth showing.
                guard (error as? AuthService.AuthError) != .cancelled else { return }
                withAnimation { errorMessage = error.localizedDescription }
            }
        }
    }
}
