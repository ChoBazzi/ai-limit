import XCTest
import AILimitShared

final class SharedTitleAndOMPTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_683_200)

    func testLegacySnapshotTitlesMigrateWithoutChangingObservationsOrFailureState() throws {
        for version in [1, 2] {
            let identity = version == 2 ? #", "connectionID":"codex", "accountName":"기본 계정""# : ""
            let data = Data("""
            {"schemaVersion":\(version),"updatedAt":"2026-09-29T00:00:00Z","displayOrder":["codex"],"providers":[
              {"provider":"codex","status":"needsAuthentication","message":"다시 연결","localTokens":[]\(identity),"lastSuccess":{
                "provider":"codex","plan":"Plus","windows":[
                  {"id":"primary","title":"기본한도 - 18000초","used":7,"limit":10,"remaining":3,"usedPercent":42,"unit":{"percent":{}},"unlimited":false,"resetsAt":"2026-09-29T01:00:00Z","resetDescription":"원본 리셋"},
                  {"id":"secondary","title":"Spark · 추가 기간 한도 · 604800초","used":2,"limit":4,"unit":{"percent":{}},"unlimited":false}
                ],"balances":[],"source":"unofficialWeb","fetchedAt":"2026-09-28T23:00:00Z"}}
            ]}
            """.utf8)
            let decoded = try SharedSnapshot.decode(data)
            let state = try XCTUnwrap(decoded.orderedProviders(selection: ["codex"]).first)
            let usage = try XCTUnwrap(state.lastSuccess)
            XCTAssertEqual(state.status, .needsAuthentication)
            XCTAssertEqual(state.message, "다시 연결")
            XCTAssertEqual(usage.plan, "Plus")
            XCTAssertEqual(usage.windows.map(\.title), ["5시간 한도", "Spark · 주간 한도"])
            XCTAssertEqual(usage.windows.map(\.id), ["primary", "secondary"])
            XCTAssertEqual(usage.windows[0].used, 7)
            XCTAssertEqual(usage.windows[0].limit, 10)
            XCTAssertEqual(usage.windows[0].remaining, 3)
            XCTAssertEqual(usage.windows[0].usedPercent, 42)
            XCTAssertEqual(usage.mostLimited?.remainingPercent, 58)
            XCTAssertNil(usage.windows[1].usedPercent)
            XCTAssertEqual(usage.windows[0].unit, .percent)
            XCTAssertFalse(usage.windows[0].unlimited)
            XCTAssertEqual(usage.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-09-29T01:00:00Z"))
            XCTAssertEqual(usage.windows[0].resetDescription, "원본 리셋")
            XCTAssertEqual(usage.fetchedAt, ISO8601DateFormatter().date(from: "2026-09-28T23:00:00Z"))
            XCTAssertEqual(usage.source, .unofficialWeb)
            let roundTrip = try SharedSnapshot.decode(decoded.encoded())
            XCTAssertEqual(roundTrip.providers[0].lastSuccess?.windows.map(\.title), usage.windows.map(\.title))
            XCTAssertEqual(roundTrip.providers[0].status, state.status)
        }
    }

    func testInitializedCodexTitlesUseOnlyReportedDurationAndKeepUnrelatedNames() {
        let titles = ["기본 한도 · 61초", "추가기간한도", "기본한도 - 000초", "Spark · 기본 한도 - 604800초",
                      "Spark - 18000초", "기본한도 모델 · 18000초", "Spark · 한도 · 18000초", "Spark · 5시간 한도"]
        let windows = titles.enumerated().map { QuotaWindow(id: String($0.offset), title: $0.element, usedPercent: 25) }
        let codex = UsageSnapshot(provider: .codex, windows: windows, source: .unofficialWeb, fetchedAt: now)
        XCTAssertEqual(codex.windows.map(\.title), ["사용 한도", "한도 · 기간 미제공", "한도 · 기간 미제공", "Spark · 주간 한도"] + Array(titles.suffix(4)))
        XCTAssertEqual(codex.windows.map(\.remainingPercent), Array(repeating: 75, count: titles.count))
        let claude = UsageSnapshot(provider: .claude, windows: windows, source: .unofficialWeb, fetchedAt: now)
        XCTAssertEqual(claude.windows.map(\.title), titles)
    }

    func testOMPSessionSelectionKeepsCumulativeValueAndIndependentHealth() {
        let history = TokenSummary(scope: "ompHistory", counters: TokenCounters(total: 999), observedAt: now)
        let session = TokenSummary(scope: "ompSession", counters: TokenCounters(total: 37), observedAt: now.addingTimeInterval(-900), isPartial: true)
        let state = ProviderState(provider: .codex, status: .ready, localTokens: [history, session], localMessage: "읽기 실패")
        XCTAssertEqual(UsageFormat.localTokens(state, at: now), "이 Mac OMP 최근 세션 · 37 토큰 · 일부 기록 · 오래됨 · 확인 필요")
    }

    func testOMPHistoryKeepsAbsentDistinctFromZeroAndUsesCivilDayScope() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        var summary = TokenSummary(scope: "ompHistory", counters: TokenCounters(), observedAt: now, periodStart: start, periodEnd: end)
        var state = ProviderState(provider: .claude, localTokens: [summary])
        XCTAssertEqual(UsageFormat.localTokens(state, at: now), "이 Mac OMP 오늘 · 토큰 수 미제공")
        summary.counters = TokenCounters(total: 0)
        state.localTokens = [summary]
        XCTAssertEqual(UsageFormat.localTokens(state, at: now), "이 Mac OMP 오늘 · 0 토큰")
        summary.periodStart = calendar.date(byAdding: .day, value: -6, to: start)!
        summary.counters = TokenCounters(input: 17, output: 0)
        state.localTokens = [summary]
        XCTAssertEqual(UsageFormat.localTokens(state, at: now), "이 Mac OMP 최근 7일 · 입력 17 · 출력 0")
    }
}
