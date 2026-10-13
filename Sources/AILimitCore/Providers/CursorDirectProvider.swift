import Foundation
import AILimitShared

// Wire fields and cents: pi-cursor@7a2ab5e43911b173320bfe06b6ea0cd0ad7a6f76/src/usage.ts.
public struct CursorDirectProvider: Sendable {
    public init() {}
    public func fetch(context: FetchContext, credential: DirectCredential) async throws -> UsageSnapshot {
        guard credential.provider == .cursor else { throw UsageError.authentication }
        let request = HTTPRequest("https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage", method: "POST", headers: ["Authorization": "Bearer " + credential.accessToken, "Content-Type": "application/json", "Accept": "application/json"], body: Data("{}".utf8))
        let response = try await context.http.send(request)
        if response.status == 403 { throw UsageError.unavailable("이 Cursor 계정은 직접 로그인 사용량 조회 권한이 없습니다. 계정의 구독·조직 호환성을 확인하세요.") }
        return try Self.decode(response.checked(now: context.now()), now: context.now())
    }

    static func decode(_ data: Data, now: Date) throws -> UsageSnapshot {
        let root = try JSON(data: data)
        let plan = root["planUsage"]
        let reset = try root["billingCycleEnd"].number().map { Date(timeIntervalSince1970: $0 / 1000) }
        let used = try plan["includedSpend"].decimal().map { $0 / 100 }
        let limit = try plan["limit"].decimal().map { $0 / 100 }
        let percent = try plan["totalPercentUsed"].number()
        var windows: [QuotaWindow] = []
        if used != nil || limit != nil || percent != nil {
            windows.append(QuotaWindow(id: "included", title: "포함 사용량", used: used, limit: limit, unit: .currency(code: "USD"), usedPercent: percent, resetsAt: reset))
        }
        for (key, title) in [("autoPercentUsed", "Auto 풀"), ("apiPercentUsed", "API 풀")] {
            if let value = try plan[key].number() { windows.append(QuotaWindow(id: key, title: title, usedPercent: value, resetsAt: reset)) }
        }
        guard !windows.isEmpty else { throw UsageError.unavailable("이 Cursor 계정에서 개인 사용량이 제공되지 않습니다. 조직·구독 호환성을 확인하세요.") }
        return UsageSnapshot(provider: .cursor, plan: root["membershipType"].string, windows: windows, balances: [], source: .unofficialWeb, fetchedAt: now)
    }
}
