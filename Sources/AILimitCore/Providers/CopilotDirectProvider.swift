import Foundation
import AILimitShared

public struct CopilotDirectProvider: Sendable {
    public init() {}
    public func fetch(context: FetchContext, credential: DirectCredential) async throws -> UsageSnapshot {
        try SubscriptionOAuth.validate(credential, provider: .copilot, now: context.now())
        guard let expected = credential.metadata["userID"] else { throw UsageError.authentication }
        let identity = try JSON(data: await context.get(HTTPRequest("https://api.github.com/user", headers: CopilotDirectAuth.headers(credential.accessToken))))
        guard let id = try identity["id"].integer(), String(id) == expected else { throw UsageError.authentication }
        var headers = CopilotDirectAuth.headers(credential.accessToken)
        headers["Editor-Version"] = "vscode/1.96.2"
        headers["Editor-Plugin-Version"] = "copilot-chat/0.26.7"
        headers["User-Agent"] = "GitHubCopilotChat/0.26.7"
        headers["X-Github-Api-Version"] = "2025-04-01"
        let json = try JSON(data: await context.get(HTTPRequest("https://api.github.com/copilot_internal/user", headers: headers)))
        let quotas = json["quota_snapshots"]
        let resetDate = json["quota_reset_date"].string.flatMap(ResetCalendarDate.init)
        let resetPrecision: ResetPrecision = resetDate == nil ? .exact : .dateOnly
        var windows: [QuotaWindow] = []
        var balances: [BalanceMetric] = []
        for (key, title) in [("premium_interactions", "Premium"), ("chat", "Chat")] {
            let quota = quotas[key]
            guard !quota.isNull else { continue }
            let entitlement = try quota["entitlement"].decimal()
            let remaining = try quota["remaining"].decimal()
            let unlimited = quota["unlimited"].bool == true
            if entitlement == 0 && remaining == 0 && !unlimited { continue }
            var used = try quota["percent_remaining"].number(allowNegative: true).map { 100 - $0 }
            if used == nil, let entitlement, entitlement > 0, let remaining {
                used = NSDecimalNumber(decimal: (entitlement - remaining) / entitlement * 100).doubleValue
            }
            if let used, !used.isFinite || used < 0 { throw UsageError.malformed }
            guard used != nil || unlimited else { continue }
            windows.append(QuotaWindow(id: key, title: title, usedPercent: used, unlimited: unlimited, resetsAt: resetDate == nil ? json["quota_reset_date"].date : nil, resetPrecision: resetPrecision, resetDate: resetDate))
        }
        // The two quotas can report the same credit pool. Never sum them.
        if let credits = try quotas["premium_interactions"]["credits_used"].decimal() ?? quotas["chat"]["credits_used"].decimal() {
            balances.append(BalanceMetric(id: "credits_used", title: "사용 크레딧", amount: credits, unit: .credits))
        }
        guard !windows.isEmpty || !balances.isEmpty else { throw UsageError.unavailable("Copilot 계정의 한도·사용 크레딧이 제공되지 않았습니다.") }
        try Task.checkCancellation()
        return UsageSnapshot(provider: .copilot, plan: json["copilot_plan"].string, windows: windows, balances: balances, source: .unofficialWeb, fetchedAt: context.now())
    }
}
