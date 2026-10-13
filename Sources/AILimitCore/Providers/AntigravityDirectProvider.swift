import Foundation
import AILimitShared

struct AntigravityDirectProvider: Sendable {
    func fetch(context: FetchContext, credential: DirectCredential) async throws -> UsageSnapshot {
        guard credential.provider == .antigravity, !credential.accessToken.isEmpty else { throw UsageError.authentication }
        let subscription = try await request("loadCodeAssist", body: ["metadata": ["ideType": "ANTIGRAVITY"]], context: context, token: credential.accessToken)
        let project = subscription["cloudaicompanionProject"].string
        let quota = try await request("retrieveUserQuotaSummary", body: project.map { ["project": $0] } ?? [:], context: context, token: credential.accessToken)
        let plan = subscription["paidTier"]["name"].string ?? subscription["currentTier"]["name"].string
        return try Self.decode(quota, plan: plan, now: context.now())
    }

    private func request(_ method: String, body: [String: Any], context: FetchContext, token: String) async throws -> JSON {
        let request = HTTPRequest("https://cloudcode-pa.googleapis.com/v1internal:\(method)", method: "POST", headers: [
            "Authorization": "Bearer \(token)", "Content-Type": "application/json", "Accept": "application/json",
            "User-Agent": "antigravity/1.11.3 Darwin/arm64"
        ], body: try JSONSerialization.data(withJSONObject: body))
        let response = try await context.http.send(request)
        // A valid Google login does not imply access to these private quota endpoints.
        if response.status == 403 {
            throw UsageError.unavailable("Google 로그인과 별개로 Antigravity 사용량 조회 권한이 거부되었습니다. 서비스에서 계정 접근 상태를 확인하세요.")
        }
        if response.status == 404 {
            throw UsageError.unavailable("Antigravity 사용량 조회 API가 제공되지 않습니다.")
        }
        return try JSON(data: response.checked(now: context.now()))
    }

    static func decode(_ root: JSON, plan: String?, now: Date) throws -> UsageSnapshot {
        let groups: JSON
        if !root["groups"].isNull { groups = root["groups"] }
        else if !root["response"]["groups"].isNull { groups = root["response"]["groups"] }
        else { groups = root["summary"]["groups"] }
        var windows: [QuotaWindow] = []
        for (groupIndex, group) in groups.array.enumerated() {
            guard let groupName = group.alias("displayName", "display_name").string ?? group["name"].string else { continue }
            for (bucketIndex, bucket) in group["buckets"].array.enumerated() {
                if bucket["disabled"].bool == true { continue }
                var remaining = bucket.alias("remainingFraction", "remaining_fraction")
                if remaining.isNull { remaining = bucket["remaining"].alias("remainingFraction", "remaining_fraction") }
                if remaining.isNull, ["remainingFraction", "remaining_fraction"].contains(bucket["remaining"]["case"].string ?? "") {
                    remaining = bucket["remaining"]["value"]
                }
                guard let fraction = try remaining.number() else { continue }
                guard fraction <= 1 else { throw UsageError.malformed }
                let label = bucket.alias("displayName", "display_name").string ?? bucket["name"].string
                    ?? bucket["window"].string ?? bucket.alias("bucketId", "bucket_id").string ?? bucket["id"].string
                guard let label, !label.isEmpty else { continue }
                let reset = bucket.alias("resetTime", "reset_time").date ?? bucket.alias("resetAt", "reset_at").date
                // Structural IDs never expose project/account IDs from the remote response.
                windows.append(QuotaWindow(id: "group-\(groupIndex)-bucket-\(bucketIndex)", title: "\(groupName) · \(label)",
                                           usedPercent: (1 - fraction) * 100, resetsAt: reset,
                                           resetDescription: bucket["description"].string))
            }
        }
        guard !windows.isEmpty else {
            throw UsageError.unavailable("Antigravity의 실제 사용량 한도가 제공되지 않습니다. 모델 목록이나 이용 가능 상태는 사용량으로 표시하지 않습니다.")
        }
        return UsageSnapshot(provider: .antigravity, plan: plan, windows: windows, source: .unofficialWeb, fetchedAt: now)
    }
}
