import Foundation
import AILimitShared

// pi-mono 11894012dd461232eb075bc890538b6866860a10 anthropic.ts.
// These upstream scopes are broader than usage access. The UI must disclose them and
// Anthropic's restriction on third-party Claude.ai login before starting authorization.
public struct ClaudeDirectAuth: Sendable {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirect = URL(string: "http://localhost:53692/callback")!
    private let wire: DirectHTTP
    public init(http: any HTTPTransport = SecureHTTPTransport(), now: @escaping @Sendable () -> Date = { Date() }) { wire = DirectHTTP(http: http, now: now) }

    public func signIn(ui: DirectSignInUI) async throws -> DirectCredential {
        let pkce = try OAuthPKCE()
        let url = try SubscriptionOAuth.url("https://claude.ai/oauth/authorize", parameters: [
            "code": "true", "response_type": "code", "client_id": Self.clientID,
            "redirect_uri": Self.redirect.absoluteString,
            "scope": "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
            "code_challenge": pkce.challenge, "code_challenge_method": "S256", "state": pkce.state
        ])
        let code = try await SubscriptionOAuth.code(ui: ui, authorization: url, redirect: Self.redirect, state: pkce.state)
        let json = try await wire.json("https://platform.claude.com/v1/oauth/token", [
            "grant_type": "authorization_code", "client_id": Self.clientID, "code": code,
            "state": pkce.state, "redirect_uri": Self.redirect.absoluteString, "code_verifier": pkce.verifier
        ])
        try Task.checkCancellation()
        return try credential(json)
    }

    public func refresh(_ credential: DirectCredential) async throws -> DirectCredential {
        try SubscriptionOAuth.validate(credential, provider: .claude, now: wire.now(), checkExpiry: false)
        guard let refresh = credential.refreshToken else {
            try SubscriptionOAuth.validate(credential, provider: .claude, now: wire.now())
            return credential
        }
        let json = try await wire.json("https://platform.claude.com/v1/oauth/token", [
            "grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": refresh
        ])
        try Task.checkCancellation()
        return try self.credential(json, previous: credential)
    }

    private func credential(_ json: JSON, previous: DirectCredential? = nil) throws -> DirectCredential {
        var result = try SubscriptionOAuth.token(json, provider: .claude, previous: previous, now: wire.now())
        try SubscriptionOAuth.bind(json["account"]["uuid"].string, key: "accountID", to: &result)
        try SubscriptionOAuth.bind(json["organization"]["uuid"].string, key: "organizationID", to: &result)
        return result
    }
}
