import Foundation
import AILimitShared
public struct PerplexityProvider: UsageProvider {
    public let id: ProviderID = .perplexity
    public init() {}
    public func fetch(context: FetchContext) async throws -> UsageSnapshot {
        let cookie = try Credentials.validate(context.secret(), for: id)
        let json = try JSON(data: await context.get(HTTPRequest("https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default", headers: ["Cookie": cookie, "Origin": "https://www.perplexity.ai", "Referer": "https://www.perplexity.ai/account/usage", "Accept": "application/json"])))
        var balances: [BalanceMetric] = []; let renewal = json.alias("renewalDateTs", "renewal_date_ts").date
        for (snake, camel, title) in [("balance_cents", "balanceCents", "크레딧 금액 잔액"), ("total_usage_cents", "totalUsageCents", "당기 사용 금액"), ("current_period_purchased_cents", "currentPeriodPurchasedCents", "당기 구매 금액")] {
            if let amount = try json.alias(camel, snake).decimal() { balances.append(BalanceMetric(id: snake, title: title + " · cents 100:1", amount: amount / 100, unit: .credits, expiresAt: renewal)) }
        }
        for (index, grant) in json.alias("creditGrants", "credit_grants").array.enumerated() {
            let type = grant["type"].string ?? "미분류"; let expiration = grant.alias("expiresAtTs", "expires_at_ts").date
            if type == "promotional", let expiration, expiration <= context.now() { continue }
            if let amount = try grant.alias("amountCents", "amount_cents").decimal() { balances.append(BalanceMetric(id: "grant.\(index)", title: "\(type) 지급 · cents 100:1", amount: amount / 100, unit: .credits, expiresAt: expiration)) }
        }
        guard !balances.isEmpty else { throw UsageError.unavailable("크레딧 금액 미제공") }
        return snapshot(id, context, balances: balances)
    }
}
