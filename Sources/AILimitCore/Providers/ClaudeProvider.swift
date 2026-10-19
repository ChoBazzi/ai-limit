import Foundation
import AILimitShared
public struct ClaudeOrganization: Sendable, Identifiable { public let id: String; public let name: String; public let chat: Bool }
public struct ClaudeProvider: UsageProvider {
    public let id: ProviderID = .claude
    public init() {}
    public func organizations(context: FetchContext) async throws -> [ClaudeOrganization] {
        let cookie = try Credentials.validate(context.secret(), for: id)
        let json = try JSON(data: await context.get(HTTPRequest("https://claude.ai/api/organizations", headers: ["Cookie": cookie, "Accept": "application/json"])))
        return json.array.compactMap { org in let caps = org["capabilities"].array.compactMap(\.string); guard caps != ["api"], let id = org["uuid"].string, UUID(uuidString: id) != nil else { return nil }; return ClaudeOrganization(id: id, name: org["name"].string ?? "조직", chat: caps.contains("chat")) }.sorted { $0.chat && !$1.chat }
    }
    public func fetch(context: FetchContext) async throws -> UsageSnapshot {
        let organizations = try await organizations(context: context)
        guard let org = context.connection.claudeOrganization, organizations.contains(where: { $0.id == org }) else { throw UsageError.configuration("Claude 조직을 선택하거나 다시 선택하세요.") }
        let cookie = try Credentials.validate(context.secret(), for: id); let base = "https://claude.ai/api/organizations/" + org
        let headers = ["Cookie": cookie, "Accept": "application/json"]
        let usage = try JSON(data: await context.get(HTTPRequest(base + "/usage", headers: headers)))
        var windows: [QuotaWindow] = []; var balances: [BalanceMetric] = []
        for (key, title) in [("five_hour", "5시간"), ("seven_day", "주간"), ("seven_day_sonnet", "Sonnet 주간"), ("seven_day_opus", "Opus 주간")] where !usage[key].isNull {
            windows.append(QuotaWindow(id: key, title: title, usedPercent: try usage[key]["utilization"].number(), resetsAt: usage[key]["resets_at"].date, resetPrecision: .exact))
        }
        async let overage = try? context.get(HTTPRequest(base + "/overage_spend_limit", headers: headers, timeout: 5))
        async let prepaid = try? context.get(HTTPRequest(base + "/prepaid/credits", headers: headers, timeout: 5))
        if let data = await overage, let value = try? JSON(data: data), value["is_enabled"].bool == true, let currency = value["currency"].string, !currency.isEmpty {
            let used = try? value["used_credits"].decimal()
            let limit = try? value["monthly_credit_limit"].decimal()
            if used != nil || limit != nil { windows.append(QuotaWindow(id: "overage", title: "추가 사용", used: used.map { $0 / 100 }, limit: limit.map { $0 / 100 }, unit: .currency(code: currency))) }
        }
        if let data = await prepaid, let value = try? JSON(data: data), let currency = value["currency"].string, !currency.isEmpty, let amount = try? value["amount"].decimal() { balances.append(BalanceMetric(id: "prepaid", title: "선불 잔액", amount: amount / 100, unit: .currency(code: currency))) }
        return snapshot(id, context, windows: windows, balances: balances)
    }
}
