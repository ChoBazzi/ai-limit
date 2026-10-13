import Foundation
import Security
import AILimitShared

public enum LocalTokenSource: String, Codable, Sendable { case native, omp }

public struct Connection: Codable, Sendable, Identifiable {
    public var id: String
    public var accountName: String
    public var provider: ProviderID; public var enabled: Bool; public var credentialReference: String?; public var executable: URL?; public var localFolder: URL?; public var localConsentedAt: Date?; public var codexHome: URL?; public var claudeOrganization: String?; public var consentedAt: Date?
    /// Tokens acquired by AI Limit itself, isolated from optional legacy CLI/manual connections.
    public var directAuthentication: Bool?
    /// Missing in older settings means native Codex/Claude records.
    public var localSource: LocalTokenSource?
    public init(provider: ProviderID, enabled: Bool = false, executable: URL? = nil, localFolder: URL? = nil, localConsentedAt: Date? = nil, codexHome: URL? = nil, claudeOrganization: String? = nil, consentedAt: Date? = nil, id: String = UUID().uuidString, accountName: String = "기본 계정", localSource: LocalTokenSource? = nil) { self.id = id; self.accountName = accountName; self.provider = provider; self.enabled = enabled; self.executable = executable; self.localFolder = localFolder; self.localConsentedAt = localConsentedAt; self.codexHome = codexHome; self.claudeOrganization = claudeOrganization; self.consentedAt = consentedAt; self.credentialReference = enabled && !provider.isCLI ? id : nil; self.localSource = localSource }
    private enum CodingKeys: String, CodingKey { case id, accountName, provider, enabled, credentialReference, executable, localFolder, localConsentedAt, localSource, codexHome, claudeOrganization, consentedAt, directAuthentication }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(ProviderID.self, forKey: .provider)
        id = try values.contains(.id) ? values.decode(String.self, forKey: .id) : provider.rawValue
        accountName = try values.contains(.accountName) ? values.decode(String.self, forKey: .accountName) : "기본 계정"
        enabled = try values.decode(Bool.self, forKey: .enabled)
        credentialReference = try values.decodeIfPresent(String.self, forKey: .credentialReference)
        executable = try values.decodeIfPresent(URL.self, forKey: .executable)
        localFolder = try values.decodeIfPresent(URL.self, forKey: .localFolder)
        localConsentedAt = try values.decodeIfPresent(Date.self, forKey: .localConsentedAt)
        localSource = try values.decodeIfPresent(LocalTokenSource.self, forKey: .localSource)
        codexHome = try values.decodeIfPresent(URL.self, forKey: .codexHome)
        claudeOrganization = try values.decodeIfPresent(String.self, forKey: .claudeOrganization)
        consentedAt = try values.decodeIfPresent(Date.self, forKey: .consentedAt)
        directAuthentication = try values.decodeIfPresent(Bool.self, forKey: .directAuthentication)
        guard Self.validID(id), !accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid connection identity"))
        }
    }
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
}
public struct ConnectionSettings: Codable, Sendable {
    public private(set) var schemaVersion = 2
    public var connections: [Connection] = []
    public var pinnedConnectionID: String?
    public var theme: String = "system"
    public init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, connections, pinnedConnectionID, pinned, theme }
    private enum IdentityKeys: String, CodingKey { case id, accountName }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version == 1 || version == 2 else { throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: values, debugDescription: "Unsupported settings schema") }
        if version == 2 {
            var rows = try values.nestedUnkeyedContainer(forKey: .connections)
            while !rows.isAtEnd {
                let identity = try rows.nestedContainer(keyedBy: IdentityKeys.self)
                _ = try identity.decode(String.self, forKey: .id)
                _ = try identity.decode(String.self, forKey: .accountName)
            }
        }
        connections = try values.decode([Connection].self, forKey: .connections)
        theme = try values.decodeIfPresent(String.self, forKey: .theme) ?? "system"
        pinnedConnectionID = try values.decodeIfPresent(String.self, forKey: .pinnedConnectionID)
        if version == 1, pinnedConnectionID == nil, let legacy = try values.decodeIfPresent(ProviderID.self, forKey: .pinned),
           connections.contains(where: { $0.id == legacy.rawValue && $0.provider == legacy }) { pinnedConnectionID = legacy.rawValue }
        try validate()
        if let pinnedConnectionID, !connections.contains(where: { $0.id == pinnedConnectionID }) { self.pinnedConnectionID = nil }
    }
    public func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(connections, forKey: .connections)
        try values.encodeIfPresent(pinnedConnectionID, forKey: .pinnedConnectionID)
        try values.encode(theme, forKey: .theme)
    }
    private func validate() throws {
        var ids: Set<String> = []
        guard connections.allSatisfy({ Connection.validID($0.id) && !$0.accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ids.insert($0.id).inserted }) else {
            throw UsageError.configuration("계정 식별자가 잘못되었거나 중복되었습니다.")
        }
        if let pinnedConnectionID, !Connection.validID(pinnedConnectionID) { throw UsageError.configuration("고정 계정 식별자가 잘못되었습니다.") }
    }
}
public final class SettingsStore: Sendable {
    public let url: URL
    public init(directory: URL = SettingsStore.directory) { url = directory.appendingPathComponent("connections-v1.json") }
    public static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AI Limit", isDirectory: true) }
    public func load() throws -> ConnectionSettings { guard FileManager.default.fileExists(atPath: url.path) else { return ConnectionSettings() }; let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return try decoder.decode(ConnectionSettings.self, from: Data(contentsOf: url)) }
    public func save(_ settings: ConnectionSettings) throws { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; try encoder.encode(settings).write(to: url, options: .atomic) }
}
public protocol SecretStore: Sendable { func load(_ accountID: String) throws -> String?; func save(_ secret: String, for accountID: String) throws; func remove(_ accountID: String) throws; func removeAll() throws }
public struct KeychainStore: SecretStore {
    private let service: String
    public init(service: String = "dev.bazzi.ai-limit.credentials") { self.service = service }
    private func query(_ accountID: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: accountID] }
    public func load(_ accountID: String) throws -> String? { var q = query(accountID); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne; var value: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &value); if status == errSecItemNotFound { return nil }; guard status == errSecSuccess, let data = value as? Data, let secret = String(data: data, encoding: .utf8) else { throw UsageError.configuration("앱 전용 Keychain을 읽을 수 없습니다.") }; return secret }
    public func save(_ secret: String, for accountID: String) throws { let attributes = [kSecValueData as String: Data(secret.utf8)]; let status = SecItemUpdate(query(accountID) as CFDictionary, attributes as CFDictionary); if status == errSecItemNotFound { var q = query(accountID); q.merge(attributes) { _, new in new }; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw UsageError.configuration("Keychain 저장 실패") } } else if status != errSecSuccess { throw UsageError.configuration("Keychain 저장 실패") } }
    public func remove(_ accountID: String) throws { let status = SecItemDelete(query(accountID) as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw UsageError.configuration("Keychain 삭제 실패") } }
    public func removeAll() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw UsageError.configuration("Keychain 삭제 실패") }
    }
}
public struct SuppliedSecret: SecretStore { private let value: String; public init(_ value: String) { self.value = value }; public func load(_ accountID: String) throws -> String? { value }; public func save(_ secret: String, for accountID: String) throws { throw UsageError.configuration("읽기 전용") }; public func remove(_ accountID: String) throws { throw UsageError.configuration("읽기 전용") }; public func removeAll() throws { throw UsageError.configuration("읽기 전용") } }

