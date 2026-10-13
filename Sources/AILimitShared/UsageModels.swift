import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex, claude, antigravity, cursor, copilot, windsurf, perplexity, grok, kiro
    public var id: String { rawValue }
    public var title: String { switch self { case .codex: "Codex"; case .claude: "Claude"; case .antigravity: "Antigravity"; case .cursor: "Cursor"; case .copilot: "GitHub Copilot"; case .windsurf: "Windsurf"; case .perplexity: "Perplexity"; case .grok: "Grok"; case .kiro: "Kiro" } }
    public var symbolName: String {
        switch self {
        case .codex: "terminal"
        case .claude: "asterisk"
        case .antigravity: "sparkles"
        case .cursor: "cursorarrow"
        case .copilot: "chevron.left.forwardslash.chevron.right"
        case .windsurf: "wind"
        case .perplexity: "magnifyingglass"
        case .grok: "bolt"
        case .kiro: "hexagon"
        }
    }
    public var accentRGB: (red: Double, green: Double, blue: Double) {
        switch self {
        case .codex: (0.10, 0.55, 0.47)
        case .claude: (0.76, 0.39, 0.25)
        case .antigravity: (0.22, 0.48, 0.86)
        case .cursor: (0.48, 0.39, 0.78)
        case .copilot: (0.35, 0.43, 0.78)
        case .windsurf: (0.10, 0.53, 0.64)
        case .perplexity: (0.18, 0.51, 0.55)
        case .grok: (0.67, 0.34, 0.52)
        case .kiro: (0.57, 0.36, 0.78)
        }
    }
    public var isCLI: Bool { [.codex, .antigravity, .copilot, .kiro].contains(self) }
    public var unofficial: Bool { ![.codex, .antigravity, .kiro].contains(self) }
    public var dashboard: URL {
        let address = switch self { case .codex: "https://chatgpt.com/codex/cloud/settings/analytics#usage"; case .claude: "https://claude.ai/settings/usage"; case .antigravity: "https://antigravity.google/"; case .cursor: "https://cursor.com/dashboard"; case .copilot: "https://github.com/settings/copilot"; case .windsurf: "https://windsurf.com/profile"; case .perplexity: "https://www.perplexity.ai/account/usage"; case .grok: "https://grok.com/"; case .kiro: "https://app.kiro.dev/account/usage" }
        return URL(string: address)!
    }
}
public enum UsageSource: String, Codable, Sendable { case publicCLI, unofficialWeb, localLog, officialAPI }
public enum MetricUnit: Codable, Sendable, Equatable {
    case percent, credits, requests, reportedUnits, currency(code: String), providerUnits(name: String)
    public var label: String { switch self { case .percent: "%"; case .credits: "크레딧"; case .requests: "요청"; case .reportedUnits: "보고된 추가 사용 단위"; case .currency(let code): code; case .providerUnits(let name): name } }
}
public struct QuotaWindow: Codable, Sendable, Identifiable {
    public var id: String; public var title: String; public var used: Decimal?; public var limit: Decimal?; public var remaining: Decimal?; public var unit: MetricUnit; public var usedPercent: Double?; public var unlimited: Bool; public var resetsAt: Date?; public var resetDescription: String?
    public init(id: String, title: String, used: Decimal? = nil, limit: Decimal? = nil, remaining: Decimal? = nil, unit: MetricUnit = .percent, usedPercent: Double? = nil, unlimited: Bool = false, resetsAt: Date? = nil, resetDescription: String? = nil) {
        self.id = id; self.title = title; self.used = used; self.limit = limit; self.remaining = remaining; self.unit = unit; self.usedPercent = usedPercent; self.unlimited = unlimited; self.resetsAt = resetsAt; self.resetDescription = resetDescription
        if self.usedPercent == nil, let used, let limit, limit > 0 { self.usedPercent = NSDecimalNumber(decimal: used / limit * 100).doubleValue }
    }
    public var remainingPercent: Double? { usedPercent.map { 100 - $0 } }
}
public struct BalanceMetric: Codable, Sendable, Identifiable {
    public var id: String; public var title: String; public var amount: Decimal; public var unit: MetricUnit; public var expiresAt: Date?
    public init(id: String, title: String, amount: Decimal, unit: MetricUnit, expiresAt: Date? = nil) { self.id = id; self.title = title; self.amount = amount; self.unit = unit; self.expiresAt = expiresAt }
}
public struct TokenCounters: Codable, Sendable, Equatable {
    public var input: Int64?; public var output: Int64?; public var cacheRead: Int64?; public var cacheWrite: Int64?; public var reasoning: Int64?; public var total: Int64?
    public init(input: Int64? = nil, output: Int64? = nil, cacheRead: Int64? = nil, cacheWrite: Int64? = nil, reasoning: Int64? = nil, total: Int64? = nil) { self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.reasoning = reasoning; self.total = total }
}
public struct TokenSummary: Codable, Sendable {
    public var scope: String; public var counters: TokenCounters; public var observedAt: Date; public var periodStart: Date?; public var periodEnd: Date?; public var isPartial: Bool; public var note: String?
    public init(scope: String, counters: TokenCounters, observedAt: Date, periodStart: Date? = nil, periodEnd: Date? = nil, isPartial: Bool = false, note: String? = nil) { self.scope = scope; self.counters = counters; self.observedAt = observedAt; self.periodStart = periodStart; self.periodEnd = periodEnd; self.isPartial = isPartial; self.note = note }
}
public struct UsageSnapshot: Codable, Sendable {
    public var provider: ProviderID; public var plan: String?; public var windows: [QuotaWindow]; public var balances: [BalanceMetric]; public var source: UsageSource; public var fetchedAt: Date
    public var resetCredits: ResetCredits?
    public init(provider: ProviderID, plan: String? = nil, windows: [QuotaWindow] = [], balances: [BalanceMetric] = [], source: UsageSource, fetchedAt: Date, resetCredits: ResetCredits? = nil) {
        self.provider = provider; self.plan = plan; self.windows = windows; self.balances = balances; self.source = source; self.fetchedAt = fetchedAt
        self.resetCredits = resetCredits
        if provider == .codex {
            for index in self.windows.indices {
                self.windows[index].title = Self.normalizedCodexTitle(self.windows[index].title)
            }
        }
    }
    private enum CodingKeys: String, CodingKey { case provider, plan, windows, balances, source, fetchedAt, resetCredits }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(provider: container.decode(ProviderID.self, forKey: .provider),
                      plan: container.decodeIfPresent(String.self, forKey: .plan),
                      windows: container.decode([QuotaWindow].self, forKey: .windows),
                      balances: container.decode([BalanceMetric].self, forKey: .balances),
                      source: container.decode(UsageSource.self, forKey: .source),
                      fetchedAt: container.decode(Date.self, forKey: .fetchedAt),
                      resetCredits: container.decodeIfPresent(ResetCredits.self, forKey: .resetCredits))
    }
    private static let legacyCodexTitle = try! NSRegularExpression(pattern: #"^(?:(.+?\s*·\s*))?(?:기본|추가\s*기간)\s*한도(?:\s*[·-]\s*([0-9]+)\s*초)?$"#)
    private static func normalizedCodexTitle(_ title: String) -> String {
        let range = NSRange(title.startIndex..., in: title)
        guard let match = legacyCodexTitle.firstMatch(in: title, range: range) else { return title }
        let prefix = Range(match.range(at: 1), in: title).map { String(title[$0]) } ?? ""
        let seconds = Range(match.range(at: 2), in: title).flatMap { Int64(title[$0]) }
        return prefix + UsageFormat.limitTitle(seconds: seconds)
    }
    public func isStale(at date: Date) -> Bool {
        date.timeIntervalSince(fetchedAt) >= 900
            || windows.contains { $0.resetsAt.map { $0 <= date } ?? false }
            || resetCredits?.credits?.contains { $0.expiresAt.map { $0 <= date } ?? false } == true
    }
    public var mostLimited: QuotaWindow? { windows.filter { $0.usedPercent != nil && !$0.unlimited }.max { $0.usedPercent! < $1.usedPercent! } }
}
public enum ConnectionStatus: String, Codable, Sendable { case disconnected, loading, ready, needsAuthentication, unavailable, failed }
public struct ProviderState: Codable, Sendable, Identifiable {
    public var provider: ProviderID; public var status: ConnectionStatus; public var lastSuccess: UsageSnapshot?; public var lastAttemptAt: Date?; public var message: String?; public var retryAfter: Date?; public var localTokens: [TokenSummary]; public var localMessage: String?
    public var connectionID: String
    public var accountName: String
    public var id: String { connectionID }
    public var displayTitle: String { provider.title + " · " + accountName }
    public var deepLink: URL {
        var components = URLComponents()
        components.scheme = "ailimit"
        components.host = "account"
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        components.percentEncodedPath = "/" + connectionID.addingPercentEncoding(withAllowedCharacters: safeCharacters)!
        return components.url!
    }
    public init(provider: ProviderID, status: ConnectionStatus = .disconnected, lastSuccess: UsageSnapshot? = nil, lastAttemptAt: Date? = nil, message: String? = nil, retryAfter: Date? = nil, localTokens: [TokenSummary] = [], localMessage: String? = nil, connectionID: String? = nil, accountName: String = "기본 계정") {
        self.provider = provider; self.status = status; self.lastSuccess = lastSuccess; self.lastAttemptAt = lastAttemptAt; self.message = message; self.retryAfter = retryAfter; self.localTokens = localTokens; self.localMessage = localMessage
        self.connectionID = connectionID ?? provider.rawValue; self.accountName = accountName
    }
    private enum CodingKeys: String, CodingKey {
        case provider, status, lastSuccess, lastAttemptAt, message, retryAfter, localTokens, localMessage, connectionID, accountName
    }
    public init(from decoder: any Decoder) throws {
        try self.init(from: decoder, allowsLegacyIdentity: true)
    }
    fileprivate init(from decoder: any Decoder, allowsLegacyIdentity: Bool) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(ProviderID.self, forKey: .provider)
        status = try container.decode(ConnectionStatus.self, forKey: .status)
        lastSuccess = try container.decodeIfPresent(UsageSnapshot.self, forKey: .lastSuccess)
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        retryAfter = try container.decodeIfPresent(Date.self, forKey: .retryAfter)
        localTokens = try container.decodeIfPresent([TokenSummary].self, forKey: .localTokens) ?? []
        localMessage = try container.decodeIfPresent(String.self, forKey: .localMessage)
        if allowsLegacyIdentity && !container.contains(.connectionID) {
            connectionID = provider.rawValue
        } else {
            connectionID = try container.decode(String.self, forKey: .connectionID)
        }
        if allowsLegacyIdentity && !container.contains(.accountName) {
            accountName = "기본 계정"
        } else {
            accountName = try container.decode(String.self, forKey: .accountName)
        }
        try validate()
    }
    fileprivate func validate() throws {
        guard !connectionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              connectionID.rangeOfCharacter(from: .controlCharacters) == nil,
              !accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              lastSuccess == nil || lastSuccess?.provider == provider else {
            throw CocoaError(.coderReadCorrupt)
        }
    }
}
public struct SharedSnapshot: Codable, Sendable {
    public var schemaVersion: Int = 2
    public var updatedAt: Date
    public var providers: [ProviderState]
    public var displayOrder: [String]
    public var usageOverview: UsageOverview?
    public init(updatedAt: Date, providers: [ProviderState], displayOrder: [String]? = nil, usageOverview: UsageOverview? = nil) {
        self.updatedAt = updatedAt; self.providers = providers; self.displayOrder = displayOrder ?? providers.map(\.id)
        self.usageOverview = usageOverview
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, updatedAt, providers, displayOrder, usageOverview }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 || version == 2 else { throw CocoaError(.coderReadCorrupt) }
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        var states = try container.nestedUnkeyedContainer(forKey: .providers)
        providers = []
        while !states.isAtEnd {
            providers.append(try ProviderState(from: states.superDecoder(), allowsLegacyIdentity: version == 1))
        }
        displayOrder = try container.decode([String].self, forKey: .displayOrder)
        usageOverview = try container.decodeIfPresent(UsageOverview.self, forKey: .usageOverview)
        try validate()
        displayOrder = orderedProviders().map(\.id)
    }
    public func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(providers, forKey: .providers)
        try container.encode(displayOrder, forKey: .displayOrder)
        try container.encodeIfPresent(usageOverview, forKey: .usageOverview)
    }
    private func validate() throws {
        guard schemaVersion == 2 else { throw CocoaError(.coderReadCorrupt) }
        var ids = Set<String>()
        for state in providers {
            try state.validate()
            guard ids.insert(state.id).inserted else { throw CocoaError(.coderReadCorrupt) }
        }
    }
    public func orderedProviders(selection: [String] = []) -> [ProviderState] {
        var byID: [String: ProviderState] = [:]
        for state in providers where byID[state.id] == nil { byID[state.id] = state }
        var result: [ProviderState] = []
        for id in selection.isEmpty ? displayOrder : selection {
            if let state = byID.removeValue(forKey: id) { result.append(state) }
        }
        if selection.isEmpty {
            for state in providers {
                if let remaining = byID.removeValue(forKey: state.id) { result.append(remaining) }
            }
        }
        return result
    }
    public static func decode(_ data: Data) throws -> SharedSnapshot {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data)
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
public enum SnapshotReader {
    public static func groupURL() -> URL? { guard let group = Bundle.main.object(forInfoDictionaryKey: "AILimitAppGroup") as? String, !group.hasPrefix("."), !group.contains("$(") else { return nil }; return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("snapshot-v1.json") }
    public static func read(_ url: URL? = groupURL()) -> SharedSnapshot? { guard let url, let data = try? Data(contentsOf: url) else { return nil }; return try? SharedSnapshot.decode(data) }
}
public enum QuotaLevel: Sendable, Equatable {
    case normal, low, exhausted, exceeded, unknown, unlimited
    public func accentRGB(dark: Bool) -> (red: Double, green: Double, blue: Double) {
        let rgb: (Double, Double, Double)
        switch self {
        case .low: rgb = dark ? (255, 183, 77) : (148, 84, 0)
        case .exhausted, .exceeded: rgb = dark ? (255, 138, 128) : (179, 38, 30)
        default: rgb = dark ? (91, 213, 203) : (0, 111, 123)
        }
        return (rgb.0 / 255, rgb.1 / 255, rgb.2 / 255)
    }
}

