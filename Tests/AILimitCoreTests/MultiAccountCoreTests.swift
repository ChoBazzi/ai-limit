import XCTest
@testable import AILimitCore
import AILimitShared

private final class AccountSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    init(_ values: [String: String] = [:]) { self.values = values }
    func load(_ accountID: String) throws -> String? { lock.withLock { values[accountID] } }
    func save(_ secret: String, for accountID: String) throws { lock.withLock { values[accountID] = secret } }
    func remove(_ accountID: String) throws { _ = lock.withLock { values.removeValue(forKey: accountID) } }
    func removeAll() throws { lock.withLock { values.removeAll() } }
}

/// Responses are released explicitly, including after cancellation, to model late server replies.
private actor AccountHTTP: HTTPTransport {
    private var responses: [String: HTTPResponse]
    private var held: Set<String>
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private var requests: [String: Int] = [:]
    private var arrivals: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellations: Set<String> = []
    private var cancellationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    init(_ responses: [String: HTTPResponse], held: Set<String> = []) { self.responses = responses; self.held = held }
    func configure(_ key: String, response: HTTPResponse) { responses[key] = response }
    func count(_ key: String) -> Int { requests[key, default: 0] }
    func waitForRequest(_ key: String) async {
        if requests[key, default: 0] > 0 { return }
        await withCheckedContinuation { arrivals[key, default: []].append($0) }
    }
    func waitForCancellation(_ key: String) async {
        if cancellations.contains(key) { return }
        await withCheckedContinuation { cancellationWaiters[key, default: []].append($0) }
    }
    private func cancelled(_ key: String) {
        cancellations.insert(key)
        cancellationWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
    }
    func release(_ key: String) { held.remove(key); waiting.removeValue(forKey: key)?.resume() }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let key = request.headers["Cookie"] ?? request.headers["Authorization"] ?? "missing"
        guard let response = responses[key] else { throw UsageError.authentication }
        requests[key, default: 0] += 1
        arrivals.removeValue(forKey: key)?.forEach { $0.resume() }
        if held.contains(key) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiting[key] = $0 }
            } onCancel: { Task { await self.cancelled(key) } }
        }
        return response
    }
}

private actor AccountRotationHTTP: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path == "/oauth/token" {
            let query = URLComponents(string: "https://fixture.invalid/?" + String(decoding: request.body ?? Data(), as: UTF8.self))
            let refresh = query?.queryItems?.first { $0.name == "refresh_token" }?.value
            guard let refresh, ["refresh-a", "refresh-b"].contains(refresh) else { throw UsageError.authentication }
            let suffix = refresh == "refresh-a" ? "a" : "b"
            return response("{\"access_token\":\"new-\(suffix)\",\"refresh_token\":\"rotated-\(suffix)\",\"expires_in\":3600}")
        }
        switch request.headers["Authorization"] {
        case "Bearer new-a": return response("{}", status: 401)
        case "Bearer new-b": return response(#"{"rate_limit":{"primary_window":{"used_percent":60}}}"#)
        default: throw UsageError.authentication
        }
    }
}

