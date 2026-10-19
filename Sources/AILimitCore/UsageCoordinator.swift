import Foundation
import AILimitShared

public struct SnapshotStore: Sendable {
    public let url: URL
    private let groupURL: URL?
    private let fallbackURL: URL
    public init(groupURL: URL? = SnapshotReader.groupURL(), fallbackDirectory: URL = SettingsStore.directory) {
        self.groupURL = groupURL; fallbackURL = fallbackDirectory.appendingPathComponent("snapshot-v1.json"); url = groupURL ?? fallbackURL
    }
    public func write(_ snapshot: SharedSnapshot) throws -> Bool {
        let data = try snapshot.encoded()
        if let groupURL {
            do { try FileManager.default.createDirectory(at: groupURL.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: groupURL, options: .atomic); return true } catch { /* Keep the app usable without broadening extension access. */ }
        }
        try FileManager.default.createDirectory(at: fallbackURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fallbackURL, options: .atomic)
        return false
    }
    public func read() -> SharedSnapshot? {
        let primary = SnapshotReader.read(groupURL); let fallback = SnapshotReader.read(fallbackURL)
        if let primary, let fallback { return primary.updatedAt >= fallback.updatedAt ? primary : fallback }
        return primary ?? fallback
    }
    fileprivate func clear(_ snapshot: SharedSnapshot) throws -> Bool {
        let data = try snapshot.encoded()
        // Reset both copies: a fallback from an earlier sharing failure must not
        // reappear on a later launch. Do not report success if either write fails.
        for target in Set([fallbackURL] + (groupURL.map { [$0] } ?? [])) {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        return groupURL != nil
    }
}
private actor FetchSlots {
    private var active = 0
    private var queue: [(UUID, CheckedContinuation<Bool, Never>)] = []
    func acquire() async -> Bool {
        let ticket = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else if active < 3 { active += 1; continuation.resume(returning: true) }
                else { queue.append((ticket, continuation)) }
            }
        } onCancel: { Task { await self.cancel(ticket) } }
    }
    private func cancel(_ ticket: UUID) {
        guard let index = queue.firstIndex(where: { $0.0 == ticket }) else { return }
        queue.remove(at: index).1.resume(returning: false)
    }
    func release() { if queue.isEmpty { active -= 1 } else { queue.removeFirst().1.resume(returning: true) } }
}
public actor UsageCoordinator {
    private var connections: [String: Connection] = [:]
    private var order: [String] = []
    private var states: [String: ProviderState] = [:]
    private var generations: [String: Int] = [:]
    private var jobs: [String: Task<Void, Never>] = [:]
    private var transitioning: Set<String> = []
    private var stopped = false
    private var resetting = false
    private var overviewScans: [String: (generation: Int, facts: LocalOverviewFacts)] = [:]
    private var usageOverview: UsageOverview?
    private let secrets: any SecretStore; private let http: any HTTPTransport; private let process: any ProcessRunning; private let now: @Sendable () -> Date; private let store: SnapshotStore; private let local = LocalUsageReader(); private let slots = FetchSlots(); private let changed: @Sendable (SharedSnapshot, String?) -> Void
    public init(connections: [Connection], secrets: any SecretStore = KeychainStore(), http: any HTTPTransport = SecureHTTPTransport(), process: any ProcessRunning = SafeProcessRunner(), store: SnapshotStore = SnapshotStore(), now: @escaping @Sendable () -> Date = { Date() }, changed: @escaping @Sendable (SharedSnapshot, String?) -> Void = { _, _ in }) {
        self.secrets = secrets; self.http = http; self.process = process; self.store = store; self.now = now; self.changed = changed
        // Ambiguous IDs must not choose one account's credentials or cached state arbitrarily.
        var seen: Set<String> = []; var duplicates: Set<String> = []
        for connection in connections where !seen.insert(connection.id).inserted { duplicates.insert(connection.id) }
        for connection in connections where Connection.validID(connection.id) && !duplicates.contains(connection.id) && !connection.accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.connections[connection.id] = connection
            order.append(connection.id)
        }
        if let prior = store.read() {
            for var state in prior.providers {
                guard let connection = self.connections[state.connectionID], connection.provider == state.provider,
                      state.lastSuccess == nil || state.lastSuccess?.provider == connection.provider,
                      connection.enabled || connection.localConsentedAt != nil else { continue }
                state.accountName = connection.accountName
                let scopes: Set<String> = connection.localSource == .omp ? ["ompSession", "ompHistory"] : ["localSession", "localHistory"]
                if connection.localConsentedAt == nil || state.localTokens.contains(where: { !scopes.contains($0.scope) }) { state.localTokens = []; state.localMessage = nil }
                // A message without token scopes has no persisted source provenance.
                if state.localTokens.isEmpty { state.localMessage = nil }
                states[connection.id] = state
            }
        }
    }
    private var orderedIDs: [String] { ProviderID.allCases.flatMap { provider in order.filter { connections[$0]?.provider == provider } } }
    public func current() -> SharedSnapshot { SharedSnapshot(updatedAt: now(), providers: orderedIDs.compactMap { states[$0] }, usageOverview: usageOverview) }
    public func replace(_ connection: Connection, initial: UsageSnapshot? = nil) async {
        guard !stopped, !resetting else { return }
        let id = connection.id
        guard Connection.validID(id), !connection.accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              initial == nil || initial?.provider == connection.provider else { return }
        let localChanged = connections[id]?.provider != connection.provider || connections[id]?.localFolder != connection.localFolder || connections[id]?.localConsentedAt != connection.localConsentedAt || (connections[id]?.localSource ?? .native) != (connection.localSource ?? .native)
        generations[id, default: 0] += 1
        let generation = generations[id, default: 0]
        if localChanged { overviewScans.removeValue(forKey: id) }
        else if let previous = overviewScans[id] { overviewScans[id] = (generation, previous.facts) }
        rebuildOverview()
        transitioning.insert(id)
        defer { if generations[id] == generation { transitioning.remove(id) } }
        // Keep draining jobs registered so shutdown/reset also await transitions.
        let previousJob = jobs[id]
        previousJob?.cancel()
        await previousJob?.value
        guard !stopped, !resetting, generations[id] == generation else { return }
        jobs.removeValue(forKey: id)
        if localChanged { await local.forget(id) }
        guard !stopped, !resetting, generations[id] == generation else { return }
        if connections[id] == nil { order.append(id) }
        connections[id] = connection
        let old = states[id]
        states[id] = ProviderState(provider: connection.provider, status: initial == nil ? .disconnected : .ready, lastSuccess: initial, lastAttemptAt: initial?.fetchedAt, localTokens: localChanged ? [] : old?.localTokens ?? [], localMessage: localChanged ? nil : old?.localMessage, connectionID: id, accountName: connection.accountName)
        rebuildOverview()
        persist()
    }
    public func rename(_ accountID: String, accountName: String) async {
        guard !stopped, !resetting, !accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, connections[accountID] != nil else { return }
        connections[accountID]?.accountName = accountName
        states[accountID]?.accountName = accountName
        persist()
    }
    public func disconnect(_ id: String) async {
        guard !stopped, !resetting else { return }
        generations[id, default: 0] += 1
        let generation = generations[id, default: 0]
        transitioning.insert(id)
        defer { if generations[id] == generation { transitioning.remove(id) } }
        let previousJob = jobs[id]
        previousJob?.cancel()
        connections.removeValue(forKey: id)
        order.removeAll { $0 == id }
        states.removeValue(forKey: id)
        overviewScans.removeValue(forKey: id)
        rebuildOverview()
        persist()
        await previousJob?.value
        guard !stopped, !resetting, generations[id] == generation else { return }
        jobs.removeValue(forKey: id)
        await local.forget(id)
        guard !stopped, !resetting, generations[id] == generation else { return }
        persist()
    }
    /// Stop admission before awaiting jobs, including jobs being drained by replace.
    /// Protected rotating-token exchanges finish saving before this returns.
    public func shutdown() async {
        stopped = true
        let pending = Array(jobs.values)
        for task in pending { task.cancel() }
        for task in pending { await task.value }
        jobs.removeAll()
    }
    /// Explicit user reset also clears an orphaned on-disk snapshot when settings
    /// could not be loaded. Initialization alone never writes or accesses secrets.
    public func reset() async throws {
        guard !stopped, !resetting else { return }
        resetting = true
        defer { resetting = false }
        let ids = Set(connections.keys).union(jobs.keys)
        for id in ids { generations[id, default: 0] += 1 }
        let pending = Array(jobs.values)
        for task in pending { task.cancel() }
        connections.removeAll(); order.removeAll(); states.removeAll()
        overviewScans.removeAll(); usageOverview = nil
        for task in pending { await task.value }
        jobs.removeAll(); transitioning.removeAll()
        for id in ids { await local.forget(id) }
        guard !stopped else { return }
        let value = current()
        do {
            let shared = try store.clear(value)
            changed(value, shared ? nil : "위젯 공유 설정 필요")
        } catch {
            changed(value, "사용량 파일 저장 실패 · 디스크와 권한을 확인하세요.")
            throw error
        }
    }
    public func refresh(only: String? = nil) async {
        guard !stopped, !resetting, !Task.isCancelled else { return }
        var pending: [Task<Void, Never>] = []
        for id in orderedIDs where only == nil || only == id {
            guard !transitioning.contains(id) else { continue }
            guard let connection = connections[id], connection.enabled || connection.localConsentedAt != nil else { continue }
            if let task = jobs[id] { pending.append(task); continue }
            let generation = generations[id, default: 0]
            let task = Task { await self.collect(connection, generation: generation) }; jobs[id] = task; pending.append(task)
        }
        for task in pending { await task.value }
    }
    private func collect(_ connection: Connection, generation: Int) async {
        let id = connection.id
        guard await slots.acquire() else { return }
        guard !Task.isCancelled, generations[id, default: 0] == generation else { await slots.release(); return }
        var state = states[id] ?? ProviderState(provider: connection.provider, connectionID: id, accountName: connections[id]?.accountName ?? connection.accountName)
        var overviewFacts: LocalOverviewFacts?
        if connection.enabled, connection.consentedAt != nil, (state.retryAfter ?? .distantPast) <= now() {
            state.status = .loading; state.lastAttemptAt = now(); states[id] = state; persist()
            let context = FetchContext(connection: connection, secrets: secrets, http: http, process: process, now: now)
            do { let value = try await Providers.make(connection.provider).fetch(context: context); state.lastSuccess = value; state.status = .ready; state.message = value.windows.isEmpty && value.balances.isEmpty ? "사용량 미제공" : nil; state.retryAfter = nil }
            catch { state.message = (error as? UsageError)?.localizedDescription ?? "조회 실패"; switch error { case UsageError.authentication: state.status = .needsAuthentication; case UsageError.unavailable: state.status = .unavailable; case UsageError.rateLimited(let date): state.status = .unavailable; state.retryAfter = date; default: state.status = .failed } }
        }
        if !Task.isCancelled, generations[id, default: 0] == generation, let folder = connection.localFolder, connection.localConsentedAt != nil {
            let result = await local.scan(accountID: id, provider: connection.provider, root: folder, now: now(), source: connection.localSource ?? .native); state.localTokens = result.summaries; state.localMessage = result.message
            overviewFacts = result.overviewFacts
        }
        await slots.release()
        guard !Task.isCancelled, generations[id, default: 0] == generation, let currentConnection = connections[id] else { return }
        state.accountName = currentConnection.accountName
        if let overviewFacts { overviewScans[id] = (generation, overviewFacts); rebuildOverview() }
        states[id] = state; jobs.removeValue(forKey: id); persist()
    }
    private func rebuildOverview() {
        let scans = overviewScans.compactMap { id, value -> LocalOverviewFacts? in
            guard value.generation == generations[id, default: 0],
                  let connection = connections[id], connection.localConsentedAt != nil, connection.localFolder != nil else { return nil }
            return value.facts
        }
        let expected = connections.values.filter { $0.localConsentedAt != nil && $0.localFolder != nil }.count
        usageOverview = LocalUsageOverview.aggregate(scans, now: now(), awaitingScans: scans.count < expected)
    }
    private func persist() { let value = current(); do { let shared = try store.write(value); changed(value, shared ? nil : "위젯 공유 설정 필요") } catch { changed(value, "사용량 파일 저장 실패 · 디스크와 권한을 확인하세요.") } }
}
