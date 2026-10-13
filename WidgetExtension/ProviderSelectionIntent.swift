import AppIntents
import AILimitShared

struct ProviderEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "연결된 계정")
    static let defaultQuery = ProviderQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}
struct ProviderQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ProviderEntity] {
        let snapshot = SnapshotReader.read()
        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }.map { id in
            // Keep an unresolved selection explicit; dropping it would mean "all accounts".
            let state = snapshot?.providers.first { $0.id == id }
            return ProviderEntity(id: id, title: state?.displayTitle ?? "연결되지 않은 계정")
        }
    }
    func suggestedEntities() async throws -> [ProviderEntity] {
        (SnapshotReader.read()?.orderedProviders() ?? []).map { ProviderEntity(id: $0.id, title: $0.displayTitle) }
    }
}
struct ProviderSelectionIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "AI 사용량"
    static let description = IntentDescription("선택하지 않으면 연결된 계정을 기본 순서로 표시합니다.")
    @Parameter(title: "계정", default: []) var providers: [ProviderEntity]
}
