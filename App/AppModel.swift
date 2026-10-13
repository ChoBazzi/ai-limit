import SwiftUI
import AppKit
import WidgetKit
import AILimitCore
import AILimitShared

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = ConnectionSettings()
    @Published var snapshot = SharedSnapshot(updatedAt: Date(), providers: [])
    @Published private(set) var menuDate = Date()
    @Published var showOverview = true {
        didSet { if showOverview && !oldValue { cancelOAuth() } }
    }
    @Published var selected: ProviderID = .codex {
        didSet {
            showOverview = false
            if selected != oldValue { cancelOAuth(); selectDefaultAccount(); message = nil; organizations = [] }
        }
    }
    @Published private(set) var selectedConnectionID: String?
    @Published var accountName = "계정 1"
    @Published private(set) var draft = Connection(provider: .codex, accountName: "계정 1")
    @Published var message: String?
    @Published var sharingMessage: String?
    @Published var settingsCorrupt = false
    @Published var busy = false
    @Published var organizations: [ClaudeOrganization] = []
    @Published private(set) var oauthProgress: String?
    @Published private(set) var oauthUserCode: String?
    @Published private(set) var oauthVerificationURL: URL?
    private let webLogin = PerplexityWebLogin()
    private var oauthTask: Task<Void, Never>?
    private var oauthGeneration = UUID()
    private var oauthCommitting = false
    private weak var oauthWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private let settingsStore: SettingsStore
    private let secrets: any SecretStore
    private let http: any HTTPTransport
    private var loop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    lazy var coordinator = UsageCoordinator(connections: settings.connections, secrets: secrets, http: http, store: SnapshotStore(fallbackDirectory: settingsStore.url.deletingLastPathComponent()), changed: { [weak self] snapshot, warning in
        Task { @MainActor in self?.snapshot = snapshot; self?.sharingMessage = warning; WidgetCenter.shared.reloadTimelines(ofKind: "dev.bazzi.ai-limit.usage") }
    })
    init(settingsStore: SettingsStore = SettingsStore(), secrets: any SecretStore = KeychainStore(), http: any HTTPTransport = SecureHTTPTransport()) {
        self.settingsStore = settingsStore; self.secrets = secrets; self.http = http
        do { settings = try settingsStore.load() } catch { settingsCorrupt = true; message = "설정 파일이 손상되었습니다. 자동으로 덮어쓰지 않습니다. 재설정을 선택하세요." }
        selectDefaultAccount()
        sharingMessage = SnapshotReader.groupURL() == nil ? "위젯 공유 설정 필요" : nil
        applyAppearance()
        loop = Task { [weak self] in
            guard let self else { return }; snapshot = await coordinator.current()
            while !Task.isCancelled {
                await coordinator.refresh()
                // Drive the clock outside MenuBarExtra's label to avoid repeated status-item layout.
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                menuDate = Date()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.coordinator.refresh() } }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            let closedWindowID = ObjectIdentifier(window)
            MainActor.assumeIsolated {
                guard let self, self.oauthWindow.map(ObjectIdentifier.init) == closedWindowID else { return }
                self.cancelOAuth()
            }
        }
    }
    var colorScheme: ColorScheme? { settings.theme == "dark" ? .dark : settings.theme == "light" ? .light : nil }
    func menuTitle(at now: Date) -> String {
        guard let pin = settings.pinnedConnectionID, let connection = settings.connections.first(where: { $0.id == pin }) else { return "AI" }
        guard let state = snapshot.providers.first(where: { $0.connectionID == pin }) else { return connection.provider.title + " · " + connection.accountName + " · 한도 미제공" }
        return UsageFormat.menuTitle(state, at: now)
    }
    var accounts: [Connection] { settings.connections.filter { $0.provider == selected } }
    var canChangeAccount: Bool { !busy || canCancelOAuth }
    func connection(_ provider: ProviderID) -> Connection {
        if provider == selected {
            return settings.connections.first { $0.id == selectedConnectionID && $0.provider == provider } ?? draft
        }
        return settings.connections.first { $0.provider == provider } ?? Connection(provider: provider)
    }
    private func makeDraft() -> Connection {
        let existing = accounts
        var number = existing.count + 1
        var name = "계정 \(number)"
        while existing.contains(where: { $0.accountName == name }) { number += 1; name = "계정 \(number)" }
        return Connection(provider: selected, accountName: name)
    }
    private func selectDefaultAccount() {
        draft = makeDraft()
        selectedConnectionID = accounts.first?.id
        accountName = connection(selected).accountName
    }
    func selectAccount(_ accountID: String) {
        guard canChangeAccount, let account = settings.connections.first(where: { $0.id == accountID }) else { return }
        cancelOAuth(); selected = account.provider; selectedConnectionID = accountID
        accountName = account.accountName; message = nil; organizations = []
    }
    func addAccount() {
        guard canChangeAccount else { return }
        cancelOAuth(); showOverview = false; draft = makeDraft()
        selectedConnectionID = nil; accountName = draft.accountName; message = nil; organizations = []
    }
    private func validatedAccountName() throws -> String {
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw UsageError.configuration("계정 이름은 줄바꿈 없이 1~64자로 입력하세요.")
        }
        return name
    }
    func renameSelectedAccount() async {
        guard !settingsCorrupt, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let name = try validatedAccountName()
            guard let id = selectedConnectionID, let index = settings.connections.firstIndex(where: { $0.id == id }) else {
                draft.accountName = name; accountName = name; return
            }
            var updated = settings; updated.connections[index].accountName = name
            try settingsStore.save(updated); settings = updated; accountName = name
            await coordinator.rename(id, accountName: name)
            message = "계정 이름을 저장했습니다. 사용량과 로그인은 유지됩니다."
        } catch { message = (error as? UsageError)?.localizedDescription ?? "계정 이름 저장 실패" }
    }
    func persistPreferences() { applyAppearance(); guard !settingsCorrupt else { return }; do { try settingsStore.save(settings) } catch { message = "설정을 저장하지 못했습니다." } }
    private func applyAppearance() { NSApp.appearance = settings.theme == "dark" ? NSAppearance(named: .darkAqua) : settings.theme == "light" ? NSAppearance(named: .aqua) : nil }
    func chooseFile(directory: Bool, codexHome: Bool = false, initialDirectory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false
        panel.directoryURL = initialDirectory
        panel.prompt = codexHome ? "이 CODEX_HOME 선택" : directory ? "이 폴더 읽기에 동의" : "이 CLI 선택"
        panel.message = directory ? "선택한 폴더만 읽습니다. 원본 기록은 수정하지 않습니다." : "선택한 기존 CLI를 읽기 전용 사용량 조회에만 사용합니다. AI Limit 자체 OAuth가 아니며 앱이 CLI 로그인을 시작하지 않습니다."
        return panel.runModal() == .OK ? panel.url : nil
    }
    func startDirectLogin(_ id: ProviderID) {
        guard !settingsCorrupt, !busy, oauthTask == nil else { return }
        var candidate = connection(id)
        do { candidate.accountName = try validatedAccountName() }
        catch { message = (error as? UsageError)?.localizedDescription; return }
        let generation = UUID()
        oauthGeneration = generation; oauthWindow = NSApp.keyWindow
        busy = true; oauthProgress = "\(id.title) 로그인 준비 중…"; message = nil
        oauthTask = Task { [weak self] in
            guard let self else { return }
            defer {
                oauthTask = nil; oauthProgress = nil; oauthUserCode = nil; oauthVerificationURL = nil
                oauthWindow = nil; oauthCommitting = false; busy = false
            }
            do {
                let opener: @Sendable (URL) async throws -> Void = { [weak self] url in
                    try await MainActor.run {
                        guard let self else { throw CancellationError() }
                        try self.checkOAuth(generation)
                        try self.openAuthorizationURL(url, provider: id)
                    }
                }
                let ui = DirectSignInUI(openURL: opener, showCode: { [weak self] code, url in
                    try await MainActor.run {
                        guard let self else { throw CancellationError() }
                        try self.checkOAuth(generation)
                        self.oauthUserCode = code; self.oauthVerificationURL = url
                        self.oauthProgress = "브라우저에서 이 창의 코드를 확인하고 로그인 승인을 완료하세요."
                    }
                    try await opener(url)
                }, authorize: { url, redirect, state in
                    try await OAuthLoopback.authorize(authorizationURL: url, redirectURL: redirect, state: state, openURL: opener)
                })
                let credential: DirectCredential
                if id == .perplexity { credential = try await webLogin.signIn() }
                else { credential = try await DirectAuthentication.signIn(id, http: http, ui: ui) }
                try checkOAuth(generation)
                oauthUserCode = nil; oauthVerificationURL = nil
                oauthProgress = "인증 완료 · 실제 계정 사용량 확인 중…"
                try validateAccountBinding(credential, replacing: candidate)
                candidate.enabled = true; candidate.consentedAt = Date(); candidate.directAuthentication = true
                candidate.credentialReference = candidate.id
                candidate.executable = nil; candidate.codexHome = nil; candidate.claudeOrganization = nil
                let pending = PendingCredentialStore(try credential.encoded(), for: candidate.id)
                let initial = try await Providers.make(id).fetch(context: FetchContext(connection: candidate, secrets: pending, http: http))
                try checkOAuth(generation)
                guard let encoded = try pending.load(candidate.id) else { throw UsageError.authentication }
                oauthCommitting = true; oauthProgress = "검증된 연결 저장 중…"
                try await commit(candidate, secret: encoded, initial: initial)
                message = "연결 완료 · 외부 앱 없이 로그인하고 실제 사용량을 확인했습니다."
            } catch {
                guard oauthGeneration == generation else { return }
                if error is CancellationError {
                    message = "로그인을 취소했습니다. 기존 연결은 유지됩니다."
                } else if case UsageError.cancelled = error {
                    message = "로그인을 취소했습니다. 기존 연결은 유지됩니다."
                } else {
                    message = (error as? UsageError)?.localizedDescription ?? "로그인 연결 실패. 기존 연결은 유지됩니다."
                }
            }
        }
    }
    // Called only during an explicitly requested login, never during migration/startup.
    func validateAccountBinding(_ credential: DirectCredential, replacing candidate: Connection) throws {
        guard candidate.provider == .codex else { return }
        for account in settings.connections where account.provider == .codex && account.directAuthentication == true {
            guard let encoded = try secrets.load(account.id) else { continue }
            let existing = try DirectCredential.decode(encoded, for: .codex)
            if account.id == candidate.id {
                for key in ["accountID", "subject"] {
                    if let previous = existing.metadata[key], !previous.isEmpty, credential.metadata[key] != previous {
                        throw UsageError.configuration("선택한 계정과 다른 로그인입니다. 다른 계정은 ‘계정 추가’로 연결하세요. 기존 연결은 유지됩니다.")
                    }
                }
            } else {
                let sameWorkspace = credential.metadata["accountID"].map { !$0.isEmpty && $0 == existing.metadata["accountID"] } ?? false
                let sameSubject = credential.metadata["subject"].map { !$0.isEmpty && $0 == existing.metadata["subject"] } ?? false
                let sameRefresh = credential.refreshToken.map { !$0.isEmpty && $0 == existing.refreshToken } ?? false
                if (sameWorkspace && sameSubject) || credential.accessToken == existing.accessToken || sameRefresh {
                    throw UsageError.configuration("이미 ‘\(account.accountName)’에 연결된 계정입니다. 해당 계정을 선택해 재로그인하거나 브라우저에서 다른 계정으로 로그인하세요.")
                }
            }
        }
    }
    private func commit(_ candidate: Connection, secret: String?, initial: UsageSnapshot) async throws {
        let old = settings.connections.first { $0.id == candidate.id }
        let oldSnapshot = snapshot.providers.first { $0.connectionID == candidate.id }?.lastSuccess
        if var paused = old { paused.enabled = false; await coordinator.replace(paused) }
        do {
            let previous = try secrets.load(candidate.id)
            if let secret { try secrets.save(secret, for: candidate.id) } else { try secrets.remove(candidate.id) }
            var updated = settings
            if let index = updated.connections.firstIndex(where: { $0.id == candidate.id }) { updated.connections[index] = candidate }
            else { updated.connections.append(candidate) }
            do { try settingsStore.save(updated) }
            catch {
                if let previous { try secrets.save(previous, for: candidate.id) } else { try secrets.remove(candidate.id) }
                throw error
            }
            settings = updated; selectedConnectionID = candidate.id; accountName = candidate.accountName
            await coordinator.replace(candidate, initial: initial)
        } catch {
            if let old { await coordinator.replace(old, initial: oldSnapshot) }
            throw error
        }
    }
    private func openAuthorizationURL(_ url: URL, provider: ProviderID) throws {
        let hosts: Set<String>
        switch provider {
        case .codex: hosts = ["auth.openai.com"]
        case .claude: hosts = ["claude.ai"]
        case .antigravity: hosts = ["accounts.google.com"]
        case .copilot: hosts = ["github.com"]
        case .cursor: hosts = ["cursor.com"]
        case .grok: hosts = ["auth.x.ai"]
        case .windsurf: hosts = ["app.devin.ai"]
        case .kiro: hosts = ["view.awsapps.com", "oidc.us-east-1.amazonaws.com"]
        case .perplexity: hosts = ["www.perplexity.ai"]
        }
        guard url.scheme == "https", hosts.contains(url.host ?? ""), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { throw UsageError.configuration("허용되지 않은 로그인 주소") }
        guard NSWorkspace.shared.open(url) else { throw UsageError.configuration("기본 브라우저를 열 수 없습니다.") }
    }
    private func checkOAuth(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard oauthGeneration == generation else { throw CancellationError() }
    }
    func cancelOAuth() {
        guard let oauthTask, !oauthCommitting else { return }
        oauthGeneration = UUID(); oauthTask.cancel(); webLogin.cancel(); oauthUserCode = nil; oauthVerificationURL = nil
        oauthProgress = "인증 취소 중…"
        message = "로그인을 취소했습니다. 기존 연결은 유지됩니다. 이미 승인한 권한은 서비스 설정에서 별도로 철회할 수 있습니다."
    }
    var canCancelOAuth: Bool { oauthTask != nil && !oauthCommitting }
    func prepareForTermination() async {
        loop?.cancel(); cancelOAuth(); await oauthTask?.value
    }
    func connect(_ id: ProviderID, rawSecret: String, executable: URL?, organization: String?, codexHome: URL?) async {
        guard !settingsCorrupt, !busy else { return }; busy = true; message = nil; defer { busy = false }
        do {
            let credential = id.isCLI ? "" : try Credentials.validate(rawSecret, for: id)
            var candidate = connection(id)
            candidate.accountName = try validatedAccountName()
            candidate.enabled = true; candidate.consentedAt = Date(); candidate.executable = executable; candidate.codexHome = codexHome
            candidate.credentialReference = id.isCLI ? nil : candidate.id; candidate.claudeOrganization = organization
            candidate.directAuthentication = nil
            if id == .claude {
                let choices = try await ClaudeProvider().organizations(context: FetchContext(connection: candidate, secrets: SuppliedSecret(credential), http: http))
                guard !choices.isEmpty else { throw UsageError.configuration("연결 가능한 Claude 조직이 없습니다.") }
                organizations = choices
                if choices.count == 1 { candidate.claudeOrganization = choices[0].id }
                else if !choices.contains(where: { $0.id == organization }) { message = "아래에서 Claude 조직을 선택하고 다시 연결하세요."; return }
            }
            let initial = try await Providers.make(id).fetch(context: FetchContext(connection: candidate, secrets: SuppliedSecret(credential), http: http))
            try await commit(candidate, secret: id.isCLI ? nil : credential, initial: initial)
            message = "연결 완료 · 실측 사용량을 저장했습니다."
        } catch { message = (error as? UsageError)?.localizedDescription ?? "연결 또는 저장 실패. 기존 연결은 유지됩니다." }
    }
    func disconnect(_ accountID: String) async {
        guard !settingsCorrupt else { return }
        cancelOAuth(); await oauthTask?.value
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard let account = settings.connections.first(where: { $0.id == accountID }) else { return }
        do {
            var updated = settings; updated.connections.removeAll { $0.id == accountID }
            if updated.pinnedConnectionID == accountID { updated.pinnedConnectionID = nil }
            // Drain this account only: no late refresh can recreate its Keychain item.
            var paused = account; paused.enabled = false
            await coordinator.replace(paused)
            try secrets.remove(accountID); try settingsStore.save(updated)
            settings = updated; await coordinator.disconnect(accountID)
            if selectedConnectionID == accountID { selectDefaultAccount() }
            message = "이 계정의 연결과 전용 Keychain을 삭제했습니다. 다른 계정은 유지됩니다. 승인 권한은 서비스 설정에서 별도로 철회하세요. 기존 CLI 로그인과 원본 로그는 유지됩니다."
        } catch { message = "연결 해제 저장 실패. 이 계정의 자동 조회를 중지했습니다. 다시 시도하세요." }
    }
    func connectLocal(_ id: ProviderID, source: LocalTokenSource = .native) async {
        guard !settingsCorrupt, !busy else { return }
        busy = true; defer { busy = false }
        var candidate = connection(id)
        do {
            candidate.accountName = try validatedAccountName()
            let initialDirectory = source == .omp ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".omp/agent/sessions") : nil
            guard let folder = chooseFile(directory: true, initialDirectory: initialDirectory) else { return }
            candidate.localFolder = folder; candidate.localConsentedAt = Date(); candidate.localSource = source
            var updated = settings
            if let index = updated.connections.firstIndex(where: { $0.id == candidate.id }) { updated.connections[index] = candidate }
            else { updated.connections.append(candidate) }
            try settingsStore.save(updated); settings = updated
            selectedConnectionID = candidate.id; accountName = candidate.accountName
            let initial = snapshot.providers.first { $0.connectionID == candidate.id }?.lastSuccess
            await coordinator.replace(candidate, initial: initial); await coordinator.refresh(only: candidate.id)
        } catch { message = (error as? UsageError)?.localizedDescription ?? "로컬 연결 저장 실패" }
    }
    func resetSettings() async {
        cancelOAuth()
        await oauthTask?.value
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            for account in settings.connections { await coordinator.disconnect(account.id) }
            try secrets.removeAll()
            let fresh = ConnectionSettings(); try settingsStore.save(fresh)
            settings = fresh; settingsCorrupt = false; selectDefaultAccount()
            message = "설정과 앱 전용 Keychain을 재설정했습니다. 서비스에서 승인한 앱 권한은 별도로 철회하세요."
        } catch { message = "재설정 실패 · 파일 및 Keychain 권한을 확인하세요." }
    }
    func handle(_ url: URL) {
        guard url.scheme == "ailimit", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard canChangeAccount else { message = "계정 저장 작업이 끝난 뒤 다시 여세요."; return }
        if url.host == "account", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
            guard segments.count == 2, segments[0].isEmpty, let accountID = String(segments[1]).removingPercentEncoding else { return }
            if settings.connections.contains(where: { $0.id == accountID }) { selectAccount(accountID) }
            else { addAccount(); message = "삭제되었거나 이 Mac에 없는 계정입니다. 위젯 편집에서 계정을 다시 선택하세요." }
        } else if url.host == "provider", let provider = ProviderID(rawValue: url.lastPathComponent) { selected = provider }
        else if url.host == "settings" { showOverview = true }
    }
}
