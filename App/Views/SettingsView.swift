import SwiftUI
import AILimitCore
import AILimitShared

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    private var states: [ProviderState] {
        ProviderID.allCases.flatMap { provider in
            model.settings.connections.filter { $0.provider == provider }.map { account in
                model.snapshot.providers.first { $0.connectionID == account.id }
                    ?? ProviderState(provider: provider, connectionID: account.id, accountName: account.accountName)
            }
        }
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "gauge.with.dots.needle.67percent").symbolRenderingMode(.hierarchical).font(.title2.weight(.bold)).foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 2) { Text("AI Limit").font(.title3.bold()); Text("나의 AI 사용량").font(.caption).foregroundStyle(.secondary) }
                }.padding(22)
                List {
                    Button { model.showOverview = true } label: {
                        Label("사용량 대시보드", systemImage: "square.grid.2x2.fill").font(.headline)
                            .foregroundStyle(model.showOverview ? Color.indigo : Color.primary).padding(.vertical, 8)
                    }.buttonStyle(.plain).listRowBackground(model.showOverview ? Color.indigo.opacity(0.10) : Color.clear)
                    Section("계정 관리") {
                        ForEach(ProviderID.allCases) { provider in
                            Button { model.selected = provider } label: {
                                HStack(spacing: 10) {
                                    ProviderMark(provider: provider, size: 28)
                                    Text(provider.title).font(.subheadline.weight(.medium))
                                    Spacer()
                                    let count = model.settings.connections.reduce(0) { $0 + ($1.provider == provider ? 1 : 0) }
                                    if count > 0 { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                }.padding(.vertical, 4).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .listRowBackground(!model.showOverview && model.selected == provider ? provider.accent.opacity(0.12) : Color.clear)
                        }
                    }
                    Section("웹 서비스") {
                        Link(destination: URL(string: "https://chatgpt.com/")!) { Label("ChatGPT 열기", systemImage: "arrow.up.right") }
                        Link(destination: URL(string: "https://gemini.google.com/")!) { Label("Gemini 열기", systemImage: "arrow.up.right") }
                        Text("채팅 사용량 자동 조회는 미포함").font(.caption2).foregroundStyle(.secondary)
                    }
                }.listStyle(.sidebar).disabled(!model.canChangeAccount)
                VStack(alignment: .leading, spacing: 10) {
                    Picker("화면 모드", selection: $model.settings.theme) { Text("시스템").tag("system"); Text("라이트").tag("light"); Text("다크").tag("dark") }
                        .onChange(of: model.settings.theme) { model.persistPreferences() }
                    Label("앱 실행 중 · 1분 주기 갱신", systemImage: "arrow.triangle.2.circlepath").font(.caption2).foregroundStyle(.secondary)
                }.padding(18)
            }.navigationSplitViewColumnWidth(min: 210, ideal: 225, max: 260)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if model.settingsCorrupt {
                        Label(model.message ?? "설정 읽기 실패", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("손상된 설정 재설정", role: .destructive) { Task { await model.resetSettings() } }
                    }
                    if model.showOverview { overview }
                    else {
                        HStack {
                            Button { model.showOverview = true } label: { Label("대시보드", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(!model.canChangeAccount)
                            Spacer()
                            Text("계정 관리").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        if let state = model.snapshot.providers.first(where: { $0.connectionID == model.selectedConnectionID }) { UsageCard(state: state) }
                        ConnectionEditor(id: model.selected).id(model.connection(model.selected).id)
                    }
                    if let sharing = model.sharingMessage {
                        DisclosureGroup {
                            Text(sharing + " · 실제 위젯 공유에는 Xcode의 Apple Team과 App Group 서명이 필요합니다. WidgetKit 갱신 시점은 시스템 예산에 따릅니다.").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                        } label: { Label("위젯 연결 안내", systemImage: "square.stack.3d.up").font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color(nsColor: .windowBackgroundColor))
        }.frame(minWidth: 900, minHeight: 600)
        .onDisappear { model.cancelOAuth() }
    }
    private var overview: some View {
        let states = self.states
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("사용량 대시보드").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("기간별 남은 한도와 로컬 토큰을 계정별로.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.coordinator.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("전체 새로고침").accessibilityLabel("전체 새로고침").disabled(model.busy || states.isEmpty)
                Menu {
                    ForEach(ProviderID.allCases) { provider in Button(provider.title) { model.selected = provider; model.addAccount() } }
                } label: { Label("계정 추가", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 8)).disabled(!model.canChangeAccount || model.settingsCorrupt)
            }
            HStack(spacing: 12) {
                summary("등록된 계정", value: states.count, symbol: "person.crop.square", color: .indigo)
                summary("사용량 있는 계정", value: states.reduce(0) { $0 + ($1.lastSuccess != nil ? 1 : 0) }, symbol: "chart.bar", color: .teal)
                summary("연결 확인 필요", value: states.reduce(0) { $0 + ([.needsAuthentication, .failed, .unavailable].contains($1.status) ? 1 : 0) }, symbol: "exclamationmark.circle", color: .orange)
            }
            UsageOverviewView(overview: model.snapshot.usageOverview,
                              hasLocalSource: model.settings.connections.contains { $0.localConsentedAt != nil && $0.localFolder != nil }) {
                model.showOverview = false
            }.disabled(!model.canChangeAccount)
            HStack {
                Text("내 계정").font(.title3.bold())
                Spacer()
                Text("계정별 한도 · 합산하지 않음").font(.caption).foregroundStyle(.secondary)
            }
            if states.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 38, weight: .light)).foregroundStyle(.indigo)
                    Text("첫 계정을 연결해 보세요").font(.title2.bold())
                    Text("로그인하면 남은 한도와 리셋 시간을 여기에 모아 보여 드립니다.\n동의하기 전에는 계정이나 로컬 기록을 읽지 않습니다.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Codex 계정 연결") { model.selected = .codex; model.addAccount() }.buttonStyle(.borderedProminent).tint(.indigo).disabled(model.settingsCorrupt || !model.canChangeAccount)
                    Text("다른 서비스는 왼쪽 계정 관리에서 선택하세요.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 56).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(states) { state in
                        DashboardAccountCard(state: state, pinned: model.settings.pinnedConnectionID == state.connectionID) { model.selectAccount(state.connectionID) }.disabled(!model.canChangeAccount)
                    }
                }
            }
            Label("마지막으로 관찰한 값입니다. 리셋 시간이 지나도 사용량을 임의로 초기화하지 않습니다.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func summary(_ title: String, value: Int, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 5) { Text(value.formatted()).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit(); Text(title).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ConnectionEditor: View {
    @EnvironmentObject var model: AppModel
    let id: ProviderID
    @State private var secret = ""
    @State private var reveal = false
    @State private var consent = false
    @State private var oauthConsent = false
    @State private var legacyEnabled = false
    @State private var executable: URL?
    @State private var codexHome: URL?
    @State private var organization = ""
    @State private var confirmDisconnect = false
    @State private var loginExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { ProviderMark(provider: id, size: 40); VStack(alignment: .leading, spacing: 4) { Text(model.selectedConnectionID == nil ? "새 \(id.title) 계정" : "연결 설정").font(.title2.weight(.semibold)); Text("로그인과 표시 설정을 계정별로 관리합니다.").font(.caption).foregroundStyle(.secondary) }; Spacer(); Link(destination: id.dashboard) { Image(systemName: "arrow.up.right.square").font(.title3) }.help("서비스 열기") }
            HStack {
                Picker("계정", selection: Binding(get: { model.selectedConnectionID ?? model.draft.id }, set: { model.selectAccount($0) })) {
                    ForEach(model.accounts) { account in Text(account.accountName).tag(account.id) }
                    if model.selectedConnectionID == nil { Text("새 계정 · " + model.accountName).tag(model.draft.id) }
                }.disabled(!model.canChangeAccount)
                Button("계정 추가") { model.addAccount() }.disabled(!model.canChangeAccount || model.settingsCorrupt)
            }
            HStack {
                TextField("계정 이름 (예: 개인 / 업무)", text: $model.accountName).textFieldStyle(.roundedBorder).accessibilityLabel("계정 이름")
                    .onSubmit { Task { await model.renameSelectedAccount() } }
                if model.selectedConnectionID != nil { Button("이름 저장") { Task { await model.renameSelectedAccount() } } }
            }.disabled(model.busy || model.settingsCorrupt)
            Text(model.selectedConnectionID == nil ? "새 계정은 로그인과 사용량 확인에 성공한 뒤 저장됩니다. 다른 계정의 로그인·로컬 폴더 동의를 복사하지 않습니다." : "선택한 계정만 갱신·재로그인·삭제합니다. 계정별 한도는 합산하지 않습니다.").font(.caption).foregroundStyle(.secondary)
            Divider()
            DisclosureGroup(isExpanded: $loginExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(instructions).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    directLogin
                }.padding(.top, 12)
            } label: { Label(model.connection(id).enabled ? "로그인 관리 · 재연결" : "로그인하여 연결", systemImage: "lock.shield").font(.headline) }
                .onChange(of: loginExpanded) { if !loginExpanded { model.cancelOAuth() } }
            Toggle("고급: 기존 CLI / 수동 세션 연결", isOn: $legacyEnabled).font(.caption).disabled(model.busy)
            if legacyEnabled {
            Text(instructions).font(.caption).foregroundStyle(.secondary)
            if id.isCLI {
                Text("이미 설치·로그인한 도구의 선택적 읽기 전용 연결입니다. 자체 OAuth의 대체 방법으로 자동 설치하거나 실행하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("실행 파일 선택") { executable = model.chooseFile(directory: false) }.accessibilityLabel("실행 파일 선택"); Text(executable?.path ?? "선택하지 않음").font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }.disabled(model.busy)
                if id == .codex {
                    HStack {
                        Button("별도 CODEX_HOME 선택(선택 사항)") { codexHome = model.chooseFile(directory: true, codexHome: true) }
                            .accessibilityLabel("별도 Codex 로그인 저장소 선택")
                        if codexHome != nil { Button("기본값") { codexHome = nil } }
                    }.disabled(model.busy)
                    Text(codexHome?.path ?? "기본 Codex 로그인 저장소 사용").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else {
                Label("세션은 사용량 조회보다 넓은 계정 권한을 가질 수 있습니다. 본인의 세션만 입력하세요. 앱 전용 Keychain에만 저장됩니다.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Group { if reveal { TextField(id == .windsurf ? "네 devin 필드 JSON" : "새 세션 값", text: $secret, axis: .vertical).lineLimit(2...7) } else { SecureField(id == .windsurf ? "네 devin 필드 JSON 붙여넣기" : "새 세션 값", text: $secret) } }.textFieldStyle(.roundedBorder)
                Toggle("입력 내용 보기", isOn: $reveal).font(.caption)
            }
            if id == .claude && !model.organizations.isEmpty { Picker("Claude 조직", selection: $organization) { Text("조직 선택").tag(""); ForEach(model.organizations) { org in Text(org.name).tag(org.id) } } }
            Toggle(id.unofficial ? "비공식 연동의 위험을 이해하고 사용량 읽기에 동의합니다." : "선택한 CLI를 실행하여 사용량을 읽는 데 동의합니다.", isOn: $consent).font(.caption).disabled(model.busy)
                .accessibilityLabel(id.unofficial ? "비공식 연동과 사용량 읽기 동의" : "선택한 CLI 실행과 사용량 읽기 동의")
            HStack {
                Button { Task { await model.connect(id, rawSecret: secret, executable: executable, organization: organization.isEmpty ? nil : organization, codexHome: codexHome); if model.message?.hasPrefix("연결 완료") == true { secret = "" } } } label: { HStack { if model.busy && model.oauthProgress == nil { ProgressView().controlSize(.small) }; Text(id.isCLI ? "기존 CLI 읽기 연결 저장" : "수동 세션 연결 테스트 및 저장") } }.buttonStyle(.borderedProminent).disabled(!consent || model.busy || model.settingsCorrupt || (id.isCLI ? executable == nil : secret.isEmpty))
            }
            }
            HStack {
                Button("새로고침") { Task { await model.coordinator.refresh(only: model.connection(id).id) } }.disabled((!model.connection(id).enabled && model.connection(id).localConsentedAt == nil) || model.busy)
                Spacer()
                Button("계정 삭제", role: .destructive) { confirmDisconnect = true }.disabled(model.busy || model.selectedConnectionID == nil)
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary).accessibilityLabel(message) }
            Divider()
            Toggle("메뉴 막대에 이 계정 고정", isOn: Binding(get: { model.settings.pinnedConnectionID == model.selectedConnectionID && model.selectedConnectionID != nil }, set: { model.settings.pinnedConnectionID = $0 ? model.selectedConnectionID : nil; model.persistPreferences() })).font(.callout).disabled(model.busy || model.selectedConnectionID == nil || model.settingsCorrupt)
            if id == .codex || id == .claude {
                DisclosureGroup("로컬 기록 · 별도 읽기 동의") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(id == .codex ? "~/.codex 폴더를 선택하세요. sessions와 archived_sessions의 가장 최근 세션 누적 카운터만 표시합니다. 계정/오늘/7일 총량이 아닙니다." : "~/.claude/projects 폴더를 선택하세요. 이 Mac의 assistant 기록을 오늘/최근 7일로 집계합니다. 삭제·누락된 기록은 알 수 없습니다.").font(.caption).foregroundStyle(.secondary)
                    Button("\(id.title) 로그 폴더 선택 및 읽기 동의") { Task { await model.connectLocal(id) } }.disabled(model.settingsCorrupt || model.busy)
                    Divider()
                    Text("OMP: ~/.omp/agent/sessions 폴더를 선택하세요. \(id == .codex ? "openai-codex" : "anthropic") 요청만 최근 세션·오늘·최근 7일로 집계합니다. 다른 공급자의 사용량은 섞지 않습니다.").font(.caption).foregroundStyle(.secondary)
                    Button("OMP 세션 폴더 선택 및 읽기 동의") { Task { await model.connectLocal(id, source: .omp) } }.disabled(model.settingsCorrupt || model.busy)
                    if let folder = model.connection(id).localFolder {
                        Text("선택한 기록: " + (model.connection(id).localSource == .omp ? "OMP" : id.title)).font(.caption.weight(.medium))
                        Text(folder.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text("선택하면 기존 로컬 기록 연결을 교체합니다. 이 Mac의 기록이며 로그인한 원격 계정의 총량이 아닙니다. 웹 연결 없이도 사용할 수 있고, 원본 대화·인증정보는 저장하거나 전송하지 않습니다.").font(.caption2).foregroundStyle(.secondary)
                }.padding(.top, 10)
                }.font(.callout)
            }
        }.padding(24).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .tint(id.accent)
        .onAppear { let connection = model.connection(id); executable = connection.executable; codexHome = connection.codexHome; organization = connection.claudeOrganization ?? ""; legacyEnabled = false; loginExpanded = !connection.enabled }
        .onDisappear { model.cancelOAuth() }
        .confirmationDialog("이 계정의 로그인과 별도로 동의한 로컬 기록 표시를 삭제할까요? 다른 계정, CLI 로그인과 원본 기록은 유지됩니다.", isPresented: $confirmDisconnect) { Button("이 계정 삭제", role: .destructive) { if let accountID = model.selectedConnectionID { Task { await model.disconnect(accountID) } } } }
    }
    private var directLogin: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(id == .perplexity ? "AI Limit 전용 웹 로그인" : "브라우저에서 계정 연결").font(.headline)
            Text("다른 앱의 로그인 파일·Keychain·브라우저 쿠키 저장소를 읽지 않습니다. 새로 승인한 토큰은 AI Limit 전용 Keychain에 저장하며, 실제 사용량 조회에 성공해야 연결을 교체합니다.").font(.caption).foregroundStyle(.secondary)
            Text("비공식 인증 클라이언트 / 내부 API를 사용합니다. 승인 권한은 사용량 읽기보다 넓을 수 있고, 업체 정책·접근 제한에 따라 중단될 수 있습니다.").font(.caption).foregroundStyle(.secondary)
            if id == .codex {
                Text("추가할 OpenAI 계정을 브라우저에서 선택하세요. 기존 계정으로 자동 로그인되면 OpenAI에서 로그아웃한 뒤 다른 계정으로 다시 진행하세요. 이미 저장한 AI Limit 연결은 유지됩니다.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("위 서비스별 제약과 비공식 연동 위험을 이해하고 로그인·사용량 조회에 동의합니다.", isOn: $oauthConsent).font(.caption).disabled(model.busy)
            HStack {
                Button(id.title + (model.connection(id).enabled ? " 재로그인" : " 로그인")) { model.startDirectLogin(id) }.buttonStyle(.borderedProminent).disabled(!oauthConsent || model.busy || model.settingsCorrupt)
                if model.oauthProgress != nil { Button("인증 취소") { model.cancelOAuth() }.disabled(!model.canCancelOAuth) }
            }
            if let code = model.oauthUserCode {
                Text(code).font(.title.monospaced()).textSelection(.enabled).accessibilityLabel("인증 코드 " + code)
                if let url = model.oauthVerificationURL { Link("브라우저에서 코드 입력", destination: url) }
                Text("이 창에서 요청한 코드만 승인하세요. 로그인 화면에 표시되는 클라이언트 이름은 AI Limit와 다를 수 있습니다.").font(.caption)
            }
            if let progress = model.oauthProgress { HStack { ProgressView().controlSize(.small); Text(progress).font(.caption) } }
            if model.connection(id).enabled {
                Label(model.connection(id).directAuthentication == true ? "직접 로그인 연결 사용 중" : "기존 연결 유지 중 · 직접 로그인 성공 후 교체됩니다.", systemImage: "link").font(.caption)
            }
        }.padding(16).background(id.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
    private var instructions: String {
        switch id {
        case .codex: "OpenAI 계정으로 브라우저에서 로그인하고 Codex 구독 한도·리셋·제공된 크레딧을 직접 조회합니다. Codex 설치가 필요하지 않습니다. ChatGPT 일반 채팅 한도와는 다릅니다."
        case .claude: "Claude 계정의 5시간·주간·모델별 사용량을 조회합니다. 주의: Anthropic은 타사 앱의 Claude.ai 로그인 제공을 명시적으로 제한합니다. 이 비공식 연결은 공식 허가가 아니며 접근 차단 위험이 있습니다. 웹 세션에서만 제공되는 추가 결제 정보는 OAuth 조회와 다를 수 있습니다."
        case .antigravity: "Google 계정으로 로그인하고 Antigravity 모델 그룹의 한도·리셋을 조회합니다. agy 설치는 필요하지 않지만 README에 안내된 로컬 OAuth 설정(clientID·clientSecret)이 필요합니다. Google 신원 로그인 성공과 quota 접근 권한은 별개이며, 타사 접근에 따른 제한·계정 제재 위험이 있습니다. Gemini 웹앱 사용량이 아닙니다."
        case .copilot: "브라우저에 인증 코드를 입력하여 Copilot 계정의 제공된 잔여 한도·크레딧·리셋 정보를 조회합니다. gh 설치나 GitHub App 등록이 필요하지 않습니다. 공개 개인 청구 보고서가 아닌 비공식 Copilot quota API를 사용합니다."
        case .kiro: "AWS Builder ID 기기 인증으로 로그인하고 Kiro 크레딧·한도·보너스·리셋을 조회합니다. kiro-cli 설치나 개발자 앱 등록은 필요하지 않습니다. Google/GitHub 소셜 전용 계정은 이 Builder ID 연결과 별개입니다."
        case .cursor: "Cursor 브라우저 로그인 승인을 받아 현재 청구 기간의 포함 사용량·한도·사용률을 직접 조회합니다. Cursor 에디터 설치나 Cookie 복사가 필요하지 않습니다."
        case .grok: "xAI 기기 인증으로 로그인하고 Grok Build / 통합 크레딧 사용률·기간·제공된 추가 사용금액을 조회합니다. Grok CLI 설치는 필요하지 않습니다. 모든 Grok 웹 채팅·모델별 메시지 제한과 같지는 않습니다."
        case .windsurf: "Devin 브라우저 로그인 후 같은 세션으로 Codeium 계열 일간·주간 잔여율을 조회합니다. Windsurf 설치가 필요하지 않습니다. 기존 Windsurf 계정의 이전·조직 상태에 따라 이 인증 경로를 사용할 수 없으며, Devin 클라우드 작업 잔액 조회가 아닙니다."
        case .perplexity: "AI Limit의 격리된 웹 창에서 직접 로그인하여 크레딧 잔액·사용액·갱신일을 조회합니다. OAuth가 아닌 웹 세션 인증입니다. Google/Apple의 내장 브라우저 제한, 기업 SSO 또는 Cloudflare로 연결이 거부될 수 있습니다. 크레딧은 검색 횟수·토큰과 다릅니다."
        }
    }
}
