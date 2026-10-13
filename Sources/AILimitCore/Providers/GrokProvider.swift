import Foundation
import AILimitShared
public struct GrokProvider: UsageProvider {
    public let id: ProviderID = .grok
    public init() {}
    public func fetch(context: FetchContext) async throws -> UsageSnapshot {
        let bearer = try Credentials.validate(context.secret(), for: id)
        return try await GrokDirectProvider().fetch(context: context, credential: DirectCredential(provider: id, accessToken: bearer))
    }
}
