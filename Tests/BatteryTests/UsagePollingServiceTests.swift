import XCTest
@testable import Battery

final class UsagePollingServiceTests: XCTestCase {

    func testNetworkTokenErrorDoesNotRequireReauth() {
        let error = TokenRefreshService.TokenError.networkError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        )
        XCTAssertFalse(UsagePollingService.requiresReauth(for: error))
    }

    func testRefreshFailedRequiresReauth() {
        let error = TokenRefreshService.TokenError.refreshFailed(statusCode: 400, body: "invalid_grant")
        XCTAssertTrue(UsagePollingService.requiresReauth(for: error))
    }

    func testRefreshFailedUnauthorizedRequiresReauth() {
        let error = TokenRefreshService.TokenError.refreshFailed(statusCode: 401, body: "invalid_client")
        XCTAssertTrue(UsagePollingService.requiresReauth(for: error))
    }

    func testRefreshFailedServerErrorDoesNotRequireReauth() {
        let error = TokenRefreshService.TokenError.refreshFailed(statusCode: 503, body: "unavailable")
        XCTAssertFalse(UsagePollingService.requiresReauth(for: error))
    }

    func testRefreshFailedRateLimitedDoesNotRequireReauth() {
        let error = TokenRefreshService.TokenError.refreshFailed(statusCode: 429, body: "slow down")
        XCTAssertFalse(UsagePollingService.requiresReauth(for: error))
    }

    func testRefreshFailedInvalidResponseDoesNotRequireReauth() {
        let error = TokenRefreshService.TokenError.refreshFailed(statusCode: 0, body: "Invalid response")
        XCTAssertFalse(UsagePollingService.requiresReauth(for: error))
    }

    func testNoRefreshTokenRequiresReauth() {
        let error = TokenRefreshService.TokenError.noRefreshToken
        XCTAssertTrue(UsagePollingService.requiresReauth(for: error))
    }

    func testAPINetworkErrorDoesNotRequireReauth() {
        let error = AnthropicAPI.APIError.networkError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        )
        XCTAssertFalse(UsagePollingService.requiresReauth(for: error))
    }

    func testAPIUnauthorizedRequiresReauth() {
        XCTAssertTrue(UsagePollingService.requiresReauth(for: AnthropicAPI.APIError.unauthorized))
    }

    func testAPIRateLimitedDoesNotRequireReauth() {
        let error = AnthropicAPI.APIError.rateLimited(retryAfter: 30)
        XCTAssertFalse(UsagePollingService.requiresReauth(for: error))
    }

    func testAPIServerErrorDoesNotRequireReauth() {
        let error = AnthropicAPI.APIError.serverError(statusCode: 500, body: "oops")
        XCTAssertFalse(UsagePollingService.requiresReauth(for: error))
    }

    func testAPIDecodingErrorDoesNotRequireReauth() {
        let error = AnthropicAPI.APIError.decodingError(
            NSError(domain: "test", code: 1)
        )
        XCTAssertFalse(UsagePollingService.requiresReauth(for: error))
    }

    func testGenericErrorDoesNotRequireReauth() {
        let error = NSError(domain: "test", code: 42)
        XCTAssertFalse(UsagePollingService.requiresReauth(for: error))
    }

    // MARK: - isRateLimited

    func testAPIRateLimitedIsRateLimited() {
        let error = AnthropicAPI.APIError.rateLimited(retryAfter: 30)
        XCTAssertTrue(UsagePollingService.isRateLimited(error))
    }

    func testTokenEndpoint429IsRateLimited() {
        let error = TokenRefreshService.TokenError.refreshFailed(statusCode: 429, body: "slow down")
        XCTAssertTrue(UsagePollingService.isRateLimited(error))
    }

    func testTokenEndpoint400IsNotRateLimited() {
        let error = TokenRefreshService.TokenError.refreshFailed(statusCode: 400, body: "invalid_grant")
        XCTAssertFalse(UsagePollingService.isRateLimited(error))
    }

    func testNetworkErrorIsNotRateLimited() {
        let error = TokenRefreshService.TokenError.networkError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        )
        XCTAssertFalse(UsagePollingService.isRateLimited(error))
    }

    // MARK: - Rotated tokens that could not be written

    private func tokens(_ access: String, _ refresh: String?) -> StoredTokens {
        StoredTokens(accessToken: access, refreshToken: refresh, expiresAt: 0)
    }

    /// A rotation the store rejects must stay in memory. The refresh token it
    /// replaced is already spent server-side, so falling back to the provider
    /// would send a dead token, earn a 400, and strand the account behind a
    /// sign-in prompt for a reason the user cannot see.
    func testRefreshedTokensSurviveAFailedWrite() {
        let service = UsagePollingService()
        let onDisk = tokens("old", "rt1")

        service.configure(tokenProvider: { onDisk }, onTokensRefreshed: { _ in false })
        service.persist(tokens("new", "rt2"))

        XCTAssertEqual(service.currentTokens()?.refreshToken, "rt2")
        XCTAssertEqual(service.currentTokens()?.accessToken, "new")
    }

    /// Once a write lands, the provider is authoritative again — otherwise the
    /// in-memory copy would shadow credentials refreshed outside the app.
    func testProviderResumesAfterASuccessfulWrite() {
        let service = UsagePollingService()
        var onDisk = tokens("old", "rt1")

        service.configure(
            tokenProvider: { onDisk },
            onTokensRefreshed: { updated in
                onDisk = updated
                return true
            }
        )
        service.persist(tokens("new", "rt2"))
        onDisk = tokens("external", "rt3")

        XCTAssertEqual(service.currentTokens()?.refreshToken, "rt3")
    }

    /// Switching accounts must not carry the previous account's stranded
    /// rotation across — those tokens belong to a different grant entirely.
    func testConfigureClearsAStrandedRotation() {
        let service = UsagePollingService()

        service.configure(tokenProvider: { self.tokens("a", "rt-a") }, onTokensRefreshed: { _ in false })
        service.persist(tokens("a-rotated", "rt-a2"))

        service.configure(tokenProvider: { self.tokens("b", "rt-b") }, onTokensRefreshed: { _ in true })

        XCTAssertEqual(service.currentTokens()?.refreshToken, "rt-b")
    }
}
