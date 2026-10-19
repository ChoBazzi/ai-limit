import XCTest
@testable import AILimitCore
import AILimitShared

private actor LifecycleHTTP: HTTPTransport {
    enum HeldRequest { case rotation, quota }
    let heldRequest: HeldRequest
    private var arrived = false
    private var released = false
    private var cancelled = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseWaiter: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    private var consumedRefresh = false
    init(_ heldRequest: HeldRequest) { self.heldRequest = heldRequest }
    func waitForRequest() async {
        if !arrived { await withCheckedContinuation { arrivalWaiters.append($0) } }
    }
    func waitForCancellation() async {
        if !cancelled { await withCheckedContinuation { cancellationWaiters.append($0) } }
    }
    private func didCancel() {
        cancelled = true
        cancellationWaiters.forEach { $0.resume() }; cancellationWaiters.removeAll()
    }
    func release() { released = true; responseWaiter?.resume(); responseWaiter = nil }
    var responseHeld: Bool { !released }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        calls += 1
        let rotation = request.url.path == "/oauth/token"
        if rotation {
            guard !consumedRefresh else { return response(#"{"error":"invalid_grant"}"#, status: 400) }
            consumedRefresh = true
        }
        if (heldRequest == .rotation && rotation) || (heldRequest == .quota && !rotation) {
            arrived = true
            arrivalWaiters.forEach { $0.resume() }; arrivalWaiters.removeAll()
            if !released {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { responseWaiter = $0 }
                } onCancel: { Task { await self.didCancel() } }
            }
        }
        if rotation { return response(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}"#) }
        if request.headers["Authorization"] == "Bearer new-access" {
            return response(#"{"rate_limit":{"primary_window":{"used_percent":25}}}"#)
        }
        if request.headers["Cookie"] != nil { return response(#"{"individualUsage":{"plan":{"totalPercentUsed":25}}}"#) }
        return response("{}", status: 401)
    }
}

private final class SnapshotNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SharedSnapshot] = []
    func record(_ value: SharedSnapshot) { lock.withLock { values.append(value) } }
    var snapshots: [SharedSnapshot] { lock.withLock { values } }
}

@MainActor
final class LifecycleTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func directConnection() -> Connection {
        var connection = Connection(provider: .codex, enabled: true, consentedAt: fixedNow)
        connection.directAuthentication = true
        return connection
    }
    private func secrets(_ connection: Connection) throws -> PendingCredentialStore {
        PendingCredentialStore(try DirectCredential(provider: .codex, accessToken: "old-access", refreshToken: "old-refresh", expiresAt: fixedNow).encoded(), for: connection.id)
    }

    func testCancelledFetchFinishesRotatingTokenExchangeBeforeReturning() async throws {
        let connection = directConnection(); let secrets = try secrets(connection)
        let http = LifecycleHTTP(.rotation)
        let context = FetchContext(connection: connection, secrets: secrets, http: http, now: { fixedNow })
        let fetch = Task { try await Providers.make(.codex).fetch(context: context) }
        await http.waitForRequest()
        fetch.cancel()
        await http.release()
        do { _ = try await fetch.value; XCTFail("Cancelled quota fetch succeeded") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let credential = try DirectCredential.decode(XCTUnwrap(secrets.load(connection.id)), for: .codex)
        XCTAssertEqual(credential.refreshToken, "rotated-refresh")
        let next = try await Providers.make(.codex).fetch(context: context)
        XCTAssertEqual(next.mostLimited?.remainingPercent, 75)
    }

    func testLocalFolderReplacementPreservesRotatedCredentialAndRejectsOldGeneration() async throws {
        let root = try directory(); let connection = directConnection(); let secrets = try secrets(connection)
        let http = LifecycleHTTP(.rotation)
        let store = SnapshotStore(groupURL: root.appendingPathComponent("shared.json"), fallbackDirectory: root)
        let coordinator = UsageCoordinator(connections: [connection], secrets: secrets, http: http, store: store, now: { fixedNow })
        let refresh = Task { await coordinator.refresh() }
        await http.waitForRequest()
        var updated = connection; updated.localFolder = root; updated.localConsentedAt = fixedNow
        let replace = Task { await coordinator.replace(updated) }
        await Task.yield()
        await http.release()
        await replace.value; await refresh.value
        let afterReplace = await coordinator.current()
        XCTAssertNil(afterReplace.providers.first?.lastSuccess)
        XCTAssertEqual(try DirectCredential.decode(XCTUnwrap(secrets.load(connection.id)), for: .codex).refreshToken, "rotated-refresh")
        await coordinator.refresh()
        let next = await coordinator.current()
        XCTAssertEqual(next.providers.first?.status, .ready)
        XCTAssertEqual(next.providers.first?.lastSuccess?.mostLimited?.remainingPercent, 75)
        await coordinator.disconnect(connection.id)
        try secrets.remove(connection.id)
        await coordinator.refresh()
        XCTAssertNil(try secrets.load(connection.id))
        XCTAssertEqual(SnapshotReader.read(store.url)?.providers.count, 0)
    }

    func testShutdownDrainsJobsAlreadyBeingReplacedAndRejectsNewRefreshes() async throws {
        let root = try directory()
        let connection = Connection(provider: .cursor, enabled: true, consentedAt: fixedNow)
        let http = LifecycleHTTP(.quota)
        let store = SnapshotStore(groupURL: root.appendingPathComponent("shared.json"), fallbackDirectory: root)
        let coordinator = UsageCoordinator(connections: [connection], secrets: SuppliedSecret("session=value"), http: http, store: store)
        let refresh = Task { await coordinator.refresh() }
        await http.waitForRequest()
        var paused = connection; paused.enabled = false
        let replace = Task { await coordinator.replace(paused) }
        await http.waitForCancellation()
        let earlyReturn = expectation(description: "Shutdown cannot return with a held job")
        earlyReturn.isInverted = true
        let shutdown = Task {
            await coordinator.shutdown()
            if await http.responseHeld { earlyReturn.fulfill() }
        }
        let waitResult = await XCTWaiter.fulfillment(of: [earlyReturn], timeout: 0.05)
        XCTAssertEqual(waitResult, .completed)
        await coordinator.refresh()
        let beforeRelease = await http.calls
        XCTAssertEqual(beforeRelease, 1)
        await http.release()
        await shutdown.value; await replace.value; await refresh.value
        let persisted = try Data(contentsOf: store.url)
        await coordinator.refresh()
        await coordinator.replace(connection)
        XCTAssertEqual(try Data(contentsOf: store.url), persisted)
        let calls = await http.calls
        XCTAssertEqual(calls, 1)
    }

    func testResetDrainsRotationBeforeSecretDeletionAndPreventsResurrection() async throws {
        let root = try directory(); let connection = directConnection(); let secrets = try secrets(connection)
        let http = LifecycleHTTP(.rotation)
        let store = SnapshotStore(groupURL: root.appendingPathComponent("shared.json"), fallbackDirectory: root)
        let coordinator = UsageCoordinator(connections: [connection], secrets: secrets, http: http, store: store, now: { fixedNow })
        let refresh = Task { await coordinator.refresh() }
        await http.waitForRequest()
        let earlyReturn = expectation(description: "Reset cannot return before credential rotation is saved")
        earlyReturn.isInverted = true
        let reset = Task {
            try await coordinator.reset()
            if await http.responseHeld { earlyReturn.fulfill() }
            try secrets.removeAll()
        }
        let waitResult = await XCTWaiter.fulfillment(of: [earlyReturn], timeout: 0.05)
        XCTAssertEqual(waitResult, .completed)
        await http.release()
        try await reset.value; await refresh.value
        await coordinator.refresh()
        XCTAssertNil(try secrets.load(connection.id))
        XCTAssertEqual(SnapshotReader.read(store.url)?.providers.count, 0)
        let calls = await http.calls
        XCTAssertEqual(calls, 1)
    }

    func testExplicitResetClearsOrphanedSnapshotWithoutFirstRunAccess() async throws {
        for shared in [false, true] {
            let root = try directory()
            let store = SnapshotStore(groupURL: shared ? root.appendingPathComponent("group.json") : nil, fallbackDirectory: root)
            let stale = SharedSnapshot(updatedAt: fixedNow, providers: [ProviderState(provider: .cursor, status: .ready, connectionID: "orphan")])
            _ = try store.write(stale)
            let fallback = SnapshotStore(groupURL: nil, fallbackDirectory: root)
            _ = try fallback.write(stale)
            let http = LifecycleHTTP(.quota)
            let notifications = SnapshotNotifications()
            let coordinator = UsageCoordinator(connections: [], secrets: SuppliedSecret("unused"), http: http, store: store, changed: { value, _ in notifications.record(value) })
            await coordinator.refresh()
            XCTAssertEqual(SnapshotReader.read(store.url)?.providers.map(\.connectionID), ["orphan"])
            XCTAssertTrue(notifications.snapshots.isEmpty)
            try await coordinator.reset()
            let cleared = try XCTUnwrap(SnapshotReader.read(store.url))
            XCTAssertTrue(cleared.providers.isEmpty)
            XCTAssertNil(cleared.usageOverview)
            XCTAssertEqual(SnapshotReader.read(fallback.url)?.providers.count, 0)
            XCTAssertEqual(notifications.snapshots.last?.providers.count, 0)
            let calls = await http.calls
            XCTAssertEqual(calls, 0)
        }
    }
}
