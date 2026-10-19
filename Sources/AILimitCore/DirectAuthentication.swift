import Foundation
import CryptoKit
import Security
import AILimitShared

public struct DirectCredential: Codable, Sendable {
    public var provider: ProviderID
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var metadata: [String: String]

    public init(provider: ProviderID, accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, metadata: [String: String] = [:]) {
        self.provider = provider; self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.metadata = metadata
    }
    public func encoded() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
    public static func decode(_ value: String, for provider: ProviderID) throws -> Self {
        guard value.utf8.count <= 128 * 1024,
              let credential = try? JSONDecoder().decode(Self.self, from: Data(value.utf8)),
              credential.provider == provider, !credential.accessToken.isEmpty,
              credential.accessToken.rangeOfCharacter(from: .newlines) == nil,
              credential.refreshToken?.rangeOfCharacter(from: .newlines) == nil else { throw UsageError.authentication }
        return credential
    }
}

public struct DirectSignInUI: Sendable {
    public let openURL: @Sendable (URL) async throws -> Void
    public let showCode: @Sendable (String, URL) async throws -> Void
    public let authorize: @Sendable (URL, URL, String) async throws -> URL
    public init(openURL: @escaping @Sendable (URL) async throws -> Void,
                showCode: @escaping @Sendable (String, URL) async throws -> Void,
                authorize: @escaping @Sendable (URL, URL, String) async throws -> URL) {
        self.openURL = openURL; self.showCode = showCode; self.authorize = authorize
    }
}

