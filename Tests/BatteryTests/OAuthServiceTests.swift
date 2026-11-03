import XCTest
@testable import Battery

@MainActor
final class OAuthServiceTests: XCTestCase {

    func testAbandonedLoginReportsTimeout() async {
        let service = OAuthService(loginTimeout: 0.05, openURL: { _ in })
        let finished = expectation(description: "login reports an outcome")

        service.startLogin { result in
            XCTAssertTrue(Self.isTimeout(result), "expected timeout, got \(result)")
            finished.fulfill()
        }
        XCTAssertTrue(service.isAuthenticating)

        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(service.isAuthenticating)
    }

    func testCanSignInAgainAfterAnAbandonedAttempt() async {
        var openedURLs: [URL] = []
        let service = OAuthService(loginTimeout: 0.05, openURL: { openedURLs.append($0) })
        let timedOut = expectation(description: "first attempt times out")

        service.startLogin { _ in timedOut.fulfill() }
        await fulfillment(of: [timedOut], timeout: 2)

        service.startLogin { _ in }
        XCTAssertEqual(openedURLs.count, 2)
        XCTAssertTrue(service.isAuthenticating)
        service.cancelLogin()
    }

    func testNewAttemptSupersedesTheInFlightOne() async {
        var openedURLs: [URL] = []
        let service = OAuthService(loginTimeout: 0.1, openURL: { openedURLs.append($0) })
        let superseded = expectation(description: "superseded attempt never reports")
        superseded.isInverted = true
        let current = expectation(description: "current attempt reports")

        service.startLogin { _ in superseded.fulfill() }
        service.startLogin { result in
            XCTAssertTrue(Self.isTimeout(result), "expected timeout, got \(result)")
            current.fulfill()
        }

        await fulfillment(of: [current, superseded], timeout: 1)
        XCTAssertEqual(openedURLs.count, 2)
    }

    func testCancelledLoginReportsNothing() async {
        let service = OAuthService(loginTimeout: 0.05, openURL: { _ in })
        let reported = expectation(description: "cancelled attempt never reports")
        reported.isInverted = true

        service.startLogin { _ in reported.fulfill() }
        service.cancelLogin()

        XCTAssertFalse(service.isAuthenticating)
        await fulfillment(of: [reported], timeout: 0.5)
    }

    private static func isTimeout(_ result: Result<OAuthService.TokenPair, Error>) -> Bool {
        guard case .failure(let error) = result else { return false }
        if case .timedOut? = error as? OAuthService.OAuthError { return true }
        return false
    }
}
