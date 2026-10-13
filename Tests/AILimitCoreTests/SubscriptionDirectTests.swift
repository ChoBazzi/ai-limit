import XCTest
import CryptoKit
@testable import AILimitCore
import AILimitShared

private actor SubscriptionHTTP: HTTPTransport {
    private var responses: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw UsageError.transport }
        return responses.removeFirst()
    }
}

private final class SubscriptionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = fixedNow
    private var waits: [TimeInterval] = []
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds); waits.append(seconds) } }
    var sleeps: [TimeInterval] { lock.withLock { waits } }
}

private actor SubscriptionAuthorization {
    private(set) var challenge: String?
    func authorize(_ url: URL, _ redirect: URL, _ state: String) throws -> URL {
        let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        challenge = parameters.first { $0.name == "code_challenge" }?.value
        return try SubscriptionOAuth.url(redirect.absoluteString, parameters: ["code": "fixture-code", "state": state])
    }
}

@MainActor
final class SubscriptionDirectTests: XCTestCase {
    private func context(_ provider: ProviderID, _ http: any HTTPTransport) -> FetchContext {
        FetchContext(connection: Connection(provider: provider, enabled: true, consentedAt: fixedNow), secrets: SuppliedSecret("not-used"), http: http, now: { fixedNow })
    }
    private func ui(_ authorization: SubscriptionAuthorization = SubscriptionAuthorization()) -> DirectSignInUI {
        DirectSignInUI(openURL: { _ in }, showCode: { _, _ in }, authorize: { try await authorization.authorize($0, $1, $2) })
    }
    private func token(_ provider: ProviderID, metadata: [String: String] = [:]) -> DirectCredential {
        DirectCredential(provider: provider, accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: fixedNow.addingTimeInterval(3600), metadata: metadata)
    }
    private func jwt(account: String) -> String {
        let payload = Data("{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"\(account)\"}}".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "fixture.\(payload).signature"
    }

    func testCodexSubjectBindingSurvivesRotationAndRejectsAnotherWorkspaceMember() async throws {
        func access(_ subject: String?) throws -> String {
            var claims: [String: Any] = ["https://api.openai.com/auth": ["chatgpt_account_id": "shared-workspace"]]
            if let subject { claims["sub"] = subject }
            let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "fixture.\(payload).signature"
        }
        let http = SubscriptionHTTP([
            response("{\"access_token\":\"\(try access("member-a"))\",\"refresh_token\":\"first\",\"expires_in\":3600}"),
            response("{\"access_token\":\"\(try access(nil))\",\"refresh_token\":\"second\",\"expires_in\":3600}"),
            response("{\"access_token\":\"\(try access("member-b"))\",\"refresh_token\":\"third\",\"expires_in\":3600}")
        ])
        let auth = CodexDirectAuth(http: http, now: { fixedNow })
        let signed = try await auth.signIn(ui: ui())
        XCTAssertEqual(signed.metadata["accountID"], "shared-workspace")
        XCTAssertEqual(signed.metadata["subject"], "member-a")
        let refreshed = try await auth.refresh(signed)
        XCTAssertEqual(refreshed.metadata["subject"], "member-a")
        XCTAssertEqual(refreshed.refreshToken, "second")
        do { _ = try await auth.refresh(refreshed); XCTFail("Different member of the same workspace accepted") }
        catch UsageError.authentication {} catch { XCTFail("Wrong error: \(error)") }
    }

    func testBothPKCELoginsBindVerifierAndRotateTokens() async throws {
        for provider in [ProviderID.codex, .claude] {
            let authorization = SubscriptionAuthorization()
            let http = SubscriptionHTTP([
                response(#"{"access_token":"first","refresh_token":"refresh-first","expires_in":3600}"#),
                response(#"{"access_token":"second","refresh_token":"refresh-second","expires_in":7200}"#)
            ])
            let signed: DirectCredential
            let refreshed: DirectCredential
            if provider == .codex {
                let auth = CodexDirectAuth(http: http, now: { fixedNow })
                signed = try await auth.signIn(ui: ui(authorization)); refreshed = try await auth.refresh(signed)
            } else {
                let auth = ClaudeDirectAuth(http: http, now: { fixedNow })
                signed = try await auth.signIn(ui: ui(authorization)); refreshed = try await auth.refresh(signed)
            }
            XCTAssertEqual(signed.expiresAt, fixedNow.addingTimeInterval(3600))
            XCTAssertEqual(refreshed.accessToken, "second")
            XCTAssertEqual(refreshed.refreshToken, "refresh-second")
            XCTAssertEqual(refreshed.expiresAt, fixedNow.addingTimeInterval(7200))
            let requests = await http.requests
            let body = try XCTUnwrap(requests.first?.body)
            let verifier: String
            if provider == .codex {
                verifier = try XCTUnwrap(URLComponents(string: "https://fixture.invalid/?" + String(decoding: body, as: UTF8.self))?.queryItems?.first { $0.name == "code_verifier" }?.value)
            } else {
                verifier = try XCTUnwrap(JSON(data: body)["code_verifier"].string)
            }
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let sentChallenge = await authorization.challenge
            XCTAssertEqual(challenge, sentChallenge)
        }
    }

    func testCallbackStateOriginDuplicateAndDenialRejectedBeforeExchange() async throws {
        for attack in ["state", "host", "duplicate", "denied"] {
            let http = SubscriptionHTTP([])
            let unsafeUI = DirectSignInUI(openURL: { _ in }, showCode: { _, _ in }, authorize: { _, redirect, state in
                var parts = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
                parts.queryItems = [URLQueryItem(name: "state", value: attack == "state" ? "replayed-state" : state), URLQueryItem(name: "code", value: "code")]
                if attack == "host" { parts.host = "attacker.invalid" }
                if attack == "duplicate" { parts.queryItems?.append(URLQueryItem(name: "code", value: "second")) }
                if attack == "denied" { parts.queryItems?.append(URLQueryItem(name: "error", value: "access_denied")) }
                return parts.url!
            })
            do { _ = try await CodexDirectAuth(http: http).signIn(ui: unsafeUI); XCTFail("Invalid callback accepted") } catch {}
            let requests = await http.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testRefreshRejectsChangedAccountAndPreservesAbsentRotation() async throws {
        let codex = token(.codex, metadata: ["accountID": "original"])
        let codexHTTP = SubscriptionHTTP([response("{\"access_token\":\"\(jwt(account: "other"))\",\"expires_in\":3600}")])
        do { _ = try await CodexDirectAuth(http: codexHTTP, now: { fixedNow }).refresh(codex); XCTFail("Changed account accepted") } catch {}
        let claude = token(.claude, metadata: ["accountID": "original", "organizationID": "org"])
        let claudeHTTP = SubscriptionHTTP([
            response(#"{"access_token":"next","expires_in":3600,"account":{"uuid":"other"}}"#),
            response(#"{"access_token":"next","expires_in":3600}"#)
        ])
        let auth = ClaudeDirectAuth(http: claudeHTTP, now: { fixedNow })
        do { _ = try await auth.refresh(claude); XCTFail("Changed account accepted") } catch {}
        let result = try await auth.refresh(claude)
        XCTAssertEqual(result.refreshToken, claude.refreshToken)
        XCTAssertEqual(result.metadata, claude.metadata)
    }

    func testExpiredRevokedAndWrongProviderCannotFetch() async throws {
        let http = SubscriptionHTTP([response("{}", status: 401)])
        var expired = token(.codex); expired.expiresAt = fixedNow
        do { _ = try await CodexDirectProvider().fetch(context: context(.codex, http), credential: expired); XCTFail("Expired bearer used") } catch {}
        do { _ = try await ClaudeDirectProvider().fetch(context: context(.claude, http), credential: token(.codex)); XCTFail("Cross-provider bearer used") } catch {}
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
        do { _ = try await CodexDirectProvider().fetch(context: context(.codex, http), credential: token(.codex)); XCTFail("Revoked bearer accepted") }
        catch { guard case UsageError.authentication = error else { return XCTFail("Expected authentication") } }
    }

    func testCodexReportedWindowAndClaudeModelDistinctions() async throws {
        let codexHTTP = SubscriptionHTTP([response(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":25,"reset_at":1790812800},"secondary_window":null}}"#)])
        let codex = try await CodexDirectProvider().fetch(context: context(.codex, codexHTTP), credential: token(.codex))
        XCTAssertEqual(codex.windows.map(\.remainingPercent), [75])
        XCTAssertEqual(codex.windows.first?.resetsAt, Date(timeIntervalSince1970: 1790812800))
        XCTAssertEqual(codex.source, .unofficialWeb)
        let claudeHTTP = SubscriptionHTTP([response(#"{"five_hour":null,"seven_day":{"utilization":40},"seven_day_sonnet":{"utilization":0},"seven_day_opus":{"utilization":85}}"#)])
        let claude = try await ClaudeDirectProvider().fetch(context: context(.claude, claudeHTTP), credential: token(.claude))
        XCTAssertEqual(claude.windows.map(\.id), ["seven_day", "seven_day_sonnet", "seven_day_opus"])
        XCTAssertEqual(claude.windows.map(\.remainingPercent), [60, 100, 15])
    }

    func testMissingQuotaNeverBecomesUnusedOrUnlimited() async throws {
        for body in ["{}", #"{"plan_type":"pro","rate_limit":{"primary_window":{}}}"#] {
            do { _ = try await CodexDirectProvider().fetch(context: context(.codex, SubscriptionHTTP([response(body)])), credential: token(.codex)); XCTFail("Missing quota accepted") } catch {}
        }
        do { _ = try await ClaudeDirectProvider().fetch(context: context(.claude, SubscriptionHTTP([response(#"{"five_hour":null,"seven_day":{}}"#)])), credential: token(.claude)); XCTFail("Missing quota accepted") } catch {}
        let http = SubscriptionHTTP([response(#"{"id":42}"#), response(#"{"copilot_plan":"individual","quota_snapshots":{"chat":{"entitlement":0,"remaining":0,"percent_remaining":100}}}"#)])
        do { _ = try await CopilotDirectProvider().fetch(context: context(.copilot, http), credential: token(.copilot, metadata: ["userID": "42"])); XCTFail("Placeholder became unlimited/unused") } catch {}
    }

    func testCodexCreditsModelsAndResponseAccountBinding() async throws {
        let payload = #"{"account_id":"original","credits":{"balance":"12.34"},"additional_rate_limits":[{"limit_name":"Spark","rate_limit":{"primary_window":{"used_percent":80,"limit_window_seconds":18000}}}]}"#
        let credential = token(.codex, metadata: ["accountID": "original"])
        let http = SubscriptionHTTP([response(payload)])
        let result = try await CodexDirectProvider().fetch(context: context(.codex, http), credential: credential)
        XCTAssertEqual(result.balances.map(\.amount), [Decimal(string: "12.34")!])
        XCTAssertEqual(result.windows.map(\.remainingPercent), [20])
        XCTAssertTrue(result.windows[0].title.contains("Spark"))
        let mismatched = SubscriptionHTTP([response(payload.replacingOccurrences(of: "original", with: "other"))])
        do { _ = try await CodexDirectProvider().fetch(context: context(.codex, mismatched), credential: credential); XCTFail("Wrong-account usage accepted") } catch {}
        let unknown = SubscriptionHTTP([response(#"{"credits":{"has_credits":true}}"#)])
        do { _ = try await CodexDirectProvider().fetch(context: context(.codex, unknown), credential: credential); XCTFail("Credit balance invented") } catch {}
    }

    func testClaudeProfileFailurePreservesQuotaButMismatchRejectsIt() async throws {
        let usage = #"{"seven_day":{"utilization":40}}"#
        let credential = token(.claude, metadata: ["accountID": "original"])
        let failed = SubscriptionHTTP([response(usage), response("{}", status: 500)])
        let snapshot = try await ClaudeDirectProvider().fetch(context: context(.claude, failed), credential: credential)
        XCTAssertEqual(snapshot.windows.map(\.remainingPercent), [60])
        XCTAssertNil(snapshot.plan)
        let changed = SubscriptionHTTP([response(usage), response(#"{"account":{"uuid":"other","has_claude_pro":true}}"#)])
        do { _ = try await ClaudeDirectProvider().fetch(context: context(.claude, changed), credential: credential); XCTFail("Changed profile accepted") }
        catch { guard case UsageError.authentication = error else { return XCTFail("Expected account mismatch") } }
    }

    func testNonExpiringCopilotAndExpiredNonRefreshableCredentials() async throws {
        let nonExpiring = DirectCredential(provider: .copilot, accessToken: "opaque", metadata: ["userID": "42"])
        let http = SubscriptionHTTP([])
        let auth = CopilotDirectAuth(http: http, now: { fixedNow })
        let unchanged = try await auth.refresh(nonExpiring)
        XCTAssertEqual(unchanged.accessToken, "opaque")
        XCTAssertNil(unchanged.expiresAt)
        var expired = nonExpiring
        expired.expiresAt = fixedNow
        do { _ = try await auth.refresh(expired); XCTFail("Expired non-refreshable token accepted") } catch {}
        let lostExpiry = SubscriptionHTTP([response(#"{"access_token":"new","refresh_token":"rotated"}"#)])
        do { _ = try await CopilotDirectAuth(http: lostExpiry, now: { fixedNow }).refresh(token(.copilot)); XCTFail("Expiring token silently became permanent") } catch {}
    }

    func testCopilotDeviceSlowDownRotationAndAccountMismatch() async throws {
        let clock = SubscriptionClock()
        let http = SubscriptionHTTP([
            response(#"{"device_code":"device","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#),
            response(#"{"error":"authorization_pending"}"#, status: 400),
            response(#"{"error":"slow_down"}"#),
            response(#"{"access_token":"first","refresh_token":"old","expires_in":3600}"#),
            response(#"{"id":42}"#),
            response(#"{"access_token":"rotated","refresh_token":"new","expires_in":7200}"#),
            response(#"{"id":99}"#)
        ])
        let auth = CopilotDirectAuth(http: http, now: { clock.now() }, sleep: { clock.advance($0) })
        let signed = try await auth.signIn(ui: ui())
        XCTAssertEqual(clock.sleeps, [5, 5, 10])
        XCTAssertEqual(signed.metadata["userID"], "42")
        let rotated = try await auth.refresh(signed)
        XCTAssertEqual(rotated.refreshToken, "new")
        XCTAssertEqual(rotated.metadata, signed.metadata)
        do { _ = try await CopilotDirectProvider().fetch(context: context(.copilot, http), credential: rotated); XCTFail("Cross-account quota fetched") } catch {}
        let paths = await http.requests.map(\.url.path)
        XCTAssertFalse(paths.contains("/copilot_internal/user"))
    }

    func testCopilotCreditPoolAndOveruseRemainIndependent() async throws {
        let http = SubscriptionHTTP([response(#"{"id":42}"#), response(#"{"quota_snapshots":{"premium_interactions":{"percent_remaining":-25,"credits_used":31},"chat":{"entitlement":0,"remaining":0,"credits_used":31}}}"#)])
        let result = try await CopilotDirectProvider().fetch(context: context(.copilot, http), credential: token(.copilot, metadata: ["userID": "42"]))
        XCTAssertEqual(result.windows.map(\.usedPercent), [125])
        XCTAssertEqual(result.balances.map(\.amount), [31])
        XCTAssertNil(result.windows.first?.resetsAt)
        let creditOnly = SubscriptionHTTP([response(#"{"id":42}"#), response(#"{"quota_snapshots":{"chat":{"credits_used":0}}}"#)])
        let zero = try await CopilotDirectProvider().fetch(context: context(.copilot, creditOnly), credential: token(.copilot, metadata: ["userID": "42"]))
        XCTAssertTrue(zero.windows.isEmpty)
        XCTAssertEqual(zero.balances.map(\.amount), [0])
    }

    func testDeviceExpiryDenialAndCancellationNeverPublishCredential() async throws {
        let device = #"{"device_code":"device","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":9,"interval":5}"#
        let clock = SubscriptionClock()
        let http = SubscriptionHTTP([response(device), response(#"{"error":"authorization_pending"}"#)])
        do { _ = try await CopilotDirectAuth(http: http, now: { clock.now() }, sleep: { clock.advance($0) }).signIn(ui: ui()); XCTFail("Expired device authorized") } catch {}
        XCTAssertEqual(clock.sleeps, [5, 4])
        for remoteError in ["access_denied", "expired_token"] {
            let denied = SubscriptionHTTP([response(device), response("{\"error\":\"\(remoteError)\"}")])
            do { _ = try await CopilotDirectAuth(http: denied, now: { fixedNow }, sleep: { _ in }).signIn(ui: ui()); XCTFail("Denied device authorized") } catch {}
        }
        let cancelledHTTP = SubscriptionHTTP([response(device)])
        let task = Task { try await CopilotDirectAuth(http: cancelledHTTP).signIn(ui: ui()) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled sign-in authorized") } catch {}
        let paths = await cancelledHTTP.requests.map(\.url.path)
        XCTAssertFalse(paths.contains("/login/oauth/access_token"))
    }
}
