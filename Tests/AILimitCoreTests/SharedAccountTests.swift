import XCTest
import AILimitShared

final class SharedAccountTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_683_200)

    private func account(_ id: String, name: String, usedPercent: Double, provider: ProviderID = .codex) -> ProviderState {
        ProviderState(provider: provider, status: .ready, lastSuccess: UsageSnapshot(provider: provider, windows: [QuotaWindow(id: "quota", title: "한도", usedPercent: usedPercent)], source: .publicCLI, fetchedAt: now), connectionID: id, accountName: name)
    }

    private func document(_ snapshot: SharedSnapshot) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.encoded()) as? [String: Any])
    }

    private func decode(_ document: [String: Any]) throws -> SharedSnapshot {
        try SharedSnapshot.decode(JSONSerialization.data(withJSONObject: document))
    }

    func testSameProviderAccountsKeepSeparateSelectionsAndObservations() throws {
        let first = account("account-a", name: "개인", usedPercent: 25)
        let second = account("account-b", name: "업무", usedPercent: 80)
        let snapshot = try SharedSnapshot.decode(SharedSnapshot(updatedAt: now, providers: [first, second]).encoded())
        XCTAssertEqual(snapshot.orderedProviders().map(\.id), ["account-a", "account-b"])
        let selected = try XCTUnwrap(snapshot.orderedProviders(selection: ["account-b"]).first)
        XCTAssertEqual(selected.id, "account-b")
        XCTAssertEqual(selected.displayTitle, "Codex · 업무")
        XCTAssertEqual(selected.lastSuccess?.mostLimited?.remainingPercent, 20)
        XCTAssertEqual(snapshot.providers.first?.lastSuccess?.mostLimited?.remainingPercent, 75)
    }

    func testDefaultOrderAppendsMissingAccountsAndExplicitOrderDeduplicates() throws {
        let accounts = [account("a", name: "A", usedPercent: 10), account("b", name: "B", usedPercent: 20), account("c", name: "C", usedPercent: 30, provider: .claude)]
        let snapshot = SharedSnapshot(updatedAt: now, providers: accounts, displayOrder: ["b", "deleted", "b"])
        XCTAssertEqual(snapshot.orderedProviders().map(\.id), ["b", "a", "c"])
        XCTAssertEqual(snapshot.orderedProviders(selection: ["c", "b", "c", "unknown"]).map(\.id), ["c", "b"])
        let decoded = try SharedSnapshot.decode(snapshot.encoded())
        XCTAssertEqual(decoded.displayOrder, ["b", "a", "c"])
    }

    func testDeletedOrLegacySelectionNeverBroadensToSiblingAccounts() {
        let snapshot = SharedSnapshot(updatedAt: now, providers: [account("new-codex", name: "새 계정", usedPercent: 25)])
        XCTAssertTrue(snapshot.orderedProviders(selection: ["deleted"]).isEmpty)
        XCTAssertTrue(snapshot.orderedProviders(selection: ["codex"]).isEmpty)
        XCTAssertEqual(snapshot.orderedProviders(selection: ["deleted", "new-codex"]).map(\.id), ["new-codex"])
        XCTAssertEqual(snapshot.orderedProviders().map(\.id), ["new-codex"])
    }

    func testLegacySnapshotMigratesIdentityWithoutRemappingOldWidgetSelection() throws {
        let legacy = Data("""
        {"schemaVersion":1,"updatedAt":"2026-09-29T00:00:00Z","displayOrder":["claude","codex","cursor"],"providers":[
          {"provider":"codex","status":"ready","localTokens":[],"lastSuccess":{"provider":"codex","windows":[{"id":"primary","title":"Primary","usedPercent":25,"unit":{"percent":{}},"unlimited":false}],"balances":[],"source":"publicCLI","fetchedAt":"2026-09-28T23:00:00Z"}},
          {"provider":"claude","status":"disconnected","localTokens":[]}
        ]}
        """.utf8)
        var migrated = try SharedSnapshot.decode(legacy)
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.displayOrder, ["claude", "codex"])
        XCTAssertEqual(migrated.providers.map(\.id), ["codex", "claude"])
        XCTAssertEqual(migrated.providers.map(\.accountName), ["기본 계정", "기본 계정"])
        migrated.providers.insert(account("new-codex", name: "새 계정", usedPercent: 90), at: 0)
        let selected = try XCTUnwrap(migrated.orderedProviders(selection: ["codex"]).first)
        XCTAssertEqual(selected.id, "codex")
        XCTAssertEqual(selected.lastSuccess?.mostLimited?.remainingPercent, 75)
        XCTAssertEqual(selected.lastSuccess?.fetchedAt, ISO8601DateFormatter().date(from: "2026-09-28T23:00:00Z"))
        let roundTrip = try SharedSnapshot.decode(migrated.encoded())
        XCTAssertEqual(roundTrip.schemaVersion, 2)
        XCTAssertEqual(roundTrip.orderedProviders(selection: ["codex"]).map(\.id), ["codex"])
    }

    func testLegacyStandaloneStateDecodesButV2MissingIdentityIsRejected() throws {
        let legacyState: [String: Any] = ["provider": "codex", "status": "disconnected", "localTokens": []]
        let state = try JSONDecoder().decode(ProviderState.self, from: JSONSerialization.data(withJSONObject: legacyState))
        XCTAssertEqual(state.id, "codex")
        XCTAssertEqual(state.accountName, "기본 계정")
        let modern: [String: Any] = ["schemaVersion": 2, "updatedAt": "2026-09-29T00:00:00Z", "displayOrder": ["codex"], "providers": [legacyState]]
        XCTAssertThrowsError(try decode(modern))
    }

    func testDuplicateIDsAreRejectedForLegacyAndModernSnapshots() throws {
        let first = account("a", name: "A", usedPercent: 10)
        let second = account("a", name: "B", usedPercent: 90, provider: .claude)
        XCTAssertThrowsError(try SharedSnapshot(updatedAt: now, providers: [first, second]).encoded())
        var modern = try document(SharedSnapshot(updatedAt: now, providers: [first]))
        let rows = try XCTUnwrap(modern["providers"] as? [[String: Any]])
        modern["providers"] = rows + rows
        XCTAssertThrowsError(try decode(modern))
        let legacyState: [String: Any] = ["provider": "codex", "status": "disconnected", "localTokens": []]
        modern["schemaVersion"] = 1
        modern["providers"] = [legacyState, legacyState]
        XCTAssertThrowsError(try decode(modern))
    }

    func testMismatchedObservationProviderIsRejectedOnReadAndWrite() throws {
        var state = account("a", name: "A", usedPercent: 10)
        var wire = try document(SharedSnapshot(updatedAt: now, providers: [state]))
        var rows = try XCTUnwrap(wire["providers"] as? [[String: Any]])
        var success = try XCTUnwrap(rows[0]["lastSuccess"] as? [String: Any])
        success["provider"] = "claude"
        rows[0]["lastSuccess"] = success
        wire["providers"] = rows
        XCTAssertThrowsError(try decode(wire))
        state.lastSuccess?.provider = .claude
        XCTAssertThrowsError(try SharedSnapshot(updatedAt: now, providers: [state]).encoded())
    }

    func testUnknownSchemaAndInvalidIdentityAreRejected() throws {
        let snapshot = SharedSnapshot(updatedAt: now, providers: [account("a", name: "A", usedPercent: 10)])
        var wire = try document(snapshot)
        wire["schemaVersion"] = 99
        XCTAssertThrowsError(try decode(wire))
        let original = try document(snapshot)
        for (key, value) in [("connectionID", ""), ("connectionID", "  "), ("connectionID", "a\nb"), ("accountName", "\n ")] {
            var invalid = original
            var rows = try XCTUnwrap(invalid["providers"] as? [[String: Any]])
            rows[0][key] = value
            invalid["providers"] = rows
            XCTAssertThrowsError(try decode(invalid), "Accepted invalid \(key)")
        }
    }

    func testAccountDeepLinkRoundTripsLocalIDWithoutQueryOrFragmentInjection() throws {
        for id in ["codex", "account-b", "local/account ?#%한글"] {
            let state = account(id, name: "이름은 링크에 포함하지 않음", usedPercent: 10)
            let components = try XCTUnwrap(URLComponents(url: state.deepLink, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, "ailimit")
            XCTAssertEqual(components.host, "account")
            XCTAssertNil(components.query)
            XCTAssertNil(components.fragment)
            XCTAssertEqual(String(components.percentEncodedPath.dropFirst()).removingPercentEncoding, id)
            XCTAssertEqual(components.percentEncodedPath.filter { $0 == "/" }.count, 1)
        }
        XCTAssertNotEqual(account("a", name: "동일 이름", usedPercent: 10).deepLink, account("b", name: "동일 이름", usedPercent: 20).deepLink)
    }

    func testSnapshotMigrationDoesNotRetainUnknownCredentialFields() throws {
        var wire = try document(SharedSnapshot(updatedAt: now, providers: [account("local-id", name: "개인", usedPercent: 10)]))
        var rows = try XCTUnwrap(wire["providers"] as? [[String: Any]])
        rows[0]["credential"] = "private-session-secret"
        rows[0]["remoteAccountID"] = "private-remote-account"
        rows[0]["email"] = "private@example.test"
        rows[0]["localFolder"] = "/private/user/history"
        wire["providers"] = rows
        let encoded = String(decoding: try decode(wire).encoded(), as: UTF8.self)
        for privateValue in ["private-session-secret", "private-remote-account", "private@example.test", "/private/user/history"] {
            XCTAssertFalse(encoded.contains(privateValue))
        }
        XCTAssertEqual(try decode(wire).providers.first?.id, "local-id")
    }
}
