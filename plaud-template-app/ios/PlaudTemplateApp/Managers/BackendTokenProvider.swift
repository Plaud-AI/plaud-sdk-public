import Foundation

/// Fetches a `user_access_token` from a self-hosted token broker (one of the
/// templates in `backend-templates/`). Falls back to the legacy `UserAccessToken`
/// in Info.plist when no broker is configured — preserving the original demo
/// path so existing setups keep working.
///
/// **Why this exists:** `client_id` and `secret_key` must never live in a
/// distributed mobile app. A broker holds them server-side and hands the
/// mobile app only short-lived per-user tokens. See `backend-templates/README.md`
/// for the full rationale and one-click deploy templates.
///
/// **Configuration** (in `PartnerConfig.local.xcconfig`):
///   BACKEND_TOKEN_ENDPOINT = https://your-broker.example.com/issue-token
///   APP_SHARED_SECRET      = <openssl rand -hex 32>
///
/// If both are missing, we use the legacy path (Info.plist `UserAccessToken`).
final class BackendTokenProvider {

    static let shared = BackendTokenProvider()

    private let session = URLSession.shared
    private let queue = DispatchQueue(label: "ai.plaud.template.backend-token", qos: .userInitiated)

    /// Cached token from the broker. `nil` until the first successful fetch.
    private var cachedToken: String?
    /// Unix epoch seconds at which the cached token expires.
    private var expiresAt: TimeInterval = 0

    private init() {}

    // MARK: - Configuration

    /// `true` if a broker is configured. When `false`, callers should use the
    /// legacy `Info.plist` token directly.
    var isConfigured: Bool {
        !backendEndpoint.isEmpty && !appSharedSecret.isEmpty
    }

    private var backendEndpoint: String {
        Bundle.main.object(forInfoDictionaryKey: "BackendTokenEndpoint") as? String ?? ""
    }

    private var appSharedSecret: String {
        Bundle.main.object(forInfoDictionaryKey: "AppSharedSecret") as? String ?? ""
    }

    // MARK: - Sync access

    /// Returns the most recent successfully-fetched token, or `nil` if none yet.
    /// Used by code paths that read the token synchronously (e.g. SDK getters).
    var currentCachedToken: String? {
        queue.sync { cachedToken }
    }

    // MARK: - Async fetch

    /// Fetches a token from the broker. On success, caches it and returns via callback on the main queue.
    /// On failure, returns the error — caller decides whether to fall back to Info.plist.
    func fetchToken(userId: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard isConfigured else {
            DispatchQueue.main.async { completion(.failure(BackendTokenError.notConfigured)) }
            return
        }
        guard let url = URL(string: backendEndpoint) else {
            DispatchQueue.main.async { completion(.failure(BackendTokenError.invalidEndpoint(backendEndpoint))) }
            return
        }

        // Short-circuit: cache hit (with 60s safety margin)
        let now = Date().timeIntervalSince1970
        if let cached = currentCachedToken, now < expiresAt - 60 {
            DispatchQueue.main.async { completion(.success(cached)) }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appSharedSecret, forHTTPHeaderField: "X-App-Secret")
        request.timeoutInterval = 30

        let body = ["user_id": userId]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let httpResp = response as? HTTPURLResponse, let data = data else {
                DispatchQueue.main.async { completion(.failure(BackendTokenError.noResponse)) }
                return
            }
            guard (200..<300).contains(httpResp.statusCode) else {
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    completion(.failure(BackendTokenError.brokerError(httpResp.statusCode, bodyStr)))
                }
                return
            }

            do {
                let parsed = try JSONDecoder().decode(IssueTokenResponse.self, from: data)
                self.queue.sync {
                    self.cachedToken = parsed.plaud_token
                    self.expiresAt = Date().timeIntervalSince1970 + TimeInterval(parsed.expires_in ?? 86400)
                }
                DispatchQueue.main.async { completion(.success(parsed.plaud_token)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    /// Drops the cached token. Call this from a 401 handler before re-fetching.
    func invalidateCache() {
        queue.sync {
            cachedToken = nil
            expiresAt = 0
        }
    }
}

// MARK: - Models

private struct IssueTokenResponse: Decodable {
    let plaud_token: String
    let expires_in: Int?
}

enum BackendTokenError: LocalizedError {
    case notConfigured
    case invalidEndpoint(String)
    case noResponse
    case brokerError(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "BACKEND_TOKEN_ENDPOINT and APP_SHARED_SECRET are not set in PartnerConfig.local.xcconfig"
        case .invalidEndpoint(let s):
            return "BACKEND_TOKEN_ENDPOINT is not a valid URL: \(s)"
        case .noResponse:
            return "Token broker returned no HTTP response"
        case .brokerError(let code, let body):
            return "Token broker HTTP \(code): \(body)"
        }
    }
}
