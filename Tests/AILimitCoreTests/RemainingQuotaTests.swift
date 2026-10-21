import XCTest
import AILimitShared

final class RemainingQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_683_200)

    func testResetClockDistinguishesAfternoonAndDatesWithoutInventingPrecision() throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        for (hour, expected) in [(0, "00:30"), (12, "12:30"), (13, "13:30"), (23, "23:30")] {
            let reset = try XCTUnwrap(calendar.date(bySettingHour: hour, minute: 30, second: 0, of: day))
            let window = QuotaWindow(id: "daily", title: "일간", resetsAt: reset, resetPrecision: .exact)
            XCTAssertEqual(UsageFormat.resetTime(window, at: day), expected)
        }
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        let afternoon = try XCTUnwrap(calendar.date(bySettingHour: 13, minute: 30, second: 0, of: tomorrow))
        var window = QuotaWindow(id: "daily", title: "일간", resetsAt: afternoon, resetPrecision: .exact)
        let otherDay = try XCTUnwrap(UsageFormat.resetTime(window, at: day))
        XCTAssertNotEqual(otherDay, "13:30")
        XCTAssertTrue(otherDay.hasSuffix("13:30"))
        let summary = UsageFormat.resetSummary(window, at: day)
        let label = UsageFormat.resetLabel(window, at: day)
        window.resetDescription = "구독 종료 안내"
        XCTAssertEqual(UsageFormat.resetTime(window, at: day), otherDay)
        XCTAssertEqual(UsageFormat.resetSummary(window, at: day), summary)
        XCTAssertEqual(UsageFormat.resetLabel(window, at: day), label)
        for precision in [ResetPrecision.dateOnly, .approximate, .unknown] {
            window.resetPrecision = precision
            XCTAssertNil(UsageFormat.resetTime(window, at: day))
            XCTAssertNotEqual(UsageFormat.resetSummary(window, at: day), summary)
            XCTAssertNotEqual(UsageFormat.resetLabel(window, at: day), label)
        }
        window.resetPrecision = .exact
        window.resetsAt = nil
        XCTAssertNil(UsageFormat.resetTime(window, at: day))
    }

    func testLegacyAndFuturePrecisionNeverInventResetClocks() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for precision in ["", #","resetPrecision":null"#, #","resetPrecision":"futurePrecision""#] {
            let data = Data(#"{"id":"quota","title":"한도","unit":{"percent":{}},"unlimited":false,"resetsAt":"2026-10-13T13:30:00Z"\#(precision)}"#.utf8)
            let window = try decoder.decode(QuotaWindow.self, from: data)
            XCTAssertNil(UsageFormat.resetTime(window, at: now))
            let snapshot = SharedSnapshot(updatedAt: now, providers: [
                ProviderState(provider: .grok, lastSuccess: UsageSnapshot(provider: .grok, windows: [window], source: .unofficialWeb, fetchedAt: now))
            ])
            let restored = try SharedSnapshot.decode(snapshot.encoded()).providers[0].lastSuccess!.windows[0]
            XCTAssertEqual(restored.resetsAt, window.resetsAt)
            XCTAssertNil(UsageFormat.resetTime(restored, at: now))
        }
    }

    func testRemainingGaugeBoundariesDoNotRewriteObservedUsage() throws {
        let cases: [(Double, Double, QuotaLevel)] = [(0, 100, .normal), (20, 80, .normal), (89.9, 10.1, .normal), (90, 10, .low), (99.9, 0.1, .low), (100, 0, .exhausted), (110, 0, .exceeded)]
        for (used, remaining, level) in cases {
            let window = QuotaWindow(id: "weekly", title: "주간 한도", usedPercent: used)
            XCTAssertEqual(try XCTUnwrap(UsageFormat.remainingPercent(window)), remaining, accuracy: 0.000_001)
            XCTAssertEqual(UsageFormat.level(window), level)
            let original = SharedSnapshot(updatedAt: now, providers: [ProviderState(provider: .codex, lastSuccess: UsageSnapshot(provider: .codex, windows: [window], source: .unofficialWeb, fetchedAt: now))])
            let restored = try SharedSnapshot.decode(original.encoded()).providers[0].lastSuccess!.windows[0]
            XCTAssertEqual(restored.usedPercent, used)
            XCTAssertEqual(restored.remainingPercent, 100 - used)
        }
    }

    func testUnknownAndUnlimitedNeverBecomeEmptyOrFullGauges() {
        let unknown = QuotaWindow(id: "unknown", title: "한도", remaining: 12, unit: .credits)
        let unlimited = QuotaWindow(id: "unlimited", title: "한도", usedPercent: 100, unlimited: true)
        XCTAssertNil(UsageFormat.remainingPercent(unknown))
        XCTAssertEqual(UsageFormat.level(unknown), .unknown)
        XCTAssertNil(UsageFormat.quotaWarning(unknown))
        XCTAssertNil(UsageFormat.remainingPercent(unlimited))
        XCTAssertEqual(UsageFormat.level(unlimited), .unlimited)
        XCTAssertNil(UsageFormat.quotaWarning(unlimited))
        XCTAssertEqual(unknown.remaining, 12)
    }

    func testLimitedSummaryIncludesPinnedConstraintInsteadOfHidingIt() {
        let windows = [QuotaWindow(id: "five", title: "5시간 한도", usedPercent: 20), QuotaWindow(id: "week", title: "주간 한도", usedPercent: 30), QuotaWindow(id: "model", title: "모델 한도", usedPercent: 95), QuotaWindow(id: "unlimited", title: "무제한", usedPercent: 200, unlimited: true)]
        let usage = UsageSnapshot(provider: .codex, windows: windows, source: .publicCLI, fetchedAt: now)
        XCTAssertEqual(usage.mostLimited?.id, "model")
        XCTAssertEqual(UsageFormat.summaryWindows(usage, maximum: 2).map(\.id), ["five", "model"])
        XCTAssertEqual(UsageFormat.summaryWindows(usage, maximum: 1).map(\.id), ["model"])
        XCTAssertEqual(UsageFormat.summaryWindows(usage, maximum: 0).map(\.id), [])
        XCTAssertEqual(UsageFormat.summaryWindows(usage, maximum: 4).map(\.id), windows.map(\.id))
        XCTAssertEqual(usage.windows.map(\.id), windows.map(\.id))
    }

    func testHistoricalWarningUsesQuotaAgeFailureAndResetNotLocalFreshness() {
        let window = QuotaWindow(id: "five", title: "5시간 한도", usedPercent: 100, resetsAt: now.addingTimeInterval(1800), resetPrecision: .exact)
        let usage = UsageSnapshot(provider: .codex, windows: [window], source: .publicCLI, fetchedAt: now)
        var state = ProviderState(provider: .codex, status: .ready, lastSuccess: usage, localTokens: [TokenSummary(scope: "ompSession", counters: TokenCounters(total: 100), observedAt: now.addingTimeInterval(900))])
        XCTAssertNil(UsageFormat.observationIssue(state, at: now.addingTimeInterval(899)))
        XCTAssertNotNil(UsageFormat.observationIssue(state, at: now.addingTimeInterval(900)))
        for status in [ConnectionStatus.failed, .unavailable, .needsAuthentication, .disconnected] {
            state.status = status
            XCTAssertNotNil(UsageFormat.observationIssue(state, at: now))
        }
        state.status = .ready
        state.lastSuccess?.windows[0].resetsAt = now
        XCTAssertNotNil(UsageFormat.observationIssue(state, at: now))
        XCTAssertEqual(UsageFormat.remainingPercent(state.lastSuccess!.windows[0]), 0)
        XCTAssertEqual(state.lastSuccess?.windows[0].usedPercent, 100)
        state.lastSuccess = nil
        XCTAssertNil(UsageFormat.observationIssue(state, at: now))
    }
}
