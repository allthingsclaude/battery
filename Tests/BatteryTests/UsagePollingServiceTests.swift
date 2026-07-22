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
}
