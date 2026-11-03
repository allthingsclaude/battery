import Foundation
import AppKit
import CryptoKit

/// Handles OAuth PKCE authentication flow with Claude.
@MainActor
final class OAuthService: ObservableObject {
    @Published var isAuthenticating: Bool = false

    private let loginTimeout: TimeInterval
    private let openURL: (URL) -> Void

    private var codeVerifier: String?
    private var oauthState: String?
    private var httpListener: OAuthHTTPListener?
    /// Identifies the in-flight attempt, so a callback from one that has since
    /// been superseded or torn down can't complete the current one.
    private var attemptID: UUID?
    private var pendingCompletion: ((Result<TokenPair, Error>) -> Void)?
    private var timeoutTask: Task<Void, Never>?

    init(
        loginTimeout: TimeInterval = 300,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.loginTimeout = loginTimeout
        self.openURL = openURL
    }

    struct TokenPair {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
    }

    enum OAuthError: LocalizedError {
        case noCodeVerifier
        case noRedirectUri
        case listenerFailed
        case timedOut
        case tokenExchangeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noCodeVerifier: return "Missing code verifier"
            case .noRedirectUri: return "Missing redirect URI"
            case .listenerFailed: return "Failed to start local server"
            case .timedOut: return "Sign-in timed out waiting for the browser"
            case .tokenExchangeFailed(let detail): return "Token exchange failed: \(detail)"
            }
        }
    }

    /// Opens the browser to sign in and reports the outcome exactly once —
    /// including a timeout when the browser never comes back, so callers are
    /// never left waiting on a tab that was closed.
    ///
    /// Starting a new attempt supersedes the in-flight one, whose completion is
    /// then never called: the caller that started the new attempt owns the outcome.
    func startLogin(completion: @escaping (Result<TokenPair, Error>) -> Void) {
        cancelLogin()

        let attempt = UUID()
        attemptID = attempt
        pendingCompletion = completion
        isAuthenticating = true

        let verifier = generateCodeVerifier()
        self.codeVerifier = verifier
        let challenge = generateCodeChallenge(verifier: verifier)

        let listener = OAuthHTTPListener(path: Constants.oauthRedirectPath) { [weak self] code in
            Task { @MainActor in
                guard let self = self, self.attemptID == attempt else { return }
                // The browser came back, so only the token exchange is left and
                // it must not be cut off by the wait for the browser expiring.
                self.timeoutTask?.cancel()
                let result: Result<TokenPair, Error>
                do {
                    result = .success(try await self.exchangeCode(code))
                } catch {
                    result = .failure(error)
                }
                guard self.attemptID == attempt else { return }
                self.finishLogin(with: result)
            }
        }

        guard let port = listener.start() else {
            finishLogin(with: .failure(OAuthError.listenerFailed))
            return
        }
        self.httpListener = listener

        let timeout = loginTimeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishLogin(with: .failure(OAuthError.timedOut))
        }

        let redirectUri = "http://localhost:\(port)\(Constants.oauthRedirectPath)"
        let state = generateCodeVerifier()
        self.oauthState = state

        var components = URLComponents(string: Constants.oauthAuthorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Constants.oauthClientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Constants.oauthScopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        if let url = components.url {
            openURL(url)
        }
    }

    /// Abandons the in-flight attempt without reporting an outcome.
    func cancelLogin() {
        pendingCompletion = nil
        tearDownAttempt()
    }

    private func finishLogin(with result: Result<TokenPair, Error>) {
        let completion = pendingCompletion
        pendingCompletion = nil
        tearDownAttempt()
        completion?(result)
    }

    private func tearDownAttempt() {
        attemptID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        httpListener?.stop()
        httpListener = nil
        isAuthenticating = false
    }

    // MARK: - Private

    private func exchangeCode(_ code: String) async throws -> TokenPair {
        guard let verifier = codeVerifier else {
            throw OAuthError.noCodeVerifier
        }
        guard let listenerPort = httpListener?.port else {
            throw OAuthError.noRedirectUri
        }

        let redirectUri = "http://localhost:\(listenerPort)\(Constants.oauthRedirectPath)"

        var request = URLRequest(url: URL(string: Constants.oauthTokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Constants.userAgent, forHTTPHeaderField: "User-Agent")

        var body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": Constants.oauthClientId,
            "code_verifier": verifier,
            "redirect_uri": redirectUri,
        ]
        if let state = oauthState {
            body["state"] = state
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.tokenExchangeFailed("No response")
        }

        guard httpResponse.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "unknown"
            throw OAuthError.tokenExchangeFailed("HTTP \(httpResponse.statusCode): \(bodyStr)")
        }

        struct TokenResponse: Codable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
        }

        let tokenResp = try JSONDecoder().decode(TokenResponse.self, from: data)
        return TokenPair(
            accessToken: tokenResp.access_token,
            refreshToken: tokenResp.refresh_token,
            expiresIn: tokenResp.expires_in ?? 3600
        )
    }

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).oauthBase64URLEncoded()
    }

    private func generateCodeChallenge(verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).oauthBase64URLEncoded()
    }
}

