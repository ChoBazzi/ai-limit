import XCTest
@testable import AILimitCore
import AILimitShared

@MainActor
final class LocalUsageRecoveryTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-12T20:00:00Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func line(_ request: String, output: Int, complete: Bool = true) -> String {
        "{\"type\":\"assistant\",\"requestId\":\"\(request)\",\"timestamp\":\"2026-10-12T12:00:00Z\",\"message\":{\"id\":\"m\",\"model\":\"claude-sonnet-4-5\",\"stop_reason\":\(complete ? "\"end_turn\"" : "null"),\"usage\":{\"input_tokens\":10,\"output_tokens\":\(output),\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}\n"
    }
    private func scan(_ reader: LocalUsageReader, _ root: URL) async -> LocalScanResult {
        await reader.scan(accountID: "local", provider: .claude, root: root, now: now, calendar: calendar)
    }
    private func finish(_ reader: LocalUsageReader, _ root: URL, attempts: Int = 100) async -> LocalScanResult {
        var result = await scan(reader, root)
        for _ in 1..<attempts where result.message != nil { result = await scan(reader, root) }
        return result
    }

    func testCompletedStreamResolvesPartialAndReplacesPreviousSummary() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("usage.jsonl")
        let baseline = line("old", output: 1)
        try Data(baseline.utf8).write(to: file)
        let reader = LocalUsageReader()
        let initial = await scan(reader, root)
        XCTAssertEqual(initial.summaries.first?.counters.total, 11)
        let provisional = line("new", output: 0, complete: false)
        try Data((baseline + provisional).utf8).write(to: file)
        let unresolved = await scan(reader, root)
        XCTAssertEqual(unresolved.summaries.first?.counters.total, 11)
        XCTAssertTrue(unresolved.summaries.first?.isPartial == true)
        // The complete revision can be in another file; deduplication is request-wide.
        try Data(line("new", output: 5).utf8).write(to: root.appendingPathComponent("complete.jsonl"))
        for _ in 0..<2 {
            let complete = await scan(reader, root)
            XCTAssertEqual(complete.summaries.first?.counters.total, 26)
            XCTAssertFalse(complete.summaries.first?.isPartial ?? true)
            XCTAssertNil(complete.message)
            let overview = try XCTUnwrap(LocalUsageOverview.aggregate([try XCTUnwrap(complete.overviewFacts)], now: now, calendar: calendar))
            XCTAssertEqual(overview.periods.first?.tokens, 26)
            XCTAssertEqual(overview.periods.first?.estimatedUSD, Decimal(string: "0.00015"))
            XCTAssertFalse(overview.isPartial)
        }
        try Data((baseline + provisional + "not-json\n").utf8).write(to: file)
        for _ in 0..<2 {
            let malformed = await scan(reader, root)
            XCTAssertEqual(malformed.summaries.first?.counters.total, 26)
            XCTAssertTrue(malformed.summaries.first?.isPartial == true)
            XCTAssertNotNil(malformed.message)
        }
    }

    func testByteBudgetResumesAcrossRecordsAndFilesUntilComplete() async throws {
        let root = try directory()
        // Each valid record and each file exceeds the scan budget. A saved cursor
        // must preserve a bounded unfinished line, not restart it on every scan.
        let padding = String(repeating: "{}\n", count: 150)
        let firstFile = root.appendingPathComponent("a.jsonl")
        try Data((padding + line("a", output: 0) + padding).utf8).write(to: firstFile)
        let reader = LocalUsageReader(scanByteLimit: 128)
        let baseline = await finish(reader, root)
        XCTAssertEqual(baseline.summaries.first?.counters.total, 10)
        XCTAssertNil(baseline.message)
        try Data((padding + line("b", output: 0) + padding).utf8).write(to: root.appendingPathComponent("b.jsonl"))
        let interrupted = await scan(reader, root)
        XCTAssertNotNil(interrupted.message)
        XCTAssertEqual(interrupted.summaries.first?.counters.total, 10)
        XCTAssertTrue(interrupted.summaries.first?.isPartial == true)
        let complete = await finish(reader, root)
        XCTAssertEqual(complete.summaries.first?.counters.total, 20)
        XCTAssertFalse(complete.summaries.first?.isPartial ?? true)
        XCTAssertNil(complete.message)
        let cached = await scan(reader, root)
        XCTAssertEqual(cached.summaries.first?.counters.total, 20)
        XCTAssertNil(cached.message)
    }

    func testFileBudgetResumesIntoArchiveAndStartsNewTraversal() async throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        let archive = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        func codexLine(_ session: String, total: Int, hour: Int) -> Data {
            Data(("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\"}}\n"
                + "{\"type\":\"event_msg\",\"timestamp\":\"2026-10-12T\(hour):00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(total)}}}}\n").utf8)
        }
        for index in 0..<2 {
            try codexLine("old-\(index)", total: 1, hour: 12).write(to: sessions.appendingPathComponent("\(index).jsonl"))
        }
        let latest = archive.appendingPathComponent("latest.jsonl")
        try codexLine("latest", total: 9999, hour: 13).write(to: latest)
        let reader = LocalUsageReader(scanByteLimit: 128 * 1024, scanFileLimit: 2)
        let interrupted = await reader.scan(accountID: "local", provider: .codex, root: root, now: now)
        XCTAssertEqual(interrupted.summaries.first?.counters.total, 1)
        XCTAssertTrue(interrupted.summaries.first?.isPartial == true)
        let complete = await reader.scan(accountID: "local", provider: .codex, root: root, now: now)
        XCTAssertEqual(complete.summaries.first?.counters.total, 9999)
        XCTAssertFalse(complete.summaries.first?.isPartial ?? true)
        XCTAssertNil(complete.message)

        // A completed traversal must restart so later appends are still observed.
        try codexLine("latest", total: 10001, hour: 14).write(to: latest, options: .atomic)
        let pending = await reader.scan(accountID: "local", provider: .codex, root: root, now: now)
        XCTAssertEqual(pending.summaries.first?.counters.total, 9999)
        XCTAssertTrue(pending.summaries.first?.isPartial == true)
        let updated = await reader.scan(accountID: "local", provider: .codex, root: root, now: now)
        XCTAssertEqual(updated.summaries.first?.counters.total, 10001)
        XCTAssertNil(updated.message)
    }

    func testFileBudgetCombinesBatchesAndPrunesDeletedFilesAfterTraversal() async throws {
        let root = try directory()
        for request in ["a", "b", "c"] {
            try Data(line(request, output: 1).utf8).write(to: root.appendingPathComponent("\(request).jsonl"))
        }
        let reader = LocalUsageReader(scanByteLimit: 128 * 1024, scanFileLimit: 2)
        let initial = await finish(reader, root)
        XCTAssertEqual(initial.summaries.map(\.counters.total), [33, 33])
        XCTAssertNil(initial.message)
        let overview = try XCTUnwrap(LocalUsageOverview.aggregate([try XCTUnwrap(initial.overviewFacts)], now: now, calendar: calendar))
        XCTAssertEqual(overview.periods.first?.tokens, 33)
        XCTAssertFalse(overview.isPartial)

        try Data(line("a", output: 9).utf8).write(to: root.appendingPathComponent("a.jsonl"), options: .atomic)
        let pending = await scan(reader, root)
        XCTAssertEqual(pending.summaries.first?.counters.total, 33)
        XCTAssertTrue(pending.summaries.first?.isPartial == true)
        let updated = await finish(reader, root)
        XCTAssertEqual(updated.summaries.map(\.counters.total), [41, 41])
        XCTAssertNil(updated.message)

        try FileManager.default.removeItem(at: root.appendingPathComponent("b.jsonl"))
        let pruned = await finish(reader, root)
        XCTAssertEqual(pruned.summaries.map(\.counters.total), [30, 30])
        XCTAssertNil(pruned.message)
    }

    func testFolderChangeDiscardsPendingTraversal() async throws {
        let original = try directory()
        for request in ["a", "b", "c"] {
            try Data(line(request, output: 1).utf8).write(to: original.appendingPathComponent("\(request).jsonl"))
        }
        let replacement = try directory()
        try Data(line("replacement", output: 7).utf8).write(to: replacement.appendingPathComponent("new.jsonl"))
        let reader = LocalUsageReader(scanByteLimit: 128 * 1024, scanFileLimit: 2)
        let interrupted = await scan(reader, original)
        XCTAssertTrue(interrupted.summaries.first?.isPartial == true)
        let changed = await scan(reader, replacement)
        XCTAssertEqual(changed.summaries.map(\.counters.total), [17, 17])
        XCTAssertNil(changed.message)
    }

    func testReplacementWithSameSizeAndDateInvalidatesSavedCursor() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("usage.jsonl")
        let padding = String(repeating: "{}\n", count: 100)
        let old = line("old", output: 1) + padding
        let replacement = line("new", output: 9) + padding
        XCTAssertEqual(old.utf8.count, replacement.utf8.count)
        try Data(old.utf8).write(to: file)
        let modified = try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let reader = LocalUsageReader(scanByteLimit: 128)
        _ = await scan(reader, root)
        try Data(replacement.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let complete = await finish(reader, root)
        XCTAssertEqual(complete.summaries.first?.counters.total, 19)
        XCTAssertNil(complete.message)
        try Data(line("shrunk", output: 2).utf8).write(to: file)
        let shrunk = await finish(reader, root)
        XCTAssertEqual(shrunk.summaries.first?.counters.total, 12)
        XCTAssertNil(shrunk.message)
    }

    func testOversizedLineIsSkippedWithoutLosingFollowingUsage() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("usage.jsonl")
        let oversized = String(repeating: "x", count: 8 * 1024 * 1024 + 1)
        try Data((oversized + "\n" + line("valid", output: 5)).utf8).write(to: file)
        let reader = LocalUsageReader(scanByteLimit: 1024 * 1024)
        var result = await scan(reader, root)
        for _ in 0..<10 { result = await scan(reader, root) }
        XCTAssertEqual(result.summaries.first?.counters.total, 15)
        XCTAssertTrue(result.summaries.first?.isPartial == true)
        XCTAssertNotNil(result.message)
    }
}
