import Foundation
import CryptoKit
import SwiftUI
import SafariServices

/// OAuth PKCE login for iOS.
///
/// This mirrors the macOS `OAuthService`: it spins up a loopback HTTP listener on
/// `http://localhost:<port>/callback`, opens the Claude authorize URL, and catches
/// the `?code=` redirect. We use `SFSafariViewController` (not
/// `ASWebAuthenticationSession`) because the registered redirect URI is an
/// `http://localhost` URL, not a custom scheme — and Safari VC keeps the app in
/// the foreground so the in-process socket listener stays alive to receive it.
///
/// NOTE: this assumes the OAuth client permits a loopback redirect, exactly as
/// the desktop app relies on. See ios/README.md → "Auth caveats".
@MainActor
final class AuthService: ObservableObject {
    @Published var isPresentingAuth = false
    @Published var authURL: URL?

    private var codeVerifier: String?
    private var oauthState: String?
    private var listener: LoopbackListener?
    private var completion: ((Result<StoredTokens, Error>) -> Void)?

    enum AuthError: LocalizedError, Equatable {
        case listenerFailed
        case tokenExchangeFailed(String)
        case cancelled
        case noCodeVerifier
        var errorDescription: String? {
            switch self {
            case .listenerFailed: return "Couldn't start the local auth listener."
            case .tokenExchangeFailed(let d): return "Sign-in failed: \(d)"
            case .cancelled: return nil   // user-initiated; nothing to report
            case .noCodeVerifier: return "Sign-in failed: missing code verifier."
            }
        }
    }

    /// - Parameter scopes: which OAuth scopes to request. Defaults to the app's
    ///   own set; cloud sync passes a narrower one so the grant it hands to the
    ///   relay can read usage but cannot make inference calls on the account.
    func startLogin(
        scopes: String = AppConfig.oauthScopes,
        completion: @escaping (Result<StoredTokens, Error>) -> Void
    ) {
        // Never leave a previous attempt's socket/thread running.
        listener?.stop()
        listener = nil
        self.completion = completion

        let verifier = Self.randomURLString()
        codeVerifier = verifier
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomURLString()
        oauthState = state

        let listener = LoopbackListener(path: AppConfig.oauthRedirectPath) { [weak self] code in
            Task { @MainActor in self?.handleCode(code) }
        }
        guard let port = listener.start() else {
            completion(.failure(AuthError.listenerFailed))
            return
        }
        self.listener = listener

        let redirectUri = "http://localhost:\(port)\(AppConfig.oauthRedirectPath)"
        var components = URLComponents(string: AppConfig.oauthAuthorizeURL)!
        components.queryItems = [
            .init(name: "client_id", value: AppConfig.oauthClientId),
            .init(name: "redirect_uri", value: redirectUri),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        authURL = components.url
        isPresentingAuth = true
    }

    /// Called when the Safari sheet is dismissed. If the callback never arrived the
    /// attempt was abandoned — tear down the listener and fail the pending
    /// completion so callers can re-enable their sign-in buttons.
    func cancelIfPending() {
        guard let pending = completion else { return }
        listener?.stop()
        listener = nil
        isPresentingAuth = false
        completion = nil
        pending(.failure(AuthError.cancelled))
    }

    func cancel() {
        cancelIfPending()
    }

    // MARK: - Private

    private func handleCode(_ code: String) {
        isPresentingAuth = false
        listener?.stop()
        let port = listener?.port
        listener = nil
        Task {
            let pending = completion
            completion = nil    // don't retain the callback (and its captures) past use
            do {
                let tokens = try await exchange(code: code, port: port)
                // The caller (UsageService.addAccount) persists these against the
                // new account's id — AuthService only produces the tokens.
                pending?(.success(tokens))
            } catch {
                pending?(.failure(error))
            }
        }
    }

    private func exchange(code: String, port: UInt16?) async throws -> StoredTokens {
        guard let verifier = codeVerifier else { throw AuthError.noCodeVerifier }
        let redirectUri = "http://localhost:\(port ?? 0)\(AppConfig.oauthRedirectPath)"
        var request = URLRequest(url: URL(string: AppConfig.oauthTokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")

        var body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": AppConfig.oauthClientId,
            "code_verifier": verifier,
            "redirect_uri": redirectUri,
        ]
        if let oauthState { body["state"] = oauthState }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AuthError.tokenExchangeFailed("HTTP \(code)")
        }

        struct TokenResponse: Codable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
        }
        let resp = try JSONDecoder().decode(TokenResponse.self, from: data)
        return StoredTokens(
            accessToken: resp.access_token,
            refreshToken: resp.refresh_token,
            expiresIn: resp.expires_in ?? 3600
        )
    }

    // MARK: - PKCE helpers

    private static func randomURLString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - SwiftUI Safari wrapper

/// Presents `authURL` in an in-app Safari view. Because the app stays foreground,
/// the loopback listener remains alive to catch the redirect.
struct AuthSafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

// MARK: - Loopback HTTP listener (ported from the macOS OAuthHTTPListener)

/// A minimal loopback HTTP server that captures the OAuth `?code=` redirect.
/// Uses BSD sockets, which are available on iOS. Alive only while the app is
/// foreground during sign-in, then torn down.
final class LoopbackListener: @unchecked Sendable {
    let path: String
    private let onCode: (String) -> Void
    private var socketFD: Int32 = -1
    private var thread: Thread?
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

        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = 0
        addr.sin6_addr = in6addr_loopback

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0 else { Darwin.close(socketFD); return nil }

        var assigned = sockaddr_in6()
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &len) }
        }
        port = UInt16(bigEndian: assigned.sin6_port)

        listen(socketFD, 5)
        thread = Thread { [weak self] in self?.acceptLoop() }
        thread?.start()

        // Auto-stop after 5 minutes so an abandoned sign-in can't leak the
        // socket/thread for the process lifetime (ported from the macOS app).
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.stop()
        }
        return port
    }

    func stop() {
        if socketFD >= 0 { Darwin.close(socketFD); socketFD = -1 }
    }

    private func acceptLoop() {
        while socketFD >= 0 {
            let client = accept(socketFD, nil, nil)
            guard client >= 0 else { return }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { Darwin.close(client); continue }
            let requestStr = String(bytes: buffer[0..<n], encoding: .utf8) ?? ""

            if let line = requestStr.split(separator: "\r\n").first,
               line.contains(path),
               let urlPart = line.split(separator: " ").dropFirst().first,
               let comps = URLComponents(string: String(urlPart)),
               let code = comps.queryItems?.first(where: { $0.name == "code" })?.value {

                let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Battery</title></head><body style=\"font-family:system-ui;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#F5F0E8;color:#2c2c2c\"><div style=\"text-align:center\"><h2 style=\"margin:0 0 8px;font-size:28px\">Authenticated</h2><p style=\"color:#888;margin:0\">Return to Battery.</p></div></body></html>"
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n"
                let out = Data((header + html).utf8)
                out.withUnsafeBytes { ptr in
                    var written = 0
                    while written < out.count {
                        let w = write(client, ptr.baseAddress! + written, out.count - written)
                        if w <= 0 { break }
                        written += w
                    }
                }
                Darwin.close(client)
                onCode(code)
                return
            } else {
                let resp = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nWaiting for auth..."
                _ = resp.withCString { write(client, $0, strlen($0)) }
                Darwin.close(client)
            }
        }
    }
}
