import Foundation
import AILimitShared

// Builder ID device flow: Quotio e0ad2858; AWS SSO OIDC public registration.
// This intentionally does not impersonate social-login callbacks or enterprise profiles.
struct KiroDirectAuth: Sendable {
    private static let base = "https://oidc.us-east-1.amazonaws.com"
    private let client: DirectHTTP
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    init(http: any HTTPTransport = SecureHTTPTransport(), now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        client = DirectHTTP(http: http, now: now)
        self.sleep = sleep
    }

    func signIn(ui: DirectSignInUI) async throws -> DirectCredential {
        try Task.checkCancellation()
        let registration = try await client.json(Self.base + "/client/register", [
            "clientName": "AI Limit", "clientType": "public",
            "scopes": ["codewhisperer:completions", "codewhisperer:analysis", "codewhisperer:conversations"]
        ])
        guard let clientID = registration["clientId"].string, !clientID.isEmpty,
              let secret = registration["clientSecret"].string, !secret.isEmpty else { throw UsageError.malformed }
        var metadata = ["clientId": clientID, "clientSecret": secret, "region": "us-east-1", "authMethod": "IdC",
                        "machineID": UUID().uuidString.lowercased()]
        if let expiry = try registration["clientSecretExpiresAt"].number() {
            guard expiry > client.now().timeIntervalSince1970 else { throw UsageError.authentication }
            metadata["clientSecretExpiresAt"] = String(expiry)
        }
        let device = try await client.json(Self.base + "/device_authorization", [
            "clientId": clientID, "clientSecret": secret, "startUrl": "https://view.awsapps.com/start"
        ])
        guard let deviceCode = device["deviceCode"].string, !deviceCode.isEmpty,
              let userCode = device["userCode"].string, !userCode.isEmpty,
              let verification = device["verificationUriComplete"].string ?? device["verificationUri"].string,
              let lifetime = try device["expiresIn"].number(), lifetime > 0 else { throw UsageError.malformed }
        let url = try Self.verificationURL(verification)
        var interval = max(5, try device["interval"].number() ?? 5)
        let deadline = client.now().addingTimeInterval(lifetime)
        guard deadline.timeIntervalSince1970.isFinite else { throw UsageError.malformed }
        try await ui.showCode(userCode, url)
        while client.now() < deadline {
            try Task.checkCancellation()
            try await sleep(min(interval, deadline.timeIntervalSince(client.now())))
            try Task.checkCancellation()
            guard client.now() < deadline else { break }
            let response = try await client.http.send(HTTPRequest(Self.base + "/token", method: "POST",
                headers: ["Content-Type": "application/json", "Accept": "application/json"],
                body: try JSONSerialization.data(withJSONObject: [
                    "clientId": clientID, "clientSecret": secret, "deviceCode": deviceCode,
                    "grantType": "urn:ietf:params:oauth:grant-type:device_code"
                ]), timeout: min(20, deadline.timeIntervalSince(client.now()))))
            try Task.checkCancellation()
            guard client.now() < deadline else { throw UsageError.authentication }
            let result = try? JSON(data: response.body)
            if let error = result?["error"].string, response.status == 400 {
                switch error {
                case "authorization_pending": continue
                case "slow_down": interval += 5; continue
                case "access_denied", "expired_token", "invalid_grant", "invalid_client", "unauthorized_client":
                    throw UsageError.authentication
                default: throw UsageError.unavailable("AWS Builder ID 인증 요청을 완료할 수 없습니다.")
                }
            }
            let payload = try JSON(data: response.checked(now: client.now()))
            guard payload["error"].isNull else { throw UsageError.authentication }
            return try Self.credential(payload, metadata: metadata, previousRefresh: nil, now: client.now())
        }
        throw UsageError.authentication
    }

    func refresh(_ credential: DirectCredential) async throws -> DirectCredential {
        guard credential.provider == .kiro, credential.metadata["region"] == "us-east-1" else { throw UsageError.authentication }
        guard let refresh = credential.refreshToken, !refresh.isEmpty else {
            guard let expiry = credential.expiresAt, expiry > client.now() else { throw UsageError.authentication }
            return credential
        }
        guard let clientID = credential.metadata["clientId"], !clientID.isEmpty,
              let secret = credential.metadata["clientSecret"], !secret.isEmpty else { throw UsageError.authentication }
        if let rawExpiry = credential.metadata["clientSecretExpiresAt"] {
            guard let expiry = Double(rawExpiry), expiry.isFinite, expiry > client.now().timeIntervalSince1970 else { throw UsageError.authentication }
        }
        let response = try await client.http.send(HTTPRequest(Self.base + "/token", method: "POST",
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            body: try JSONSerialization.data(withJSONObject: [
                "clientId": clientID, "clientSecret": secret, "refreshToken": refresh, "grantType": "refresh_token"
            ])))
        let result = try? JSON(data: response.body)
        if let error = result?["error"].string,
           ["invalid_grant", "invalid_client", "expired_token", "access_denied", "unauthorized_client"].contains(error),
           [400, 401, 403].contains(response.status) { throw UsageError.authentication }
        let payload = try JSON(data: response.checked(now: client.now()))
        guard payload["error"].isNull else { throw UsageError.authentication }
        try Task.checkCancellation()
        return try Self.credential(payload, metadata: credential.metadata, previousRefresh: refresh, now: client.now())
    }

    static func verificationURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              ["oidc.us-east-1.amazonaws.com", "view.awsapps.com"].contains(parts.host ?? "") else { throw UsageError.malformed }
        return url
    }

    static func credential(_ tokens: JSON, metadata: [String: String], previousRefresh: String?, now: Date) throws -> DirectCredential {
        guard let access = tokens["accessToken"].string, !access.isEmpty,
              !access.contains(where: { $0.isWhitespace }),
              let lifetime = try tokens["expiresIn"].number(), lifetime > 0,
              now.addingTimeInterval(lifetime).timeIntervalSince1970.isFinite else { throw UsageError.malformed }
        if let type = tokens["tokenType"].string, type.lowercased() != "bearer" { throw UsageError.malformed }
        let refresh = tokens["refreshToken"].string ?? previousRefresh
        if let refresh, refresh.isEmpty || refresh.contains(where: { $0.isWhitespace }) { throw UsageError.malformed }
        var metadata = metadata
        if let arn = tokens["profileArn"].string, !arn.isEmpty {
            if let existing = metadata["profileARN"], existing != arn { throw UsageError.authentication }
            metadata["profileARN"] = arn
        }
        return DirectCredential(provider: .kiro, accessToken: access, refreshToken: refresh,
                                expiresAt: now.addingTimeInterval(lifetime), metadata: metadata)
    }
}
