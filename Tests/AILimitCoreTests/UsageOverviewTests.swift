import XCTest
@testable import AILimitCore
import AILimitShared

private actor OverviewHeldHTTP: HTTPTransport {
    private var arrived = false
    private var cancelled = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var cancellation: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func waitForRequest() async {
        if !arrived { await withCheckedContinuation { arrival = $0 } }
    }
    func waitForCancellation() async {
        if !cancelled { await withCheckedContinuation { cancellation = $0 } }
    }
    private func didCancel() { cancelled = true; cancellation?.resume(); cancellation = nil }
    func finish() { release?.resume(); release = nil }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                release = $0; arrived = true; arrival?.resume(); arrival = nil
            }
        } onCancel: { Task { await self.didCancel() } }
        return response("{}", status: 401)
    }
}

@MainActor
final class UsageOverviewTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-12T20:00:00Z")!
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func calendar(_ zone: String = "UTC") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func save(_ text: String, at root: URL, name: String = "usage.jsonl") throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(name), options: .atomic)
    }
    private func header(_ session: String = "private-session") -> String {
        "{\"type\":\"session\",\"version\":3,\"id\":\"\(session)\"}\n"
    }
    private func entry(_ id: String, at: String = "2026-10-12T12:00:00Z", model: String = "claude-sonnet-4-5", usage: String = "\"input\":100,\"output\":20,\"cacheRead\":10,\"cacheWrite\":0") -> String {
        "{\"type\":\"message\",\"id\":\"\(id)\",\"timestamp\":\"\(at)\",\"message\":{\"role\":\"assistant\",\"provider\":\"anthropic\",\"model\":\"\(model)\",\"content\":[{\"type\":\"text\",\"text\":\"private-prompt-marker\"}],\"usage\":{\(usage)}}}\n"
    }
    private func connection(_ id: String, root: URL, provider: ProviderID = .claude, source: LocalTokenSource = .omp) -> Connection {
        Connection(provider: provider, localFolder: root, localConsentedAt: now, id: id, localSource: source)
    }
    private func facts(_ root: URL, provider: ProviderID = .claude, source: LocalTokenSource = .omp, at: Date? = nil) async throws -> LocalOverviewFacts {
        let scan = await LocalUsageReader().scan(accountID: "synthetic", provider: provider, root: root, now: at ?? now, source: source)
        return try XCTUnwrap(scan.overviewFacts)
    }

    func testIncompleteRefreshDoesNotRestampRetainedAccountSummaryIntoNewPeriods() async throws {
        let root = try directory()
        try save(header() + entry("one"), at: root)
        let reader = LocalUsageReader()
        let first = await reader.scan(accountID: "same", provider: .claude, root: root, now: now, source: .omp)
        XCTAssertEqual(first.summaries.first?.counters.total, 130)
        try save(header() + String(entry("unfinished").dropLast()), at: root)
        let later = date("2026-11-02T20:00:00Z")
        let second = await reader.scan(accountID: "same", provider: .claude, root: root, now: later, source: .omp)
        XCTAssertEqual(second.summaries.first?.counters.total, 130)
        XCTAssertEqual(second.summaries.first?.observedAt, first.summaries.first?.observedAt)
        let overview = try XCTUnwrap(LocalUsageOverview.aggregate([try XCTUnwrap(second.overviewFacts)], now: later, calendar: calendar()))
        XCTAssertEqual(overview.generatedAt, later)
        XCTAssertTrue(overview.isPartial)
        XCTAssertTrue(overview.periods.allSatisfy { $0.tokens == nil && $0.estimatedUSD == nil })
        let old = try XCTUnwrap(first.overviewFacts)
        let stale = try XCTUnwrap(LocalUsageOverview.aggregate([old], now: later, calendar: calendar()))
        XCTAssertEqual(stale.generatedAt, now)
        XCTAssertTrue(stale.periods.allSatisfy { $0.tokens == nil })
    }

    func testDisconnectDiscardsLateCollectionWithoutRemovingSiblingFacts() async throws {
        let aRoot = try directory()
        let bRoot = try directory()
        try save(header() + entry("a"), at: aRoot)
        try save(header() + entry("b"), at: bRoot)
        var a = connection("a", root: aRoot)
        let b = connection("b", root: bRoot)
        let fixed = now
        let transport = OverviewHeldHTTP()
        let store = SnapshotStore(groupURL: aRoot.appendingPathComponent("shared.json"), fallbackDirectory: aRoot)
        let coordinator = UsageCoordinator(connections: [a, b], secrets: SuppliedSecret("sessionKey=synthetic"), http: transport, store: store, now: { fixed })
        await coordinator.refresh()
        let before = await coordinator.current()
        XCTAssertEqual(before.usageOverview?.periods.first?.tokens, 260)
        a.enabled = true; a.consentedAt = now; a.credentialReference = a.id
        await coordinator.replace(a)
        let refresh = Task { await coordinator.refresh(only: a.id) }
        await transport.waitForRequest()
        let disconnect = Task { await coordinator.disconnect(a.id) }
        await transport.waitForCancellation()
        await transport.finish()
        await refresh.value
        await disconnect.value
        let after = await coordinator.current()
        XCTAssertEqual(after.providers.map(\.connectionID), [b.id])
        XCTAssertEqual(after.usageOverview?.periods.first?.tokens, 130)
        XCTAssertEqual(store.read()?.usageOverview?.periods.first?.tokens, 130)
    }

    func testRepeatedShortIDsAtDifferentTimesAndDistinctNativeRequestsStaySeparate() async throws {
        let root = try directory()
        try save(header("first") + entry("short", at: "2026-10-12T11:00:00Z"), at: root)
        try save(header("second") + entry("short", at: "2026-10-12T12:00:00Z"), at: root, name: "second.jsonl")
        let scan = try await facts(root)
        let overview = LocalUsageOverview.aggregate([scan], now: now)
        XCTAssertEqual(overview?.periods.first?.recordCount, 2)
        XCTAssertEqual(overview?.periods.first?.tokens, 260)
        XCTAssertEqual(overview?.periods.first?.estimatedUSD, Decimal(string: "0.001206"))
        let native = try directory()
        let rows = ["first-request", "second-request"].map { request in
            "{\"type\":\"assistant\",\"requestId\":\"\(request)\",\"timestamp\":\"2026-10-12T12:00:00Z\",\"message\":{\"id\":\"shared-message\",\"model\":\"claude-sonnet-4-5\",\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20,\"cache_read_input_tokens\":10,\"cache_creation_input_tokens\":0}}}\n"
        }.joined()
        try save(rows, at: native)
        let nativeScan = try await facts(native, source: .native)
        let nativeOverview = LocalUsageOverview.aggregate([nativeScan], now: now)
        XCTAssertEqual(nativeOverview?.periods.first?.recordCount, 2)
        XCTAssertEqual(nativeOverview?.periods.first?.tokens, 260)
        XCTAssertEqual(nativeOverview?.periods.first?.estimatedUSD, Decimal(string: "0.001206"))
    }

    func testUnpricedCompleteRecordsDoNotMarkTokenCoveragePartial() async throws {
        let root = try directory()
        try save(header() + entry("unknown-model", model: "unpublished-model"), at: root)
        let scan = try await facts(root)
        let overview = try XCTUnwrap(LocalUsageOverview.aggregate([scan], now: now))
        XCTAssertEqual(overview.periods.first?.tokens, 130)
        XCTAssertEqual(overview.periods.first?.unpricedRecords, 1)
        XCTAssertNil(overview.periods.first?.estimatedUSD)
        XCTAssertFalse(overview.periods.first?.isPartial ?? true)
        XCTAssertFalse(overview.isPartial)
    }

    func testCoordinatorDeduplicatesSameAndOverlappingFoldersAndForksBeforePricing() async throws {
        let root = try directory()
        let child = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let inherited = entry("private-request-id")
        try save(header() + inherited, at: child)
        try save(header("fork") + inherited + entry("unique"), at: root, name: "fork.jsonl")
        let fixed = now
        let store = SnapshotStore(groupURL: root.appendingPathComponent("shared.json"), fallbackDirectory: root)
        let coordinator = UsageCoordinator(connections: [connection("a", root: root), connection("b", root: root), connection("c", root: child)], store: store, now: { fixed })
        await coordinator.refresh()
        let snapshot = await coordinator.current()
        let overview = try XCTUnwrap(snapshot.usageOverview)
        for period in overview.periods {
            XCTAssertEqual(period.recordCount, 2)
            XCTAssertEqual(period.tokens, 260)
            XCTAssertEqual(period.estimatedUSD, Decimal(string: "0.001206"))
            XCTAssertEqual(period.unpricedRecords, 0)
        }
        let persisted = try XCTUnwrap(store.read()?.usageOverview)
        XCTAssertEqual(persisted.periods.first?.tokens, 260)
        let encoded = String(decoding: try snapshot.encoded(), as: UTF8.self)
        for secret in [root.path, "private-session", "private-request-id", "private-prompt-marker", "claude-sonnet-4-5"] { XCTAssertFalse(encoded.contains(secret)) }
        await coordinator.disconnect("a")
        let afterFirst = await coordinator.current()
        XCTAssertEqual(afterFirst.usageOverview?.periods.first?.tokens, 260)
        await coordinator.disconnect("b")
        let afterSecond = await coordinator.current()
        XCTAssertEqual(afterSecond.usageOverview?.periods.first?.tokens, 130)
        await coordinator.disconnect("c")
        let empty = await coordinator.current()
        XCTAssertNil(empty.usageOverview)
    }

    func testSourceChangeAndStartupNeverReuseUnprovenancedOverview() async throws {
        let root = try directory()
        try save(header() + entry("one"), at: root)
        let fixed = now
        let store = SnapshotStore(groupURL: root.appendingPathComponent("shared.json"), fallbackDirectory: root)
        var account = connection("account", root: root)
        let coordinator = UsageCoordinator(connections: [account], store: store, now: { fixed })
        await coordinator.refresh()
        account.localSource = .native
        let restarted = UsageCoordinator(connections: [account], store: store, now: { fixed })
        let cached = await restarted.current()
        XCTAssertNil(cached.usageOverview)
        await coordinator.replace(account)
        let changed = await coordinator.current()
        XCTAssertNil(changed.usageOverview)
        await coordinator.refresh()
        let rescanned = await coordinator.current()
        XCTAssertNil(rescanned.usageOverview?.periods.first?.tokens)
        account.localConsentedAt = nil
        await coordinator.replace(account)
        await coordinator.refresh()
        let revoked = await coordinator.current()
        XCTAssertNil(revoked.usageOverview)
    }

    func testCivilWeekMonthDSTYearAndFutureBoundaries() async throws {
        let root = try directory()
        // Monday midnight is 08:00Z before the spring DST transition.
        let end = date("2026-03-08T20:00:00Z")
        try save(header() + entry("before", at: "2026-03-02T07:59:59Z") + entry("monday", at: "2026-03-02T08:00:00Z") + entry("now", at: "2026-03-08T20:00:00Z") + entry("future", at: "2026-03-08T20:00:01Z") + entry("previous-month", at: "2026-03-01T07:59:59Z"), at: root)
        let scan = try await facts(root, at: end)
        let overview = try XCTUnwrap(LocalUsageOverview.aggregate([scan], now: end, calendar: calendar("America/Los_Angeles")))
        let week = try XCTUnwrap(overview.totals(for: .week, at: end, calendar: calendar("America/Los_Angeles")))
        XCTAssertEqual(week.start, date("2026-03-02T08:00:00Z"))
        XCTAssertEqual(week.end, date("2026-03-09T07:00:00Z"))
        XCTAssertEqual(week.tokens, 260)
        XCTAssertEqual(overview.totals(for: .month, at: end, calendar: calendar("America/Los_Angeles"))?.tokens, 390)
        XCTAssertNil(overview.totals(for: .week, at: date("2026-03-09T07:00:00Z"), calendar: calendar("America/Los_Angeles")))
        let newYear = date("2027-01-01T12:00:00Z")
        XCTAssertEqual(UsagePeriod.week.interval(containing: newYear, calendar: calendar())?.start, date("2026-12-28T00:00:00Z"))
        XCTAssertEqual(UsagePeriod.month.interval(containing: newYear, calendar: calendar())?.start, date("2027-01-01T00:00:00Z"))
    }

    func testUnknownModelMissingTotalsAndExplicitZeroRemainDistinct() async throws {
        let root = try directory()
        try save(header() + entry("unknown", model: "not-a-tariff") + entry("incomplete", usage: "\"input\":10") + entry("zero", usage: "\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0"), at: root)
        let scan = try await facts(root)
        let overview = try XCTUnwrap(LocalUsageOverview.aggregate([scan], now: now, calendar: calendar()))
        let week = try XCTUnwrap(overview.totals(for: .week, at: now, calendar: calendar()))
        XCTAssertEqual(week.tokens, 130)
        XCTAssertEqual(week.recordCount, 3)
        XCTAssertEqual(week.missingTokenRecords, 1)
        XCTAssertEqual(week.unpricedRecords, 2)
        XCTAssertEqual(week.estimatedUSD, 0)
        XCTAssertTrue(week.isPartial)
        let empty = try directory()
        let emptyScan = try await facts(empty)
        let noRecords = LocalUsageOverview.aggregate([emptyScan], now: now, calendar: calendar())
        XCTAssertNil(noRecords?.periods.first?.tokens)
        XCTAssertNil(noRecords?.periods.first?.estimatedUSD)
    }

    func testNativeCodexRetainsSessionButNeverAddsCumulativePeriodTokens() async throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try save("{\"type\":\"session_meta\",\"payload\":{\"id\":\"native\"}}\n{\"type\":\"event_msg\",\"timestamp\":\"2026-10-12T12:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"output_tokens\":50,\"total_tokens\":150}}}}\n", at: sessions)
        let scan = await LocalUsageReader().scan(accountID: "native", provider: .codex, root: root, now: now)
        XCTAssertEqual(scan.summaries.first?.counters.total, 150)
        let overview = try XCTUnwrap(LocalUsageOverview.aggregate([try XCTUnwrap(scan.overviewFacts)], now: now))
        XCTAssertNil(overview.periods.first?.tokens)
        XCTAssertNil(overview.periods.first?.estimatedUSD)
        XCTAssertTrue(overview.isPartial)
        XCTAssertTrue(overview.notes.contains { $0.contains("OMP") })
    }

    func testNativeClaudeRevisionDedupeAndLongCachePricing() async throws {
        let root = try directory()
        func native(_ output: Int, timestamp: String, long: Int = 40) -> String {
            "{\"type\":\"assistant\",\"requestId\":\"req\",\"timestamp\":\"\(timestamp)\",\"message\":{\"id\":\"msg\",\"model\":\"claude-sonnet-4-5\",\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":100,\"output_tokens\":\(output),\"cache_read_input_tokens\":10,\"cache_creation_input_tokens\":100,\"cache_creation\":{\"ephemeral_5m_input_tokens\":60,\"ephemeral_1h_input_tokens\":\(long)}}}}\n"
        }
        try save(native(5, timestamp: "2026-10-12T11:00:00Z") + native(20, timestamp: "2026-10-12T12:00:00Z"), at: root)
        let scan = try await facts(root, source: .native)
        let overview = LocalUsageOverview.aggregate([scan, scan], now: now)
        XCTAssertEqual(overview?.periods.first?.tokens, 230)
        XCTAssertEqual(overview?.periods.first?.estimatedUSD, Decimal(string: "0.001068"))
        try save(native(20, timestamp: "2026-10-12T12:00:00Z", long: 50), at: root)
        let invalid = try await facts(root, source: .native)
        let unpriced = LocalUsageOverview.aggregate([invalid], now: now)
        XCTAssertEqual(unpriced?.periods.first?.tokens, 230)
        XCTAssertNil(unpriced?.periods.first?.estimatedUSD)
        XCTAssertEqual(unpriced?.periods.first?.unpricedRecords, 1)
    }

    func testConflictingForkAndOverflowDoNotBecomePlausibleTotals() async throws {
        let root = try directory()
        try save(header("a") + entry("same"), at: root)
        try save(header("b") + entry("same", model: "unknown"), at: root, name: "fork.jsonl")
        let conflict = try await facts(root)
        let excluded = LocalUsageOverview.aggregate([conflict], now: now)
        XCTAssertNil(excluded?.periods.first?.tokens)
        XCTAssertTrue(excluded?.isPartial == true)
        let large = try directory()
        try save(header() + entry("max", usage: "\"totalTokens\":9223372036854775807") + entry("one", usage: "\"totalTokens\":1"), at: large)
        let overflow = try await facts(large)
        let result = LocalUsageOverview.aggregate([overflow], now: now)
        XCTAssertNil(result?.periods.first?.tokens)
        XCTAssertEqual(result?.periods.first?.recordCount, 2)
        XCTAssertTrue(result?.isPartial == true)
    }
}
