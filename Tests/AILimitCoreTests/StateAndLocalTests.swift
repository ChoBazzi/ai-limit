import XCTest
@testable import AILimitCore
import AILimitShared

actor MutableHTTP: HTTPTransport {
    var status = 200
    var delay: Duration = .zero
    var calls = 0
    func configure(status: Int, delay: Duration = .zero) { self.status = status; self.delay = delay }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        calls += 1; let captured = status; let wait = delay
        await Task.detached { try? await Task.sleep(for: wait) }.value
        return response("{\"individualUsage\":{\"plan\":{\"totalPercentUsed\":25}}}", status: captured)
    }
}
@MainActor
final class StateAndLocalTests: XCTestCase {
    func temporaryDirectory() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url }
    func testSingleFlightImmediateRefreshAndRateLimitDeferral() async throws {
        let directory = try temporaryDirectory(); let http = MutableHTTP()
        await http.configure(status: 200, delay: .milliseconds(40))
        let coordinator = UsageCoordinator(connections: [Connection(provider: .cursor, enabled: true, consentedAt: fixedNow)], secrets: SuppliedSecret("cookie=value"), http: http, store: SnapshotStore(groupURL: directory.appendingPathComponent("snapshot.json"), fallbackDirectory: directory), now: { fixedNow })
        async let first: Void = coordinator.refresh()
        async let second: Void = coordinator.refresh()
        _ = await (first, second)
        let count = await http.calls; XCTAssertEqual(count, 1)
        await coordinator.refresh()
        let afterMenu = await http.calls; XCTAssertEqual(afterMenu, 2)
        await http.configure(status: 429)
        await coordinator.refresh()
        await coordinator.refresh()
        let afterThrottle = await http.calls; XCTAssertEqual(afterThrottle, 3)
        let state = await coordinator.current().providers[0]
        XCTAssertEqual(state.retryAfter, fixedNow.addingTimeInterval(300))
        XCTAssertEqual(state.lastSuccess?.mostLimited?.remainingPercent, 75)
    }
    func testCoordinatorRetainsTimestampAndDiscardsDisconnectedGeneration() async throws {
        let directory = try temporaryDirectory(); let store = SnapshotStore(groupURL: directory.appendingPathComponent("snapshot-v1.json"), fallbackDirectory: directory); let http = MutableHTTP()
        let connection = Connection(provider: .cursor, enabled: true, consentedAt: fixedNow)
        let coordinator = UsageCoordinator(connections: [connection], secrets: SuppliedSecret("cookie=value"), http: http, store: store, now: { fixedNow })
        await coordinator.refresh(); let first = await coordinator.current(); XCTAssertEqual(first.providers[0].lastSuccess?.mostLimited?.remainingPercent, 75)
        await http.configure(status: 401); await coordinator.refresh(); let failed = await coordinator.current(); XCTAssertEqual(failed.providers[0].status, .needsAuthentication); XCTAssertEqual(failed.providers[0].lastSuccess?.fetchedAt, fixedNow)
        XCTAssertEqual(SnapshotReader.read(store.url)?.providers[0].lastSuccess?.mostLimited?.remainingPercent, 75); XCTAssertTrue(failed.providers[0].lastSuccess!.isStale(at: fixedNow.addingTimeInterval(960)))
        await http.configure(status: 200, delay: .milliseconds(100)); let inFlight = Task { await coordinator.refresh() }; try await Task.sleep(for: .milliseconds(20)); await coordinator.disconnect(connection.id); await inFlight.value
        let disconnected = await coordinator.current(); XCTAssertTrue(disconnected.providers.isEmpty); XCTAssertTrue(SnapshotReader.read(store.url)!.providers.isEmpty)
    }
    func testFailureIsolationAndReplacementClearsOldAccount() async throws {
        let directory = try temporaryDirectory(); let context = FixtureHTTP(responses: ["/api/usage-summary": response("{}", status: 401), "/v1/billing": response("{\"config\":{\"creditUsagePercent\":30}}")])
        let connections = [ProviderID.cursor, .grok].map { Connection(provider: $0, enabled: true, consentedAt: fixedNow) }
        struct Secrets: SecretStore { let cursorID: String; func load(_ accountID: String) throws -> String? { accountID == cursorID ? "cookie=value" : "bearer" }; func save(_ value: String, for accountID: String) throws {}; func remove(_ accountID: String) throws {}; func removeAll() throws {} }
        let coordinator = UsageCoordinator(connections: connections, secrets: Secrets(cursorID: connections[0].id), http: context, store: SnapshotStore(groupURL: directory.appendingPathComponent("snapshot.json"), fallbackDirectory: directory), now: { fixedNow })
        await coordinator.refresh(); let states = await coordinator.current().providers; XCTAssertEqual(states.map(\.status), [.needsAuthentication, .ready]); XCTAssertEqual(states[1].lastSuccess?.mostLimited?.remainingPercent, 70)
        await coordinator.replace(connections[1]); let after = await coordinator.current(); XCTAssertNil(after.providers.first { $0.provider == .grok }?.lastSuccess)
    }
    func codexLine(total: Int, at: String) -> String { "{\"type\":\"event_msg\",\"timestamp\":\"\(at)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":80,\"cached_input_tokens\":20,\"output_tokens\":20,\"reasoning_output_tokens\":5,\"total_tokens\":\(total)}}}}\n" }
    func testCodexLatestCumulativeArchiveDuplicatesAndTruncation() async throws {
        let root = try temporaryDirectory(); let active = root.appendingPathComponent("sessions"); let archive = root.appendingPathComponent("archived_sessions"); try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"same-session\"}}\n"
        let full = meta + codexLine(total: 100, at: "2026-09-28T10:00:00Z") + codexLine(total: 150, at: "2026-09-28T11:00:00Z")
        let file = active.appendingPathComponent("a.jsonl"); try Data(full.utf8).write(to: file); try Data(full.utf8).write(to: archive.appendingPathComponent("copy.jsonl"))
        let reader = LocalUsageReader(); let result = await reader.scan(accountID: "codex-account", provider: .codex, root: root, now: fixedNow); XCTAssertEqual(result.summaries[0].counters.total, 150); XCTAssertEqual(result.summaries[0].scope, "localSession")
        try FileManager.default.removeItem(at: archive.appendingPathComponent("copy.jsonl")); try Data((meta + codexLine(total: 90, at: "2026-09-28T12:00:00Z")).utf8).write(to: file, options: .atomic)
        let replaced = await reader.scan(accountID: "codex-account", provider: .codex, root: root, now: fixedNow); XCTAssertEqual(replaced.summaries[0].counters.total, 90)
        try Data((meta + codexLine(total: 300, at: "2026-09-28T13:00:00Z").dropLast()).utf8).write(to: file)
        let partial = await reader.scan(accountID: "codex-account", provider: .codex, root: root, now: fixedNow); XCTAssertEqual(partial.summaries[0].counters.total, 90); XCTAssertTrue(partial.summaries[0].isPartial)
    }
    func claudeLine(output: Int, at: String, stop: String = "\"end_turn\"", request: String = "request") -> String { "{\"type\":\"assistant\",\"timestamp\":\"\(at)\",\"requestId\":\"\(request)\",\"message\":{\"id\":\"message\",\"stop_reason\":\(stop),\"usage\":{\"input_tokens\":10,\"output_tokens\":\(output),\"cache_read_input_tokens\":3,\"cache_creation_input_tokens\":2}}}\n" }
    func testClaudeFinalCumulativeDedupeAndCacheTotal() async throws {
        let root = try temporaryDirectory(); let line = claudeLine(output: 5, at: "2026-09-28T10:00:00Z", stop: "null") + claudeLine(output: 20, at: "2026-09-28T10:01:00Z")
        try Data(line.utf8).write(to: root.appendingPathComponent("a.jsonl")); try Data(line.utf8).write(to: root.appendingPathComponent("copy.jsonl"))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reader = LocalUsageReader(); let result = await reader.scan(accountID: "claude-account", provider: .claude, root: root, now: ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!, calendar: calendar)
        XCTAssertEqual(result.summaries.count, 2); XCTAssertEqual(result.summaries[0].counters.output, 20); XCTAssertEqual(result.summaries[0].counters.total, 35); XCTAssertNil(result.summaries[0].counters.reasoning)
    }
    func testClaudeIncompleteConflictNegativeAndDST() async throws {
        let root = try temporaryDirectory(); let incomplete = "{\"type\":\"assistant\",\"timestamp\":\"2026-03-08T12:00:00Z\",\"requestId\":\"r\",\"message\":{\"id\":\"m\",\"stop_reason\":null,\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n"
        let file = root.appendingPathComponent("a.jsonl"); try Data(incomplete.utf8).write(to: file)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!; let now = ISO8601DateFormatter().date(from: "2026-03-08T20:00:00Z")!
        let reader = LocalUsageReader(); let missing = await reader.scan(accountID: "claude-account", provider: .claude, root: root, now: now, calendar: calendar); XCTAssertTrue(missing.summaries.isEmpty); XCTAssertNotNil(missing.message)
        try Data(claudeLine(output: 20, at: "2026-03-08T12:00:00Z").utf8).write(to: file)
        let valid = await reader.scan(accountID: "claude-account", provider: .claude, root: root, now: now, calendar: calendar); XCTAssertEqual(valid.summaries[0].periodEnd!.timeIntervalSince(valid.summaries[0].periodStart!), 23 * 3600)
        try Data((claudeLine(output: 20, at: "2026-03-08T12:00:00Z") + claudeLine(output: 30, at: "2026-03-08T12:00:00Z")).utf8).write(to: file)
        let conflict = await LocalUsageReader().scan(accountID: "claude-account", provider: .claude, root: root, now: now, calendar: calendar); XCTAssertTrue(conflict.summaries.isEmpty); XCTAssertNotNil(conflict.message)
        try Data(claudeLine(output: -1, at: "2026-03-08T12:00:00Z").utf8).write(to: file)
        let negative = await LocalUsageReader().scan(accountID: "claude-account", provider: .claude, root: root, now: now, calendar: calendar); XCTAssertTrue(negative.summaries.isEmpty); XCTAssertNotNil(negative.message)
    }
    func testUnavailableGroupUsesAppOnlyFallback() throws {
        let directory = try temporaryDirectory()
        let blocked = directory.appendingPathComponent("not-a-file")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let store = SnapshotStore(groupURL: blocked, fallbackDirectory: directory.appendingPathComponent("private"))
        let value = SharedSnapshot(updatedAt: fixedNow, providers: [ProviderState(provider: .codex)])
        XCTAssertFalse(try store.write(value))
        XCTAssertEqual(store.read()?.providers.map(\.provider), [.codex])
        XCTAssertNil(SnapshotReader.read(blocked))
    }
    func testCrossOriginRedirectNeverCarriesSession() {
        let origin = URL(string: "https://claude.ai/api/organizations")!
        XCTAssertTrue(RedirectPolicy.permits(from: origin, to: URL(string: "https://claude.ai:443/api/next")))
        for target in ["https://cursor.com/api", "http://claude.ai/api", "https://claude.ai:444/api", "https://claude.ai.attacker.invalid/"] {
            XCTAssertFalse(RedirectPolicy.permits(from: origin, to: URL(string: target)))
        }
    }
    func testHTTPSOriginRestriction() async {
        for url in ["http://claude.ai/api/organizations", "https://example.com/", "https://claude.ai:444/api/organizations"] { do { _ = try await SecureHTTPTransport().send(HTTPRequest(url)); XCTFail("Forbidden origin reached") } catch {} }
    }
}
