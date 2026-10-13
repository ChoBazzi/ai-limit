import SwiftUI
import WidgetKit
import AILimitShared

@main
struct AILimitWidgets: Widget {
    let kind = "dev.bazzi.ai-limit.usage"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ProviderSelectionIntent.self, provider: SnapshotTimelineProvider()) { entry in
            UsageWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }.configurationDisplayName("AI Limit").description("개인 AI 구독의 남은 한도와 이 Mac의 로컬 토큰 기록").supportedFamilies([.systemSmall, .systemMedium, .systemLarge]).contentMarginsDisabled()
    }
}
struct UsageWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    private var maximum: Int { family == .systemSmall ? 1 : family == .systemMedium ? 4 : 8 }
    var body: some View {
        let providers = entry.providers
        VStack(alignment: .leading, spacing: family == .systemSmall ? 2 : 4) {
            HStack {
                Label(family == .systemSmall ? providers.first?.displayTitle ?? "AI Limit" : "AI Limit", systemImage: "gauge.with.dots.needle.67percent")
                    .symbolRenderingMode(.hierarchical).foregroundStyle(.indigo).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                if providers.count > maximum {
                    Text("+\(providers.count - maximum)").font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel("외 \(providers.count - maximum)개 계정")
                }
                Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.secondary)
            }
            if providers.isEmpty {
                Spacer()
                Label(entry.selection.isEmpty ? "앱을 열어 연결 상태 확인" : "선택한 계정의 연결 상태 확인", systemImage: "link.badge.plus").font(.callout)
                Spacer()
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top), count: family == .systemSmall ? 1 : 2), alignment: .leading, spacing: 4) {
                    ForEach(providers.prefix(maximum)) { state in
                        Link(destination: state.deepLink) { row(state) }
                    }
                }
                Spacer(minLength: 0)
            }
        }.padding(family == .systemLarge ? 12 : 8)
            .widgetURL(providers.first?.deepLink ?? URL(string: "ailimit://settings"))
    }
    private func row(_ state: ProviderState) -> some View {
        let rgb = state.provider.accentRGB
        let accent = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        let usage = state.lastSuccess
        let issue = UsageFormat.observationIssue(state, at: entry.date)
        let historical = issue != nil
        let windows = usage.map { UsageFormat.summaryWindows($0, maximum: 2) } ?? []
        return VStack(alignment: .leading, spacing: family == .systemLarge ? 1 : 0) {
            if family != .systemSmall {
            HStack(spacing: 3) {
                Image(systemName: state.provider.symbolName).foregroundStyle(accent)
                Text(state.provider == .codex ? state.accountName : state.displayTitle).lineLimit(1).help(state.displayTitle)
                Spacer(minLength: 0)
                if state.provider == .codex {
                    Text(usage?.resetCredits.map { "리셋권 \($0.availableCount)개" } ?? "리셋권 —")
                        .font(.system(size: family == .systemMedium ? 9 : 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(historical ? Color.secondary : Color.primary).fixedSize()
                        .help(UsageFormat.resetCreditsSummary(usage))
                }
                if historical {
                    Text("이전 관찰").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                        .fixedSize().help(issue ?? "")
                } else if [.needsAuthentication, .failed, .unavailable].contains(state.status) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(quotaAccent(.low))
                }
            }.font(.system(size: family == .systemMedium ? 11 : 12, weight: .semibold))
            }
            if !windows.isEmpty {
                ForEach(windows) { window in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 2) {
                            Text(window.title).lineLimit(1)
                            Spacer(minLength: 0)
                            if let warning = warningCaption(window) {
                                Label(warning, systemImage: warningSymbol(window))
                                    .font(.system(size: 8, weight: .semibold)).fixedSize()
                                    .foregroundStyle(quotaColor(window, historical: historical))
                            }
                            Text(UsageFormat.compactQuota(window)).fontWeight(.semibold)
                                .monospacedDigit().fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(quotaColor(window, historical: historical))
                        }.font(.system(size: family == .systemMedium ? 10 : 11))
                        if family == .systemSmall {
                            if let remaining = UsageFormat.remainingPercent(window) {
                                GeometryReader { geometry in
                                    Capsule().fill(Color.secondary.opacity(0.15)).overlay(alignment: .leading) {
                                        Capsule().fill(quotaColor(window, historical: historical)).frame(width: geometry.size.width * remaining / 100)
                                    }
                                }.frame(height: 3).accessibilityHidden(true)
                            }
                            Text(UsageFormat.resetSummary(window, at: entry.date))
                                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(historical ? Color.secondary : Color.primary).lineLimit(1).minimumScaleFactor(0.9)
                            if let time = UsageFormat.resetTime(window, at: entry.date) {
                                Text("(" + time + ")").font(.system(size: 10, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(historical ? Color.secondary : Color.primary)
                            }
                        }
                    }
                }
            } else if let balance = usage?.balances.first {
                Text(balance.title + " " + UsageFormat.amount(balance.amount, unit: balance.unit))
                    .font(.system(size: 10)).foregroundStyle(historical ? Color.secondary : Color.primary).lineLimit(2)
            } else {
                Text("사용량 미제공").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if family != .systemSmall, let selected = usage?.mostLimited ?? windows.first {
                HStack(spacing: 2) {
                    let period = selected.title.hasSuffix(" 한도") ? String(selected.title.dropLast(3)) : selected.title
                    Text(period + " · " + UsageFormat.resetDisplay(selected, at: entry.date))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if let usage, usage.windows.count > windows.count {
                        Text("+\(usage.windows.count - windows.count)").fixedSize()
                    }
                }.font(.system(size: family == .systemMedium ? 9.5 : 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(historical ? Color.secondary : Color.primary)
            }
            Divider()
            Text(UsageFormat.localTokens(state, at: entry.date))
                .font(.system(size: family == .systemMedium ? 8.5 : 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            if family == .systemSmall {
                HStack(spacing: 2) {
                    if state.provider == .codex {
                        Text(UsageFormat.resetCreditsSummary(usage)).font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(historical ? Color.secondary : Color.primary)
                    }
                    Spacer(minLength: 0)
                    if let usage {
                        Text((historical ? "이전 관찰 " : "관찰 ") + usage.fetchedAt.formatted(date: .omitted, time: .shortened))
                        if usage.windows.count > windows.count { Text("+\(usage.windows.count - windows.count) 한도") }
                    }
                }.font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, family == .systemSmall ? 0 : 4)
        .padding(.vertical, family == .systemLarge ? 2 : 0)
        .background(Color.secondary.opacity(family == .systemSmall ? 0 : 0.06), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore).accessibilityLabel(accessibilitySummary(state))
    }
    private func quotaColor(_ window: QuotaWindow, historical: Bool) -> Color {
        if historical { return .secondary }
        let level = UsageFormat.level(window)
        switch level {
        case .unknown, .unlimited: return .secondary
        default: return quotaAccent(level)
        }
    }
    private func quotaAccent(_ level: QuotaLevel) -> Color {
        let rgb = level.accentRGB(dark: colorScheme == .dark)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
    private func warningSymbol(_ window: QuotaWindow) -> String {
        switch UsageFormat.level(window) {
        case .exhausted: return "nosign"
        case .exceeded: return "exclamationmark.octagon.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }
    private func warningCaption(_ window: QuotaWindow) -> String? {
        switch UsageFormat.level(window) {
        case .low: return "임박"
        case .exhausted: return "소진"
        case .exceeded: return "초과"
        default: return nil
        }
    }
    private func accessibilitySummary(_ state: ProviderState) -> String {
        var result = state.displayTitle
        if let usage = state.lastSuccess {
            for window in usage.windows {
                result += ", " + window.title + ", " + UsageFormat.quota(window)
                if let warning = UsageFormat.quotaWarning(window) { result += ", " + warning }
                result += ", " + UsageFormat.resetDisplay(window, at: entry.date) + ", " + UsageFormat.resetLabel(window, at: entry.date)
                if let note = window.resetDescription { result += ", " + note }
            }
            for balance in usage.balances { result += ", " + balance.title + " " + UsageFormat.amount(balance.amount, unit: balance.unit) }
            result += ", 마지막 성공 " + usage.fetchedAt.formatted()
            if let issue = UsageFormat.observationIssue(state, at: entry.date) { result += ", 이전 관찰, " + issue }
        } else { result += ", 사용량 미제공" }
        result += ", " + UsageFormat.localTokens(state, at: entry.date)
        if state.provider == .codex { result += ", " + UsageFormat.resetCreditsSummary(state.lastSuccess) }
        if state.status != .ready { result += ", 연결 상태 확인" }
        return result
    }
}
