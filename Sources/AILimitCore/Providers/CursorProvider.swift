import Foundation
import AILimitShared
public struct CursorProvider: UsageProvider {
    public let id: ProviderID = .cursor
    public init() {}
    public func fetch(context: FetchContext) async throws -> UsageSnapshot {
        let cookie = try Credentials.validate(context.secret(), for: id)
        let json = try JSON(data: await context.get(HTTPRequest("https://cursor.com/api/usage-summary", headers: ["Cookie": cookie, "Accept": "application/json", "Origin": "https://cursor.com", "Referer": "https://cursor.com/dashboard"])))
        let individual = json["individualUsage"]; guard !individual.isNull else { throw UsageError.unavailable("개인 한도 미제공 · 팀 사용량을 개인 한도로 표시하지 않습니다.") }
        let reset = json["billingCycleEnd"].date; var windows: [QuotaWindow] = []
        for (key, title) in [("plan", "포함 사용량"), ("onDemand", "추가 사용 금액")] {
            let value = individual[key]; guard !value.isNull else { continue }
            windows.append(QuotaWindow(id: key, title: title, used: try value["used"].decimal().map { $0 / 100 }, limit: try value["limit"].decimal().map { $0 / 100 }, remaining: try value["remaining"].decimal().map { $0 / 100 }, unit: .currency(code: "USD"), usedPercent: key == "plan" ? try value["totalPercentUsed"].number() : nil, unlimited: key == "plan" && json["isUnlimited"].bool == true, resetsAt: reset, resetPrecision: .exact, resetDescription: json["billingCycleStart"].date.map { "결제 주기 시작 " + $0.formatted(date: .numeric, time: .omitted) }))
        }
        for (key, title) in [("autoPercentUsed", "Auto pool"), ("apiPercentUsed", "API pool")] { if let percent = try individual["plan"][key].number() { windows.append(QuotaWindow(id: key, title: title, usedPercent: percent, resetsAt: reset, resetPrecision: .exact)) } }
        return snapshot(id, context, plan: json["membershipType"].string, windows: windows)
    }
}
