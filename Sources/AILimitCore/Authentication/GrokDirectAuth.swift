import Foundation

// Official xai-org/grok-build@f0e3be1100ef5252488e3be8bb0e91cf68d8c305:
// crates/codegen/xai-grok-login/src/{config.rs,device_code.rs,oidc/protocol.rs}.
public struct GrokDirectAuth: Sendable {
    static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    private static let scope = "openid profile email offline_access grok-cli:access api:access conversations:read conversations:write workspaces:read workspaces:write"
    private let http: any HTTPTransport
    private let now: @Sendable () -> Date
    public init(http: any HTTPTransport = SecureHTTPTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http; self.now = now
    }

    public func signIn(ui: DirectSignInUI) async throws -> DirectCredential {
        let request = DirectWebAuthSupport.formRequest("https://auth.x.ai/oauth2/device/code", parameters: ["client_id": Self.clientID, "scope": Self.scope, "referrer": "grok-build"])
        let response = try await http.send(request)
        if response.status == 404 { throw UsageError.unavailable("현재 Grok 인증 서버에서 기기 코드 로그인을 제공하지 않습니다.") }
        let json = try JSON(data: response.checked(now: now()))
        let deviceCode = try DirectWebAuthSupport.token(json, "device_code")
        let userCode = try DirectWebAuthSupport.token(json, "user_code")
        guard userCode.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              let expires = try json["expires_in"].number(), expires > 0 else { throw UsageError.malformed }
        let uri = try DirectWebAuthSupport.token(json, "verification_uri")
        guard let verificationURL = URL(string: uri), verificationURL.scheme == "https", verificationURL.host != nil,
              verificationURL.user == nil, verificationURL.password == nil else { throw UsageError.malformed }
        var interval = max(1, try json["interval"].number() ?? 5)
        guard interval <= 900 else { throw UsageError.timeout }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(min(expires, 900)))
        try await ui.showCode(userCode, verificationURL)
        while clock.now < deadline {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            try await Task.sleep(for: min(.seconds(interval), remaining))
            guard clock.now < deadline else { throw UsageError.timeout }
            let poll = try await http.send(DirectWebAuthSupport.formRequest("https://auth.x.ai/oauth2/token", parameters: ["grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": deviceCode, "client_id": Self.clientID]))
            try Task.checkCancellation()
            if let credential = try Self.pollResult(poll, now: now(), interval: &interval) { return credential }
        }
        throw UsageError.timeout
    }

    // Inspect OAuth errors before HTTP status classification: pending is not failed login.
    static func pollResult(_ response: HTTPResponse, now: Date, interval: inout Double) throws -> DirectCredential? {
        if (200..<300).contains(response.status) { return try credential(JSON(data: response.body), now: now) }
        if response.status == 400, let json = try? JSON(data: response.body) {
            switch json["error"].string {
            case "authorization_pending": return nil
            case "slow_down": interval += 5; return nil
            case "access_denied": throw UsageError.authentication
            case "expired_token": throw UsageError.timeout
            default: break
            }
        }
        _ = try response.checked(now: now)
        throw UsageError.authentication
    }

    static func credential(_ json: JSON, now: Date, previous: DirectCredential? = nil) throws -> DirectCredential {
        let access = try DirectWebAuthSupport.token(json, "access_token")
        let refresh = json["refresh_token"].isNull ? previous?.refreshToken : try DirectWebAuthSupport.token(json, "refresh_token")
        let lifetime = try json["expires_in"].number()
        if let lifetime, lifetime <= 0 { throw UsageError.authentication }
        return DirectCredential(provider: .grok, accessToken: access, refreshToken: refresh, expiresAt: lifetime.map { now.addingTimeInterval($0) } ?? DirectWebAuthSupport.jwtExpiry(access), metadata: previous?.metadata ?? [:])
    }

    public func refresh(_ credential: DirectCredential) async throws -> DirectCredential {
        guard credential.provider == .grok else { throw UsageError.authentication }
        guard let refresh = credential.refreshToken, !refresh.isEmpty else {
            if let expiry = credential.expiresAt, expiry <= now() { throw UsageError.authentication }
            return credential
        }
        let response = try await http.send(DirectWebAuthSupport.formRequest("https://auth.x.ai/oauth2/token", parameters: ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": Self.clientID]))
        if response.status == 400 { throw UsageError.authentication }
        return try Self.credential(JSON(data: response.checked(now: now())), now: now(), previous: credential)
    }
}
