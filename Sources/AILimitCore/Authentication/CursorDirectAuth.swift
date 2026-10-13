import Foundation

// Protocol: Rahularya01/pi-cursor@7a2ab5e43911b173320bfe06b6ea0cd0ad7a6f76/src/auth/oauth.ts.
public struct CursorDirectAuth: Sendable {
    private let http: any HTTPTransport
    private let now: @Sendable () -> Date
    public init(http: any HTTPTransport = SecureHTTPTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http; self.now = now
    }

    public func signIn(ui: DirectSignInUI) async throws -> DirectCredential {
        let pkce = try OAuthPKCE()
        let uuid = UUID().uuidString
        let login = try DirectWebAuthSupport.url("https://cursor.com/loginDeepControl", parameters: ["challenge": pkce.challenge, "uuid": uuid, "mode": "login", "redirectTarget": "cli"])
        let poll = try DirectWebAuthSupport.url("https://api2.cursor.sh/auth/poll", parameters: ["uuid": uuid, "verifier": pkce.verifier])
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(600))
        try await ui.openURL(login)
        var delay: Double = 1
        while clock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(delay))
            guard clock.now < deadline else { throw UsageError.timeout }
            // The verifier query is required by Cursor's protocol; never log this URL.
            let response = try await http.send(HTTPRequest(poll.absoluteString, timeout: 15))
            try Task.checkCancellation()
            if response.status == 404 { delay = min(delay * 1.2, 10); continue }
            let json = try JSON(data: response.checked(now: now()))
            let access = try DirectWebAuthSupport.token(json, "accessToken")
            let refresh = try DirectWebAuthSupport.token(json, "refreshToken")
            return DirectCredential(provider: .cursor, accessToken: access, refreshToken: refresh, expiresAt: DirectWebAuthSupport.jwtExpiry(access))
        }
        throw UsageError.timeout
    }

    public func refresh(_ credential: DirectCredential) async throws -> DirectCredential {
        guard credential.provider == .cursor else { throw UsageError.authentication }
        guard let refresh = credential.refreshToken, !refresh.isEmpty else {
            if let expiry = credential.expiresAt, expiry <= now() { throw UsageError.authentication }
            return credential
        }
        let json = try await DirectHTTP(http: http, now: now).json("https://api2.cursor.sh/auth/exchange_user_api_key", [:], headers: ["Authorization": "Bearer " + refresh])
        let access = try DirectWebAuthSupport.token(json, "accessToken")
        let rotated = json["refreshToken"].isNull ? refresh : try DirectWebAuthSupport.token(json, "refreshToken")
        return DirectCredential(provider: .cursor, accessToken: access, refreshToken: rotated, expiresAt: DirectWebAuthSupport.jwtExpiry(access), metadata: credential.metadata)
    }
}
