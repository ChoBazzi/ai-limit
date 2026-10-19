import Foundation
import AILimitShared

// Management endpoint and headers: kiro-account-manager 4c3a8d9 (2026-09-28).
struct KiroDirectProvider: Sendable {
    func fetch(context: FetchContext, credential: DirectCredential) async throws -> UsageSnapshot {
        guard credential.provider == .kiro, !credential.accessToken.isEmpty,
              credential.metadata["region"] == "us-east-1" else { throw UsageError.authentication }
        guard var url = URLComponents(string: "https://management.us-east-1.kiro.dev/getUsageLimits") else { throw UsageError.malformed }
        url.queryItems = [URLQueryItem(name: "isEmailRequired", value: "true"),
                          URLQueryItem(name: "origin", value: "AI_EDITOR"),
                          URLQueryItem(name: "resourceType", value: "AGENTIC_REQUEST")]
        // Only a profile actually supplied for this grant may be sent. Never synthesize a Builder-ID ARN.
        if let arn = credential.metadata["profileARN"], !arn.isEmpty {
            url.queryItems?.append(URLQueryItem(name: "profileArn", value: arn))
        }
        guard let endpoint = url.url else { throw UsageError.malformed }
        let suffix = "KiroIDE-0.12.301-\(credential.metadata["machineID"] ?? "ai-limit") AILimit/0.1.0"
        let response = try await context.http.send(HTTPRequest(endpoint.absoluteString, headers: [
            "Authorization": "Bearer \(credential.accessToken)", "Accept": "application/json",
            "User-Agent": "aws-sdk-js/1.0.0 ua/2.1 os/darwin lang/js md/nodejs#22.22.0 api/codewhispererruntime#1.0.0 m/N,E \(suffix)",
            "x-amz-user-agent": "aws-sdk-js/1.0.0 \(suffix)",
            "amz-sdk-invocation-id": UUID().uuidString.lowercased(), "amz-sdk-request": "attempt=1; max=1"
        ]))
        if response.status == 423 || (response.status == 403 && (try? JSON(data: response.body)["reason"].string) == "TemporarilySuspended") {
            throw UsageError.unavailable("Kiro 계정의 서비스 이용이 제한되었습니다. Kiro에서 계정 상태를 확인하세요.")
        }
        return try Self.decode(JSON(data: response.checked(now: context.now())), now: context.now())
    }

    static func decode(_ root: JSON, now: Date) throws -> UsageSnapshot {
        var windows: [QuotaWindow] = []
        for (index, item) in root["usageBreakdownList"].array.enumerated() {
            let title = item["displayName"].string ?? item["resourceType"].string ?? "Kiro 사용량"
            let unit = metricUnit(item)
            let reset = item["nextDateReset"].date ?? root["nextDateReset"].date
            if let monthly = try window(item, id: "resource-\(index)", title: title, unit: unit, reset: reset) {
                windows.append(monthly)
            }
            let trial = item["freeTrialInfo"]
            if trial["freeTrialStatus"].string == "ACTIVE", trial["freeTrialExpiry"].date.map({ $0 > now }) ?? true,
               let window = try window(trial, id: "resource-\(index)-trial", title: title + " · 무료 체험", unit: unit,
                                       reset: trial["freeTrialExpiry"].date, resetDescription: "무료 체험 만료") {
                windows.append(window)
            }
            for (bonusIndex, bonus) in item["bonuses"].array.enumerated() {
                guard bonus["status"].string == "ACTIVE", bonus["expiresAt"].date.map({ $0 > now }) ?? true else { continue }
                if let window = try window(bonus, id: "resource-\(index)-bonus-\(bonusIndex)", title: title + " · 보너스 \(bonusIndex + 1)",
                                           unit: unit, reset: bonus["expiresAt"].date, resetDescription: "보너스 만료") {
                    windows.append(window)
                }
            }
        }
        guard !windows.isEmpty else { throw UsageError.unavailable("Kiro 계정에서 실제 사용량 한도가 제공되지 않습니다.") }
        return UsageSnapshot(provider: .kiro, plan: root["subscriptionInfo"]["subscriptionTitle"].string,
                             windows: windows, source: .unofficialWeb, fetchedAt: now)
    }

    private static func window(_ value: JSON, id: String, title: String, unit: MetricUnit, reset: Date?, resetDescription: String? = nil) throws -> QuotaWindow? {
        let used = try value.alias("currentUsageWithPrecision", "currentUsage").decimal()
        let limit = try value.alias("usageLimitWithPrecision", "usageLimit").decimal()
        guard used != nil || limit != nil else { return nil }
        return QuotaWindow(id: id, title: title, used: used, limit: limit, unit: unit,
                           resetsAt: reset, resetPrecision: .exact, resetDescription: resetDescription)
    }

    private static func metricUnit(_ item: JSON) -> MetricUnit {
        if let unit = item["unit"].string, !unit.isEmpty {
            if ["credit", "credits"].contains(unit.lowercased()) { return .credits }
            return .providerUnits(name: unit)
        }
        if item["resourceType"].string == "AGENTIC_REQUEST" { return .credits }
        return .providerUnits(name: item["resourceType"].string ?? "Kiro 보고 단위")
    }
}
