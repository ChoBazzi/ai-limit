import Foundation
import AILimitShared

/// Token-only API-price equivalent, not a subscription bill or historical spend.
/// Versioned comparison basis: standard, global USD tariffs observed on `asOf`.
/// Excludes tools, taxes, negotiated discounts, batch/flex/fast and residency uplifts.
/// Only exact first-party model IDs below are supported; no prefix/date stripping.
enum APIPriceCatalog {
    static let asOf = "2026-10-12"

    // Rates are exact thousandths of USD per million tokens, converted to Decimal
    // once. This avoids binary floating point and reparsing prices per request.
    private struct Rates: Sendable {
        let input: Decimal
        let output: Decimal
        let read: Decimal?
        let write: Decimal?
        let longWrite: Decimal?

        init(_ input: Int, _ output: Int, _ read: Int?, _ write: Int? = nil, _ longWrite: Int? = nil) {
            self.input = Decimal(input) / 1_000
            self.output = Decimal(output) / 1_000
            self.read = read.map { Decimal($0) / 1_000 }
            self.write = write.map { Decimal($0) / 1_000 }
            self.longWrite = longWrite.map { Decimal($0) / 1_000 }
        }
    }

    private struct Tariff: Sendable {
        let standard: Rates
        let threshold: Int64?
        let long: Rates?

        init(_ standard: Rates, threshold: Int64? = nil, long: Rates? = nil) {
            self.standard = standard
            self.threshold = threshold
            self.long = long
        }
    }

    // https://developers.openai.com/api/docs/pricing (Standard tables).
    // Short <=272,000 input tokens; long >272,000. A '-' is unsupported,
    // never a zero-priced bucket. GPT-5.6 Sol includes the published promotion
    // available at least through 2026-11-21; this is not a forward price forecast.
    // Older Codex rates and exact IDs additionally verified at:
    // https://developers.openai.com/api/docs/models/gpt-5.1-codex
    // https://developers.openai.com/api/docs/models/gpt-5.1-codex-max
    // https://developers.openai.com/api/docs/models/gpt-5.2-codex
    private static let openAI: [String: Tariff] = [
        "gpt-6-astra": Tariff(Rates(10_000, 50_000, 1_000, 12_500), threshold: 272_000, long: Rates(20_000, 75_000, 2_000, 25_000)),
        "gpt-6.1-sol": Tariff(Rates(2_000, 10_000, 100, 2_500), threshold: 272_000, long: Rates(4_000, 15_000, 200, 5_000)),
        "gpt-6-sol": Tariff(Rates(2_000, 10_000, 200, 2_500), threshold: 272_000, long: Rates(4_000, 15_000, 400, 5_000)),
        "gpt-6-luna": Tariff(Rates(100, 500, 10, 125), threshold: 272_000, long: Rates(200, 750, 20, 250)),
        "gpt-5.6-sol": Tariff(Rates(4_000, 20_000, 400, 5_000), threshold: 272_000, long: Rates(8_000, 30_000, 800, 10_000)),
        "gpt-5.6-terra": Tariff(Rates(2_000, 12_000, 200, 2_500), threshold: 272_000, long: Rates(4_000, 18_000, 400, 5_000)),
        "gpt-5.6-luna": Tariff(Rates(200, 1_200, 20, 250), threshold: 272_000, long: Rates(400, 1_800, 40, 500)),
        "gpt-5.6-cyber": Tariff(Rates(12_500, 75_000, 1_250, 15_625), threshold: 272_000),
        "gpt-5.5": Tariff(Rates(5_000, 30_000, 500), threshold: 272_000, long: Rates(10_000, 45_000, 1_000)),
        "gpt-5.5-pro": Tariff(Rates(30_000, 180_000, nil), threshold: 272_000, long: Rates(60_000, 270_000, nil)),
        "gpt-5.5-cyber": Tariff(Rates(12_500, 75_000, 1_250), threshold: 272_000),
        "gpt-5.4": Tariff(Rates(2_500, 15_000, 250), threshold: 272_000, long: Rates(5_000, 22_500, 500)),
        "gpt-5.4-pro": Tariff(Rates(30_000, 180_000, nil), threshold: 272_000, long: Rates(60_000, 270_000, nil)),
        "gpt-5.4-mini": Tariff(Rates(750, 4_500, 75), threshold: 272_000),
        "gpt-5.4-nano": Tariff(Rates(200, 1_250, 20), threshold: 272_000),
        "gpt-5.3-codex": Tariff(Rates(1_750, 14_000, 175), threshold: 272_000),
        "gpt-5.2-codex": Tariff(Rates(1_750, 14_000, 175), threshold: 272_000),
        "gpt-5.1-codex": Tariff(Rates(1_250, 10_000, 125), threshold: 272_000),
        "gpt-5.1-codex-max": Tariff(Rates(1_250, 10_000, 125), threshold: 272_000),
        "gpt-5.2": Tariff(Rates(1_750, 14_000, 175), threshold: 272_000),
        "gpt-5.2-pro": Tariff(Rates(21_000, 168_000, nil), threshold: 272_000),
        "gpt-5.1": Tariff(Rates(1_250, 10_000, 125), threshold: 272_000),
        "gpt-5": Tariff(Rates(1_250, 10_000, 125), threshold: 272_000),
        "gpt-5-mini": Tariff(Rates(250, 2_000, 25), threshold: 272_000),
        "gpt-5-nano": Tariff(Rates(50, 400, 5), threshold: 272_000),
        "gpt-5-pro": Tariff(Rates(15_000, 120_000, nil), threshold: 272_000)
    ]

