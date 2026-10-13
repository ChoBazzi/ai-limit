import XCTest
@testable import AILimitCore
import AILimitShared

final class APIPriceCatalogTests: XCTestCase {
    private func usd(_ value: String) -> Decimal {
        Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))!
    }

    func testDisjointCacheBucketsAndReasoningAreChargedOnce() {
        var usage = TokenCounters(input: 1_000, output: 2_000, cacheRead: 3_000, cacheWrite: 4_000, reasoning: 1_500, total: 99_999)
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .codex, model: "gpt-6-astra", counters: usage), usd("0.163"))
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .codex, model: "gpt-6.1-sol", counters: usage), usd("0.0323"))
        usage.total = nil
        usage.reasoning = nil
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .codex, model: "gpt-6-astra", counters: usage), usd("0.163"))
    }

    func testOpenAILongContextUsesAllPromptBucketsAndWholeRequestRates() {
        var usage = TokenCounters(input: 270_000, output: 1_000, cacheRead: 1_000, cacheWrite: 1_000)
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .codex, model: "gpt-6-astra", counters: usage), usd("2.7635"))
        usage.input = 270_001
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .codex, model: "gpt-6-astra", counters: usage), usd("5.50202"))
        // A cache-only increment can cross the threshold; output cannot.
        usage.input = 270_000
        usage.cacheRead = 1_001
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .codex, model: "gpt-6-astra", counters: usage), usd("5.502002"))
        usage.cacheRead = 1_000
        usage.output = 2_000
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .codex, model: "gpt-6-astra", counters: usage), usd("2.8135"))
    }

    func testClaudeCacheTTLSubsetAndDefaultBaseline() {
        let usage = TokenCounters(input: 1_000, output: 2_000, cacheRead: 3_000, cacheWrite: 4_000)
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .claude, model: "claude-sonnet-4-6", counters: usage), usd("0.0489"))
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .claude, model: "claude-sonnet-4-6", counters: usage, cacheWriteLong: 1_000), usd("0.05115"))
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .claude, model: "claude-sonnet-4-6", counters: usage, cacheWriteLong: 4_000), usd("0.0579"))
        XCTAssertNil(APIPriceCatalog.estimate(provider: .claude, model: "claude-sonnet-4-6", counters: usage, cacheWriteLong: 4_001))
        XCTAssertNil(APIPriceCatalog.estimate(provider: .claude, model: "claude-sonnet-4-6", counters: usage, cacheWriteLong: -1))
        XCTAssertNil(APIPriceCatalog.estimate(provider: .codex, model: "gpt-6-astra", counters: usage, cacheWriteLong: 1))
    }

    func testHaikuPromptThresholdIncludesReadsAndWrites() {
        var usage = TokenCounters(input: 98_000, output: 1_000, cacheRead: 1_000, cacheWrite: 1_000)
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .claude, model: "claude-haiku-5-5", counters: usage), usd("0.010435"))
        usage.input = 98_001
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .claude, model: "claude-haiku-5-5", counters: usage), usd("0.0521755"))
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .claude, model: "claude-haiku-5-5", counters: usage, cacheWriteLong: 1_000), usd("0.0525505"))
    }

    func testModernClaudeHasNoGenericLongContextPremium() {
        let usage = TokenCounters(input: 900_000, output: 1_000, cacheRead: 0, cacheWrite: 0)
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .claude, model: "claude-sonnet-4-6", counters: usage), usd("2.715"))
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .claude, model: "claude-opus-5-5", counters: usage), usd("3.62"))
        XCTAssertNil(APIPriceCatalog.estimate(provider: .claude, model: "claude-sonnet-4-5", counters: usage))
        XCTAssertNil(APIPriceCatalog.estimate(provider: .codex, model: "gpt-5.6-cyber", counters: usage))
    }

    func testDocumentedAliasesOnlyAndProviderIsolation() {
        let usage = TokenCounters(input: 1_000, output: 0, cacheRead: 0, cacheWrite: 0)
        for model in ["claude-opus-4-5", "claude-opus-4-5-20251101"] {
            XCTAssertEqual(APIPriceCatalog.estimate(provider: .claude, model: model, counters: usage), usd("0.005"))
        }
        for model in ["claude-sonnet-4-5", "claude-sonnet-4-5-20250929"] {
            XCTAssertEqual(APIPriceCatalog.estimate(provider: .claude, model: model, counters: usage), usd("0.003"))
        }
        for model in ["claude-haiku-4-5", "claude-haiku-4-5-20251001"] {
            XCTAssertEqual(APIPriceCatalog.estimate(provider: .claude, model: model, counters: usage), usd("0.001"))
        }
        for model in ["claude-opus-4-5-20251102", "claude-sonnet-4-6-20260101", "claude-sonnet-9", "anthropic/claude-sonnet-4-6"] {
            XCTAssertNil(APIPriceCatalog.estimate(provider: .claude, model: model, counters: usage))
        }
        for model in ["gpt-6-astra-latest", "gpt-6-astra-20261012", "gpt-5.6-future", "GPT-6-ASTRA", " gpt-6-astra", ""] {
            XCTAssertNil(APIPriceCatalog.estimate(provider: .codex, model: model, counters: usage))
        }
        XCTAssertNil(APIPriceCatalog.estimate(provider: .claude, model: "gpt-6-astra", counters: usage))
        XCTAssertNil(APIPriceCatalog.estimate(provider: .codex, model: "claude-opus-5-5", counters: usage))
        XCTAssertNil(APIPriceCatalog.estimate(provider: .cursor, model: "gpt-6-astra", counters: usage))
        XCTAssertNil(APIPriceCatalog.estimate(provider: .codex, model: nil, counters: usage))
    }

    func testUnsupportedBucketsAreNotFreeAndMissingIsNotZero() {
        var usage = TokenCounters(input: 1, output: 1, cacheRead: 0, cacheWrite: 0)
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .codex, model: "gpt-5.5-pro", counters: usage), usd("0.00021"))
        usage.cacheRead = 1
        XCTAssertNil(APIPriceCatalog.estimate(provider: .codex, model: "gpt-5.5-pro", counters: usage))
        usage.cacheRead = 0
        usage.cacheWrite = 1
        XCTAssertNil(APIPriceCatalog.estimate(provider: .codex, model: "gpt-5.3-codex", counters: usage))
        usage.cacheWrite = 0
        for key in [\TokenCounters.input, \.output, \.cacheRead, \.cacheWrite] {
            var incomplete = usage
            incomplete[keyPath: key] = nil
            XCTAssertNil(APIPriceCatalog.estimate(provider: .codex, model: "gpt-6-astra", counters: incomplete))
        }
        XCTAssertNil(APIPriceCatalog.estimate(provider: .codex, model: "gpt-6-astra", counters: TokenCounters(total: 100)))
        let zero = TokenCounters(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .codex, model: "gpt-6-astra", counters: zero), 0)
        XCTAssertNil(APIPriceCatalog.estimate(provider: .codex, model: "unknown", counters: zero))
    }

    func testNegativeAndOverflowCountersAreUnpriced() {
        let usage = TokenCounters(input: 1, output: 1, cacheRead: 1, cacheWrite: 1)
        for key in [\TokenCounters.input, \.output, \.cacheRead, \.cacheWrite, \.reasoning, \.total] {
            var invalid = usage
            invalid[keyPath: key] = -1
            XCTAssertNil(APIPriceCatalog.estimate(provider: .codex, model: "gpt-6-astra", counters: invalid))
        }
        for overflow in [
            TokenCounters(input: .max, output: 0, cacheRead: 1, cacheWrite: 0),
            TokenCounters(input: .max, output: 0, cacheRead: 0, cacheWrite: 1),
            TokenCounters(input: .max, output: 1, cacheRead: 0, cacheWrite: 0)
        ] {
            XCTAssertNil(APIPriceCatalog.estimate(provider: .claude, model: "claude-opus-5-5", counters: overflow))
        }
        let huge = TokenCounters(input: 0, output: .max, cacheRead: 0, cacheWrite: 0)
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .codex, model: "gpt-5-pro", counters: huge), usd("1106804644422573.09684"))
    }

    func testTinyFractionalUSDRemainsExactAndCodexUsesItsOwnTariff() {
        let tiny = TokenCounters(input: 1, output: 0, cacheRead: 1, cacheWrite: 0)
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .codex, model: "gpt-5-nano", counters: tiny), usd("0.000000055"))
        let usage = TokenCounters(input: 1_000, output: 2_000, cacheRead: 3_000, cacheWrite: 0)
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .codex, model: "gpt-5.3-codex", counters: usage), usd("0.030275"))
        XCTAssertEqual(APIPriceCatalog.estimate(provider: .codex, model: "gpt-5.1-codex-max", counters: usage), usd("0.021625"))
    }
}
