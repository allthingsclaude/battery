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
    private var currentTokens: StoredTokens?
    private var onTokensRefreshed: ((StoredTokens) -> Void)?

    /// Exponential backoff state for rate limiting
    private var consecutiveRateLimits: Int = 0
    private static let maxBackoffInterval: TimeInterval = 600 // 10 minutes
    private static let baseBackoffInterval: TimeInterval = 60  // 1 minute

    init(interval: TimeInterval = Constants.defaultPollInterval) {
        self.currentInterval = interval
    }

    /// Configure the polling service with tokens and a callback for when tokens are refreshed.
    func configure(tokens: StoredTokens?, onTokensRefreshed: @escaping (StoredTokens) -> Void) {
        self.currentTokens = tokens
        self.onTokensRefreshed = onTokensRefreshed
        self.needsReauth = (tokens == nil)
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
            case .refreshFailed, .noRefreshToken:
                return true
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

    @MainActor
    func pollNow() async {
        guard let tokens = currentTokens else {
            needsReauth = true
            return
        }

        do {
            let (accessToken, updatedTokens) = try await tokenRefreshService.refreshIfNeeded(tokens: tokens)

            if let updated = updatedTokens {
                currentTokens = updated
                onTokensRefreshed?(updated)
            }

            let usage = try await api.fetchUsage(accessToken: accessToken)
            self.latestUsage = usage
            self.lastError = nil
            self.needsReauth = false
            self.consecutiveRateLimits = 0
        } catch {
            // Rate limits are transient — don't overwrite lastError if we have cached data
            if let apiError = error as? AnthropicAPI.APIError, case .rateLimited = apiError {
                consecutiveRateLimits += 1
                // Only surface error if we have no cached data at all
                if latestUsage == nil {
                    self.lastError = error
                }
                return
            }

            self.lastError = error

            // On 401, try force refresh; other auth-fatal errors need reauth
            if let apiError = error as? AnthropicAPI.APIError, apiError.isUnauthorized {
                await retryWithForceRefresh()
            } else if Self.requiresReauth(for: error) {
                self.needsReauth = true
            }
        }
    }

    @MainActor
    private func retryWithForceRefresh() async {
        guard let tokens = currentTokens, let refreshToken = tokens.refreshToken else {
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
            currentTokens = updated
            onTokensRefreshed?(updated)

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
