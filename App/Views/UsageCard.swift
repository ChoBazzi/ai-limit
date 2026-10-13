import SwiftUI
import AILimitShared

extension ProviderID {
    var accent: Color { let rgb = accentRGB; return Color(red: rgb.red, green: rgb.green, blue: rgb.blue) }
}

struct ProviderMark: View {
    let provider: ProviderID
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: provider.symbolName).font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(provider.accent).frame(width: size, height: size)
            .background(provider.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

private struct QuotaReading: View {
    let window: QuotaWindow
    let state: ProviderState
    let now: Date
    var compact = false
    var detail = false
    @Environment(\.colorScheme) private var colorScheme

    private var historical: Bool { UsageFormat.observationIssue(state, at: now) != nil }
    private var tint: Color {
        if historical { return .secondary }
        let rgb = UsageFormat.level(window).accentRGB(dark: colorScheme == .dark)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
    private var detailReading: AttributedString {
        var reading = AttributedString(UsageFormat.quota(window))
        if let range = reading.range(of: UsageFormat.compactQuota(window)) {
            reading[range].font = .caption.weight(.semibold).monospacedDigit()
        }
        return reading
    }
    private var accessibilityReading: String {
        let observation = state.lastSuccess.map { "관찰 " + $0.fetchedAt.formatted(date: .abbreviated, time: .shortened) } ?? ""
        return [state.displayTitle, window.title,
                detail ? UsageFormat.quota(window) : UsageFormat.compactQuota(window),
                UsageFormat.quotaWarning(window), UsageFormat.resetDisplay(window, at: now), UsageFormat.resetLabel(window, at: now),
                window.resetDescription, UsageFormat.observationIssue(state, at: now) ?? (state.status == .loading ? "갱신 중" : "연결됨"),
                observation].compactMap { $0 }.joined(separator: ", ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: detail ? 5 : 2) {
            HStack(spacing: 4) {
                Text(window.title).font(detail ? .subheadline.weight(.medium) : .caption.weight(.medium)).lineLimit(detail ? nil : 1)
                if !detail {
                    Spacer(minLength: 2)
                    if let warning = UsageFormat.quotaWarning(window) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.medium)).foregroundStyle(tint).fixedSize()
                    }
                    Text(UsageFormat.compactQuota(window)).font(.caption.weight(.semibold)).monospacedDigit().fixedSize(horizontal: true, vertical: false)
                }
            }
            if detail { Text(detailReading).font(.caption.monospacedDigit()) }
            if let remaining = UsageFormat.remainingPercent(window) {
                GeometryReader { geometry in
                    Capsule().fill(Color.secondary.opacity(0.12)).overlay(alignment: .leading) {
                        Capsule().fill(tint).frame(width: geometry.size.width * remaining / 100)
                    }
                }.frame(height: detail ? 6 : 3).accessibilityHidden(true)
            }
            if detail, let warning = UsageFormat.quotaWarning(window) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.medium)).foregroundStyle(tint)
            }
            Label(UsageFormat.resetDisplay(window, at: now), systemImage: "arrow.clockwise")
                .font(.system(size: compact ? 11 : 12, weight: .semibold)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .help(UsageFormat.resetLabel(window, at: now))
            if detail {
                Text(UsageFormat.resetLabel(window, at: now)).font(.caption).foregroundStyle(.secondary)
            }
            if !compact, let description = window.resetDescription, !description.isEmpty {
                Text(description).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(historical ? Color.secondary : Color.primary)
        .accessibilityElement(children: .ignore).accessibilityLabel(accessibilityReading)
    }
}

