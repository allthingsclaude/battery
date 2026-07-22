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
}
