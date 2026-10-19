import Foundation
import AILimitShared

/// Private scan provenance and request metadata never cross the shared snapshot boundary.
struct LocalOverviewFacts: Sendable {
    let provider: ProviderID
    let source: LocalTokenSource
    let observedAt: Date
    let records: [LocalUsageReader.Record]
    let isPartial: Bool
}

enum LocalUsageOverview {
    private struct Key: Hashable {
        let provider: ProviderID
        let source: String
        let identity: String
        var at: Date? = nil
    }
    private struct Row {
        let provider: ProviderID
        let record: LocalUsageReader.Record
    }

    static func aggregate(_ scans: [LocalOverviewFacts], now: Date, calendar: Calendar = .current, awaitingScans: Bool = false) -> UsageOverview? {
        guard !scans.isEmpty else { return nil }
        var partial = awaitingScans || scans.contains { $0.isPartial }
        var notes = ["이 Mac에서 읽기에 동의한 로컬 기록만 집계합니다. 계정 전체 사용량·구독 요금·실제 청구액이 아니며 삭제된 기록은 포함되지 않습니다.", "최신 표준·글로벌 API 단가로 환산한 추정 USD이며 과거 청구액이 아닙니다. 캐시 TTL 미기록 시 기본 5분 단가를 가정합니다."]
        if scans.contains(where: { $0.provider == .codex && $0.source == .native }) {
            partial = true
            notes.append("Codex 기본 로그의 누적·상속 카운터는 이번 주·이번 달 합계에서 제외됩니다. 요청별 기록을 제공하는 OMP 폴더를 연결하세요. 최근 로컬 세션 표시는 유지됩니다.")
        }
        // First reject conflicting OMP revisions within their original session.
        // Use all consented scans together: account labels and folder paths are not identities.
        var original: [Key: Row] = [:]
        var rejected: Set<Key> = []
        var inheritedIdentities: [Key: Set<Key>] = [:]
        var incompleteNative: Set<Key> = []
        for scan in scans where !(scan.provider == .codex && scan.source == .native) {
            for record in scan.records {
                let key = Key(provider: scan.provider, source: scan.source.rawValue, identity: record.key)
                // Future events are not consumption observed by this scan, even if a
                // later refresh of another account has advanced the aggregate clock.
                guard record.at <= min(now, scan.observedAt) else { continue }
                if scan.source == .omp {
                    let inherited = Key(provider: scan.provider, source: key.source, identity: record.entryID ?? record.key, at: record.at)
                    inheritedIdentities[key, default: []].insert(inherited)
                }
                if !record.complete {
                    if scan.source == .omp { rejected.insert(key) }
                    else { incompleteNative.insert(key) }
                    continue
                }
                let row = Row(provider: scan.provider, record: record)
                if let old = original[key] {
                    if scan.source == .native, record.at > old.record.at {
                        original[key] = row; rejected.remove(key)
                    } else if scan.source == .omp || record.at == old.record.at {
                        if !equivalent(old.record, record) { rejected.insert(key) }
                    }
                } else { original[key] = row }
            }
        }
        partial = partial || !rejected.isEmpty || incompleteNative.contains { original[$0] == nil }
        // Forks retain entry IDs and timestamps. Short IDs can be reused at a
        // different time; only the pair identifies an inherited request.
        var requests: [Key: Row] = [:]
        // Every revision of a rejected original poisons its inherited identity,
        // not just the timestamp of whichever revision happened to be seen first.
        var conflicts = rejected.reduce(into: Set<Key>()) { result, key in
            result.formUnion(inheritedIdentities[key] ?? [])
        }
        for (key, row) in original {
            let record = row.record
            let isOMP = key.source == LocalTokenSource.omp.rawValue
            let requestKey = Key(provider: key.provider, source: key.source, identity: isOMP ? (record.entryID ?? record.key) : key.identity, at: isOMP ? record.at : nil)
            if rejected.contains(key) { conflicts.insert(requestKey); continue }
            if let old = requests[requestKey] {
                if !equivalent(old.record, record) { conflicts.insert(requestKey); partial = true }
            } else { requests[requestKey] = row }
        }
        let rows = requests.filter { key, row in
            !conflicts.contains(key) && (key.source != LocalTokenSource.omp.rawValue || row.record.origin == (row.provider == .codex ? "openai-codex" : "anthropic"))
        }.map(\.value)
        let generatedAt = scans.map(\.observedAt).min()!
        if partial { notes.append("일부 기록의 읽기·식별·집계가 불완전합니다. 확인된 요청만 표시하며 미제공 값은 0으로 간주하지 않습니다.") }
        if generatedAt < now { notes.append("폴더별 마지막 읽기 시각이 다를 수 있습니다. 갱신 시각은 포함된 읽기 중 가장 오래된 시각입니다.") }
        var periods: [PeriodUsageTotals] = []
        for period in UsagePeriod.allCases {
            guard let interval = period.interval(containing: now, calendar: calendar) else { continue }
            let included = rows.filter { $0.record.at >= interval.start && $0.record.at < interval.end && $0.record.at <= now }
            var total = PeriodUsageTotals(period: period, start: interval.start, end: interval.end, recordCount: included.count, isPartial: partial)
            var tokenOverflow = false
            var costOverflow = false
            for row in included {
                if let tokens = row.record.counters.total {
                    let (sum, overflow) = (total.tokens ?? 0).addingReportingOverflow(tokens)
                    if overflow { tokenOverflow = true } else { total.tokens = sum }
                } else { total.missingTokenRecords += 1 }
                if !row.record.invalidPricing, let estimate = APIPriceCatalog.estimate(provider: row.provider, model: row.record.model, counters: row.record.counters, cacheWriteLong: row.record.cacheWriteLong) {
                    var lhs = total.estimatedUSD ?? 0
                    var rhs = estimate
                    var sum = Decimal()
                    if NSDecimalAdd(&sum, &lhs, &rhs, .plain) == .noError { total.estimatedUSD = sum }
                    else { costOverflow = true }
                } else { total.unpricedRecords += 1 }
            }
            if tokenOverflow { total.tokens = nil }
            if costOverflow { total.estimatedUSD = nil }
            total.isPartial = total.isPartial || tokenOverflow || costOverflow || total.missingTokenRecords > 0
            periods.append(total)
        }
        return UsageOverview(generatedAt: generatedAt, periods: periods, pricingAsOf: APIPriceCatalog.asOf, notes: notes, isPartial: partial || periods.contains { $0.isPartial })
    }

    private static func equivalent(_ a: LocalUsageReader.Record, _ b: LocalUsageReader.Record) -> Bool {
        a.at == b.at && a.counters == b.counters && a.origin == b.origin && a.model == b.model && a.cacheWriteLong == b.cacheWriteLong && a.invalidPricing == b.invalidPricing
    }
}
