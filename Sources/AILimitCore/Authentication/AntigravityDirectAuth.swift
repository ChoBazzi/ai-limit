import Foundation
import AILimitShared

struct AntigravityOAuthConfiguration: Decodable, Sendable {
    let clientID: String
    let clientSecret: String

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Limit/antigravity-oauth.json")
    }

    static func load(from url: URL = defaultURL) throws -> Self {
        do {
            let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard !value.clientID.isEmpty, !value.clientSecret.isEmpty,
                  !value.clientID.contains(where: { $0.isWhitespace }),
                  !value.clientSecret.contains(where: { $0.isWhitespace }) else { throw UsageError.malformed }
            return value
        } catch {
            throw UsageError.configuration("Antigravity OAuth 로컬 설정이 없거나 올바르지 않습니다. ~/Library/Application Support/AI Limit/antigravity-oauth.json에 clientID와 clientSecret을 설정하세요. README의 로컬 OAuth 설정을 확인하세요.")
        }
    }
}

struct AntigravityDirectAuth: Sendable {
    private let configuration: @Sendable () throws -> AntigravityOAuthConfiguration
    static let redirectURI = "http://127.0.0.1:51121/oauth2callback"
    private let client: DirectHTTP

    init(http: any HTTPTransport = SecureHTTPTransport(), now: @escaping @Sendable () -> Date = { Date() },
         configuration: @escaping @Sendable () throws -> AntigravityOAuthConfiguration = { try AntigravityOAuthConfiguration.load() }) {
        client = DirectHTTP(http: http, now: now)
        self.configuration = configuration
    }

    func signIn(ui: DirectSignInUI) async throws -> DirectCredential {
        let configuration = try configuration()
        let pkce = try OAuthPKCE()
        guard var authorization = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth"),
              let redirect = URL(string: Self.redirectURI) else { throw UsageError.malformed }
        authorization.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile https://www.googleapis.com/auth/cloud-platform"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let url = authorization.url else { throw UsageError.malformed }
        let callback = try await ui.authorize(url, redirect, pkce.state)
        try Task.checkCancellation()
        let code = try Self.authorizationCode(callback, state: pkce.state)
        let tokens = try await client.form("https://oauth2.googleapis.com/token", [
            "client_id": configuration.clientID, "client_secret": configuration.clientSecret,
            "grant_type": "authorization_code", "code": code,
            "code_verifier": pkce.verifier, "redirect_uri": Self.redirectURI
        ])
        var credential = try Self.credential(tokens, previous: nil, now: client.now())
        // Identity is optional enrichment, never copied to the shared usage snapshot.
        if let user = try? await client.get("https://www.googleapis.com/oauth2/v2/userinfo", headers: ["Authorization": "Bearer \(credential.accessToken)"]) {
            credential.metadata["accountID"] = user["id"].string
            credential.metadata["email"] = user["email"].string
        }
        try Task.checkCancellation()
        return credential
    }

    func refresh(_ credential: DirectCredential) async throws -> DirectCredential {
        guard credential.provider == .antigravity else { throw UsageError.authentication }
        guard let refresh = credential.refreshToken, !refresh.isEmpty else {
            guard let expiry = credential.expiresAt, expiry > client.now() else { throw UsageError.authentication }
            return credential
        }
        let configuration = try configuration()
        let tokens = try await client.form("https://oauth2.googleapis.com/token", [
            "client_id": configuration.clientID, "client_secret": configuration.clientSecret,
            "grant_type": "refresh_token", "refresh_token": refresh
        ])
        try Task.checkCancellation()
        return try Self.credential(tokens, previous: credential, now: client.now())
    }

    static func authorizationCode(_ callback: URL, state: String) throws -> String {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1", parts.port == 51121,
              parts.path == "/oauth2callback", parts.user == nil, parts.password == nil,
              parts.fragment == nil else { throw UsageError.authentication }
        let items = parts.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        let codes = items.filter { $0.name == "code" }
        guard states.count == 1, states[0].value == state,
              !items.contains(where: { $0.name == "error" }), codes.count == 1,
              let code = codes[0].value, !code.isEmpty else { throw UsageError.authentication }
        return code
    }

    static func credential(_ tokens: JSON, previous: DirectCredential?, now: Date) throws -> DirectCredential {
        guard let access = tokens["access_token"].string, !access.isEmpty,
              !access.contains(where: { $0.isWhitespace }),
              let lifetime = try tokens["expires_in"].number(), lifetime > 0,
              now.addingTimeInterval(lifetime).timeIntervalSince1970.isFinite else { throw UsageError.malformed }
        if let type = tokens["token_type"].string, type.lowercased() != "bearer" { throw UsageError.malformed }
        if let scope = tokens["scope"].string,
           !scope.split(separator: " ").contains("https://www.googleapis.com/auth/cloud-platform") {
            throw UsageError.unavailable("Google 로그인은 완료되었지만 Antigravity 조회 권한이 부여되지 않았습니다.")
        }
        let refresh = tokens["refresh_token"].string ?? previous?.refreshToken
        if let refresh, refresh.isEmpty || refresh.contains(where: { $0.isWhitespace }) { throw UsageError.malformed }
        return DirectCredential(provider: .antigravity, accessToken: access, refreshToken: refresh,
                                expiresAt: now.addingTimeInterval(lifetime), metadata: previous?.metadata ?? [:])
    }
}
