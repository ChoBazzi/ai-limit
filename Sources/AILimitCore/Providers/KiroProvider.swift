import Foundation
import AILimitShared
public struct KiroProvider: UsageProvider {
    public let id: ProviderID = .kiro
    public init() {}
    public func fetch(context: FetchContext) async throws -> UsageSnapshot {
        let output = try await context.execute(["chat", "--no-interactive", "/usage"], timeout: 20)
        guard output.status == 0 else { throw UsageError.authentication }
        let raw = String(decoding: output.stdout, as: UTF8.self)
        let text = raw.replacingOccurrences(of: #"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))"#, with: "", options: .regularExpression)
        if text.range(of: #"(?i)(please (?:log|sign) in|not (?:logged|signed) in|login required|authentication failed)"#, options: .regularExpression) != nil { throw UsageError.authentication }
        func capture(_ pattern: String) -> [String]? { guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }; return (1..<match.numberOfRanges).map { (text as NSString).substring(with: match.range(at: $0)) } }
        func number(_ value: String) throws -> Decimal { guard let number = Decimal(string: value.replacingOccurrences(of: ",", with: "")), !number.isNaN, number >= 0 else { throw UsageError.malformed }; return number }
        let plan = capture(#"Plan:\s*([^|\n]+)"#)?.first?.trimmingCharacters(in: .whitespaces) ?? (text.localizedCaseInsensitiveContains("managed by") ? "조직 관리 플랜" : nil)
        var reset: Date?; let calendar = Calendar.current
        if let date = capture(#"resets on\s+(\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2})"#)?.first {
            let parts = date.split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int($0) }
            if parts.count == 3 { reset = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) }
            else if parts.count == 2 { let year = calendar.component(.year, from: context.now()); reset = calendar.date(from: DateComponents(year: year, month: parts[0], day: parts[1])); if let first = reset, first < calendar.startOfDay(for: context.now()) { reset = calendar.date(from: DateComponents(year: year + 1, month: parts[0], day: parts[1])) } }
        }
        var windows: [QuotaWindow] = []
        if let pair = capture(#"\(([\d,.]+)\s+of\s+([\d,.]+)\s+covered in plan\)"#) { windows.append(QuotaWindow(id: "monthly", title: "월간 크레딧", used: try number(pair[0]), limit: try number(pair[1]), unit: .credits, resetsAt: reset, resetPrecision: .dateOnly, resetDescription: reset == nil ? nil : "날짜 단위 리셋(정확한 시각 미제공)")) }
        if let pair = capture(#"Bonus[\s\S]*?([\d,.]+)\s*/\s*([\d,.]+)\s+credits used"#) { let days = capture(#"expires in\s+(\d+)\s+days"#)?.first.flatMap(Int.init); windows.append(QuotaWindow(id: "bonus", title: "보너스 크레딧", used: try number(pair[0]), limit: try number(pair[1]), unit: .credits, resetsAt: days.flatMap { calendar.date(byAdding: .day, value: $0, to: context.now()) }, resetPrecision: .approximate, resetDescription: days.map { "약 \($0)일 후 만료" })) }
        guard plan != nil || !windows.isEmpty else { throw UsageError.malformed }
        return snapshot(id, context, plan: plan, windows: windows)
    }
}
