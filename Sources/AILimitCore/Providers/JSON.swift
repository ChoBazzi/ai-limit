import Foundation
import AILimitShared

// Keeps provider wire data out of shared state and refuses non-finite/negative metrics.
struct JSON {
    private let value: Any
    init(data: Data) throws { do { value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch { throw UsageError.malformed } }
    private init(_ value: Any) { self.value = value }
    subscript(_ key: String) -> JSON { JSON((value as? [String: Any])?[key] ?? NSNull()) }
    func alias(_ camel: String, _ snake: String) -> JSON { self[camel].isNull ? self[snake] : self[camel] }
    var isNull: Bool { value is NSNull }
    var keys: [String] { Array((value as? [String: Any] ?? [:]).keys) }
    var array: [JSON] { (value as? [Any] ?? []).map { JSON($0) } }
    var string: String? { value as? String }
    var bool: Bool? { guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }; return n.boolValue }
    func decimal(allowNegative: Bool = false) throws -> Decimal? {
        if isNull { return nil }; guard bool == nil else { throw UsageError.malformed }
        let text = string ?? (value as? NSNumber)?.stringValue
        guard let text, text.range(of: #"^-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil, let result = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !result.isNaN, allowNegative || result >= 0 else { throw UsageError.malformed }; return result
    }
    func number(allowNegative: Bool = false) throws -> Double? { guard let decimal = try decimal(allowNegative: allowNegative) else { return nil }; let value = NSDecimalNumber(decimal: decimal).doubleValue; guard value.isFinite else { throw UsageError.malformed }; return value }
    func integer() throws -> Int64? { guard let value = try decimal() else { return nil }; guard value <= Decimal(Int64.max), value == Decimal(NSDecimalNumber(decimal: value).int64Value) else { throw UsageError.malformed }; return NSDecimalNumber(decimal: value).int64Value }
    var date: Date? { if let text = string { if let number = Double(text), number.isFinite { return Date(timeIntervalSince1970: number) }; let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; if let date = iso.date(from: text) { return date }; iso.formatOptions = [.withInternetDateTime]; if let date = iso.date(from: text) { return date }; let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; return formatter.date(from: text) }; if let number = value as? NSNumber, number.doubleValue.isFinite { return Date(timeIntervalSince1970: number.doubleValue) }; return nil }
}
import CoreFoundation

func requireCLI(_ output: ProcessOutput) throws -> Data { guard output.status == 0 else { throw UsageError.authentication }; return output.stdout }
func snapshot(_ id: ProviderID, _ context: FetchContext, plan: String? = nil, windows: [QuotaWindow] = [], balances: [BalanceMetric] = []) -> UsageSnapshot { UsageSnapshot(provider: id, plan: plan, windows: windows, balances: balances, source: id.isCLI ? .publicCLI : .unofficialWeb, fetchedAt: context.now()) }
public enum Providers {
    public static func make(_ id: ProviderID) -> any UsageProvider { AuthenticatedUsageProvider(id: id) }
    static func legacy(_ id: ProviderID) -> any UsageProvider { switch id { case .codex: CodexProvider(); case .claude: ClaudeProvider(); case .antigravity: AntigravityProvider(); case .cursor: CursorProvider(); case .copilot: CopilotProvider(); case .windsurf: WindsurfProvider(); case .perplexity: PerplexityProvider(); case .grok: GrokProvider(); case .kiro: KiroProvider() } }
}
