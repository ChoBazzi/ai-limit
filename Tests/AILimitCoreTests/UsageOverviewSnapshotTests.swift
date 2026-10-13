import XCTest
import AILimitShared

final class UsageOverviewSnapshotTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func calendar(_ zone: String) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        result.firstWeekday = 1
        return result
    }
    private func overview(at now: Date, calendar: Calendar) -> UsageOverview {
        UsageOverview(generatedAt: now, periods: UsagePeriod.allCases.map { period in
            let interval = period.interval(containing: now, calendar: calendar)!
            return PeriodUsageTotals(period: period, start: interval.start, end: interval.end, tokens: 1234, estimatedUSD: Decimal(string: "0.1234"), recordCount: 1)
        }, pricingAsOf: "2026-10-12")
    }

    func testMondayRolloverHidesPreviousWeekButKeepsCurrentMonthAcrossDST() throws {
        let la = calendar("America/Los_Angeles")
        let sunday = date("2026-03-09T06:59:59Z")
        let value = overview(at: sunday, calendar: la)
        let week = try XCTUnwrap(value.totals(for: .week, at: sunday, calendar: la))
        XCTAssertEqual(week.start, date("2026-03-02T08:00:00Z"))
        XCTAssertEqual(week.end, date("2026-03-09T07:00:00Z"))
        XCTAssertNil(value.totals(for: .week, at: week.end, calendar: la))
        XCTAssertEqual(value.totals(for: .month, at: week.end, calendar: la)?.tokens, 1234)
    }

    func testNewMonthAndTimezoneChangeCannotRelabelCachedTotalsAsCurrent() throws {
        let seoul = calendar("Asia/Seoul")
        let lastDay = date("2026-12-31T14:59:59Z")
        let value = overview(at: lastDay, calendar: seoul)
        XCTAssertNil(value.totals(for: .month, at: lastDay.addingTimeInterval(1), calendar: seoul))
        XCTAssertEqual(value.totals(for: .week, at: lastDay.addingTimeInterval(1), calendar: seoul)?.tokens, 1234)
        let la = calendar("America/Los_Angeles")
        XCTAssertNil(value.totals(for: .week, at: lastDay, calendar: la))
        XCTAssertNil(value.totals(for: .month, at: lastDay, calendar: la))
        let decoded = try SharedSnapshot.decode(SharedSnapshot(updatedAt: lastDay, providers: [], usageOverview: value).encoded())
        XCTAssertNil(decoded.usageOverview?.totals(for: .month, at: lastDay.addingTimeInterval(1), calendar: seoul))
    }

    func testReaggregatingOldScansCannotClaimCoverageOfANewWeek() {
        let seoul = calendar("Asia/Seoul")
        let monday = date("2026-10-11T15:00:00Z")
        var value = overview(at: monday, calendar: seoul)
        value.generatedAt = monday.addingTimeInterval(-1)
        XCTAssertNil(value.totals(for: .week, at: monday, calendar: seoul))
        XCTAssertEqual(value.totals(for: .month, at: monday, calendar: seoul)?.tokens, 1234)
        value.generatedAt = monday
        XCTAssertEqual(value.totals(for: .week, at: monday, calendar: seoul)?.tokens, 1234)
    }
}
