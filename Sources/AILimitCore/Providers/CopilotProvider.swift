import Foundation
import AILimitShared
public struct CopilotProvider: UsageProvider {
    public let id: ProviderID = .copilot
    public init() {}
    public func fetch(context: FetchContext) async throws -> UsageSnapshot {
        let output = try await context.execute(["api", "--hostname", "github.com", "--method", "GET", "--include", "-H", "Accept: application/json", "-H", "Editor-Version: vscode/1.96.2", "-H", "Editor-Plugin-Version: copilot-chat/0.26.7", "-H", "User-Agent: GitHubCopilotChat/0.26.7", "-H", "X-Github-Api-Version: 2025-04-01", "/copilot_internal/user"])
        let text = String(decoding: output.stdout, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        guard let split = text.range(of: "\n\n") else { throw output.status == 0 ? UsageError.malformed : UsageError.authentication }
        let lines = text[..<split.lowerBound].split(separator: "\n"); guard let statusText = lines.first?.split(separator: " ").dropFirst().first, let status = Int(statusText) else { throw UsageError.malformed }
        var headers: [String: String] = [:]; for line in lines.dropFirst() { let pair = line.split(separator: ":", maxSplits: 1); if pair.count == 2 { headers[String(pair[0])] = pair[1].trimmingCharacters(in: .whitespaces) } }
        let data = try HTTPResponse(status: status, headers: headers, body: Data(text[split.upperBound...].utf8)).checked(now: context.now())
        guard output.status == 0 else { throw UsageError.authentication }
        let json = try JSON(data: data); let quotas = json["quota_snapshots"]; var windows: [QuotaWindow] = []; var balances: [BalanceMetric] = []
        let resetDate = json["quota_reset_date"].string.flatMap(ResetCalendarDate.init)
        let resetPrecision: ResetPrecision = resetDate == nil ? .exact : .dateOnly
        for (key, title) in [("premium_interactions", "Premium"), ("chat", "Chat")] {
            let quota = quotas[key]; guard !quota.isNull else { continue }
            let entitlement = try quota["entitlement"].decimal(); let remaining = try quota["remaining"].decimal(); let unlimited = quota["unlimited"].bool == true
            if entitlement == 0 && remaining == 0 && !unlimited { continue }
            var used = try quota["percent_remaining"].number(allowNegative: true).map { 100 - $0 }
            if used == nil, let entitlement, entitlement > 0, let remaining { used = NSDecimalNumber(decimal: (entitlement - remaining) / entitlement * 100).doubleValue }
            if let used, used < 0 { throw UsageError.malformed }
            windows.append(QuotaWindow(id: key, title: title, usedPercent: used, unlimited: unlimited, resetsAt: resetDate == nil ? json["quota_reset_date"].date : nil, resetPrecision: resetPrecision, resetDate: resetDate))
        }
        if let credits = try quotas["premium_interactions"]["credits_used"].decimal() ?? quotas["chat"]["credits_used"].decimal() { balances.append(BalanceMetric(id: "credits_used", title: "사용 크레딧", amount: credits, unit: .credits)) }
        return snapshot(id, context, plan: json["copilot_plan"].string, windows: windows, balances: balances)
    }
}