struct AccountSummary: View {
    let state: ProviderState
    var compact = false
    var pinned = false
    @Environment(\.colorScheme) private var colorScheme
    private var attentionColor: Color {
        let rgb = QuotaLevel.low.accentRGB(dark: colorScheme == .dark)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
    private var status: String {
        switch state.status {
        case .ready: "연결됨"
        case .loading: "갱신 중"
        case .needsAuthentication: "재로그인 필요"
        case .failed: "조회 실패"
        case .unavailable: "조회 불가"
        case .disconnected: state.localTokens.isEmpty ? "연결 확인" : "로컬 기록"
        }
    }
    private var needsAttention: Bool { [.needsAuthentication, .failed, .unavailable].contains(state.status) }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                HStack(spacing: 7) {
                    ProviderMark(provider: state.provider, size: compact ? 24 : 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.accountName).font(compact ? .caption.weight(.semibold) : .headline).lineLimit(1)
                        Text(state.provider.title + (state.lastSuccess?.plan.map { " · " + $0 } ?? "")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(state.provider.accent).accessibilityLabel("메뉴 막대 고정") }
                    Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary)
                }
                if let usage = state.lastSuccess {
                    let issue = UsageFormat.observationIssue(state, at: timeline.date)
                    if let issue {
                        Label(issue, systemImage: "clock.badge.exclamationmark")
                            .font(.system(size: compact ? 9 : 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(UsageFormat.summaryWindows(usage, maximum: compact ? 2 : usage.windows.count)) { window in
                        QuotaReading(window: window, state: state, now: timeline.date, compact: compact)
                    }
                    if compact, usage.windows.count > 2 {
                        Text("외 \(usage.windows.count - 2)개 한도 · 상세에서 확인").font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(usage.balances.prefix(compact ? 1 : usage.balances.count)) { balance in
                        HStack { Text(balance.title); Spacer(); Text(UsageFormat.amount(balance.amount, unit: balance.unit)).monospacedDigit() }
                            .font(.caption).foregroundStyle(issue == nil ? Color.primary : Color.secondary)
                    }
                    if usage.windows.isEmpty && usage.balances.isEmpty { Text("사용량 미제공").font(.caption).foregroundStyle(.secondary) }
                } else { Text("사용량 미제공").font(.caption).foregroundStyle(.secondary) }
                if state.provider == .codex {
                    Label(UsageFormat.resetCreditsSummary(state.lastSuccess), systemImage: "ticket")
                        .font(.system(size: compact ? 11 : 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(UsageFormat.observationIssue(state, at: timeline.date) == nil ? Color.primary : Color.secondary)
                }
                Divider()
                Text(UsageFormat.localTokens(state, at: timeline.date))
                    .font(.system(size: compact ? 9 : 11)).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
                    .help("별도로 읽기 동의한 이 Mac의 기록입니다. 현재 원격 계정의 전체 토큰 사용량이 아니며, 토큰을 한도 퍼센트에서 추정하지 않습니다.")
                HStack(spacing: 4) {
                    Image(systemName: needsAttention ? "exclamationmark.circle.fill" : state.status == .loading ? "arrow.triangle.2.circlepath" : "circle.fill")
                        .font(.system(size: needsAttention ? 9 : 5))
                    Text(status)
                    Spacer(minLength: 0)
                    if let usage = state.lastSuccess {
                        Text("관찰 " + usage.fetchedAt.formatted(date: UsageFormat.observationIssue(state, at: timeline.date) == nil ? .omitted : .abbreviated, time: .shortened)).monospacedDigit()
                    }
                }.font(.system(size: compact ? 9 : 10)).foregroundStyle(needsAttention ? attentionColor : Color.secondary)
                if !compact, let message = state.message { Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
    }
}

struct DashboardAccountCard: View {
    let state: ProviderState
    var pinned = false
    let open: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: open) {
            AccountSummary(state: state, pinned: pinned)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(state.provider.accent.opacity(hovered ? 0.55 : 0.18), lineWidth: 1))
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityElement(children: .combine).accessibilityHint("계정 사용량 상세와 연결 관리 열기")
    }
}

struct UsageCard: View {
    let state: ProviderState
    var compact = false
    private var statusLabel: String { switch state.status { case .disconnected: "연결 안 됨"; case .loading: "갱신 중"; case .ready: "연결됨"; case .needsAuthentication: "재연결 필요"; case .unavailable: "현재 조회 불가"; case .failed: "조회 실패" } }
    private var sourceLabel: String {
        guard let source = state.lastSuccess?.source else {
            return state.localTokens.isEmpty ? "구독 한도 미연결" : "로컬 기록"
        }
        switch source {
        case .officialAPI: return "공식 API · OAuth"
        case .publicCLI: return "CLI 보고"
        case .unofficialWeb: return "비공식 연동"
        case .localLog: return "로컬 기록"
        }
    }
    var body: some View {
        if compact {
            AccountSummary(state: state, compact: true).padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(state.provider.accent.opacity(0.18), lineWidth: 1))
        } else {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                ProviderMark(provider: state.provider)
                Text(state.displayTitle).font(.system(.title2, design: .rounded, weight: .semibold))
                Spacer()
                if state.status == .loading { ProgressView().controlSize(.small) }
                Text(sourceLabel).font(.caption2.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 4).background(.quaternary, in: Capsule())
            }
            HStack { Label(statusLabel, systemImage: state.status == .ready ? "checkmark.circle" : "info.circle"); if let plan = state.lastSuccess?.plan { Text(plan) } }.font(.caption).foregroundStyle(.secondary)
            if let usage = state.lastSuccess {
                if usage.source == .publicCLI { Text("선택한 CLI 로그인 계정").font(.caption2).foregroundStyle(.secondary) }
                let issue = UsageFormat.observationIssue(state, at: timeline.date)
                if let issue {
                    Label(issue, systemImage: "clock.badge.exclamationmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                ForEach(usage.windows) { window in
                    QuotaReading(window: window, state: state, now: timeline.date, detail: true)
                }
                if state.provider == .codex {
                    ResetCreditsDetail(credits: usage.resetCredits, now: timeline.date)
                        .foregroundStyle(issue == nil ? Color.primary : Color.secondary)
                }
                ForEach(usage.balances) { balance in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(balance.title); Spacer(); Text(UsageFormat.amount(balance.amount, unit: balance.unit)).monospacedDigit() }
                        if let expiration = balance.expiresAt { Text("갱신/만료 " + expiration.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
                    }.font(.caption).foregroundStyle(issue == nil ? Color.primary : Color.secondary)
                }
                if usage.windows.isEmpty && usage.balances.isEmpty { Text("사용량 미제공").font(.caption).foregroundStyle(.secondary) }
                Label("마지막 관찰 " + usage.fetchedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
            }
            if let message = state.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Divider()
            Text("로컬 기록").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(UsageFormat.localTokens(state, at: timeline.date)).font(.subheadline.weight(.medium))
            if !state.localTokens.isEmpty || state.localMessage != nil {
                DisclosureGroup("이 Mac의 로컬 토큰") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(state.localTokens.enumerated()), id: \.offset) { _, summary in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(summary.note ?? summary.scope).font(.caption)
                                let counters = summary.counters
                                ForEach(Array([("입력", counters.input), ("출력", counters.output), ("캐시 읽기", counters.cacheRead), ("캐시 쓰기", counters.cacheWrite), ("추론", counters.reasoning), ("총 토큰", counters.total)].enumerated()), id: \.offset) { _, item in if let value = item.1 { HStack { Text(item.0); Spacer(); Text(value.formatted()).monospacedDigit() }.font(.caption2) } }
                                Text("관찰 " + summary.observedAt.formatted() + (timeline.date.timeIntervalSince(summary.observedAt) >= 900 ? " · 오래된 기록" : "") + (summary.isPartial ? " · 일부 기록" : "")).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if let message = state.localMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.top, 8)
                }.font(.caption)
            }
        }.padding(24).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(state.provider.accent.opacity(0.18), lineWidth: 1))
        }
        }
    }
}

