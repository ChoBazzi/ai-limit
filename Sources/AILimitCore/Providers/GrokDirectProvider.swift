import Foundation
import AILimitShared

public struct GrokDirectProvider: Sendable {
    public init() {}
    public func fetch(context: FetchContext, credential: DirectCredential) async throws -> UsageSnapshot {
        guard credential.provider == .grok else { throw UsageError.authentication }
        let headers = ["Authorization": "Bearer " + credential.accessToken, "x-xai-token-auth": "xai-grok-cli", "Accept": "application/json"]
        let response = try await context.http.send(HTTPRequest("https://cli-chat-proxy.grok.com/v1/billing?format=credits", headers: headers))
        if response.status == 403 || response.status == 404 {
            throw UsageError.unavailable("이 Grok 계정에서 Build/통합 크레딧 조회가 허용되지 않습니다. 모든 웹 채팅 한도를 지원하는 연동이 아닙니다.")
        }
        var result = try Self.decode(response.checked(now: context.now()), now: context.now())
        if let data = try? await context.get(HTTPRequest("https://cli-chat-proxy.grok.com/v1/settings", headers: headers, timeout: 5)), let settings = try? JSON(data: data) {
            result.plan = settings["subscription_tier_display"].string ?? result.plan
        }
        try Task.checkCancellation()
        return result
    }

    static func decode(_ data: Data, now: Date) throws -> UsageSnapshot {
        let root = try JSON(data: data)
        let config = root["config"]
        guard !config.isNull else { throw UsageError.malformed }
        let reset = config["currentPeriod"]["end"].date ?? config["billingPeriodEnd"].date
        let percent = try config["creditUsagePercent"].number()
        let title = config["isUnifiedBillingUser"].bool == true ? "Grok 통합 크레딧" : "Grok Build 크레딧"
        var windows: [QuotaWindow] = []
        if let percent {
            windows.append(QuotaWindow(id: "included", title: title, usedPercent: percent, resetsAt: reset, resetPrecision: .exact, resetDescription: "웹 채팅의 모든 모델별 메시지 한도는 아닙니다."))
        }
        // Official billing.rs Cent explicitly specifies USD cents for this REST response.
        // Missing val remains unavailable; do not infer zero from an omitted scalar.
        let used = try config["onDemandUsed"]["val"].decimal().map { $0 / 100 }
        let cap = try config["onDemandCap"]["val"].decimal().map { $0 / 100 }
        if used != nil || cap != nil { windows.append(QuotaWindow(id: "onDemand", title: "추가 사용", used: used, limit: cap, unit: .currency(code: "USD"), resetsAt: reset, resetPrecision: .exact)) }
        var balances: [BalanceMetric] = []
        if let prepaid = try config["prepaidBalance"]["val"].decimal() {
            balances.append(BalanceMetric(id: "prepaid", title: "선불 크레딧 잔액", amount: prepaid / 100, unit: .currency(code: "USD")))
        }
        guard !windows.isEmpty || !balances.isEmpty else {
            throw UsageError.unavailable("로그인했지만 Grok Build/통합 크레딧 수치가 제공되지 않습니다. 기간 정보만으로 연결 성공이나 잔여량을 판단하지 않습니다.")
        }
        return UsageSnapshot(provider: .grok, plan: root["subscription_tier"].string, windows: windows, balances: balances, source: .unofficialWeb, fetchedAt: now)
    }
}
