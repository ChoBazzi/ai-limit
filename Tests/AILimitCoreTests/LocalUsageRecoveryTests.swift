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
