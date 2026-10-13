import Foundation

public enum UsagePeriod: String, Codable, Sendable, CaseIterable, Identifiable {
    case week, month
    public var id: String { rawValue }
    public var title: String { self == .week ? "이번 주" : "이번 달" }
    public func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval? {
        var calendar = calendar
        calendar.firstWeekday = 2
        return calendar.dateInterval(of: self == .week ? .weekOfYear : .month, for: date)
    }
}

public struct PeriodUsageTotals: Codable, Sendable, Identifiable {
    public var period: UsagePeriod
    public var start: Date
    public var end: Date
    /// Sum of known per-request totals; nil is not zero. Missing records are counted separately.
    public var tokens: Int64?
    public var estimatedUSD: Decimal?
    public var recordCount: Int
    public var missingTokenRecords: Int
    public var unpricedRecords: Int
    public var isPartial: Bool
    public var id: String { period.rawValue }
    public init(period: UsagePeriod, start: Date, end: Date, tokens: Int64? = nil, estimatedUSD: Decimal? = nil, recordCount: Int = 0, missingTokenRecords: Int = 0, unpricedRecords: Int = 0, isPartial: Bool = false) {
        self.period = period; self.start = start; self.end = end; self.tokens = tokens; self.estimatedUSD = estimatedUSD
        self.recordCount = recordCount; self.missingTokenRecords = missingTokenRecords; self.unpricedRecords = unpricedRecords; self.isPartial = isPartial
    }
}

/// Deduplicated, consented local history. Never an account-wide billing statement.
public struct UsageOverview: Codable, Sendable {
    public var generatedAt: Date
    public var periods: [PeriodUsageTotals]
    public var pricingAsOf: String
    public var notes: [String]
    public var isPartial: Bool
    public init(generatedAt: Date, periods: [PeriodUsageTotals], pricingAsOf: String, notes: [String] = [], isPartial: Bool = false) {
        self.generatedAt = generatedAt; self.periods = periods; self.pricingAsOf = pricingAsOf; self.notes = notes; self.isPartial = isPartial
    }
    public func totals(for period: UsagePeriod, at now: Date, calendar: Calendar = .current) -> PeriodUsageTotals? {
        guard let interval = period.interval(containing: now, calendar: calendar), generatedAt >= interval.start else { return nil }
        return periods.first { $0.period == period && $0.start == interval.start && $0.end == interval.end }
    }
}