/// Validate a candidate and any rotated tokens without replacing the saved connection.
public final class PendingCredentialStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private let accountID: String
    private var value: String?
    public init(_ value: String, for accountID: String) { self.value = value; self.accountID = accountID }
    public func load(_ accountID: String) throws -> String? { guard accountID == self.accountID else { throw UsageError.authentication }; return lock.withLock { value } }
    public func save(_ secret: String, for accountID: String) throws { guard accountID == self.accountID else { throw UsageError.authentication }; lock.withLock { value = secret } }
    public func remove(_ accountID: String) throws { guard accountID == self.accountID else { throw UsageError.authentication }; lock.withLock { value = nil } }
    public func removeAll() throws { lock.withLock { value = nil } }
}
public enum Credentials {
    public static func validate(_ raw: String, for provider: ProviderID) throws -> String {
        guard provider == .windsurf || raw.rangeOfCharacter(from: .newlines) == nil else { throw UsageError.configuration("Cookie와 토큰에는 줄바꿈을 넣을 수 없습니다.") }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty else { throw UsageError.authentication }
        switch provider {
        case .claude:
            let key = value.contains("=") ? cookies(value)["sessionKey"] : value
            guard let key, !key.isEmpty, !key.hasPrefix("sk-ant-api"), !key.hasPrefix("sk-ant-oat"), !key.contains(";") else { throw UsageError.configuration("Claude 웹 sessionKey만 입력하세요. API/OAuth 키는 지원하지 않습니다.") }; return "sessionKey=" + key
        case .perplexity:
            let fields = cookies(value)
            for family in ["__Secure-authjs.session-token", "authjs.session-token", "__Secure-next-auth.session-token", "next-auth.session-token"] {
                if let token = fields[family], !token.isEmpty { return "\(family)=\(token)" }
                let chunks = fields.compactMap { key, value -> (Int, String)? in guard key.hasPrefix(family + "."), let index = Int(key.dropFirst(family.count + 1)), index >= 0 else { return nil }; return (index, value) }.sorted { $0.0 < $1.0 }
                if !chunks.isEmpty, chunks.enumerated().allSatisfy({ $0.offset == $0.element.0 && !$0.element.1.isEmpty }) { return chunks.map { "\(family).\($0.0)=\($0.1)" }.joined(separator: "; ") }
            }; throw UsageError.configuration("허용된 session cookie 전체(연속된 .0, .1 조각 포함)를 입력하세요.")
        case .windsurf:
            let json = try JSON(data: Data(value.utf8)); let keys = ["devin_session_token", "devin_auth1_token", "devin_account_id", "devin_primary_org_id"]
            guard Set(json.keys) == Set(keys), keys.allSatisfy({ json[$0].string.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.rangeOfCharacter(from: .newlines) == nil } ?? false }) else { throw UsageError.configuration("정확히 네 개의 devin 필드가 필요합니다.") }; return value
        case .grok:
            guard !value.hasPrefix("xai-"), !value.contains("="), !value.contains(";"), !value.contains(" "), !value.contains("{") else { throw UsageError.configuration("API 키나 Cookie가 아닌 Grok CLI bearer 값만 입력하세요.") }; return value
        case .cursor: guard value.contains("=") else { throw UsageError.configuration("Cookie header를 입력하세요.") }; return value
        default: return value
        }
    }
    private static func cookies(_ value: String) -> [String: String] { value.split(separator: ";").reduce(into: [:]) { result, part in let pieces = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }; if pieces.count == 2 { result[pieces[0]] = pieces[1] } } }
}
