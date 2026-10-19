import Foundation
import AILimitShared
public struct CodexProvider: UsageProvider {
    public let id: ProviderID = .codex
    public init() {}
    public func fetch(context: FetchContext) async throws -> UsageSnapshot {
        let data = try requireCLI(await context.execute(["-s", "read-only", "-a", "never", "app-server"], rpc: true))
        var replies: [Int64: JSON] = [:]
        for line in data.split(separator: 10) { let json = try JSON(data: Data(line)); guard let id = try json["id"].integer() else { continue }; guard [0, 1, 2].contains(id), replies[id] == nil, json["error"].isNull, !json["result"].isNull else { throw UsageError.malformed }; replies[id] = json["result"] }
        guard replies.count == 3, let account = replies[1]?["account"], !account.isNull else { throw UsageError.authentication }
        guard account["type"].string == "chatgpt" else { throw UsageError.unavailable("API 키 계정은 개인 구독 한도를 제공하지 않습니다.") }
        let result = replies[2]!; let root = result["rateLimits"]; var windows: [QuotaWindow] = []; var balances: [BalanceMetric] = []
        func append(_ rate: JSON, key: String) throws {
            let name = rate["limitName"].string ?? key
            for kind in ["primary", "secondary"] {
                let window = rate[kind]; guard !window.isNull else { continue }
                let minutes = try window["windowDurationMins"].integer()
                let duration = minutes?.multipliedReportingOverflow(by: 60)
                guard duration?.overflow != true else { throw UsageError.malformed }
                let title = UsageFormat.limitTitle(seconds: duration?.partialValue)
                windows.append(QuotaWindow(id: key + "." + kind, title: name == "Codex" || name == "codex" ? title : name + " · " + title, usedPercent: try window["usedPercent"].number(), resetsAt: window["resetsAt"].date, resetPrecision: .exact))
            }
            let credits = rate["credits"]
            if let balance = try credits["balance"].decimal() { balances.append(BalanceMetric(id: key + ".credits", title: name + " 크레딧 잔액", amount: balance, unit: .credits)) }
            if credits["unlimited"].bool == true { windows.append(QuotaWindow(id: key + ".unlimited", title: name + " 크레딧", unit: .credits, unlimited: true)) }
        }
        let rootID = root["limitId"].string ?? "codex"
        if !root.isNull { try append(root, key: rootID) }
        for key in result["rateLimitsByLimitId"].keys.sorted() where root.isNull || key != root["limitId"].string { try append(result["rateLimitsByLimitId"][key], key: key) }
        var value = snapshot(id, context, plan: root["planType"].string ?? account["planType"].string, windows: windows, balances: balances)
        value.resetCredits = Self.resetCredits(from: result["rateLimitResetCredits"])
        return value
    }

    private static func resetCredits(from summary: JSON) -> ResetCredits? {
        guard let count = try? summary["availableCount"].integer() else { return nil }
        let rows = summary["credits"]
        let credits: [ResetCredit]? = rows.isNull ? nil : rows.array.compactMap { row in
            guard row["resetType"].string == "codexRateLimits",
                  row["status"].string == "available",
                  row.keys.contains("expiresAt") else { return nil }
            if row["expiresAt"].isNull { return ResetCredit(expiresAt: nil) }
            guard let epoch = try? row["expiresAt"].number(allowNegative: true) else { return nil }
            return ResetCredit(expiresAt: Date(timeIntervalSince1970: epoch))
        }
        return ResetCredits(availableCount: count, credits: credits)
    }
}
