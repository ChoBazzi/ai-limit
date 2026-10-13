import Foundation
import AILimitShared

// wham/usage contract: flukelaster/LLM-Usage-Widget
// 4e9ba459dff930af19d325dab4443892c4f2ce9b CodexUsageFetcher.swift.
public struct CodexDirectProvider: Sendable {
    public init() {}
    public func fetch(context: FetchContext, credential: DirectCredential) async throws -> UsageSnapshot {
        try SubscriptionOAuth.validate(credential, provider: .codex, now: context.now())
        var headers = ["Authorization": "Bearer " + credential.accessToken, "Accept": "application/json", "User-Agent": "AI-Limit"]
        if let account = credential.metadata["accountID"] {
            guard SubscriptionOAuth.validSecret(account) else { throw UsageError.authentication }
            if let claims = CodexDirectAuth.routingClaims(credential.accessToken),
               let tokenAccount = claims["https://api.openai.com/auth"]["chatgpt_account_id"].string ?? claims["chatgpt_account_id"].string,
               tokenAccount != account { throw UsageError.authentication }
            headers["ChatGPT-Account-Id"] = account
        }
        let json = try JSON(data: await context.get(HTTPRequest("https://chatgpt.com/backend-api/wham/usage", headers: headers)))
        if let expected = credential.metadata["accountID"],
           let reported = json.alias("accountId", "account_id").string,
           expected != reported { throw UsageError.authentication }
        let rates = json.alias("rate_limits", "rate_limit")
        var windows = try Self.windows(rates)
        // Additive model limits and credit fields are confirmed by CodexBar
        // 22fbf3559024c9106e3f59847f86e490cafce87b CodexOAuthUsageFetcher.swift.
        for (index, extra) in json["additional_rate_limits"].array.enumerated() {
            let name = extra["limit_name"].string ?? extra["metered_feature"].string ?? "모델 한도"
            windows += try Self.windows(extra["rate_limit"], prefix: "model-\(index)-", name: name)
        }
        var balances: [BalanceMetric] = []
        if let balance = try json["credits"]["balance"].decimal() {
            balances.append(BalanceMetric(id: "credits", title: "크레딧 잔액", amount: balance, unit: .credits))
        }
        if json["credits"]["unlimited"].bool == true {
            windows.append(QuotaWindow(id: "credits-unlimited", title: "크레딧", unit: .credits, unlimited: true))
        }
        var resetCredits: ResetCredits?
        if let count = try? json["rate_limit_reset_credits"]["available_count"].integer() {
            resetCredits = ResetCredits(availableCount: count)
        }
        try Task.checkCancellation()
        // Source revision: 26dd19ef478cfa294406413bafedb84b49f93ea4.
        // Read-only contract: openai/codex backend-client/src/client/rate_limit_resets.rs
        // and backend-client/src/types.rs. Optional detail outages must not erase quotas
        // or the independently reported count from wham/usage.
        var detailData: Data?
        do {
            detailData = try await context.get(HTTPRequest(
                "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", headers: headers, timeout: 5))
        } catch is CancellationError {
            throw CancellationError()
        } catch UsageError.cancelled {
            throw UsageError.cancelled
        } catch {
            try Task.checkCancellation()
        }
        if let detailData, let details = try? JSONDecoder().decode(ResetCreditDetails.self, from: detailData) {
            let expected = credential.metadata["accountID"] ?? json.alias("accountId", "account_id").string
            if let expected, let reported = details.accountID,
               expected != reported { throw UsageError.authentication }
            if let count = details.availableCount {
                resetCredits = ResetCredits(availableCount: count)
            }
            if let rows = details.credits {
                resetCredits?.credits = rows.compactMap(\.credit)
            }
        }
        try Task.checkCancellation()
        guard !windows.isEmpty || !balances.isEmpty || resetCredits != nil else {
            throw UsageError.unavailable("Codex 계정의 사용 한도가 제공되지 않았습니다.")
        }
        return UsageSnapshot(provider: .codex, plan: json["plan_type"].string ?? rates["plan_type"].string,
                             windows: windows, balances: balances, source: .unofficialWeb, fetchedAt: context.now(),
                             resetCredits: resetCredits)
    }

    private static func windows(_ rates: JSON, prefix: String = "", name: String? = nil) throws -> [QuotaWindow] {
        var result: [QuotaWindow] = []
        for key in ["primary", "secondary"] {
            let window = rates.alias(key, key + "_window")
            guard let used = try window["used_percent"].number() else { continue }
            let seconds = try window["limit_window_seconds"].integer()
            let duration = UsageFormat.limitTitle(seconds: seconds)
            let label = name.map { $0 + " · " + duration } ?? duration
            result.append(QuotaWindow(id: prefix + key, title: label, usedPercent: used,
                                      resetsAt: window.alias("resets_at", "reset_at").date))
        }
        return result
    }

    private struct ResetCreditDetails: Decodable {
        let availableCount: Int64?
        let credits: [ResetCreditRow]?
        let accountID: String?
        private enum CodingKeys: String, CodingKey {
            case availableCount = "available_count", credits, accountId, accountID = "account_id"
        }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accountID = (try? container.decode(String.self, forKey: .accountId))
                ?? (try? container.decode(String.self, forKey: .accountID))
            let count = try? container.decode(Int64.self, forKey: .availableCount)
            availableCount = count.flatMap { $0 >= 0 ? $0 : nil }
            credits = try? container.decode([ResetCreditRow].self, forKey: .credits)
        }
    }

    private struct ResetCreditRow: Decodable {
        let credit: ResetCredit?
        private enum CodingKeys: String, CodingKey {
            case resetType = "reset_type", status, expiresAt = "expires_at"
        }
        init(from decoder: any Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self),
                  (try? container.decode(String.self, forKey: .resetType)) == "codex_rate_limits",
                  (try? container.decode(String.self, forKey: .status)) == "available",
                  container.contains(.expiresAt) else {
                credit = nil
                return
            }
            if (try? container.decodeNil(forKey: .expiresAt)) == true {
                credit = ResetCredit(expiresAt: nil)
                return
            }
            // REST supplies ISO8601 strings, unlike the app-server's epoch seconds.
            // A malformed/missing expiry must never become an unlimited-lifetime pass.
            guard let text = try? container.decode(String.self, forKey: .expiresAt),
                  let expiry = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
                    ?? (try? Date.ISO8601FormatStyle().parse(text)) else {
                credit = nil
                return
            }
            credit = ResetCredit(expiresAt: expiry)
        }
    }
}
