import XCTest
import AILimitCore
import AILimitShared

@MainActor
final class CalendarResetTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func usage(_ window: QuotaWindow, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(provider: .copilot, windows: [window], source: .publicCLI, fetchedAt: fetchedAt)
    }
    private func roundTrip(_ value: UsageSnapshot) throws -> UsageSnapshot {
        try XCTUnwrap(SharedSnapshot.decode(SharedSnapshot(updatedAt: value.fetchedAt, providers: [
            ProviderState(provider: value.provider, status: .ready, lastSuccess: value)
        ]).encoded()).providers.first?.lastSuccess)
    }

    func testCopilotCivilDateSurvivesBothProvidersSharingAndTimezoneChanges() async throws {
        let body = #"{"quota_reset_date":"2026-10-22","quota_snapshots":{"chat":{"percent_remaining":75}}}"#
        let cli = try await CopilotProvider().fetch(context: testContext(.copilot, cli: Data(("HTTP/2.0 200 OK\n\n" + body).utf8)))
        let direct = try await CopilotDirectProvider().fetch(context: testContext(.copilot, responses: [
            "/user": response(#"{"id":1}"#), "/copilot_internal/user": response(body)
        ]), credential: DirectCredential(provider: .copilot, accessToken: "fixture", metadata: ["userID": "1"]))
        for original in [cli, direct] {
            let restored = try roundTrip(original)
            let window = try XCTUnwrap(restored.windows.first)
            XCTAssertEqual(window.resetDate?.rawValue, "2026-10-22")
            XCTAssertNil(window.resetsAt)
            XCTAssertEqual(restored.mostLimited?.remainingPercent, 75)
            XCTAssertEqual(UsageFormat.summaryWindows(restored, maximum: 1).first?.id, window.id)
            for zone in ["America/Los_Angeles", "Asia/Seoul", "America/Los_Angeles"] {
                let local = calendar(zone)
                let now = instant("2026-10-22T12:00:00Z")
                XCTAssertTrue(UsageFormat.resetSummary(window, at: now, calendar: local).contains("2026-10-22"))
                XCTAssertTrue(UsageFormat.resetLabel(window, at: now, calendar: local).contains("2026-10-22"))
                XCTAssertNil(UsageFormat.resetTime(window, at: now))
                let boundary = try XCTUnwrap(window.resetBoundary(calendar: local))
                XCTAssertEqual(local.dateComponents([.year, .month, .day, .hour], from: boundary), DateComponents(year: 2026, month: 10, day: 23, hour: 0))
            }
        }
    }

    func testCivilDayExpiresOnlyAtNextLocalDayAndOrdinaryAgeStillApplies() throws {
        let window = QuotaWindow(id: "monthly", title: "월간", usedPercent: 20, resetPrecision: .dateOnly, resetDate: ResetCalendarDate("2026-10-22"))
        for zone in ["America/Los_Angeles", "Asia/Seoul"] {
            let local = calendar(zone)
            let boundary = try XCTUnwrap(window.resetBoundary(calendar: local))
            for offset in [-86_400.0, -43_200, -1, 0, 1] {
                let now = boundary.addingTimeInterval(offset)
                let fresh = usage(window, fetchedAt: now)
                let state = ProviderState(provider: .copilot, status: .ready, lastSuccess: fresh)
                XCTAssertEqual(window.hasResetElapsed(at: now, calendar: local), offset >= 0)
                XCTAssertEqual(fresh.isStale(at: now, calendar: local), offset >= 0)
                XCTAssertEqual(UsageFormat.observationIssue(state, at: now, calendar: local) != nil, offset >= 0)
                XCTAssertEqual(UsageFormat.resetSummary(window, at: now, calendar: local).contains("지남"), offset >= 0)
                XCTAssertEqual(UsageFormat.resetLabel(window, at: now, calendar: local).contains("지남"), offset >= 0)
            }
            let noon = boundary.addingTimeInterval(-43_200)
            let observed = usage(window, fetchedAt: noon)
            XCTAssertFalse(observed.isStale(at: noon.addingTimeInterval(899), calendar: local))
            XCTAssertTrue(observed.isStale(at: noon.addingTimeInterval(900), calendar: local))
        }
    }

    func testKiroTodayIsFreshAndYearlessTodayDoesNotRollForward() async throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let components = local.dateComponents([.year, .month, .day], from: fixedNow)
        let civil = String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
        for reported in [civil, "\(components.month!)/\(components.day!)"] {
            let output = "Plan: KIRO PRO\n(10 of 50 covered in plan)\nresets on \(reported)"
            let value = try await KiroProvider().fetch(context: testContext(.kiro, cli: Data(output.utf8)))
            let restored = try roundTrip(value)
            let window = try XCTUnwrap(restored.windows.first)
            XCTAssertEqual(window.resetDate?.rawValue, civil)
            XCTAssertNil(window.resetsAt)
            XCTAssertFalse(restored.isStale(at: fixedNow))
            XCTAssertNil(UsageFormat.observationIssue(ProviderState(provider: .kiro, status: .ready, lastSuccess: restored), at: fixedNow))
            XCTAssertTrue(UsageFormat.resetDisplay(window, at: fixedNow).contains(civil))
        }
    }

    func testExactResetAndResetCreditExpiryRetainInstantBoundaries() throws {
        let reset = instant("2026-10-22T13:30:00Z")
        let exact = QuotaWindow(id: "exact", title: "한도", usedPercent: 30, resetsAt: reset, resetPrecision: .exact)
        let snapshot = try roundTrip(usage(exact, fetchedAt: reset.addingTimeInterval(-60)))
        XCTAssertFalse(snapshot.isStale(at: reset.addingTimeInterval(-1)))
        XCTAssertTrue(snapshot.isStale(at: reset))
        XCTAssertNotNil(UsageFormat.resetTime(exact, at: reset))
        XCTAssertEqual(UsageFormat.resetSummary(exact, at: reset.addingTimeInterval(-60)), "1분 후 리셋")
        XCTAssertTrue(UsageFormat.resetLabel(exact, at: reset).contains("지남"))
        let credits = UsageSnapshot(provider: .codex, source: .publicCLI, fetchedAt: reset.addingTimeInterval(-60), resetCredits: ResetCredits(availableCount: 1, credits: [ResetCredit(expiresAt: reset)]))
        XCTAssertFalse(credits.isStale(at: reset.addingTimeInterval(-1)))
        XCTAssertTrue(credits.isStale(at: reset))
        XCTAssertTrue(UsageFormat.observationIssue(ProviderState(provider: .codex, status: .ready, lastSuccess: credits), at: reset)?.contains("사용기한 지남") == true)
    }

    func testUncertainAndLegacyResetDatesDoNotInventElapsedInstants() throws {
        let now = instant("2026-10-22T12:00:00Z")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for precision in ["", #", "resetPrecision":null"#, #", "resetPrecision":"unknown""#, #", "resetPrecision":"approximate""#, #", "resetPrecision":"dateOnly""#, #", "resetPrecision":"futureValue""#] {
            let json = #"{"id":"quota","title":"한도","unit":{"percent":{}},"unlimited":false,"usedPercent":30,"resetsAt":"2026-10-21T00:00:00Z"\#(precision)}"#
            let original = try decoder.decode(QuotaWindow.self, from: Data(json.utf8))
            let restored = try roundTrip(usage(original, fetchedAt: now))
            let window = restored.windows[0]
            XCTAssertNil(window.resetBoundary())
            XCTAssertNil(UsageFormat.resetTime(window, at: now))
            XCTAssertFalse(restored.isStale(at: now))
            XCTAssertNil(UsageFormat.observationIssue(ProviderState(provider: .copilot, status: .ready, lastSuccess: restored), at: now))
            XCTAssertFalse(UsageFormat.resetSummary(window, at: now).contains("지남"))
            XCTAssertFalse(UsageFormat.resetLabel(window, at: now).contains("지남"))
            XCTAssertTrue(restored.isStale(at: now.addingTimeInterval(900)))
            XCTAssertEqual(window.resetsAt, original.resetsAt)
        }
    }

    func testCivilDateValidationAndDSTBoundary() throws {
        for invalid in ["2026-02-29", "2026-13-01", "2026-04-31", "0000-01-01", "2026-1-01"] {
            XCTAssertNil(ResetCalendarDate(invalid))
            XCTAssertThrowsError(try JSONDecoder().decode(ResetCalendarDate.self, from: Data("\"\(invalid)\"".utf8)))
        }
        let local = calendar("America/Los_Angeles")
        let date = try XCTUnwrap(ResetCalendarDate("2026-11-01"))
        XCTAssertEqual(date.endBoundary(calendar: local), instant("2026-11-02T08:00:00Z"))
    }
}
