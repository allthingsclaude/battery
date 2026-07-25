import Foundation

// `UsageResponse` / `UsageBucket` now live in BatteryKit/UsageAPIShared.swift
// (shared with the widget). This file keeps the app's refresh-aware client.

/// Fetches usage and refreshes tokens. A compact merge of the macOS
/// `AnthropicAPI` + `TokenRefreshService`, minus rate-limit file logging.
actor UsageAPI {

    enum APIError: LocalizedError {
        case unauthorized
        case rateLimited
        case server(Int)
        case network(Error)
        case decoding(Error)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Session expired — please sign in again."
            case .rateLimited:  return "Rate limited by the API."
            case .server(let c): return "Server error (\(c))."
            case .network(let e): return e.localizedDescription
            case .decoding(let e): return "Bad response: \(e.localizedDescription)"
            }
        }
    }

    /// Returns valid usage plus (if a refresh happened) the updated tokens.
    func fetchUsage(tokens: StoredTokens) async throws -> (UsageResponse, StoredTokens?) {
        var updated: StoredTokens?
        var accessToken = tokens.accessToken

        if tokens.isExpiringSoon {
            guard let refresh = tokens.refreshToken else { throw APIError.unauthorized }
            let refreshed = try await refreshTokens(refreshToken: refresh, previous: tokens)
            accessToken = refreshed.accessToken
            updated = refreshed
        }

        let usage = try await requestUsage(accessToken: accessToken)
        return (usage, updated)
    }

    // MARK: - Private

    private func requestUsage(accessToken: String) async throws -> UsageResponse {
        var request = URLRequest(url: URL(string: "\(AppConfig.apiBaseURL)/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.server(0) }
            switch http.statusCode {
            case 200: break
            case 401: throw APIError.unauthorized
            case 429: throw APIError.rateLimited
            default:  throw APIError.server(http.statusCode)
            }
            do { return try JSONDecoder().decode(UsageResponse.self, from: data) }
            catch { throw APIError.decoding(error) }
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.network(error)
        }
    }

    private func refreshTokens(refreshToken: String, previous: StoredTokens) async throws -> StoredTokens {
        var request = URLRequest(url: URL(string: AppConfig.oauthTokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": AppConfig.oauthClientId,
            "scope": AppConfig.oauthScopes,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.server(0) }
        guard http.statusCode == 200 else {
            // 400/401/403 mean the grant itself is dead → force re-login.
            if [400, 401, 403].contains(http.statusCode) { throw APIError.unauthorized }
            throw APIError.server(http.statusCode)
        }

        struct TokenResponse: Codable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int
        }
        let resp = try JSONDecoder().decode(TokenResponse.self, from: data)
        return StoredTokens(
            accessToken: resp.access_token,
            refreshToken: resp.refresh_token ?? previous.refreshToken,
            expiresIn: resp.expires_in
        )
    }
}
