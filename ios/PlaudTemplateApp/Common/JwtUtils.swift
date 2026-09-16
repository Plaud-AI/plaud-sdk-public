import Foundation

/// Minimal JWT payload reader for the userAccessToken (display + account-switch detection only —
/// no signature verification; the backend remains the source of truth).
enum JwtUtils {

    struct TokenInfo {
        let sub: String
        let userId: String
        let expSeconds: TimeInterval
        let clientId: String
    }

    /// Parse sub / user_id / exp / client_id from a JWT; nil if the token is malformed.
    static func parse(_ token: String) -> TokenInfo? {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String, !sub.isEmpty
        else { return nil }
        return TokenInfo(
            sub: sub,
            userId: (json["user_id"] as? String) ?? sub,
            expSeconds: (json["exp"] as? TimeInterval) ?? 0,
            clientId: (json["client_id"] as? String) ?? ""
        )
    }

    /// "eyJhb…Kdxg" style mask for on-screen display.
    static func mask(_ token: String) -> String {
        guard token.count > 12 else { return token }
        return "\(token.prefix(6))…\(token.suffix(6))"
    }
}
