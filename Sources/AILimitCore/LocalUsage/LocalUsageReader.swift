import Foundation
import AILimitShared

public struct LocalScanResult: Sendable {
    public let summaries: [TokenSummary]
    public let message: String?
    var overviewFacts: LocalOverviewFacts? = nil
}
public actor LocalUsageReader {
    struct Record: Sendable {
        let key: String
        let at: Date
        let counters: TokenCounters
        let complete: Bool
        var session: String? = nil
        var entryID: String? = nil
        var origin: String? = nil
        var isPartial = false
        var model: String? = nil
        var cacheWriteLong: Int64? = nil
        var invalidPricing = false
    }
    struct Cached: Sendable {
        let identity: String; let size: Int; let modified: Date
        var records: [Record] = []
        var partial = false
        var offset: UInt64 = 0
        var buffer = Data()
        var discardingLine = false
        var finished = false
        var session: String? = nil
        var parentSession: String? = nil
    }
    private struct AccountCache {
        let provider: ProviderID
        let root: URL
        let source: LocalTokenSource
        var files: [URL: Cached] = [:]
        var previous: [TokenSummary] = []
    }
    private var accounts: [String: AccountCache] = [:]
    private let scanByteLimit: Int
    private let scanTimeLimit: Duration
    public init() {
        scanByteLimit = 128 * 1024 * 1024
        scanTimeLimit = .seconds(5)
    }
    init(scanByteLimit: Int, scanTimeLimit: Duration = .seconds(5)) {
        precondition(scanByteLimit > 0 && scanTimeLimit > .zero)
        self.scanByteLimit = scanByteLimit
        self.scanTimeLimit = scanTimeLimit
    }
    public func scan(accountID: String, provider: ProviderID, root: URL, now: Date, calendar: Calendar = .current, source: LocalTokenSource = .native) -> LocalScanResult {
        guard provider == .codex || provider == .claude else { accounts.removeValue(forKey: accountID); return LocalScanResult(summaries: [], message: "로컬 토큰 지원 없음") }
        let root = root.standardizedFileURL
        var account = accounts.removeValue(forKey: accountID).flatMap { $0.provider == provider && $0.root == root && $0.source == source ? $0 : nil } ?? AccountCache(provider: provider, root: root, source: source)
        var cache = account.files
        account.files = [:]
        defer { account.files = cache; accounts[accountID] = account }
        let started = ContinuousClock.now
        var budget = scanByteLimit; var count = 0; var partial = false; var denied = false; var records: [Record] = []; var visited: Set<URL> = []
        var enumerationFinished = true
        if !FileManager.default.isReadableFile(atPath: root.path) { denied = true }
        let roots = source == .native && provider == .codex ? [root.appendingPathComponent("sessions"), root.appendingPathComponent("archived_sessions")] : [root]
        for directory in roots {
            if !FileManager.default.fileExists(atPath: directory.path) { if provider == .claude || source == .omp { denied = true }; continue }
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in denied = true; return false }) else { denied = true; continue }
            for case let url as URL in enumerator {
                if ContinuousClock.now - started >= scanTimeLimit || count >= 2000 { partial = true; enumerationFinished = false; break }
                guard url.pathExtension == "jsonl" else { continue }
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey]); guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    count += 1; visited.insert(url); let size = values.fileSize ?? 0; let modified = values.contentModificationDate ?? .distantPast; let identity = String(describing: values.fileResourceIdentifier)
                    var file = cache.removeValue(forKey: url).flatMap {
                        $0.identity == identity && $0.size == size && $0.modified == modified ? $0 : nil
                    } ?? Cached(identity: identity, size: size, modified: modified)
                    if !file.finished && budget > 0 {
                        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                        try handle.seek(toOffset: file.offset)
                        while file.offset < UInt64(size) {
                            if budget <= 0 || ContinuousClock.now - started >= scanTimeLimit { break }
                            let chunk = try handle.read(upToCount: min(65_536, budget, size - Int(file.offset))) ?? Data()
                            guard !chunk.isEmpty else { throw UsageError.malformed }
                            budget -= chunk.count; file.offset += UInt64(chunk.count); file.buffer.append(chunk)
                            while let newline = file.buffer.firstIndex(of: 10) {
                                let line = file.buffer.prefix(upTo: newline)
                                if file.discardingLine || line.count > 8 * 1024 * 1024 { file.partial = true }
                                else if !line.isEmpty {
                                    do {
                                        let json = try JSON(data: Data(line))
                                        if source == .omp, json["type"].string == "session" {
                                            file.session = nil
                                            guard let id = json["id"].string, !id.isEmpty, let version = try json["version"].integer(), version == 2 || version == 3 else { throw UsageError.malformed }
                                            file.session = id
                                            file.parentSession = json["parentSession"].string
                                            if !json["parentSession"].isNull && (file.parentSession?.isEmpty != false) { file.partial = true }
                                        } else if source == .native, provider == .codex, json["type"].string == "session_meta" { file.session = json["payload"]["id"].string }
                                        let record = try source == .omp ? decodeOMP(json, provider: provider, session: file.session) : decode(json, provider: provider, session: file.session)
                                        if let record {
                                            file.records.append(record)
                                            if record.isPartial { file.partial = true }
                                        }
                                    } catch { file.partial = true }
                                }
                                file.buffer.removeSubrange(...newline)
                                file.discardingLine = false
                            }
                            // Skip an oversized record through its newline, without retaining
                            // its contents or abandoning later valid records in this file.
                            if file.discardingLine || file.buffer.count > 8 * 1024 * 1024 {
                                file.partial = true; file.discardingLine = true; file.buffer.removeAll(keepingCapacity: false)
                            }
                        }
                        file.finished = file.offset == UInt64(size)
                        if file.finished {
                            if !file.buffer.isEmpty || file.discardingLine { file.partial = true }
                            file.buffer.removeAll(keepingCapacity: false)
                        }
                        // Never combine a saved cursor with replaced, truncated or appended
                        // contents. Restart on the next scan if the file changed while open.
                        let current = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey])
                        guard String(describing: current.fileResourceIdentifier) == identity,
                              current.fileSize == size, current.contentModificationDate == modified else {
                            partial = true
                            continue
                        }
                    }
                    records.append(contentsOf: file.records)
                    partial = partial || file.partial || !file.finished
                    cache[url] = file
                } catch { denied = true; partial = true }
            }
        }
        if enumerationFinished { cache = cache.filter { visited.contains($0.key) } }
        partial = partial || denied
        if source == .omp {
            // Lineage can name a session ID or an opaque path. Only already-scanned
            // headers/files can resolve it; never follow a parent outside consent.
            let knownSessions = Set(cache.values.compactMap(\.session))
            let knownPaths = Set(cache.filter { $0.value.session != nil }.keys.map(\.path))
            for file in cache.values {
                if let parent = file.parentSession, !knownSessions.contains(parent), !knownPaths.contains(parent) { partial = true }
            }
            let overviewFacts = LocalOverviewFacts(provider: provider, source: source, observedAt: now, records: records, isPartial: partial)
            let summaries = ompSummaries(records, provider: provider, now: now, calendar: calendar, partial: &partial)
            let result: [TokenSummary]
            if partial, !account.previous.isEmpty { result = account.previous.map { var value = $0; value.isPartial = true; return value } }
            else { result = summaries; if !partial { account.previous = summaries } }
            return LocalScanResult(summaries: result, message: denied ? "OMP 기록 읽기 실패 · 권한과 폴더를 확인하세요." : partial ? "OMP 일부 기록만 확인됨 · 이전 완전한 결과가 있으면 유지합니다." : result.isEmpty ? "OMP 기록 없음 · 사용량 0을 의미하지 않습니다." : nil, overviewFacts: overviewFacts)
        }
        var selected: [String: Record] = [:]; var conflicts: Set<String> = []; var incomplete: Set<String> = []
        for record in records {
            let key = provider == .codex ? record.key + "@" + String(record.at.timeIntervalSince1970) : record.key
            guard record.complete else { incomplete.insert(key); continue }
            if let old = selected[key] {
                if record.at > old.at { selected[key] = record; conflicts.remove(key) }
                else if record.at == old.at && record.counters != old.counters { conflicts.insert(key) }
            } else { selected[key] = record }
        }
        // Native Claude streaming rows are provisional, not permanently malformed.
        // A complete revision resolves the same request even across different files.
        partial = partial || !conflicts.isEmpty || incomplete.contains { selected[$0] == nil }
        let valid = selected.filter { !conflicts.contains($0.key) }.map(\.value)
        var summaries: [TokenSummary] = []
        if provider == .codex {
            if let latest = valid.max(by: { $0.at < $1.at }) { summaries = [TokenSummary(scope: "localSession", counters: latest.counters, observedAt: latest.at, isPartial: partial, note: "최근 로컬 세션 · 누적 카운터(상속 문맥 포함 가능). 이 Mac 기록이며 계정 총량이 아닙니다.")] }
        } else {
            let today = calendar.startOfDay(for: now); let end = calendar.date(byAdding: .day, value: 1, to: today)!
            for (start, title) in [(today, "오늘"), (calendar.date(byAdding: .day, value: -6, to: today)!, "최근 7일")] {
                let rows = valid.filter { $0.at >= start && $0.at < end }; guard !rows.isEmpty else { continue }
                func sum(_ key: KeyPath<TokenCounters, Int64?>) -> Int64? { var total: Int64 = 0; for row in rows { guard let value = row.counters[keyPath: key] else { return nil }; let (next, overflow) = total.addingReportingOverflow(value); guard !overflow else { partial = true; return nil }; total = next }; return total }
                let counters = TokenCounters(input: sum(\.input), output: sum(\.output), cacheRead: sum(\.cacheRead), cacheWrite: sum(\.cacheWrite), total: sum(\.total))
                summaries.append(TokenSummary(scope: "localHistory", counters: counters, observedAt: rows.map(\.at).max()!, periodStart: start, periodEnd: end, isPartial: partial, note: title + " · 이 Mac에 남아 있는 기록 · 일부 기록/출력 토큰이 누락될 수 있음"))
            }
        }
        if partial, !account.previous.isEmpty { summaries = account.previous.map { var value = $0; value.isPartial = true; return value } }
        else if !partial { account.previous = summaries }
        return LocalScanResult(summaries: summaries, message: denied ? "기록 읽기 실패 · 권한과 폴더를 확인하세요." : partial ? "일부 기록만 확인됨 · 이전 완전한 결과가 있으면 유지합니다." : summaries.isEmpty ? "기록 없음 · 사용량 0을 의미하지 않습니다." : nil, overviewFacts: LocalOverviewFacts(provider: provider, source: source, observedAt: now, records: provider == .codex ? [] : records, isPartial: partial))
    }
    public func forget(_ accountID: String) { accounts.removeValue(forKey: accountID) }
    private func decode(_ json: JSON, provider: ProviderID, session: String?) throws -> Record? {
        let usage: JSON; let key: String
        if provider == .codex {
            guard json["type"].string == "event_msg", json["payload"]["type"].string == "token_count" else { return nil }
            usage = json["payload"]["info"]["total_token_usage"]; guard !usage.isNull else { return nil }; guard let session else { throw UsageError.malformed }; key = session
        } else {
            guard json["type"].string == "assistant" else { return nil }; usage = json["message"]["usage"]; guard !usage.isNull else { return nil }
            guard let message = json["message"]["id"].string, let request = json["requestId"].string ?? json["sessionId"].string else { throw UsageError.malformed }; key = request + ":" + message
        }
        guard let at = json["timestamp"].date else { throw UsageError.malformed }
        let input = try usage["input_tokens"].integer(); let output = try usage["output_tokens"].integer(); let read = try usage[provider == .codex ? "cached_input_tokens" : "cache_read_input_tokens"].integer(); let write = try usage[provider == .codex ? "cache_write_input_tokens" : "cache_creation_input_tokens"].integer()
        var total = try provider == .codex ? usage["total_tokens"].integer() : nil
        if provider == .claude, let input, let output, let read, let write { var sum: Int64 = 0; for value in [input, output, read, write] { let (next, overflow) = sum.addingReportingOverflow(value); guard !overflow else { throw UsageError.malformed }; sum = next }; total = sum }
        let complete = !(provider == .claude && json["message"]["stop_reason"].isNull && (input ?? 0) > 0 && output == 0 && (read ?? 0) == 0 && (write ?? 0) == 0)
        var cacheWriteLong: Int64?
        var invalidPricing = false
        if provider == .claude, !usage["cache_creation"].isNull {
            do {
                cacheWriteLong = try usage["cache_creation"]["ephemeral_1h_input_tokens"].integer()
                let short = try usage["cache_creation"]["ephemeral_5m_input_tokens"].integer()
                if let long = cacheWriteLong, let write, long > write { invalidPricing = true }
                if let short, let write {
                    let (sum, overflow) = short.addingReportingOverflow(cacheWriteLong ?? 0)
                    if overflow || sum != write { invalidPricing = true }
                }
            } catch { invalidPricing = true }
        }
        return Record(key: key, at: at, counters: TokenCounters(input: input, output: output, cacheRead: read, cacheWrite: write, reasoning: provider == .codex ? try usage["reasoning_output_tokens"].integer() : nil, total: total), complete: complete, entryID: provider == .claude ? json["message"]["id"].string : nil, model: json["message"]["model"].string, cacheWriteLong: cacheWriteLong, invalidPricing: invalidPricing)
    }
}
