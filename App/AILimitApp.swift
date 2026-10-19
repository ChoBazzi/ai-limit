import SwiftUI
import AppKit
import AILimitShared

@main
struct AILimitApp: App {
    @StateObject private var model: AppModel
    @NSApplicationDelegateAdaptor(AILimitAppDelegate.self) private var appDelegate
    init() {
        let model = _appDelegate.wrappedValue.model
        _model = StateObject(wrappedValue: model)
    }
    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(model).preferredColorScheme(model.colorScheme)
        } label: {
            let title = model.menuTitle(at: model.menuDate)
            HStack(spacing: 4) {
                Image(systemName: "sparkles").renderingMode(.template)
                if title != "AI" { Text(title) }
            }
            .accessibilityLabel("AI Limit " + title)
        }.menuBarExtraStyle(.window)
        Window("AI Limit · 연결과 사용량", id: "settings") {
            SettingsView().environmentObject(model).preferredColorScheme(model.colorScheme)
                .onOpenURL { url in
                    model.handle(url)
                    Task { await model.coordinator.refresh() }
                }
                .onAppear {
                    Task { await model.coordinator.refresh() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                    Task { await model.coordinator.refresh() }
                }
        }.defaultSize(width: 1080, height: 760).windowResizability(.contentMinSize)
    }
}

@MainActor
final class AILimitAppDelegate: NSObject, NSApplicationDelegate {
    // Own the model before any window/menu appears, including background launches.
    let model = AppModel()
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MenuPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let accounts = model.snapshot.orderedProviders()
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent").symbolRenderingMode(.hierarchical).foregroundStyle(.indigo).font(.title2)
                VStack(alignment: .leading, spacing: 2) { Text("AI Limit").font(.headline); Text("기간별 남은 한도 · 로컬 토큰").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Button { Task { await model.coordinator.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("전체 새로고침").accessibilityLabel("전체 새로고침")
                Button { model.showOverview = true; openSettings() } label: { Image(systemName: "square.grid.2x2") }.buttonStyle(.plain).help("사용량 대시보드").accessibilityLabel("사용량 대시보드").disabled(!model.canChangeAccount)
            }.padding(12)
            UsageOverviewView(overview: model.snapshot.usageOverview,
                              hasLocalSource: model.settings.connections.contains { $0.localConsentedAt != nil && $0.localFolder != nil }) {
                model.showOverview = false; openSettings()
            }.disabled(!model.canChangeAccount).padding(.horizontal, 10).padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    if model.snapshot.providers.isEmpty {
                        Image(systemName: "link.badge.plus").font(.system(size: 32)).foregroundStyle(.secondary).padding(.top, 24)
                        Text("나의 AI, 한눈에").font(.title3.bold())
                        Text("개인 구독의 남은 한도를 연결하세요.\n동의 전에는 계정이나 기록을 읽지 않습니다.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("서비스 연결") { model.showOverview = true; openSettings() }.buttonStyle(.borderedProminent).tint(.indigo).padding(.bottom, 24)
                    }
                    Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(0..<((accounts.count + 1) / 2), id: \.self) { row in
                            GridRow {
                                ForEach(0..<2, id: \.self) { column in
                                    let index = row * 2 + column
                                    if index < accounts.count {
                                        let state = accounts[index]
                                        Button { model.selectAccount(state.connectionID); openSettings() } label: {
                                            UsageCard(state: state, compact: true).frame(width: 356, alignment: .leading)
                                        }.buttonStyle(.plain).accessibilityElement(children: .combine)
                                            .accessibilityHint("이 계정의 사용량 상세와 연결 관리 열기").disabled(!model.canChangeAccount)
                                    }
                                }
                            }
                        }
                    }
                    if let warning = model.sharingMessage { Label(warning, systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.secondary) }
                }.padding(10)
            }.frame(height: model.snapshot.providers.isEmpty ? 280 : 590)
            Divider()
            HStack { Text("읽기 전용 · 1분 주기").font(.caption).foregroundStyle(.secondary); Spacer(); Button("종료") { NSApp.terminate(nil) }.buttonStyle(.plain) }.padding(10)
        }.frame(width: 740).frame(maxHeight: 800)
            .task { await model.coordinator.refresh() }
    }
    private func openSettings() { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
}
