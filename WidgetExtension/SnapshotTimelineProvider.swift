import WidgetKit
import AILimitShared

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedSnapshot?
    let selection: [String]
    var providers: [ProviderState] { snapshot?.orderedProviders(selection: selection) ?? [] }
}
struct SnapshotTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: .now, snapshot: nil, selection: []) }
    func snapshot(for configuration: ProviderSelectionIntent, in context: Context) async -> UsageEntry { UsageEntry(date: .now, snapshot: SnapshotReader.read(), selection: configuration.providers.map(\.id)) }
    func timeline(for configuration: ProviderSelectionIntent, in context: Context) async -> Timeline<UsageEntry> {
        let now = Date(); let snapshot = SnapshotReader.read(); let selection = configuration.providers.map(\.id)
        // Reformat cached reset countdowns without issuing additional collection requests.
        var boundaries = [now] + (1...15).map { now.addingTimeInterval(Double($0) * 60) }
        for provider in snapshot?.orderedProviders(selection: selection) ?? [] {
            if let value = provider.lastSuccess {
                boundaries.append(value.fetchedAt.addingTimeInterval(900))
                boundaries.append(contentsOf: value.windows.compactMap { $0.resetBoundary() })
                boundaries.append(contentsOf: value.resetCredits?.credits?.compactMap(\.expiresAt) ?? [])
            }
        }
        let dates = Set(boundaries.filter { $0 >= now && $0 <= now.addingTimeInterval(900) }).sorted()
        return Timeline(entries: dates.map { UsageEntry(date: $0, snapshot: snapshot, selection: selection) }, policy: .after(now.addingTimeInterval(900)))
    }
}
