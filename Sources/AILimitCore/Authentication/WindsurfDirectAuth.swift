import Foundation

// Custom Devin PKCE, not standard OAuth: CLIProxyAPI@acdace936fa7df2905500c7f5e0a97d683138dea
// internal/auth/devin/devin_auth.go. No passwords, Auth1 bridge, or external app storage.
public struct WindsurfDirectAuth: Sendable {
    private let http: any HTTPTransport
    private let now: @Sendable () -> Date
    public init(http: any HTTPTransport = SecureHTTPTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http; self.now = now
    }

    public func signIn(ui: DirectSignInUI) async throws -> DirectCredential {
        let pkce = try OAuthPKCE()
        guard let callback = URL(string: "http://127.0.0.1:57891/callback") else { throw UsageError.malformed }
        let login = try DirectWebAuthSupport.url("https://app.devin.ai/auth/cli/continue", parameters: ["redirect_uri": callback.absoluteString, "state": pkce.state, "prompt": "select_account", "code_challenge": pkce.challenge, "code_challenge_method": "S256"])
        let returned = try await ui.authorize(login, callback, pkce.state)
        try Task.checkCancellation()
        let components = URLComponents(url: returned, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        guard returned.scheme == callback.scheme, returned.host == callback.host, returned.port == callback.port, returned.path == callback.path,
              query.filter({ $0.name == "state" }).count == 1, query.first(where: { $0.name == "state" })?.value == pkce.state,
              !query.contains(where: { $0.name == "error" }), query.filter({ $0.name == "code" }).count == 1,
              let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw UsageError.authentication }
        let client = DirectHTTP(http: http, now: now)
        let json = try await client.json("https://api.devin.ai/auth/cli/token", ["code": code, "code_verifier": pkce.verifier])
        let raw = try DirectWebAuthSupport.token(json, "token")
        let token = raw.hasPrefix("eyJ") ? "devin-session-token$" + raw : raw
        let profile = try await client.get("https://api.devin.ai/v3/self", headers: ["Authorization": "Bearer " + token])
        // Preserve only supplied binding fields in Keychain, never in the shared quota snapshot.
        var metadata: [String: String] = [:]
        for key in ["user_id", "org_id", "principal_type"] {
            if let value = profile[key].string { metadata[key] = value }
        }
        let jwt = token.hasPrefix("devin-session-token$") ? String(token.dropFirst("devin-session-token$".count)) : token
        return DirectCredential(provider: .windsurf, accessToken: token, expiresAt: DirectWebAuthSupport.jwtExpiry(jwt), metadata: metadata)
    }

    public func refresh(_ credential: DirectCredential) async throws -> DirectCredential {
        guard credential.provider == .windsurf else { throw UsageError.authentication }
        // This protocol documents no refresh exchange or guaranteed session lifetime.
        if let expiry = credential.expiresAt, expiry <= now() { throw UsageError.authentication }
        return credential
    }
}