    // https://platform.claude.com/docs/en/about-claude/pricing
    // https://platform.claude.com/docs/en/models/overview
    // https://platform.claude.com/docs/en/about-claude/models/model-ids-and-versions
    // https://platform.claude.com/docs/en/models/opus-4-5/overview
    // https://platform.claude.com/docs/en/models/haiku-4-5/overview
    // 4.6+ IDs are pinned dateless snapshots. Only documented pre-4.6 aliases
    // and their exact snapshot dates are accepted. Unverified retired IDs omitted.
    // No long-context premium for 4.6+ except Haiku 5.5 (>100,000 prompt tokens).
    // Pre-4.6 requests beyond 200k are unpriced: this catalogue does not infer
    // a legacy long-context beta tariff from the modern pricing table.
    private static let anthropic: [String: Tariff] = [
        "claude-fable-5-1": Tariff(Rates(10_000, 50_000, 250, 12_500, 20_000)),
        "claude-fable-5": Tariff(Rates(10_000, 50_000, 1_000, 12_500, 20_000)),
        "claude-opus-5-5": Tariff(Rates(4_000, 20_000, 200, 5_000, 8_000)),
        "claude-opus-5": Tariff(Rates(5_000, 25_000, 500, 6_250, 10_000)),
        "claude-opus-4-8": Tariff(Rates(5_000, 25_000, 500, 6_250, 10_000)),
        "claude-opus-4-7": Tariff(Rates(5_000, 25_000, 500, 6_250, 10_000)),
        "claude-opus-4-6": Tariff(Rates(5_000, 25_000, 500, 6_250, 10_000)),
        "claude-opus-4-5": Tariff(Rates(5_000, 25_000, 500, 6_250, 10_000), threshold: 200_000),
        "claude-opus-4-5-20251101": Tariff(Rates(5_000, 25_000, 500, 6_250, 10_000), threshold: 200_000),
        "claude-sonnet-5-5": Tariff(Rates(2_000, 10_000, 100, 2_500, 4_000)),
        "claude-sonnet-5": Tariff(Rates(2_000, 10_000, 200, 2_500, 4_000)),
        "claude-sonnet-4-6": Tariff(Rates(3_000, 15_000, 300, 3_750, 6_000)),
        "claude-sonnet-4-5": Tariff(Rates(3_000, 15_000, 300, 3_750, 6_000), threshold: 200_000),
        "claude-sonnet-4-5-20250929": Tariff(Rates(3_000, 15_000, 300, 3_750, 6_000), threshold: 200_000),
        "claude-haiku-5-5": Tariff(Rates(100, 500, 10, 125, 200), threshold: 100_000, long: Rates(500, 2_500, 50, 625, 1_000)),
        "claude-haiku-4-5": Tariff(Rates(1_000, 5_000, 100, 1_250, 2_000), threshold: 200_000),
        "claude-haiku-4-5-20251001": Tariff(Rates(1_000, 5_000, 100, 1_250, 2_000), threshold: 200_000)
    ]

    /// All four chargeable buckets must be present, nonnegative and disjoint.
    /// `cacheWriteLong` is the 1h subset of `cacheWrite`, not an additional bucket.
    /// If absent, Claude cache writes use the documented default 5m baseline:
    /// https://platform.claude.com/docs/en/build-with-claude/prompt-caching
    /// This is an estimate assumption, not evidence of the original request TTL.
    static func estimate(provider: ProviderID, model: String?, counters: TokenCounters, cacheWriteLong: Int64? = nil) -> Decimal? {
        guard let model, let input = counters.input, let output = counters.output,
              let read = counters.cacheRead, let write = counters.cacheWrite,
              input >= 0, output >= 0, read >= 0, write >= 0,
              counters.reasoning.map({ $0 >= 0 }) ?? true,
              counters.total.map({ $0 >= 0 }) ?? true else { return nil }
        let longWrite = cacheWriteLong ?? 0
        guard longWrite >= 0, longWrite <= write else { return nil }
        let (inputAndRead, readOverflow) = input.addingReportingOverflow(read)
        let (prompt, writeOverflow) = inputAndRead.addingReportingOverflow(write)
        let (_, totalOverflow) = prompt.addingReportingOverflow(output)
        guard !readOverflow, !writeOverflow, !totalOverflow else { return nil }

        let tariff: Tariff?
        switch provider {
        case .codex: tariff = openAI[model]
        case .claude: tariff = anthropic[model]
        default: return nil
        }
        guard let tariff else { return nil }
        let rates: Rates
        if let threshold = tariff.threshold, prompt > threshold {
            guard let long = tariff.long else { return nil }
            rates = long
        } else {
            rates = tariff.standard
        }
        guard read == 0 || rates.read != nil,
              write == longWrite || rates.write != nil,
              longWrite == 0 || rates.longWrite != nil else { return nil }
        // total is deliberately not used as a chargeable bucket. Reasoning is
        // already in output. Rate tier applies to the entire request, not excess.
        // Int64 counts and bounded published tariffs fit Decimal exactly here.
        let cost = Decimal(input) * rates.input + Decimal(output) * rates.output
            + Decimal(read) * (rates.read ?? 0)
            + Decimal(write - longWrite) * (rates.write ?? 0)
            + Decimal(longWrite) * (rates.longWrite ?? 0)
        return cost / 1_000_000
    }
}
