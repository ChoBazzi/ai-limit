import Foundation
import AILimitShared

// Protocol: anomalyco/opencode 7945de208964a49300d7f770d1a71d078db9a4c4,
// packages/opencode/src/plugin/openai/codex.ts. This does not launch Codex.
public struct CodexDirectAuth: Sendable {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let redirect = URL(string: "http://localhost:1455/auth/callback")!
    private let wire: DirectHTTP
    public init(http: any HTTPTransport = SecureHTTPTransport(), now: @escaping @Sendable () -> Date = { Date() }) { wire = DirectHTTP(http: http, now: now) }

    public func signIn(ui: DirectSignInUI) async throws -> DirectCredential {
        let pkce = try OAuthPKCE()
        let url = try SubscriptionOAuth.url("https://auth.openai.com/oauth/authorize", parameters: [
            "response_type": "code", "client_id": Self.clientID, "redirect_uri": Self.redirect.absoluteString,
            "scope": "openid profile email offline_access", "code_challenge": pkce.challenge,
            "code_challenge_method": "S256", "state": pkce.state, "id_token_add_organizations": "true",
            "codex_cli_simplified_flow": "true", "originator": "ai_limit"
        ])
        let code = try await SubscriptionOAuth.code(ui: ui, authorization: url, redirect: Self.redirect, state: pkce.state)
        let json = try await wire.form("https://auth.openai.com/oauth/token", [
            "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect.absoluteString,
            "client_id": Self.clientID, "code_verifier": pkce.verifier
        ])
        try Task.checkCancellation()
        return try credential(json)
    }

    public func refresh(_ credential: DirectCredential) async throws -> DirectCredential {
        try SubscriptionOAuth.validate(credential, provider: .codex, now: wire.now(), checkExpiry: false)
        guard let refresh = credential.refreshToken else {
            try SubscriptionOAuth.validate(credential, provider: .codex, now: wire.now())
            return credential
        }
        let json = try await wire.form("https://auth.openai.com/oauth/token", [
            "grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": refresh
        ])
        try Task.checkCancellation()
        return try self.credential(json, previous: credential)
    }

    private func credential(_ json: JSON, previous: DirectCredential? = nil) throws -> DirectCredential {
        var result = try SubscriptionOAuth.token(json, provider: .codex, previous: previous, now: wire.now())
        // Routing hints only, extracted from the HTTPS-issued access token. We never consume
        // id_token as an authenticated identity assertion or establish a local OIDC session.
        // The resource server validates the bearer and its account entitlement on every read.
        if let claims = Self.routingClaims(result.accessToken) {
            let auth = claims["https://api.openai.com/auth"]
            try SubscriptionOAuth.bind(auth["chatgpt_account_id"].string ?? claims["chatgpt_account_id"].string, key: "accountID", to: &result)
            // Pair workspace routing with the subject when supplied; workspace IDs alone
            // cannot distinguish two members of the same organization.
            try SubscriptionOAuth.bind(claims["sub"].string, key: "subject", to: &result)
        }
        return result
    }

    static func routingClaims(_ token: String) -> JSON? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var value = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSON(data: data)
    }
}
