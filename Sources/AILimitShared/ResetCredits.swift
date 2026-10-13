import Foundation

/// Available reset passes, separate from monetary/usage credits.
public struct ResetCredits: Codable, Sendable {
    public var availableCount: Int64
    /// Nil means details were not provided; the backend may return only a subset.
    public var credits: [ResetCredit]?
    public init(availableCount: Int64, credits: [ResetCredit]? = nil) {
        self.availableCount = availableCount
        self.credits = credits
    }
}

public struct ResetCredit: Codable, Sendable {
    /// Nil means the source explicitly reports no expiration, not a missing detail row.
    public var expiresAt: Date?
    public init(expiresAt: Date?) { self.expiresAt = expiresAt }
}

extension UsageFormat {
    public static func resetCreditsSummary(_ usage: UsageSnapshot?) -> String {
        guard let credits = usage?.resetCredits else { return "리셋권 정보 미제공" }
        return "리셋권 \(credits.availableCount)개"
    }
}