public enum UsageFormat {
    public static func limitTitle(seconds: Int64?) -> String {
        guard let seconds, seconds > 0 else { return "한도 · 기간 미제공" }
        if seconds == 604_800 { return "주간 한도" }
        if seconds == 86_400 { return "일간 한도" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600)시간 한도" }
        if seconds % 60 == 0 { return "\(seconds / 60)분 한도" }
        return "사용 한도"
    }
    public static func remainingPercent(_ window: QuotaWindow) -> Double? {
        guard !window.unlimited, let remaining = window.remainingPercent, remaining.isFinite else { return nil }
        return min(100, max(0, remaining))
    }
    public static func level(_ window: QuotaWindow) -> QuotaLevel {
        if window.unlimited { return .unlimited }
        guard let used = window.usedPercent, used.isFinite else { return .unknown }
        if used > 100 { return .exceeded }
        if used == 100 { return .exhausted }
        return used >= 90 ? .low : .normal
    }
    public static func quotaWarning(_ window: QuotaWindow) -> String? {
        switch level(window) {
        case .low: return "한도 임박"
        case .exhausted: return "한도 소진"
        case .exceeded: return "한도 초과"
        default: return nil
        }
    }
    public static func compactQuota(_ window: QuotaWindow) -> String {
        if window.unlimited { return "무제한" }
        if let remaining = remainingPercent(window) { return remaining.formatted(.number.precision(.fractionLength(0...1))) + "% 남음" }
        if let remaining = window.remaining { return "잔여 " + amount(remaining, unit: window.unit) }
        return "남은 비율 미제공"
    }
    public static func summaryWindows(_ usage: UsageSnapshot, maximum: Int) -> [QuotaWindow] {
        guard maximum > 0 else { return [] }
        var result = Array(usage.windows.prefix(maximum))
        if let limiting = usage.mostLimited, !result.contains(where: { $0.id == limiting.id }), !result.isEmpty {
            result[result.count - 1] = limiting
        }
        return result
    }
    public static func observationIssue(_ state: ProviderState, at now: Date) -> String? {
        guard let usage = state.lastSuccess else { return nil }
        if usage.windows.contains(where: { $0.resetsAt.map { $0 <= now } ?? false }) { return "리셋 지남 · 갱신 필요" }
        if usage.resetCredits?.credits?.contains(where: { $0.expiresAt.map { $0 <= now } ?? false }) == true {
            return "리셋권 사용기한 지남 · 갱신 필요"
        }
        switch state.status {
        case .needsAuthentication: return "재로그인 필요 · 마지막 확인 값"
        case .failed, .unavailable: return "조회 실패 · 마지막 확인 값"
        case .disconnected: return "구독 한도 미연결 · 마지막 확인 값"
        default: return usage.isStale(at: now) ? "이전 관찰 · 갱신 필요" : nil
        }
    }
    public static func resetSummary(_ window: QuotaWindow, at now: Date) -> String {
        guard let reset = window.resetsAt else { return "리셋 정보 미제공" }
        guard reset > now else { return "리셋 지남 · 갱신 필요" }
        guard window.resetDescription == nil else {
            return reset.formatted(.dateTime.month(.twoDigits).day(.twoDigits)) + " 리셋 · 시각 미제공"
        }
        let seconds = reset.timeIntervalSince(now)
        if seconds < 60 { return "1분 이내 리셋" }
        let minutes = ceil(seconds / 60)
        let hours = floor(minutes / 60)
        let days = floor(hours / 24)
        func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }
        if days > 0 {
            let remainder = hours.truncatingRemainder(dividingBy: 24)
            return number(days) + "일" + (remainder > 0 ? " " + number(remainder) + "시간" : "") + " 후 리셋"
        }
        if hours > 0 {
            let remainder = minutes.truncatingRemainder(dividingBy: 60)
            return number(hours) + "시간" + (remainder > 0 ? " " + number(remainder) + "분" : "") + " 후 리셋"
        }
        return number(minutes) + "분 후 리셋"
    }

    public static func resetTime(_ window: QuotaWindow, at now: Date) -> String? {
        guard let reset = window.resetsAt, window.resetDescription == nil else { return nil }
        let time = reset.formatted(Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: .current, calendar: .current
        ))
        if Calendar.current.isDate(reset, inSameDayAs: now) { return time }
        return reset.formatted(.dateTime.month(.twoDigits).day(.twoDigits)) + " " + time
    }

    public static func resetDisplay(_ window: QuotaWindow, at now: Date) -> String {
        let summary = resetSummary(window, at: now)
        guard let time = resetTime(window, at: now) else { return summary }
        return summary + " (" + time + ")"
    }

    public static func resetLabel(_ window: QuotaWindow, at now: Date) -> String {
        guard let reset = window.resetsAt else { return "리셋 정보 미제공" }
        let date = reset.formatted(date: .abbreviated, time: window.resetDescription == nil ? .shortened : .omitted)
        return reset <= now ? "리셋 지남 · " + date : date + " 리셋"
    }
    public static func menuTitle(_ state: ProviderState, at now: Date) -> String {
        guard let usage = state.lastSuccess else { return state.displayTitle + " · 한도 미제공" }
        let prefix = state.displayTitle + (observationIssue(state, at: now) == nil ? " · " : " · 이전 관찰 · ")
        guard let window = usage.mostLimited ?? usage.windows.first(where: { !$0.unlimited }) ?? usage.windows.first else { return prefix + "한도 미제공" }
        return prefix + window.title + " " + compactQuota(window) + (quotaWarning(window).map { " · " + $0 } ?? "")
    }
    public static func localTokens(_ state: ProviderState, at now: Date) -> String {
        guard let summary = state.localTokens.first(where: { $0.scope == "localSession" || $0.scope == "ompSession" }) ?? state.localTokens.first else {
            if state.localMessage != nil { return "토큰 기록 · 확인 필요" }
            return state.provider == .codex || state.provider == .claude ? "토큰 · 로컬 기록 연결 필요" : "토큰 수 미제공"
        }
        let scope: String
        if summary.scope == "localSession" || summary.scope == "ompSession" { scope = "최근 세션" }
        else if let start = summary.periodStart, Calendar.current.isDate(start, inSameDayAs: now) { scope = "오늘" }
        else if let start = summary.periodStart, let end = summary.periodEnd, Calendar.current.dateComponents([.day], from: start, to: end).day == 7 { scope = "최근 7일" }
        else { scope = "로컬 기록" }
        let counters = summary.counters
        let value: String
        if let total = counters.total { value = total.formatted() + " 토큰" }
        else {
            var parts: [String] = []
            if let input = counters.input { parts.append("입력 " + input.formatted()) }
            if let output = counters.output { parts.append("출력 " + output.formatted()) }
            value = parts.isEmpty ? "토큰 수 미제공" : parts.joined(separator: " · ")
        }
        let source = summary.scope == "ompSession" || summary.scope == "ompHistory" ? "이 Mac OMP" : "이 Mac"
        return "\(source) \(scope) · " + value
            + (summary.isPartial ? " · 일부 기록" : "")
            + (now.timeIntervalSince(summary.observedAt) >= 900 ? " · 오래됨" : "")
            + (state.localMessage != nil ? " · 확인 필요" : "")
    }
    public static func amount(_ amount: Decimal, unit: MetricUnit) -> String { "\(NSDecimalNumber(decimal: amount).stringValue) \(unit.label)" }
    public static func quota(_ window: QuotaWindow) -> String {
        if window.unlimited { return "무제한" }
        var parts = [compactQuota(window)]
        if let used = window.usedPercent, used.isFinite {
            parts.append(used.formatted(.number.precision(.fractionLength(0...1))) + "% 사용")
            if used > 100 { parts.append((used - 100).formatted(.number.precision(.fractionLength(0...1))) + "%p 초과") }
        }
        if let used = window.used { parts.append("사용 " + amount(used, unit: window.unit)) }
        if let limit = window.limit { parts.append("한도 " + amount(limit, unit: window.unit)) }
        if let remaining = window.remaining, remainingPercent(window) != nil { parts.append("잔여 " + amount(remaining, unit: window.unit)) }
        return parts.joined(separator: " · ")
    }
}
