import Foundation
import AILimitShared

// Threat model: callbacks are untrusted browser input; tokens only arrive over the pinned
// HTTPS token transport. No tokens, remote error descriptions or identity data are logged.
// The application owns the redacted auth-event audit trail and Keychain persistence.
enum SubscriptionOAuth {
    private static let forbiddenSecretCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
    static func code(ui: DirectSignInUI, authorization: URL, redirect: URL, state: String) async throws -> String {
        let callback = try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { try await ui.authorize(authorization, redirect, state) }
            group.addTask { try await Task.sleep(for: .seconds(300)); throw UsageError.timeout }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw UsageError.cancelled }
            return result
        }
        try Task.checkCancellation()
        guard callback.scheme == redirect.scheme, callback.host == redirect.host,
              callback.port == redirect.port, callback.path == redirect.path,
              callback.user == nil, callback.password == nil, callback.fragment == nil,
              let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { throw UsageError.authentication }
        let items = parts.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state,
              !items.contains(where: { $0.name == "error" }),
              items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw UsageError.authentication }
        return code
    }

    static func url(_ base: String, parameters: [String: String]) throws -> URL {
        guard var parts = URLComponents(string: base) else { throw UsageError.malformed }
        parts.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw UsageError.malformed }
        return url
    }

    static func token(_ json: JSON, provider: ProviderID, previous: DirectCredential? = nil, now: Date, requiresExpiry: Bool = true) throws -> DirectCredential {
        guard json["error"].isNull, let access = json["access_token"].string, validSecret(access),
              previous == nil || previous?.provider == provider else { throw UsageError.authentication }
        if let type = json["token_type"].string, type.lowercased() != "bearer" { throw UsageError.authentication }
        let lifetime = try json["expires_in"].number()
        if let lifetime {
            guard lifetime > 0 else { throw UsageError.malformed }
        } else if requiresExpiry || previous?.expiresAt != nil {
            throw UsageError.malformed
        }
        let refresh = json["refresh_token"].string ?? previous?.refreshToken
        if let refresh, !validSecret(refresh) { throw UsageError.malformed }
        return DirectCredential(provider: provider, accessToken: access, refreshToken: refresh,
                                expiresAt: lifetime.map { now.addingTimeInterval($0) }, metadata: previous?.metadata ?? [:])
    }

    static func validate(_ credential: DirectCredential, provider: ProviderID, now: Date, checkExpiry: Bool = true) throws {
        guard credential.provider == provider, validSecret(credential.accessToken),
              !checkExpiry || credential.expiresAt.map({ $0 > now }) != false else { throw UsageError.authentication }
    }

    static func validSecret(_ value: String) -> Bool {
        !value.isEmpty && value.rangeOfCharacter(from: forbiddenSecretCharacters) == nil
    }

    static func bind(_ value: String?, key: String, to credential: inout DirectCredential) throws {
        guard let value else { return }
        guard validSecret(value) else { throw UsageError.malformed }
        if let old = credential.metadata[key], old != value { throw UsageError.authentication }
        credential.metadata[key] = value
    }
}
