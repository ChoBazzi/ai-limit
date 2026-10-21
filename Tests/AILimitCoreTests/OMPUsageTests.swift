import XCTest
@testable import AILimitCore
import AILimitShared

@MainActor
final class OMPUsageTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-03-08T20:00:00Z")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func header(_ id: String = "session", version: Int = 3) -> String {
        "{\"type\":\"session\",\"version\":\(version),\"id\":\"\(id)\"}\n"
    }
    private func entry(_ id: String, provider: String = "openai-codex", at: String = "2026-03-08T12:00:00Z", usage: String = "\"input\":10,\"output\":5,\"cacheRead\":3,\"cacheWrite\":2", role: String = "assistant") -> String {
        "{\"type\":\"message\",\"id\":\"\(id)\",\"timestamp\":\"\(at)\",\"message\":{\"role\":\"\(role)\",\"provider\":\"\(provider)\",\"usage\":{\(usage)}}}\n"
    }
    private func save(_ text: String, root: URL, file: String = "a.jsonl") throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(file), options: .atomic)
    }
    private func scan(_ root: URL, provider: ProviderID = .codex, reader: LocalUsageReader = LocalUsageReader(), source: LocalTokenSource = .omp) async -> LocalScanResult {
        await reader.scan(accountID: "local-account", provider: provider, root: root, now: now, calendar: calendar, source: source)
    }

    func testMixedProvidersRecursiveCopiesAndNormalizedTotals() async throws {
        let root = try directory()
        let nested = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let text = header() + entry("one", usage: "\"input\":10,\"output\":5,\"cacheRead\":30,\"cacheWrite\":2,\"reasoningTokens\":4")
            + entry("two", provider: "anthropic") + entry("three", provider: "openai")
            + entry("four", role: "user") + entry("five", role: "toolResult")
        try save(text, root: nested)
        try save(text, root: root, file: "copy.jsonl")
        let codex = await scan(root)
        XCTAssertEqual(codex.summaries.map(\.counters.total), [47, 47, 47])
        XCTAssertEqual(codex.summaries[0].counters.input, 10)
        XCTAssertEqual(codex.summaries[0].counters.cacheRead, 30)
        XCTAssertEqual(codex.summaries[0].counters.reasoning, 4)
        XCTAssertFalse(codex.summaries[0].isPartial)
        let claude = await scan(root, provider: .claude)
        XCTAssertEqual(claude.summaries.map(\.counters.total), [20, 20, 20])
    }

    func testConflictingRevisionsExcludedRegardlessOfOrderAndTimestamp() async throws {
        for reversed in [false, true] {
            let root = try directory()
            let old = entry("collision")
            let newer = entry("collision", at: "2026-03-08T13:00:00Z", usage: "\"input\":10,\"output\":50,\"cacheRead\":3,\"cacheWrite\":2")
            try save(header() + (reversed ? newer + old : old + newer) + entry("good"), root: root)
            let result = await scan(root)
            XCTAssertEqual(result.summaries.map(\.counters.total), [20, 20, 20])
            XCTAssertTrue(result.summaries.allSatisfy(\.isPartial))
        }
        let root = try directory()
        try save(header() + entry("bad") + entry("bad", usage: "\"input\":-1"), root: root)
        let malformedRevision = await scan(root)
        XCTAssertTrue(malformedRevision.summaries.isEmpty)
        XCTAssertNotNil(malformedRevision.message)
        try save(header() + entry("provider-conflict") + entry("provider-conflict", provider: "anthropic"), root: root)
        let changedProvider = await scan(root)
        XCTAssertTrue(changedProvider.summaries.isEmpty)
        XCTAssertNotNil(changedProvider.message)
    }

    func testForkInheritanceIsNotCountedTwiceAndUnknownLineageIsPartial() async throws {
        let root = try directory()
        let inherited = entry("inherited")
        try save(header("parent") + inherited, root: root)
        let forkHeader = "{\"type\":\"title\",\"title\":\"ignored\"}\n{\"type\":\"session\",\"version\":3,\"id\":\"fork\",\"parentSession\":\"parent\"}\n"
        try save(forkHeader + inherited + entry("new", at: "2026-03-08T14:00:00Z"), root: root, file: "fork.jsonl")
        let fork = await scan(root)
        XCTAssertEqual(fork.summaries.map(\.counters.total), [40, 40, 40])
        XCTAssertFalse(fork.summaries[0].isPartial)
        // Removing the parent leaves an opaque unresolved lineage marker; the reader
        // may show retained local records but cannot claim complete period coverage.
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.jsonl"))
        let orphan = await scan(root)
        XCTAssertEqual(orphan.summaries.map(\.counters.total), [40, 40, 40])
        XCTAssertTrue(orphan.summaries.allSatisfy(\.isPartial))
        let externalHeader = "{\"type\":\"session\",\"version\":3,\"id\":\"fork\",\"parentSession\":\"/outside-consent/private.jsonl\"}\n"
        try save(externalHeader + inherited, root: root, file: "fork.jsonl")
        let opaque = await scan(root)
        XCTAssertEqual(opaque.summaries.map(\.counters.total), [20, 20, 20])
        XCTAssertTrue(opaque.summaries.allSatisfy(\.isPartial))
    }

    func testExplicitZeroMissingFieldsAuthoritativeTotalAndOverflow() async throws {
        let root = try directory()
        try save(header() + entry("zero", usage: "\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":0"), root: root)
        let zero = await scan(root)
        XCTAssertEqual(zero.summaries[0].counters.total, 0)
        XCTAssertFalse(zero.summaries[0].isPartial)
        try save(header() + entry("missing", usage: "\"input\":0,\"totalTokens\":19"), root: root)
        let missing = await scan(root)
        XCTAssertEqual(missing.summaries[0].counters.total, 19)
        XCTAssertNil(missing.summaries[0].counters.output)
        XCTAssertNil(missing.summaries[0].counters.cacheRead)
        try save(header() + entry("missing", usage: "\"input\":0"), root: root)
        let missingTotal = await scan(root)
        XCTAssertNil(missingTotal.summaries[0].counters.total)
        for usage in ["", "\"input_tokens\":10,\"output_tokens\":2", "\"input\":true", "\"input\":-1", "\"input\":1.5", "\"totalTokens\":9223372036854775808", "\"input\":9223372036854775807,\"output\":1,\"cacheRead\":0,\"cacheWrite\":0"] {
            try save(header() + entry("bad", usage: usage), root: root)
            let invalid = await scan(root)
            XCTAssertTrue(invalid.summaries.isEmpty)
            XCTAssertNotNil(invalid.message)
        }
        try save(header() + entry("provided", usage: "\"input\":9223372036854775807,\"output\":1,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":42"), root: root)
        let provided = await scan(root)
        XCTAssertEqual(provided.summaries[0].counters.total, 42)
        try save(header() + entry("first", usage: "\"input\":9223372036854775807,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0") + entry("second"), root: root)
        let aggregateOverflow = await scan(root)
        XCTAssertNil(aggregateOverflow.summaries[0].counters.total)
        XCTAssertNil(aggregateOverflow.summaries[0].counters.input)
        XCTAssertEqual(aggregateOverflow.summaries[0].counters.output, 5)
        XCTAssertTrue(aggregateOverflow.summaries.allSatisfy(\.isPartial))
    }

    func testLatestMatchingSessionAndCivilDayBoundaries() async throws {
        let root = try directory()
        try save(header("older") + entry("one", at: "2026-03-08T07:59:59Z") + entry("other-provider", provider: "anthropic", at: "2026-03-09T06:59:59Z"), root: root)
        try save(header("latest") + entry("one", at: "2026-03-08T08:00:00Z") + entry("two", at: "2026-03-08T12:00:00Z"), root: root, file: "b.jsonl")
        try save(header("boundary") + entry("inside", at: "2026-03-02T08:00:00Z") + entry("outside", at: "2026-03-02T07:59:59Z"), root: root, file: "c.jsonl")
        let result = await scan(root)
        XCTAssertEqual(result.summaries.map(\.scope), ["ompSession", "ompHistory", "ompHistory"])
        XCTAssertEqual(result.summaries.map(\.counters.total), [40, 40, 80])
        XCTAssertEqual(result.summaries[0].observedAt, ISO8601DateFormatter().date(from: "2026-03-08T12:00:00Z"))
        XCTAssertEqual(result.summaries[1].periodEnd!.timeIntervalSince(result.summaries[1].periodStart!), 23 * 3600)
        XCTAssertEqual(result.summaries[2].periodEnd!.timeIntervalSince(result.summaries[2].periodStart!), 167 * 3600)
        try save(header("next-day") + entry("tomorrow", at: "2026-03-09T07:00:00Z"), root: root, file: "d.jsonl")
        let nextDay = await scan(root)
        XCTAssertEqual(nextDay.summaries.map(\.counters.total), [20, 40, 80])
    }

    func testTrailingRecordStaleFallbackReplacementAndSourceIsolation() async throws {
        let root = try directory()
        let reader = LocalUsageReader()
        try save(header() + entry("good"), root: root)
        let good = await scan(root, reader: reader)
        try save(header() + String(entry("new", usage: "\"input\":1").dropLast()), root: root)
        let partial = await scan(root, reader: reader)
        XCTAssertEqual(partial.summaries[0].counters, good.summaries[0].counters)
        XCTAssertEqual(partial.summaries[0].observedAt, good.summaries[0].observedAt)
        XCTAssertTrue(partial.summaries[0].isPartial)
        let native = await scan(root, reader: reader, source: .native)
        XCTAssertTrue(native.summaries.isEmpty)
        let switchedBack = await scan(root, reader: reader)
        XCTAssertTrue(switchedBack.summaries.isEmpty)
        try save(header() + entry("zero", usage: "\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0"), root: root)
        let replaced = await scan(root, reader: reader)
        XCTAssertEqual(replaced.summaries[0].counters.total, 0)
        XCTAssertFalse(replaced.summaries[0].isPartial)
    }

    func testUnsupportedSchemaMissingUsageAndSymlinksDoNotInventUsage() async throws {
        let root = try directory()
        for text in [header(version: 999) + entry("one"), entry("no-header"), header() + entry("empty", usage: "")] {
            try save(text, root: root)
            let invalid = await scan(root)
            XCTAssertTrue(invalid.summaries.isEmpty)
            XCTAssertNotNil(invalid.message)
        }
        let outside = try directory()
        try save(header() + entry("external"), root: outside)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.jsonl"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.jsonl"), withDestinationURL: outside.appendingPathComponent("a.jsonl"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-directory"), withDestinationURL: outside)
        let linked = await scan(root)
        XCTAssertTrue(linked.summaries.isEmpty)
    }

    func testMessageMillisecondsFallbackAndExplicitMalformedDate() async throws {
        let root = try directory()
        let milliseconds = Int64(now.timeIntervalSince1970 * 1000)
        let message = "\"message\":{\"role\":\"assistant\",\"provider\":\"openai-codex\",\"timestamp\":\(milliseconds),\"usage\":{\"input\":1,\"output\":2,\"cacheRead\":0,\"cacheWrite\":0}}"
        try save(header() + "{\"type\":\"message\",\"id\":\"one\",\(message)}\n", root: root)
        let fallback = await scan(root)
        XCTAssertEqual(fallback.summaries[0].observedAt, now)
        XCTAssertEqual(fallback.summaries[0].counters.total, 3)
        try save(header() + "{\"type\":\"message\",\"id\":\"one\",\"timestamp\":\"invalid\",\(message)}\n", root: root)
        let invalid = await scan(root)
        XCTAssertTrue(invalid.summaries.isEmpty)
        for timestamp in ["", "\"timestamp\":\"invalid\","] {
            let malformed = "{\"type\":\"message\",\"id\":\"one\",\(timestamp)\"message\":{\"role\":\"assistant\",\"provider\":\"openai-codex\",\"usage\":{\"input\":99}}}\n"
            try save(header("parent") + entry("one") + malformed, root: root)
            try save(header("fork") + entry("one") + entry("unrelated", at: "2026-03-08T14:00:00Z"), root: root, file: "fork.jsonl")
            let conservative = await scan(root)
            XCTAssertEqual(conservative.summaries.filter { $0.scope == "ompHistory" }.map(\.counters.total), [20, 20])
            XCTAssertTrue(conservative.summaries.allSatisfy(\.isPartial))
        }
    }

    func testSettingsRoundTripLegacyDefaultAndCoordinatorSourceReplacement() async throws {
        let root = try directory()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(Connection.self, from: Data("{\"provider\":\"codex\",\"enabled\":false}".utf8))
        XCTAssertNil(legacy.localSource)
        var connection = Connection(provider: .codex, localFolder: root, localConsentedAt: now, localSource: .omp)
        XCTAssertEqual(try decoder.decode(Connection.self, from: encoder.encode(connection)).localSource, .omp)
        try save(header() + entry("one"), root: root)
        let store = SnapshotStore(groupURL: root.appendingPathComponent("snapshot.json"), fallbackDirectory: root)
        let fixed = now
        let coordinator = UsageCoordinator(connections: [connection], store: store, now: { fixed })
        await coordinator.refresh()
        let first = await coordinator.current()
        XCTAssertEqual(first.providers[0].localTokens[0].counters.total, 20)
        connection.localSource = .native
        let relaunched = UsageCoordinator(connections: [connection], store: store, now: { fixed })
        let restored = await relaunched.current()
        XCTAssertTrue(restored.providers[0].localTokens.isEmpty)
        await coordinator.replace(connection)
        let replaced = await coordinator.current()
        XCTAssertTrue(replaced.providers[0].localTokens.isEmpty)
        await coordinator.refresh()
        let native = await coordinator.current()
        XCTAssertTrue(native.providers[0].localTokens.isEmpty)
        connection.localSource = .omp
        try save(header() + String(entry("partial").dropLast()), root: root)
        await coordinator.replace(connection)
        await coordinator.refresh()
        let partial = await coordinator.current()
        XCTAssertTrue(partial.providers[0].localTokens.isEmpty)
        XCTAssertNil(partial.providers[0].lastSuccess)
    }
}
