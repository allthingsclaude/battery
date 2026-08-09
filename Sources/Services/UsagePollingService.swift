import Foundation
import Combine

/// Coordinates periodic polling of the Anthropic usage API.
class UsagePollingService: ObservableObject {
    @Published var latestUsage: UsageResponse?
    @Published var lastError: Error?
    @Published var isPolling: Bool = false
    @Published var needsReauth: Bool = false

    private let tokenRefreshService = TokenRefreshService()
    private let api = AnthropicAPI()
    private var pollingTask: Task<Void, Never>?
    private var currentInterval: TimeInterval
    private var tokenProvider: (() -> AccountManager.TokenLookup)?
    private var onTokensRefreshed: ((StoredTokens) -> Bool)?

    /// A refreshed pair the store would not accept. Refresh tokens are
    /// single-use, so once a rotation lands the previous one is dead
    /// server-side: falling back to the provider would re-read that dead token
    /// and strand the account behind a sign-in prompt. Held here so the session
    /// keeps working, and cleared as soon as a write succeeds.
    private var unpersistedTokens: StoredTokens?

    /// Exponential backoff state for rate limiting
    private var consecutiveRateLimits: Int = 0
    private static let maxBackoffInterval: TimeInterval = 600 // 10 minutes
    private static let baseBackoffInterval: TimeInterval = 60  // 1 minute

    init(interval: TimeInterval = Constants.defaultPollInterval) {
        self.currentInterval = interval
    }

    /// Configure the polling service with a token provider and a callback for
    /// when tokens are refreshed. The provider is consulted on EVERY poll so
    /// tokens updated on disk (or Claude Code live credentials) are picked up
    /// without reconfiguring.
    func configure(
        tokenProvider: @escaping () -> AccountManager.TokenLookup,
        onTokensRefreshed: @escaping (StoredTokens) -> Bool
    ) {
        self.tokenProvider = tokenProvider
        self.onTokensRefreshed = onTokensRefreshed
        // A new account's tokens have nothing to do with the outgoing one's.
        self.unpersistedTokens = nil
        if case .missing = tokenProvider() { self.needsReauth = true } else { self.needsReauth = false }
    }

    /// The tokens this poll should use: whatever the provider reports, unless a
    /// rotation is stranded in memory because the store rejected it.
    ///
    /// Internal rather than private only so the tests can reach it — `pollNow`
    /// is the sole caller and it takes the network with it.
    func currentTokens() -> AccountManager.TokenLookup {
        if let held = unpersistedTokens { return .tokens(held) }
        return tokenProvider?() ?? .missing
    }

    /// Hand refreshed tokens to the store, keeping them in memory if it fails.
    func persist(_ tokens: StoredTokens) {
        unpersistedTokens = (onTokensRefreshed?(tokens) == true) ? nil : tokens
    }

    func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        pollingTask = Task { [weak self] in
            guard let self = self else { return }
            // Immediate first poll
            await self.pollNow()
            // Then poll at interval (with backoff when rate limited)
            while !Task.isCancelled {
                let interval = self.effectiveInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await self.pollNow()
            }
        }
    }

    /// Returns the polling interval, extended by exponential backoff when rate limited.
    private var effectiveInterval: TimeInterval {
        guard consecutiveRateLimits > 0 else { return currentInterval }
        let backoff = Self.baseBackoffInterval * pow(2.0, Double(consecutiveRateLimits - 1))
        return min(backoff, Self.maxBackoffInterval)
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
    }

    func setInterval(_ interval: TimeInterval) {
        currentInterval = interval
    }

    /// Returns true only for errors that mean stored credentials cannot be used
    /// without a fresh OAuth login. Transient network failures return false.
    static func requiresReauth(for error: Error) -> Bool {
        if let tokenError = error as? TokenRefreshService.TokenError {
            switch tokenError {
            case .networkError:
                return false
            case .noRefreshToken:
                return true
            case .refreshFailed(let statusCode, _):
                // Only 400/401/403 mean the grant itself was rejected.
                // 5xx, 429 etc. are server trouble — retry, don't force login.
                return [400, 401, 403].contains(statusCode)
            }
        }
        if let apiError = error as? AnthropicAPI.APIError {
            switch apiError {
            case .unauthorized:
                return true
            case .networkError, .rateLimited, .serverError, .decodingError:
                return false
            }
        }
        return false
    }

    /// Returns true when the error is a rate limit from either endpoint,
    /// so polling should back off rather than retry at full speed.
    static func isRateLimited(_ error: Error) -> Bool {
        if let apiError = error as? AnthropicAPI.APIError, case .rateLimited = apiError {
            return true
        }
        if let tokenError = error as? TokenRefreshService.TokenError,
           case .refreshFailed(let statusCode, _) = tokenError, statusCode == 429 {
            return true
        }
        return false
    }

    @MainActor
    func pollNow() async {
        let tokens: StoredTokens
        switch currentTokens() {
        case .tokens(let found):
            tokens = found
        case .missing:
            needsReauth = true
            return
        case .liveUnavailable:
            // Mapped to Claude Code but unreadable right now. Surfaced as an
            // error, never as a sign-in prompt: signing in here would create a
            // second refresh chain for an account that already has a working
            // one, which is the failure this bridge exists to avoid.
            lastError = LiveCredentialError.unreadable
            return
        }

        do {
            let accessToken: String
            if tokens.isLive {
                // Live Claude Code credential: use as-is, never refresh it —
                // rotating a shared chain would strand Claude Code's copy.
                accessToken = tokens.accessToken
            } else {
                let (token, updatedTokens) = try await tokenRefreshService.refreshIfNeeded(tokens: tokens)
                accessToken = token
                if let updated = updatedTokens {
                    persist(updated)
                }
            }

            let usage = try await api.fetchUsage(accessToken: accessToken)
            self.latestUsage = usage
            self.lastError = nil
            self.needsReauth = false
            self.consecutiveRateLimits = 0
        } catch {
            // Rate limits are transient — don't overwrite lastError if we have cached data
            if Self.isRateLimited(error) {
                consecutiveRateLimits += 1
                // Only surface error if we have no cached data at all
                if latestUsage == nil {
                    self.lastError = error
                }
                return
            }

            self.lastError = error

            // On 401, try force refresh; other auth-fatal errors need reauth.
            // Live tokens are exempt: a stale live token is transient — Claude
            // Code tooling refreshes it and the next poll picks it up.
            if let apiError = error as? AnthropicAPI.APIError, apiError.isUnauthorized {
                if !tokens.isLive {
                    await retryWithForceRefresh(tokens: tokens)
                }
            } else if Self.requiresReauth(for: error), !tokens.isLive {
                self.needsReauth = true
            }
        }
    }

    @MainActor
    private func retryWithForceRefresh(tokens: StoredTokens) async {
        guard let refreshToken = tokens.refreshToken else {
            needsReauth = true
            return
        }

        do {
            let response = try await tokenRefreshService.forceRefresh(refreshToken: refreshToken)
            let updated = StoredTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken ?? tokens.refreshToken,
                expiresIn: response.expiresIn
            )
            persist(updated)

            let usage = try await api.fetchUsage(accessToken: response.accessToken)
            self.latestUsage = usage
            self.lastError = nil
            self.needsReauth = false
            self.consecutiveRateLimits = 0
        } catch {
            self.lastError = error
            if Self.requiresReauth(for: error) {
                self.needsReauth = true
            }
        }
    }
}
