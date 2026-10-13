import Foundation
import AILimitShared

public struct ClaudeDirectProvider: Sendable {
    public init() {}
    public func fetch(context: FetchContext, credential: DirectCredential) async throws -> UsageSnapshot {
        try SubscriptionOAuth.validate(credential, provider: .claude, now: context.now())
        let headers = ["Authorization": "Bearer " + credential.accessToken, "Accept": "application/json",
                       "anthropic-beta": "oauth-2025-04-20", "User-Agent": "claude-code/2.1.0"]
        let json = try JSON(data: await context.get(HTTPRequest("https://api.anthropic.com/api/oauth/usage", headers: headers)))
        var windows: [QuotaWindow] = []
        for (key, title) in [("five_hour", "5시간"), ("seven_day", "주간"),
                             ("seven_day_sonnet", "Sonnet 주간"), ("seven_day_opus", "Opus 주간")] {
            guard let used = try json[key]["utilization"].number() else { continue }
            windows.append(QuotaWindow(id: key, title: title, usedPercent: used, resetsAt: json[key]["resets_at"].date))
        }
        guard !windows.isEmpty else { throw UsageError.unavailable("Claude 계정의 사용 한도가 제공되지 않았습니다.") }
        try Task.checkCancellation()
        // Profile enrichment is optional and cannot turn a successful quota read into
        // an outage. An explicitly changed account, however, must never be displayed.
        var plan: String?
        if let data = try? await context.get(HTTPRequest("https://api.anthropic.com/api/oauth/profile", headers: headers, timeout: 5)),
           let profile = try? JSON(data: data) {
            for (key, field) in [("accountID", "account"), ("organizationID", "organization")] {
                if let expected = credential.metadata[key], let observed = profile[field]["uuid"].string,
                   expected != observed { throw UsageError.authentication }
            }
            if let type = profile["organization"]["organization_type"].string, !type.isEmpty { plan = type }
            else if profile["account"]["has_claude_max"].bool == true { plan = "claude_max" }
            else if profile["account"]["has_claude_pro"].bool == true { plan = "claude_pro" }
        }
        try Task.checkCancellation()
        return UsageSnapshot(provider: .claude, plan: plan, windows: windows, source: .unofficialWeb, fetchedAt: context.now())
    }
}
