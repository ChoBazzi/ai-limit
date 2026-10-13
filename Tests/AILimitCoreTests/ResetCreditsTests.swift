import XCTest
@testable import AILimitCore
import AILimitShared

@MainActor
final class ResetCreditsTests: XCTestCase {
    private func fetch(_ summary: String?) async throws -> UsageSnapshot {
        var replies = try fixture("codex.jsonl").split(separator: 10).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        var result = try XCTUnwrap(replies[2]["result"] as? [String: Any])
        if let summary {
            result["rateLimitResetCredits"] = try JSONSerialization.jsonObject(with: Data(summary.utf8), options: [.fragmentsAllowed])
        }
        replies[2]["result"] = result
        var data = Data()
        for reply in replies {
            data.append(try JSONSerialization.data(withJSONObject: reply))
            data.append(10)
        }
        return try await CodexProvider().fetch(context: testContext(.codex, cli: data))
    }

    private func roundTrip(_ value: UsageSnapshot, status: ConnectionStatus = .ready) throws -> UsageSnapshot {
        let shared = SharedSnapshot(updatedAt: fixedNow, providers: [ProviderState(provider: .codex, status: status, lastSuccess: value)])
        return try XCTUnwrap(SharedSnapshot.decode(shared.encoded()).providers.first?.lastSuccess)
    }

    func testLegacySnapshotAndCLILeaveResetCountUnknown() async throws {
        let legacy = Data("""
        {"schemaVersion":1,"updatedAt":"2026-09-28T00:00:00Z","displayOrder":["codex"],"providers":[{"provider":"codex","status":"ready","lastSuccess":{"provider":"codex","plan":"plus","windows":[],"balances":[],"source":"publicCLI","fetchedAt":"2026-09-28T00:00:00Z"}}]}
        """.utf8)
        let stored = try XCTUnwrap(SharedSnapshot.decode(legacy).providers.first?.lastSuccess)
        XCTAssertNil(stored.resetCredits)
        XCTAssertEqual(stored.plan, "plus")
        let current = try await fetch(nil)
        XCTAssertNil(current.resetCredits)
        XCTAssertEqual(current.windows.first?.remainingPercent, 75)
    }

    func testAuthoritativeCountSurvivesCappedDetailsAndRoundTrip() async throws {
        let value = try await fetch("""
        {"availableCount":7,"credits":[
          {"id":"private-reset-id","resetType":"codexRateLimits","status":"available","expiresAt":1790812800,"title":"private-title","description":"private-description"},
          {"resetType":"codexRateLimits","status":"available","expiresAt":null}
        ]}
        """)
        let stored = try roundTrip(value)
        XCTAssertEqual(stored.resetCredits?.availableCount, 7)
        let rows = try XCTUnwrap(stored.resetCredits?.credits)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].expiresAt, Date(timeIntervalSince1970: 1790812800))
        XCTAssertNil(rows[1].expiresAt)
        XCTAssertEqual(stored.windows.first?.remainingPercent, 75)
        XCTAssertEqual(stored.balances.first?.amount, Decimal(string: "12.34"))
        let data = try SharedSnapshot(updatedAt: fixedNow, providers: [ProviderState(provider: .codex, lastSuccess: value)]).encoded()
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["private-reset-id", "private-title", "private-description"] {
            XCTAssertFalse(text.contains(secret))
        }
    }

    func testExplicitZeroIsDistinctFromUnknownAndCountOnly() async throws {
        let zero = try roundTrip(await fetch(#"{"availableCount":0,"credits":[]}"#))
        XCTAssertEqual(zero.resetCredits?.availableCount, 0)
        XCTAssertEqual(zero.resetCredits?.credits?.count, 0)
        for summary in [#"{"availableCount":4}"#, #"{"availableCount":"4","credits":null}"#] {
            let stored = try roundTrip(await fetch(summary))
            XCTAssertEqual(stored.resetCredits?.availableCount, 4)
            XCTAssertNil(stored.resetCredits?.credits)
        }
        for summary in ["null", "{}", #"{"credits":[]}"#, #"{"availableCount":null}"#, #"{"availableCount":-1}"#, #"{"availableCount":1.5}"#, #"{"availableCount":true}"#, #"{"availableCount":"NaN"}"#, #"{"availableCount":9223372036854775808}"#] {
            let value = try roundTrip(await fetch(summary))
            XCTAssertNil(value.resetCredits, summary)
            XCTAssertEqual(value.windows.first?.remainingPercent, 75, summary)
        }
    }

    func testOnlyAvailableSupportedRowsWithExplicitValidExpiryAreIncluded() async throws {
        let value = try await fetch("""
        {"availableCount":12,"credits":[
          {"resetType":"codexRateLimits","status":"available","expiresAt":null},
          {"resetType":"codexRateLimits","status":"available","expiresAt":1790812800},
          {"resetType":"codexRateLimits","status":"available"},
          {"resetType":"codexRateLimits","status":"available","expiresAt":"invalid"},
          {"resetType":"codexRateLimits","status":"available","expiresAt":true},
          {"resetType":"codexRateLimits","status":"available","expiresAt":{}},
          {"resetType":"codexRateLimits","status":"redeeming","expiresAt":null},
          {"resetType":"codexRateLimits","status":"redeemed","expiresAt":null},
          {"resetType":"codexRateLimits","status":"unknown","expiresAt":null},
          {"resetType":"unknown","status":"available","expiresAt":null},
          {"status":"available","expiresAt":null},
          {"resetType":"codexRateLimits","expiresAt":null}
        ]}
        """)
        XCTAssertEqual(value.resetCredits?.availableCount, 12)
        let rows = try XCTUnwrap(value.resetCredits?.credits)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(rows[0].expiresAt)
        XCTAssertEqual(rows[1].expiresAt, Date(timeIntervalSince1970: 1790812800))
    }

    func testMalformedDetailsCannotEraseKnownCountOrQuotas() async throws {
        for details in ["{}", "true", "42", #""broken""#, "[null,{},false]"] {
            let value = try await fetch("{\"availableCount\":3,\"credits\":\(details)}")
            XCTAssertEqual(value.resetCredits?.availableCount, 3, details)
            XCTAssertEqual(value.resetCredits?.credits?.count ?? 0, 0, details)
            XCTAssertEqual(value.windows.first?.remainingPercent, 75, details)
        }
    }

    func testCachedExpirationMarksLastSuccessStaleWithoutDecrementingCount() async throws {
        let expiresAt = fixedNow.addingTimeInterval(90)
        let value = try await fetch("""
        {"availableCount":5,"credits":[{"resetType":"codexRateLimits","status":"available","expiresAt":\(Int64(expiresAt.timeIntervalSince1970))}]}
        """)
        let cached = try roundTrip(value, status: .needsAuthentication)
        XCTAssertFalse(cached.isStale(at: expiresAt.addingTimeInterval(-1)))
        XCTAssertTrue(cached.isStale(at: expiresAt))
        XCTAssertTrue(cached.isStale(at: expiresAt.addingTimeInterval(1)))
        XCTAssertEqual(cached.resetCredits?.availableCount, 5)
        XCTAssertEqual(cached.resetCredits?.credits?.first?.expiresAt, expiresAt)
        XCTAssertEqual(cached.fetchedAt, fixedNow)
        let nonExpiring = try await fetch(#"{"availableCount":1,"credits":[{"resetType":"codexRateLimits","status":"available","expiresAt":null}]}"#)
        XCTAssertFalse(nonExpiring.isStale(at: expiresAt))
        XCTAssertTrue(nonExpiring.isStale(at: fixedNow.addingTimeInterval(900)))
    }
}