@MainActor
final class MultiAccountCoreTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func store() throws -> SnapshotStore {
        let root = try directory()
        return SnapshotStore(groupURL: root.appendingPathComponent("snapshot-v1.json"), fallbackDirectory: root)
    }
    private func cursor(_ id: String) -> Connection {
        Connection(provider: .cursor, enabled: true, consentedAt: fixedNow, id: id, accountName: id)
    }
    private func quota(_ percent: Int) -> HTTPResponse {
        response("{\"individualUsage\":{\"plan\":{\"totalPercentUsed\":\(percent)}}}")
    }

    func testLegacySettingsSnapshotAndCredentialKeysRemainAligned() async throws {
        let root = try directory(); let settingsStore = SettingsStore(directory: root)
        try Data(#"{"connections":[{"provider":"cursor","enabled":true,"credentialReference":"cursor","consentedAt":"2026-09-28T00:00:00Z"}],"pinned":"cursor","theme":"dark"}"#.utf8).write(to: settingsStore.url)
        let settings = try settingsStore.load()
        XCTAssertEqual(settings.connections.map(\.id), ["cursor"])
        XCTAssertEqual(settings.pinnedConnectionID, "cursor")
        let secrets = AccountSecrets(["cursor": "session=legacy"])
        XCTAssertEqual(try FetchContext(connection: settings.connections[0], secrets: secrets).secret(), "session=legacy")
        let snapshotStore = SnapshotStore(groupURL: root.appendingPathComponent("snapshot-v1.json"), fallbackDirectory: root)
        try Data(#"{"schemaVersion":1,"updatedAt":"2026-09-28T00:00:00Z","providers":[{"provider":"cursor","status":"ready","localTokens":[],"lastSuccess":{"provider":"cursor","windows":[],"balances":[],"source":"unofficialWeb","fetchedAt":"2026-09-28T00:00:00Z"}}],"displayOrder":["cursor"]}"#.utf8).write(to: snapshotStore.url)
        let coordinator = UsageCoordinator(connections: settings.connections, secrets: secrets, store: snapshotStore)
        let restored = await coordinator.current()
        XCTAssertEqual(restored.providers.map(\.connectionID), ["cursor"])
        XCTAssertEqual(restored.providers.first?.lastSuccess?.fetchedAt, ISO8601DateFormatter().date(from: "2026-09-28T00:00:00Z"))
        try settingsStore.save(settings)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsStore.url)) as? [String: Any])
        XCTAssertEqual(saved["schemaVersion"] as? Int, 2)
        XCTAssertEqual(saved["pinnedConnectionID"] as? String, "cursor")
        XCTAssertNil(saved["pinned"])
        let reloaded = try settingsStore.load()
        XCTAssertEqual(reloaded.connections.map(\.id), ["cursor"])
        XCTAssertEqual(try secrets.load("cursor"), "session=legacy")
        let fresh = Connection(provider: .cursor, enabled: true, consentedAt: fixedNow)
        XCTAssertNotNil(UUID(uuidString: fresh.id))
        XCTAssertNotEqual(fresh.id, Connection(provider: .cursor).id)
        let unrelated = UsageCoordinator(connections: [fresh], secrets: secrets, store: snapshotStore)
        let unrelatedSnapshot = await unrelated.current()
        XCTAssertTrue(unrelatedSnapshot.providers.isEmpty)
    }

    func testNewAccountIDsLabelsAndPinSurviveSettingsRoundTrip() throws {
        let settingsStore = SettingsStore(directory: try directory())
        let a = Connection(provider: .codex, enabled: true, accountName: "개인")
        let b = Connection(provider: .codex, enabled: true, accountName: "업무")
        var settings = ConnectionSettings()
        settings.connections = [a, b]; settings.pinnedConnectionID = b.id
        try settingsStore.save(settings)
        let loaded = try settingsStore.load()
        XCTAssertEqual(loaded.connections.map(\.id), [a.id, b.id])
        XCTAssertEqual(loaded.connections.map(\.accountName), ["개인", "업무"])
        XCTAssertEqual(loaded.pinnedConnectionID, b.id)
    }

    func testSettingsRejectAmbiguousOrInvalidIdentitiesWithoutOverwritingFile() throws {
        let settingsStore = SettingsStore(directory: try directory())
        for entries in [
            #"[{"provider":"cursor","enabled":true},{"provider":"cursor","enabled":true}]"#,
            #"[{"provider":"cursor","enabled":true,"id":"same"},{"provider":"codex","enabled":true,"id":"same"}]"#,
            #"[{"provider":"cursor","enabled":true,"id":""}]"#,
            #"[{"provider":"cursor","enabled":true,"id":"../other"}]"#
        ] {
            let input = Data("{\"connections\":\(entries)}".utf8)
            try input.write(to: settingsStore.url)
            XCTAssertThrowsError(try settingsStore.load())
            XCTAssertEqual(try Data(contentsOf: settingsStore.url), input)
        }
        try Data(#"{"schemaVersion":99,"connections":[]}"#.utf8).write(to: settingsStore.url)
        XCTAssertThrowsError(try settingsStore.load())
        try Data(#"{"schemaVersion":2,"connections":[{"provider":"codex","enabled":true}]}"#.utf8).write(to: settingsStore.url)
        XCTAssertThrowsError(try settingsStore.load())
        try Data(#"{"connections":[],"pinned":"codex"}"#.utf8).write(to: settingsStore.url)
        XCTAssertNil(try settingsStore.load().pinnedConnectionID)
    }

    func testSameProviderQuotaAuthenticationAndBackoffAreIndependent() async throws {
        let a = cursor("account-a"); let b = cursor("account-b")
        let http = AccountHTTP(["session=a": quota(25), "session=b": quota(60)])
        let snapshotStore = try store()
        let coordinator = UsageCoordinator(connections: [b, a], secrets: AccountSecrets([a.id: "session=a", b.id: "session=b"]), http: http, store: snapshotStore, now: { fixedNow })
        await coordinator.refresh()
        var states = await coordinator.current().providers
        XCTAssertEqual(states.map(\.connectionID), [b.id, a.id])
        XCTAssertEqual(states.map { $0.lastSuccess?.mostLimited?.remainingPercent }, [40, 75])
        await http.configure("session=a", response: response("{}", status: 429))
        await coordinator.refresh(only: a.id)
        await http.configure("session=b", response: response("{}", status: 401))
        await coordinator.refresh()
        states = await coordinator.current().providers
        XCTAssertEqual(states.map(\.status), [.needsAuthentication, .unavailable])
        XCTAssertNil(states[0].retryAfter)
        XCTAssertEqual(states[1].retryAfter, fixedNow.addingTimeInterval(300))
        XCTAssertEqual(states.map { $0.lastSuccess?.fetchedAt }, [fixedNow, fixedNow])
        let aCalls = await http.count("session=a"); let bCalls = await http.count("session=b")
        XCTAssertEqual(aCalls, 2); XCTAssertEqual(bCalls, 2)
        await coordinator.rename(a.id, accountName: "Personal")
        let renamed = await coordinator.current()
        XCTAssertEqual(renamed.providers.map(\.accountName), [b.id, "Personal"])
        XCTAssertEqual(renamed.providers[1].retryAfter, states[1].retryAfter)
        await coordinator.refresh(only: "cursor")
        let ignoredCalls = await http.count("session=b")
        XCTAssertEqual(ignoredCalls, bCalls)
        await coordinator.replace(a)
        let replaced = await coordinator.current()
        XCTAssertNil(replaced.providers[1].lastSuccess)
        XCTAssertEqual(replaced.providers[0].lastSuccess?.mostLimited?.remainingPercent, 40)
        XCTAssertEqual(SnapshotReader.read(snapshotStore.url)?.providers.map(\.connectionID), [b.id, a.id])
    }

    func testConcurrentAccountsRenameAndDisconnectDiscardOnlyDeletedLateResponse() async throws {
        let a = cursor("account-a"); let b = cursor("account-b")
        let http = AccountHTTP(["session=a": quota(25), "session=b": quota(60)], held: ["session=a", "session=b"])
        let snapshotStore = try store()
        let coordinator = UsageCoordinator(connections: [a, b], secrets: AccountSecrets([a.id: "session=a", b.id: "session=b"]), http: http, store: snapshotStore, now: { fixedNow })
        let refreshA = Task { await coordinator.refresh(only: a.id) }
        await http.waitForRequest("session=a")
        let refreshB = Task { await coordinator.refresh() }
        await http.waitForRequest("session=b")
        await coordinator.rename(b.id, accountName: "Work")
        let removing = Task { await coordinator.disconnect(a.id) }
        await http.waitForCancellation("session=a")
        await http.release("session=a")
        await removing.value; await refreshA.value
        let during = await coordinator.current()
        XCTAssertEqual(during.providers.map(\.connectionID), [b.id])
        XCTAssertEqual(during.providers.first?.status, .loading)
        await http.release("session=b"); await refreshB.value
        let final = await coordinator.current()
        XCTAssertEqual(final.providers.map(\.connectionID), [b.id])
        XCTAssertEqual(final.providers.first?.accountName, "Work")
        XCTAssertEqual(final.providers.first?.lastSuccess?.mostLimited?.remainingPercent, 40)
        XCTAssertEqual(SnapshotReader.read(snapshotStore.url)?.providers.map(\.connectionID), [b.id])
        let aCalls = await http.count("session=a"); let bCalls = await http.count("session=b")
        XCTAssertEqual(aCalls, 1); XCTAssertEqual(bCalls, 1)
    }

    func testRollingBackPausedDraftDoesNotLeaveEntryOrAlterSavedSibling() async throws {
        let saved = cursor("saved")
        let draft = Connection(provider: .cursor, id: "draft")
        let http = AccountHTTP(["session=saved": quota(25)])
        let snapshotStore = try store()
        let coordinator = UsageCoordinator(connections: [saved], secrets: AccountSecrets([saved.id: "session=saved"]), http: http, store: snapshotStore, now: { fixedNow })
        await coordinator.refresh()
        await coordinator.replace(draft)
        await coordinator.disconnect(draft.id)
        await coordinator.refresh(only: draft.id)
        let remaining = await coordinator.current()
        XCTAssertEqual(remaining.providers.map(\.connectionID), [saved.id])
        XCTAssertEqual(remaining.providers.first?.lastSuccess?.mostLimited?.remainingPercent, 75)
        XCTAssertEqual(remaining.providers.first?.lastSuccess?.fetchedAt, fixedNow)
        XCTAssertEqual(SnapshotReader.read(snapshotStore.url)?.providers.map(\.connectionID), [saved.id])
    }

    func testRotatingCodexTokenFamiliesPersistSeparatelyEvenWhenOneQuotaFails() async throws {
        var a = Connection(provider: .codex, enabled: true, consentedAt: fixedNow, id: "codex-a")
        var b = Connection(provider: .codex, enabled: true, consentedAt: fixedNow, id: "codex-b")
        a.directAuthentication = true; b.directAuthentication = true
        let secrets = AccountSecrets([
            a.id: try DirectCredential(provider: .codex, accessToken: "old-a", refreshToken: "refresh-a", expiresAt: fixedNow).encoded(),
            b.id: try DirectCredential(provider: .codex, accessToken: "old-b", refreshToken: "refresh-b", expiresAt: fixedNow).encoded()
        ])
        let coordinator = UsageCoordinator(connections: [a, b], secrets: secrets, http: AccountRotationHTTP(), store: try store(), now: { fixedNow })
        await coordinator.refresh()
        let states = await coordinator.current().providers
        XCTAssertEqual(states.map(\.status), [.needsAuthentication, .ready])
        XCTAssertEqual(states[1].lastSuccess?.mostLimited?.remainingPercent, 40)
        XCTAssertEqual(try DirectCredential.decode(XCTUnwrap(secrets.load(a.id)), for: .codex).refreshToken, "rotated-a")
        XCTAssertEqual(try DirectCredential.decode(XCTUnwrap(secrets.load(b.id)), for: .codex).refreshToken, "rotated-b")
        await coordinator.disconnect(a.id); try secrets.remove(a.id)
        XCTAssertNil(try secrets.load(a.id))
        XCTAssertEqual(try DirectCredential.decode(XCTUnwrap(secrets.load(b.id)), for: .codex).accessToken, "new-b")
    }

    func testPendingCredentialRejectsSiblingReadWriteAndDelete() throws {
        let pending = PendingCredentialStore("candidate", for: "account-a")
        XCTAssertThrowsError(try pending.load("account-b"))
        XCTAssertThrowsError(try pending.save("other", for: "account-b"))
        XCTAssertThrowsError(try pending.remove("account-b"))
        XCTAssertEqual(try pending.load("account-a"), "candidate")
        try pending.save("rotated", for: "account-a")
        XCTAssertEqual(try pending.load("account-a"), "rotated")
        try pending.remove("account-a")
        XCTAssertNil(try pending.load("account-a"))
    }

    func testKeychainDeleteAndResetAreAccountAndServiceScoped() throws {
        let namespace = "dev.bazzi.ai-limit.tests." + UUID().uuidString
        let own = KeychainStore(service: namespace)
        let other = KeychainStore(service: namespace + ".unrelated")
        defer { try? own.removeAll(); try? other.removeAll() }
        try own.save("first-family", for: "codex")
        let account = UUID().uuidString
        try own.save("second-family", for: account)
        try other.save("unrelated-family", for: account)
        try own.remove("codex")
        XCTAssertNil(try own.load("codex"))
        XCTAssertEqual(try own.load(account), "second-family")
        try own.removeAll()
        XCTAssertNil(try own.load(account))
        XCTAssertEqual(try other.load(account), "unrelated-family")
    }

    func testCacheRestoreRejectsSameIDWithDifferentProviderAndDuplicateConnections() async throws {
        let snapshotStore = try store()
        let old = UsageSnapshot(provider: .codex, source: .unofficialWeb, fetchedAt: fixedNow)
        _ = try snapshotStore.write(SharedSnapshot(updatedAt: fixedNow, providers: [ProviderState(provider: .codex, lastSuccess: old, connectionID: "same")]))
        let mixed = UsageCoordinator(connections: [cursor("same")], store: snapshotStore)
        let mixedState = await mixed.current()
        XCTAssertTrue(mixedState.providers.isEmpty)
        let duplicates = UsageCoordinator(connections: [cursor("same"), Connection(provider: .codex, enabled: true, id: "same")], store: snapshotStore)
        let duplicateState = await duplicates.current()
        XCTAssertTrue(duplicateState.providers.isEmpty)
    }

    func testLocalFallbackHistoryIsIsolatedByAccountRootAndProvider() async throws {
        let root = try directory(); let secondRoot = try directory()
        let file = root.appendingPathComponent("usage.jsonl")
        func log(_ output: Int) -> Data {
            Data("{\"type\":\"assistant\",\"timestamp\":\"2026-09-28T12:00:00Z\",\"requestId\":\"r\",\"message\":{\"id\":\"m\",\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":10,\"output_tokens\":\(output),\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}\n".utf8)
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-28T14:00:00Z"))
        let reader = LocalUsageReader()
        try log(10).write(to: file)
        let a = await reader.scan(accountID: "a", provider: .claude, root: root, now: now, calendar: calendar)
        XCTAssertEqual(a.summaries.first?.counters.total, 20)
        try log(25).write(to: file, options: .atomic)
        let b = await reader.scan(accountID: "b", provider: .claude, root: root, now: now, calendar: calendar)
        XCTAssertEqual(b.summaries.first?.counters.total, 35)
        try Data("{incomplete".utf8).write(to: file, options: .atomic)
        let fallbackA = await reader.scan(accountID: "a", provider: .claude, root: root, now: now, calendar: calendar)
        let fallbackB = await reader.scan(accountID: "b", provider: .claude, root: root, now: now, calendar: calendar)
        let draft = await reader.scan(accountID: "draft", provider: .claude, root: root, now: now, calendar: calendar)
        XCTAssertEqual(fallbackA.summaries.first?.counters.total, 20)
        XCTAssertEqual(fallbackB.summaries.first?.counters.total, 35)
        XCTAssertTrue(fallbackA.summaries.first?.isPartial == true)
        XCTAssertTrue(draft.summaries.isEmpty)
        await reader.forget("a")
        let retained = await reader.scan(accountID: "b", provider: .claude, root: root, now: now, calendar: calendar)
        let forgotten = await reader.scan(accountID: "a", provider: .claude, root: root, now: now, calendar: calendar)
        XCTAssertEqual(retained.summaries.first?.counters.total, 35)
        XCTAssertTrue(forgotten.summaries.isEmpty)
        try Data("{incomplete".utf8).write(to: secondRoot.appendingPathComponent("usage.jsonl"))
        let changedRoot = await reader.scan(accountID: "b", provider: .claude, root: secondRoot, now: now, calendar: calendar)
        XCTAssertTrue(changedRoot.summaries.isEmpty)
        try log(25).write(to: secondRoot.appendingPathComponent("usage.jsonl"), options: .atomic)
        let completeAgain = await reader.scan(accountID: "b", provider: .claude, root: secondRoot, now: now, calendar: calendar)
        XCTAssertEqual(completeAgain.summaries.first?.counters.total, 35)
        let sessions = secondRoot.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("{incomplete".utf8).write(to: sessions.appendingPathComponent("usage.jsonl"))
        let changedProvider = await reader.scan(accountID: "b", provider: .codex, root: secondRoot, now: now, calendar: calendar)
        XCTAssertTrue(changedProvider.summaries.isEmpty)
    }
}