struct OAuthPKCE: Sendable {
    let verifier: String
    let challenge: String
    let state: String
    init() throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw UsageError.configuration("인증 난수 생성 실패") }
            return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        verifier = try random(); state = try random()
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct DirectHTTP: Sendable {
    let http: any HTTPTransport
    let now: @Sendable () -> Date
    init(http: any HTTPTransport, now: @escaping @Sendable () -> Date = { Date() }) { self.http = http; self.now = now }
    func form(_ url: String, _ parameters: [String: String]) async throws -> JSON {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = parameters.sorted { $0.key < $1.key }.map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        return try await send(HTTPRequest(url, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"], body: Data(body.utf8)))
    }
    func json(_ url: String, _ parameters: [String: Any], headers: [String: String] = [:]) async throws -> JSON {
        var headers = headers; headers["Content-Type"] = "application/json"; headers["Accept"] = "application/json"
        return try await send(HTTPRequest(url, method: "POST", headers: headers, body: JSONSerialization.data(withJSONObject: parameters)))
    }
    func get(_ url: String, headers: [String: String] = [:]) async throws -> JSON { try await send(HTTPRequest(url, headers: headers)) }
    private func send(_ request: HTTPRequest) async throws -> JSON {
        try Task.checkCancellation()
        let response = try await http.send(request)
        try Task.checkCancellation()
        if response.status == 400, let error = try? JSON(data: response.body),
           ["invalid_grant", "invalid_client", "expired_token", "access_denied"].contains(error["error"].string ?? "") {
            throw UsageError.authentication
        }
        return try JSON(data: response.checked(now: now()))
    }
}

public enum DirectAuthentication {
    public static func signIn(_ provider: ProviderID, http: any HTTPTransport = SecureHTTPTransport(), ui: DirectSignInUI) async throws -> DirectCredential {
        let credential: DirectCredential
        switch provider {
        case .codex: credential = try await CodexDirectAuth(http: http).signIn(ui: ui)
        case .claude: credential = try await ClaudeDirectAuth(http: http).signIn(ui: ui)
        case .copilot: credential = try await CopilotDirectAuth(http: http).signIn(ui: ui)
        case .antigravity: credential = try await AntigravityDirectAuth(http: http).signIn(ui: ui)
        case .kiro: credential = try await KiroDirectAuth(http: http).signIn(ui: ui)
        case .cursor: credential = try await CursorDirectAuth(http: http).signIn(ui: ui)
        case .grok: credential = try await GrokDirectAuth(http: http).signIn(ui: ui)
        case .windsurf: credential = try await WindsurfDirectAuth(http: http).signIn(ui: ui)
        case .perplexity: throw UsageError.configuration("앱의 웹 세션 로그인 창을 사용하세요.")
        }
        try Task.checkCancellation()
        return try DirectCredential.decode(credential.encoded(), for: provider)
    }
    static func refreshed(_ credential: DirectCredential, context: FetchContext) async throws -> DirectCredential {
        switch credential.provider {
        case .codex: try await CodexDirectAuth(http: context.http, now: context.now).refresh(credential)
        case .claude: try await ClaudeDirectAuth(http: context.http, now: context.now).refresh(credential)
        case .copilot: try await CopilotDirectAuth(http: context.http, now: context.now).refresh(credential)
        case .antigravity: try await AntigravityDirectAuth(http: context.http, now: context.now).refresh(credential)
        case .kiro: try await KiroDirectAuth(http: context.http, now: context.now).refresh(credential)
        case .cursor: try await CursorDirectAuth(http: context.http, now: context.now).refresh(credential)
        case .grok: try await GrokDirectAuth(http: context.http, now: context.now).refresh(credential)
        case .windsurf: try await WindsurfDirectAuth(http: context.http, now: context.now).refresh(credential)
        case .perplexity: throw UsageError.authentication
        }
    }
}

struct AuthenticatedUsageProvider: UsageProvider {
    let id: ProviderID
    func fetch(context: FetchContext) async throws -> UsageSnapshot {
        guard context.connection.directAuthentication == true else { return try await Providers.legacy(id).fetch(context: context) }
        guard context.connection.enabled, context.connection.consentedAt != nil else { throw UsageError.authentication }
        var credential = try DirectCredential.decode(context.secret(), for: id)
        if let expires = credential.expiresAt, expires <= context.now().addingTimeInterval(credential.refreshToken == nil ? 0 : 120) {
            try Task.checkCancellation()
            let expiring = credential
            // A refresh can consume a one-use token. Once started, finish the exchange
            // and persist its replacement even if the caller is cancelled. Lifecycle
            // transitions await fetch completion before replacing/removing secrets.
            credential = try await Task {
                let refreshed = try await DirectAuthentication.refreshed(expiring, context: context)
                let validated = try DirectCredential.decode(refreshed.encoded(), for: id)
                try context.secrets.save(validated.encoded(), for: context.connection.id)
                return validated
            }.value
            try Task.checkCancellation()
        }
        let result: UsageSnapshot
        switch id {
        case .codex: result = try await CodexDirectProvider().fetch(context: context, credential: credential)
        case .claude: result = try await ClaudeDirectProvider().fetch(context: context, credential: credential)
        case .copilot: result = try await CopilotDirectProvider().fetch(context: context, credential: credential)
        case .antigravity: result = try await AntigravityDirectProvider().fetch(context: context, credential: credential)
        case .kiro: result = try await KiroDirectProvider().fetch(context: context, credential: credential)
        case .cursor: result = try await CursorDirectProvider().fetch(context: context, credential: credential)
        case .grok: result = try await GrokDirectProvider().fetch(context: context, credential: credential)
        case .windsurf: result = try await WindsurfDirectProvider().fetch(context: context, credential: credential)
        case .perplexity:
            var webContext = context; webContext.secrets = SuppliedSecret(credential.accessToken)
            result = try await PerplexityProvider().fetch(context: webContext)
        }
        try Task.checkCancellation()
        guard !result.balances.isEmpty || result.windows.contains(where: { $0.usedPercent != nil || $0.used != nil || $0.remaining != nil || $0.unlimited }) else {
            throw UsageError.unavailable("로그인은 되었지만 이 계정의 사용량이 제공되지 않습니다. 권한·플랜·서비스 접근 제한을 확인하세요.")
        }
        return result
    }
}
