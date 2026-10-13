import Foundation
import AILimitShared

// flukelaster/LLM-Usage-Widget 4e9ba459dff930af19d325dab4443892c4f2ce9b
// CopilotOAuthClient.swift; public first-party client, not a user-created GitHub App.
public struct CopilotDirectAuth: Sendable {
    static let clientID = "Iv1.b507a08c87ecfe98"
    private let wire: DirectHTTP
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    public init(http: any HTTPTransport = SecureHTTPTransport(), now: @escaping @Sendable () -> Date = { Date() }, sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        wire = DirectHTTP(http: http, now: now); self.sleep = sleep
    }

    public func signIn(ui: DirectSignInUI) async throws -> DirectCredential {
        try Task.checkCancellation()
        let device = try await wire.form("https://github.com/login/device/code", ["client_id": Self.clientID, "scope": "read:user"])
        guard let code = device["device_code"].string, SubscriptionOAuth.validSecret(code),
              let userCode = device["user_code"].string, SubscriptionOAuth.validSecret(userCode),
              let uri = device["verification_uri"].string, uri == "https://github.com/login/device",
              let url = URL(string: uri), let lifetime = try device["expires_in"].number(), lifetime > 0 else { throw UsageError.malformed }
        let duration = min(lifetime, 900)
        let deadline = wire.now().addingTimeInterval(duration)
        let monotonicDeadline = ContinuousClock.now.advanced(by: .seconds(duration))
        var remaining = duration
        var interval = max(try device["interval"].number() ?? 5, 5)
        try await ui.showCode(userCode, url)
        while remaining > 0 && wire.now() < deadline && ContinuousClock.now < monotonicDeadline {
            try Task.checkCancellation()
            let wait = min(interval, remaining, max(0, deadline.timeIntervalSince(wire.now())))
            try await sleep(wait)
            remaining -= wait
            try Task.checkCancellation()
            guard remaining > 0, wire.now() < deadline, ContinuousClock.now < monotonicDeadline else { throw UsageError.timeout }
            let response = try await wire.http.send(Self.pollRequest(code, timeout: min(20, remaining)))
            // OAuth pending/slow_down can be sent with HTTP 400 or 200. Never accept a
            // token from an unsuccessful HTTP response, even if its body contains one.
            if response.status != 200 && response.status != 400 { _ = try response.checked(now: wire.now()); throw UsageError.authentication }
            let json = try JSON(data: response.body)
            switch json["error"].string {
            case "authorization_pending": continue
            case "slow_down": interval = max(interval + 5, try json["interval"].number() ?? 0); continue
            case .some: throw UsageError.authentication
            case nil:
                guard response.status == 200, wire.now() < deadline, ContinuousClock.now < monotonicDeadline else { throw UsageError.authentication }
                var result = try SubscriptionOAuth.token(json, provider: .copilot, now: wire.now(), requiresExpiry: false)
                let identity = try await wire.get("https://api.github.com/user", headers: Self.headers(result.accessToken))
                guard let id = try identity["id"].integer(), id > 0 else { throw UsageError.authentication }
                result.metadata["userID"] = String(id)
                try Task.checkCancellation()
                return result
            }
        }
        throw UsageError.timeout
    }

    public func refresh(_ credential: DirectCredential) async throws -> DirectCredential {
        try SubscriptionOAuth.validate(credential, provider: .copilot, now: wire.now(), checkExpiry: false)
        guard let refresh = credential.refreshToken else {
            try SubscriptionOAuth.validate(credential, provider: .copilot, now: wire.now())
            return credential
        }
        let json = try await wire.form("https://github.com/login/oauth/access_token", [
            "grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": refresh
        ])
        try Task.checkCancellation()
        // Preserve the account binding; quota fetch verifies /user before reading usage.
        // Returning immediately lets the caller durably save rotated tokens first.
        return try SubscriptionOAuth.token(json, provider: .copilot, previous: credential, now: wire.now(), requiresExpiry: false)
    }

    static func headers(_ access: String) -> [String: String] {
        ["Authorization": "token " + access, "Accept": "application/json", "User-Agent": "AI-Limit"]
    }

    private static func pollRequest(_ code: String, timeout: TimeInterval) -> HTTPRequest {
        let fields = ["client_id": clientID, "device_code": code, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"]
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let form = fields.sorted { $0.key < $1.key }.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        return HTTPRequest("https://github.com/login/oauth/access_token", method: "POST", headers: ["Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"], body: Data(form.utf8), timeout: timeout)
    }
}