private struct ResetCreditsDetail: View {
    let credits: ResetCredits?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("리셋권", systemImage: "ticket").font(.headline)
            if let credits {
                Text("남은 리셋권 \(credits.availableCount)개").font(.subheadline.weight(.semibold)).monospacedDigit()
                if let details = credits.credits {
                    ForEach(details.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 2) {
                            if let expiration = details[index].expiresAt {
                                Text("리셋권 \(index + 1) · 사용기한 " + expiration.formatted(date: .abbreviated, time: .shortened))
                                if expiration <= now { Text("사용기한 지남 · 갱신 필요").foregroundStyle(.secondary) }
                            } else {
                                Text("리셋권 \(index + 1) · 사용기한 없음")
                            }
                        }.font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    let missing = credits.availableCount - Int64(details.count)
                    if missing > 0 { Text("\(missing)개는 사용기한 정보 미제공").font(.caption).foregroundStyle(.secondary) }
                } else if credits.availableCount > 0 {
                    Text("사용기한 정보 미제공").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("리셋권 정보 미제공").font(.caption).foregroundStyle(.secondary)
            }
            Text("한도 리셋 시각·크레딧 잔액과 별개이며, 이 앱에서는 리셋권을 사용하지 않습니다.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct UsageOverviewView: View {
    let overview: UsageOverview?
    let hasLocalSource: Bool
    let openConnections: () -> Void
    @State private var showingBasis = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    ForEach(UsagePeriod.allCases) { period in
                        periodCard(period, at: timeline.date)
                    }
                }
                HStack(spacing: 5) {
                    Text("이 Mac 기록 · API 환산액(USD) · 실제 청구액 아님")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if let overview, timeline.date.timeIntervalSince(overview.generatedAt) >= 900 {
                        Text("이전 집계").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if !hasLocalSource {
                        Button("로컬 기록 연결", action: openConnections).font(.caption).buttonStyle(.plain)
                    }
                    Button { showingBasis = true } label: {
                        Label("집계 기준", systemImage: "info.circle").font(.system(size: 10))
                    }.buttonStyle(.plain).popover(isPresented: $showingBasis, arrowEdge: .bottom) {
                        basis(at: timeline.date)
                    }
                }
            }
        }
    }

    private func periodCard(_ period: UsagePeriod, at now: Date) -> some View {
        let totals = overview?.totals(for: period, at: now)
        let partial = totals?.isPartial == true || overview?.isPartial == true || (totals?.missingTokenRecords ?? 0) > 0
        let costPartial = (totals?.unpricedRecords ?? 0) > 0
        let tokenText: String
        if let tokens = totals?.tokens {
            tokenText = tokens.formatted(.number.notation(.compactName).precision(.fractionLength(0...2))) + " 토큰"
        } else {
            tokenText = !hasLocalSource ? "연결 필요" : totals == nil ? "집계 대기" : totals?.recordCount == 0 ? "기록 없음" : "토큰 미제공"
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(period.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if partial || costPartial {
                    Text(partial ? "일부 기록" : "금액 일부")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(tokenText).font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                Text(costText(totals?.estimatedUSD)).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.indigo).lineLimit(1).minimumScaleFactor(0.8)
            }
        }.padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.indigo.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(period.title + ", " + (totals?.tokens.map { $0.formatted() + " 토큰" } ?? tokenText)
                + ", API 환산액 " + costText(totals?.estimatedUSD) + (partial ? ", 일부 기록" : "") + (costPartial ? ", 일부 요청 금액 미산정" : ""))
    }

    private func costText(_ amount: Decimal?) -> String {
        guard let amount else { return "금액 미산정" }
        if amount > 0 && amount < Decimal(string: "0.01")! { return "≈ <$0.01" }
        return "≈ " + amount.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")).precision(.fractionLength(2)))
    }

    private func basis(at now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("토큰·API 환산액 집계 기준").font(.headline)
                Text("이번 주는 월요일부터, 이번 달은 1일부터 현재까지입니다. Mac의 시간대를 사용합니다. 읽기 동의한 로컬 기록만 중복 제거하여 합산하며, 원격 계정 전체 사용량이나 구독 결제액이 아닙니다.")
                if let overview {
                    Text("단가 기준일: " + overview.pricingAsOf)
                    Text("집계 확인: " + overview.generatedAt.formatted(date: .abbreviated, time: .shortened))
                    ForEach(UsagePeriod.allCases) { period in
                        if let totals = overview.totals(for: period, at: now) {
                            Text("\(period.title): \(totals.recordCount)건 · 토큰 미제공 \(totals.missingTokenRecords)건 · 금액 미산정 \(totals.unpricedRecords)건")
                        }
                    }
                    ForEach(overview.notes, id: \.self) { Text($0) }
                } else {
                    Text("계정 관리 → 로컬 기록 · 별도 읽기 동의에서 기록 폴더를 연결하면 집계를 시작합니다.")
                }
                Text("모델·입력·출력·캐시 단가가 확인되는 요청만 금액을 계산합니다. 추론 토큰은 출력에 포함되므로 중복 과금하지 않습니다. 미산정 요청이 있으면 표시 금액은 계산 가능한 요청의 소계입니다.")
                Button("로컬 기록 연결 설정", action: openConnections)
            }.font(.caption).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }.frame(width: 390, height: 340)
    }
}
