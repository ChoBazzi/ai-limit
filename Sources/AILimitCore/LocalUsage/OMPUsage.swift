import Foundation
import AILimitShared

extension LocalUsageReader {
    func decodeOMP(_ json: JSON, provider: ProviderID, session: String?) throws -> Record? {
        guard json["type"].string == "message", json["message"]["role"].string == "assistant" else { return nil }
        let message = json["message"]
        guard let origin = message["provider"].string, !origin.isEmpty else { throw UsageError.malformed }
        let matchesProvider = origin == (provider == .codex ? "openai-codex" : "anthropic")
        guard let session, let entry = json["id"].string, !entry.isEmpty else {
            if matchesProvider { throw UsageError.malformed }
            return nil
        }
        // Length-prefixing prevents identities containing delimiters from colliding.
        let key = "\(session.utf8.count):\(session)\(entry)"
        // Retain only identity for other providers so a conflicting provider rewrite
        // cannot make a copied entry appear to belong to the selected quota account.
        if !matchesProvider { return Record(key: key, at: .distantPast, counters: TokenCounters(), complete: true, session: session, entryID: entry, origin: origin) }
        do {
            let at: Date
            if !json["timestamp"].isNull {
                guard json["timestamp"].string?.contains("T") == true, let date = json["timestamp"].date else { throw UsageError.malformed }
                at = date
            } else {
                guard let milliseconds = try message["timestamp"].integer() else { throw UsageError.malformed }
                at = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
            }
            let usage = message["usage"]
            let input = try usage["input"].integer()
            let output = try usage["output"].integer()
            let read = try usage["cacheRead"].integer()
            let write = try usage["cacheWrite"].integer()
            let reasoning = try usage["reasoningTokens"].integer()
            var total = try usage["totalTokens"].integer()
            guard [input, output, read, write, total].contains(where: { $0 != nil }) else { throw UsageError.malformed }
            // OMP persists normalized, disjoint input/cache buckets, not raw API
            // input_tokens (which can include cache hits). Reasoning is part of output.
            if total == nil, let input, let output, let read, let write {
                var sum: Int64 = 0
                for value in [input, output, read, write] {
                    let (next, overflow) = sum.addingReportingOverflow(value)
                    guard !overflow else { throw UsageError.malformed }
                    sum = next
                }
                total = sum
            }
            return Record(key: key, at: at, counters: TokenCounters(input: input, output: output, cacheRead: read, cacheWrite: write, reasoning: reasoning, total: total), complete: true, session: session, entryID: entry, origin: origin, isPartial: [input, output, read, write].contains(where: { $0 == nil }), model: message["model"].string)
        } catch {
            // An invalid revision must invalidate earlier copies with this identity,
            // not silently resurrect their values as if the newer record did not exist.
            return Record(key: key, at: .distantPast, counters: TokenCounters(), complete: false, session: session, entryID: entry, origin: origin, isPartial: true)
        }
    }

    func ompSummaries(_ records: [Record], provider: ProviderID, now: Date, calendar: Calendar, partial: inout Bool) -> [TokenSummary] {
        var selected: [String: Record] = [:]
        var conflicts: Set<String> = []
        for record in records {
            guard record.complete else { conflicts.insert(record.key); partial = true; continue }
            if let old = selected[record.key] {
                // OMP appends completed messages, not streaming cumulative revisions.
                // Conflicting copies are excluded regardless of timestamp or file order.
                if old.at != record.at || old.counters != record.counters || old.origin != record.origin { conflicts.insert(record.key); partial = true }
            } else { selected[record.key] = record }
        }
        let origin = provider == .codex ? "openai-codex" : "anthropic"
        let valid = selected.values.filter { !conflicts.contains($0.key) && $0.origin == origin }
        guard !valid.isEmpty else { return [] }
        let note = "이 Mac OMP에 남아 있는 해당 공급자 기록 · 현재 로그인 계정의 총량이 아닙니다. 계정 귀속을 확인할 수 없으며 삭제·분기·누락된 기록으로 실제 사용량과 다를 수 있습니다."
        func counters(_ rows: [Record]) -> TokenCounters {
            func sum(_ key: KeyPath<TokenCounters, Int64?>) -> Int64? {
                var sum: Int64 = 0
                for row in rows {
                    guard let value = row.counters[keyPath: key] else { return nil }
                    let (next, overflow) = sum.addingReportingOverflow(value)
                    guard !overflow else { partial = true; return nil }
                    sum = next
                }
                return sum
            }
            return TokenCounters(input: sum(\.input), output: sum(\.output), cacheRead: sum(\.cacheRead), cacheWrite: sum(\.cacheWrite), reasoning: sum(\.reasoning), total: sum(\.total))
        }
        var summaries: [TokenSummary] = []
        // The latest matching-provider usage selects a session, not a newer unrelated
        // provider turn or filesystem modification time. Tie-break by stable identity.
        if let latest = valid.max(by: { $0.at == $1.at ? $0.key < $1.key : $0.at < $1.at }) {
            let rows = valid.filter { $0.session == latest.session }
            summaries.append(TokenSummary(scope: "ompSession", counters: counters(rows), observedAt: latest.at, note: "최근 OMP 세션 · 요청별 사용량 누적(상속 기록 포함 가능). " + note))
        }
        // Forks preserve non-header entry IDs and timestamps under a new session
        // header. Count inherited requests once across history, while retaining the
        // latest session's own cumulative view (including inherited requests).
        struct HistoryKey: Hashable { let entry: String; let at: Date }
        var history: [HistoryKey: Record] = [:]
        var historyConflicts: Set<HistoryKey> = []
        for row in valid {
            guard let entry = row.entryID else { partial = true; continue }
            let key = HistoryKey(entry: entry, at: row.at)
            if let old = history[key] {
                if old.counters != row.counters { historyConflicts.insert(key); partial = true }
            } else { history[key] = row }
        }
        let historyRows = history.filter { !historyConflicts.contains($0.key) }.map(\.value)
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: today), let week = calendar.date(byAdding: .day, value: -6, to: today) else { return summaries.map { var value = $0; value.isPartial = true; return value } }
        for (start, title) in [(today, "오늘"), (week, "최근 7일")] {
            let rows = historyRows.filter { $0.at >= start && $0.at < end }
            guard let observed = rows.map(\.at).max() else { continue }
            summaries.append(TokenSummary(scope: "ompHistory", counters: counters(rows), observedAt: observed, periodStart: start, periodEnd: end, note: title + " · " + note))
        }
        // An overflow found in any scope makes the whole scan partial, including
        // summaries already constructed before that overflow was encountered.
        return summaries.map { var value = $0; value.isPartial = partial; return value }
    }
}