// MARK: - Base64URL encoding (private to OAuth)

private extension Data {
    func oauthBase64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - HTTP Listener for OAuth callback

final class OAuthHTTPListener: @unchecked Sendable {
    // Load Battery icon from app bundle and base64-encode at init time
    static let iconBase64: String = {
        guard let url = Bundle.main.url(forResource: "BatteryIcon", withExtension: "png"),
              let data = try? Data(contentsOf: url) else {
            return ""
        }
        return data.base64EncodedString()
    }()

    let path: String
    private let onCode: (String) -> Void
    private var socketFD: Int32 = -1
    private var listenThread: Thread?
    private(set) var port: UInt16 = 0

    init(path: String, onCode: @escaping (String) -> Void) {
        self.path = path
        self.onCode = onCode
    }

    func start() -> UInt16? {
        socketFD = socket(AF_INET6, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }

        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        var no: Int32 = 0
        setsockopt(socketFD, IPPROTO_IPV6, IPV6_V6ONLY, &no, socklen_t(MemoryLayout.size(ofValue: no)))

        var addr6 = sockaddr_in6()
        addr6.sin6_family = sa_family_t(AF_INET6)
        addr6.sin6_port = 0
        addr6.sin6_addr = in6addr_loopback

        let bindResult = withUnsafePointer(to: &addr6) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindResult == 0 else { Darwin.close(socketFD); return nil }

        var assignedAddr = sockaddr_in6()
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &assignedAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &len)
            }
        }
        self.port = UInt16(bigEndian: assignedAddr.sin6_port)

        listen(socketFD, 5)

        listenThread = Thread { [weak self] in
            self?.acceptLoop()
        }
        listenThread?.start()

        return port
    }

    func stop() {
        if socketFD >= 0 { Darwin.close(socketFD); socketFD = -1 }
    }

    private func acceptLoop() {
        while socketFD >= 0 {
            let clientFD = accept(socketFD, nil, nil)
            guard clientFD >= 0 else { return }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(clientFD, &buffer, buffer.count)
            guard bytesRead > 0 else { Darwin.close(clientFD); continue }

            let requestStr = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

            if let codeLine = requestStr.split(separator: "\r\n").first,
               codeLine.contains(path),
               let urlPart = codeLine.split(separator: " ").dropFirst().first,
               let components = URLComponents(string: String(urlPart)),
               let code = components.queryItems?.first(where: { $0.name == "code" })?.value {

                let iconTag: String
                if OAuthHTTPListener.iconBase64.isEmpty {
                    iconTag = ""
                } else {
                    iconTag = "<img src=\"data:image/png;base64,\(OAuthHTTPListener.iconBase64)\" width=\"140\" height=\"140\" style=\"margin-bottom:16px\">"
                }

                let body = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Battery</title></head><body style=\"font-family:system-ui,-apple-system,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#F5F0E8;color:#2c2c2c\"><div style=\"text-align:center\">\(iconTag)<h2 style=\"margin:0 0 8px;font-size:32px;font-weight:600;color:#111\">Authenticated!</h2><p style=\"margin:0;color:#888;font-size:14px\">You can close this tab and return to Battery.</p></div></body></html>"

                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                let response = header + body
                let responseData = Data(response.utf8)
                responseData.withUnsafeBytes { ptr in
                    var totalWritten = 0
                    while totalWritten < responseData.count {
                        let written = write(clientFD, ptr.baseAddress! + totalWritten, responseData.count - totalWritten)
                        if written <= 0 { break }
                        totalWritten += written
                    }
                }
                Darwin.close(clientFD)
                onCode(code)
                return
            } else {
                let resp = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nWaiting for auth..."
                _ = resp.withCString { write(clientFD, $0, strlen($0)) }
                Darwin.close(clientFD)
            }
        }
    }
}
