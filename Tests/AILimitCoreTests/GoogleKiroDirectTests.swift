import XCTest
import CryptoKit
@testable import AILimitCore
import AILimitShared

private actor GoogleKiroHTTP: HTTPTransport {
    private var replies: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []
    init(_ replies: [HTTPResponse]) { self.replies = replies }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw UsageError.transport }
        return replies.removeFirst()
    }
}

private final class GoogleKiroClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = fixedNow
    private var delays: [TimeInterval] = []
    func now() -> Date { lock.withLock { instant } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant.addTimeInterval(seconds); delays.append(seconds) } }
    var sleeps: [TimeInterval] { lock.withLock { delays } }
}

private actor GoogleAuthorizationCapture {
    var authorization: URL?
    func save(_ url: URL) { authorization = url }
}

@MainActor
final class GoogleKiroDirectTests: XCTestCase {
    private let registration = #"{"clientId":"registered-client","clientSecret":"registered-secret","clientSecretExpiresAt":1893456000}"#
    private let device = #"{"deviceCode":"device-secret","userCode":"ABCD-EFGH","verificationUriComplete":"https://oidc.us-east-1.amazonaws.com/device_authorization?user_code=ABCD-EFGH","expiresIn":60,"interval":5}"#
    private let awsToken = #"{"accessToken":"aws-access","refreshToken":"aws-refresh","expiresIn":3600,"tokenType":"Bearer"}"#
    private let googleToken = #"{"access_token":"google-access","refresh_token":"google-refresh","expires_in":3600,"token_type":"Bearer"}"#

    private func deviceUI() -> DirectSignInUI {
        DirectSignInUI(openURL: { _ in }, showCode: { _, _ in }, authorize: { _, _, _ in throw UsageError.configuration("Device flow must not use a callback") })
    }

    func testGooglePKCEOfflineSignInAndIdentityStayPrivate() async throws {
        let capture = GoogleAuthorizationCapture()
        let ui = DirectSignInUI(openURL: { _ in }, showCode: { _, _ in }, authorize: { authorization, redirect, state in
            await capture.save(authorization)
            var callback = try XCTUnwrap(URLComponents(url: redirect, resolvingAgainstBaseURL: false))
            callback.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code", value: "issued-code")]
            return try XCTUnwrap(callback.url)
        })
        let http = GoogleKiroHTTP([response(googleToken), response(#"{"id":"private-account","email":"private@example.test"}"#)])
        let credential = try await AntigravityDirectAuth(http: http, now: { fixedNow }, configuration: {
            AntigravityOAuthConfiguration(clientID: "fixture-google-client", clientSecret: "fixture-google-secret")
        }).signIn(ui: ui)
        XCTAssertEqual(credential.expiresAt, fixedNow.addingTimeInterval(3600))
        XCTAssertEqual(credential.metadata["accountID"], "private-account")
        let authorization = await capture.authorization
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(authorization), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "access_type" }?.value, "offline")
        let requests = await http.requests
        let exchange = try XCTUnwrap(URLComponents(string: "https://fixture.invalid/?" + String(decoding: XCTUnwrap(requests.first?.body), as: UTF8.self))?.queryItems)
        let verifier = try XCTUnwrap(exchange.first { $0.name == "code_verifier" }?.value)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(query.first { $0.name == "code_challenge" }?.value, challenge)
        XCTAssertEqual(exchange.first { $0.name == "redirect_uri" }?.value, AntigravityDirectAuth.redirectURI)
        XCTAssertEqual(credential.refreshToken, "google-refresh")
    }

    func testGoogleLocalConfigurationFailureDoesNotOpenBrowserOrSendTokens() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("antigravity-oauth.json")
        let http = GoogleKiroHTTP([])
        let ui = DirectSignInUI(openURL: { _ in XCTFail("Unexpected browser") }, showCode: { _, _ in XCTFail("Unexpected code") }, authorize: { _, _, _ in
            XCTFail("Missing configuration opened authorization")
            throw UsageError.authentication
        })
        let auth = AntigravityDirectAuth(http: http, configuration: { try AntigravityOAuthConfiguration.load(from: file) })
        let existing = DirectCredential(provider: .antigravity, accessToken: "old", refreshToken: "private-refresh")
        let cases: [String?] = [nil, "{invalid-private-content", #"{"clientID":"fixture","clientSecret":""}"#, #"{"clientID":"bad client","clientSecret":"private-value"}"#, #"{"clientID":"fixture"}"#]
        for content in cases {
            if let content { try Data(content.utf8).write(to: file) }
            for refresh in [false, true] {
                do {
                    if refresh { _ = try await auth.refresh(existing) }
                    else { _ = try await auth.signIn(ui: ui) }
                    XCTFail("Invalid configuration accepted")
                } catch let error as UsageError {
                    guard case .configuration = error else { return XCTFail("Expected configuration error") }
                    XCTAssertFalse(error.localizedDescription.contains("private-"))
                }
            }
        }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testGoogleApprovalKeepsOriginalClientWhenLocalFileChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("antigravity-oauth.json")
        try Data(#"{"clientID":"fixture-first","clientSecret":"fixture-first-secret"}"#.utf8).write(to: file)
        let ui = DirectSignInUI(openURL: { _ in }, showCode: { _, _ in }, authorize: { authorization, redirect, state in
            let items = try XCTUnwrap(URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.first { $0.name == "client_id" }?.value, "fixture-first")
            XCTAssertNil(items.first { $0.name == "client_secret" })
            try Data(#"{"clientID":"fixture-second","clientSecret":"fixture-second-secret"}"#.utf8).write(to: file)
            var callback = try XCTUnwrap(URLComponents(url: redirect, resolvingAgainstBaseURL: false))
            callback.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code", value: "issued-code")]
            return try XCTUnwrap(callback.url)
        })
        let http = GoogleKiroHTTP([response(googleToken), response("{}")])
        let credential = try await AntigravityDirectAuth(http: http, configuration: {
            try AntigravityOAuthConfiguration.load(from: file)
        }).signIn(ui: ui)
        let requests = await http.requests
        let fields = try XCTUnwrap(URLComponents(string: "https://fixture.invalid/?" + String(decoding: XCTUnwrap(requests.first?.body), as: UTF8.self))?.queryItems)
        XCTAssertEqual(fields.first { $0.name == "client_id" }?.value, "fixture-first")
        XCTAssertEqual(fields.first { $0.name == "client_secret" }?.value, "fixture-first-secret")
        let stored = try credential.encoded()
        XCTAssertFalse(stored.contains("fixture-first-secret"))
        XCTAssertFalse(stored.contains("fixture-second-secret"))
    }

    func testGoogleCallbackRejectsWrongStateOriginAndAmbiguousCode() throws {
        for callback in [
            "http://127.0.0.1:51121/oauth2callback?state=wrong&code=code",
            "http://attacker.invalid:51121/oauth2callback?state=expected&code=code",
            "http://127.0.0.1:51121/other?state=expected&code=code",
            "http://127.0.0.1:51121/oauth2callback?state=expected&state=wrong&code=code",
            "http://127.0.0.1:51121/oauth2callback?state=expected&code=a&code=b",
            "http://127.0.0.1:51121/oauth2callback?state=expected&error=access_denied"
        ] {
            XCTAssertThrowsError(try AntigravityDirectAuth.authorizationCode(XCTUnwrap(URL(string: callback)), state: "expected"))
        }
    }

    func testGoogleRefreshPreservesBindingAndAcceptsRotation() async throws {
        let existing = DirectCredential(provider: .antigravity, accessToken: "old", refreshToken: "old-refresh", expiresAt: fixedNow,
                                        metadata: ["accountID": "private-account"])
        let http = GoogleKiroHTTP([response(googleToken), response(#"{"access_token":"next-access","expires_in":1800}"#)])
        let auth = AntigravityDirectAuth(http: http, now: { fixedNow }, configuration: {
            AntigravityOAuthConfiguration(clientID: "fixture-google-client", clientSecret: "fixture-google-secret")
        })
        let rotated = try await auth.refresh(existing)
        XCTAssertEqual(rotated.refreshToken, "google-refresh")
        let refreshed = try await auth.refresh(rotated)
        XCTAssertEqual(refreshed.refreshToken, "google-refresh")
        XCTAssertEqual(refreshed.metadata, existing.metadata)
        XCTAssertEqual(refreshed.expiresAt, fixedNow.addingTimeInterval(1800))
        for invalid in [#"{"access_token":"x"}"#, #"{"access_token":"x","expires_in":0}"#, #"{"access_token":"x","expires_in":3600,"scope":"openid email"}"#] {
            XCTAssertThrowsError(try AntigravityDirectAuth.credential(JSON(data: Data(invalid.utf8)), previous: existing, now: fixedNow))
        }
    }

    func testAntigravityRealSummaryUsesResolvedProjectAndNeverLeaksIt() async throws {
        let summary = #"{"summary":{"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"session","remainingFraction":0.25,"resetTime":"2026-10-01T00:00:00Z"},{"bucketId":"weekly","remaining":{"case":"remainingFraction","value":1}}]},{"name":"Claude + GPT","buckets":[{"name":"weekly","remaining":{"remainingFraction":0}}]}]}}"#
        let http = GoogleKiroHTTP([response(#"{"cloudaicompanionProject":"private-project","paidTier":{"name":"AI Pro"}}"#), response(summary)])
        var context = testContext(.antigravity); context.http = http
        let snapshot = try await AntigravityDirectProvider().fetch(context: context, credential: DirectCredential(provider: .antigravity, accessToken: "private-token"))
        XCTAssertEqual(snapshot.windows.map(\.remainingPercent), [25, 100, 0])
        XCTAssertEqual(snapshot.plan, "AI Pro")
        XCTAssertEqual(snapshot.source, .unofficialWeb)
        let requests = await http.requests
        XCTAssertEqual(requests.map { $0.url.path }, ["/v1internal:loadCodeAssist", "/v1internal:retrieveUserQuotaSummary"])
        XCTAssertEqual(try JSON(data: XCTUnwrap(requests.last?.body))["project"].string, "private-project")
        let shared = String(decoding: try SharedSnapshot(updatedAt: fixedNow, providers: [ProviderState(provider: .antigravity, lastSuccess: snapshot)]).encoded(), as: UTF8.self)
        for secret in ["private-project", "private-token", "private-account"] { XCTAssertFalse(shared.contains(secret)) }
    }

    func testAntigravityMissingDisabledAndCatalogAreNotFullQuota() throws {
        for body in [#"{"models":{"gemini":{"quotaInfo":{"remainingFraction":1}}}}"#,
                     #"{"groups":[{"name":"Gemini","buckets":[{"name":"session"},{"name":"weekly","disabled":true,"remainingFraction":1}]}]}"#,
                     #"{"groups":[{"name":"Gemini","buckets":[{"name":"session","remainingFraction":1.01}]}]}"#] {
            XCTAssertThrowsError(try AntigravityDirectProvider.decode(JSON(data: Data(body.utf8)), plan: "Pro", now: fixedNow))
        }
    }

    func testAntigravityQuotaDeniedDistinctFromExpiredAuthentication() async throws {
        for status in [401, 403] {
            let http = GoogleKiroHTTP([response(#"{"cloudaicompanionProject":"project"}"#), response("{}", status: status)])
            var context = testContext(.antigravity); context.http = http
            do {
                _ = try await AntigravityDirectProvider().fetch(context: context, credential: DirectCredential(provider: .antigravity, accessToken: "token"))
                XCTFail("Quota denial accepted")
            } catch let error as UsageError {
                if status == 403 { guard case .unavailable = error else { return XCTFail("Quota denial is not token expiry") } }
                else { guard case .authentication = error else { return XCTFail("401 must require authentication") } }
            }
            let requests = await http.requests
            XCTAssertFalse(requests.contains { $0.url.path.contains("fetchAvailableModels") })
        }
    }

    func testKiroPendingSlowDownAndPublicRegistrationExpiry() async throws {
        let clock = GoogleKiroClock()
        let http = GoogleKiroHTTP([response(registration), response(device), response(#"{"error":"authorization_pending"}"#, status: 400),
                                  response(#"{"error":"slow_down"}"#, status: 400), response(awsToken)])
        let credential = try await KiroDirectAuth(http: http, now: { clock.now() }, sleep: { clock.advance($0) }).signIn(ui: deviceUI())
        XCTAssertEqual(clock.sleeps, [5, 5, 10])
        XCTAssertEqual(credential.expiresAt, clock.now().addingTimeInterval(3600))
        XCTAssertEqual(credential.metadata["clientId"], "registered-client")
        XCTAssertEqual(credential.metadata["clientSecret"], "registered-secret")
        XCTAssertNil(credential.metadata["profileARN"])
        let raw = try credential.encoded()
        XCTAssertEqual(try DirectCredential.decode(raw, for: .kiro).metadata, credential.metadata)
    }

    func testKiroDenialDeadlineAndPhishingNeverAuthorize() async throws {
        for code in ["access_denied", "expired_token", "invalid_grant"] {
            let clock = GoogleKiroClock()
            let http = GoogleKiroHTTP([response(registration), response(device), response("{\"error\":\"\(code)\",\"error_description\":\"private-remote-text\"}", status: 400)])
            do { _ = try await KiroDirectAuth(http: http, now: { clock.now() }, sleep: { clock.advance($0) }).signIn(ui: deviceUI()); XCTFail("Denied grant authorized") }
            catch { XCTAssertFalse(error.localizedDescription.contains("private-remote-text")) }
        }
        let clock = GoogleKiroClock()
        let http = GoogleKiroHTTP([response(registration), response(device)])
        do { _ = try await KiroDirectAuth(http: http, now: { clock.now() }, sleep: { _ in clock.advance(61) }).signIn(ui: deviceUI()); XCTFail("Expired device code polled") } catch {}
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.url.path == "/token" })
        for url in ["https://oidc.us-east-1.amazonaws.com.attacker.invalid/device_authorization", "http://view.awsapps.com/start", "https://user@view.awsapps.com/start"] {
            XCTAssertThrowsError(try KiroDirectAuth.verificationURL(url))
        }
    }

    func testKiroCancellationCannotPublishDeviceToken() async throws {
        let http = GoogleKiroHTTP([response(registration), response(device), response(awsToken)])
        let ui = deviceUI()
        let task = Task {
            try await KiroDirectAuth(http: http, now: { fixedNow }, sleep: { _ in
                try await Task.sleep(for: .seconds(60))
            }).signIn(ui: ui)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled login produced a credential") } catch {}
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.url.path == "/token" })
    }

    func testKiroNonJSONRateLimitKeepsBackoffDuringRefresh() async throws {
        let http = GoogleKiroHTTP([HTTPResponse(status: 429, headers: ["Retry-After": "42"], body: Data("rate limited".utf8))])
        let credential = DirectCredential(provider: .kiro, accessToken: "old", refreshToken: "refresh",
            metadata: ["region": "us-east-1", "clientId": "client", "clientSecret": "secret"])
        do {
            _ = try await KiroDirectAuth(http: http, now: { fixedNow }).refresh(credential)
            XCTFail("Rate-limited refresh succeeded")
        } catch let error as UsageError {
            guard case .rateLimited(let retry) = error else { return XCTFail("Non-JSON error lost HTTP classification") }
            XCTAssertEqual(retry, fixedNow.addingTimeInterval(42))
        }
    }

    func testKiroRefreshRotationAndRegistrationExpiryFailClosed() async throws {
        var existing = DirectCredential(provider: .kiro, accessToken: "old", refreshToken: "old-refresh", expiresAt: fixedNow,
            metadata: ["region": "us-east-1", "clientId": "client", "clientSecret": "secret", "profileARN": "actual-profile", "clientSecretExpiresAt": "1893456000"])
        let http = GoogleKiroHTTP([response(awsToken)])
        let auth = KiroDirectAuth(http: http, now: { fixedNow })
        let rotated = try await auth.refresh(existing)
        XCTAssertEqual(rotated.refreshToken, "aws-refresh")
        XCTAssertEqual(rotated.metadata["profileARN"], "actual-profile")
        existing.metadata["clientSecretExpiresAt"] = String(fixedNow.timeIntervalSince1970)
        do { _ = try await auth.refresh(existing); XCTFail("Expired registration refreshed") } catch {}
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertThrowsError(try KiroDirectAuth.credential(JSON(data: Data(#"{"accessToken":"new","expiresIn":3600,"profileArn":"other-profile"}"#.utf8)), metadata: rotated.metadata, previousRefresh: rotated.refreshToken, now: fixedNow))
    }

    func testKiroPreciseMainTrialAndBonusRemainSeparate() throws {
        let body = #"{"subscriptionInfo":{"subscriptionTitle":"KIRO PRO"},"nextDateReset":1790812800,"userInfo":{"email":"private@example.test"},"usageBreakdownList":[{"resourceType":"AGENTIC_REQUEST","unit":"CREDITS","currentUsage":10,"currentUsageWithPrecision":10.25,"usageLimit":100,"freeTrialInfo":{"freeTrialStatus":"ACTIVE","currentUsageWithPrecision":2.5,"usageLimitWithPrecision":20,"freeTrialExpiry":1893456000},"bonuses":[{"status":"ACTIVE","currentUsage":3,"usageLimit":15,"expiresAt":1893456000},{"status":"EXPIRED","currentUsage":1,"usageLimit":1000},{"status":"ACTIVE","currentUsage":0,"usageLimit":1000,"expiresAt":1}]}]}"#
        let snapshot = try KiroDirectProvider.decode(JSON(data: Data(body.utf8)), now: fixedNow)
        XCTAssertEqual(snapshot.windows.map(\.used), [Decimal(string: "10.25"), Decimal(string: "2.5"), 3])
        XCTAssertEqual(snapshot.windows.map(\.limit), [100, 20, 15])
        XCTAssertEqual(snapshot.windows[0].usedPercent, 10.25)
        XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1790812800))
        XCTAssertEqual(snapshot.windows[1].resetsAt, Date(timeIntervalSince1970: 1893456000))
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.unit == .credits })
        let shared = String(decoding: try SharedSnapshot(updatedAt: fixedNow, providers: [ProviderState(provider: .kiro, lastSuccess: snapshot)]).encoded(), as: UTF8.self)
        XCTAssertFalse(shared.contains("private@example.test"))
    }

    func testKiroMissingZeroOverageAndUnknownUnitSemantics() throws {
        let body = #"{"usageBreakdownList":[{"resourceType":"AGENTIC_REQUEST","usageLimit":100},{"unit":"custom units","currentUsage":0,"usageLimit":0},{"resourceType":"AGENTIC_REQUEST","currentUsage":120,"usageLimit":100,"overageCap":1000}]}"#
        let snapshot = try KiroDirectProvider.decode(JSON(data: Data(body.utf8)), now: fixedNow)
        XCTAssertNil(snapshot.windows[0].used)
        XCTAssertNil(snapshot.windows[0].usedPercent)
        XCTAssertEqual(snapshot.windows[1].used, 0)
        XCTAssertNil(snapshot.windows[1].usedPercent)
        XCTAssertEqual(snapshot.windows[1].unit, .providerUnits(name: "custom units"))
        XCTAssertEqual(snapshot.windows[2].usedPercent, 120)
        XCTAssertEqual(snapshot.windows[2].limit, 100)
        for body in [#"{"subscriptionInfo":{"subscriptionTitle":"KIRO PRO"}}"#, #"{"usageBreakdownList":[{"currentUsageWithPrecision":-1,"currentUsage":0,"usageLimit":100}]}"#] {
            XCTAssertThrowsError(try KiroDirectProvider.decode(JSON(data: Data(body.utf8)), now: fixedNow))
        }
    }

    func testKiroDirectManagementDoesNotInventProfile() async throws {
        for profile in [nil, "arn:aws:codewhisperer:us-east-1:123:profile/actual"] as [String?] {
            let http = GoogleKiroHTTP([response(#"{"usageBreakdownList":[{"resourceType":"AGENTIC_REQUEST","currentUsage":1,"usageLimit":10}]}"#)])
            var context = testContext(.kiro); context.http = http
            var credential = DirectCredential(provider: .kiro, accessToken: "token", metadata: ["region": "us-east-1"])
            credential.metadata["profileARN"] = profile
            let snapshot = try await KiroDirectProvider().fetch(context: context, credential: credential)
            XCTAssertEqual(snapshot.windows[0].usedPercent, 10)
            let requests = await http.requests
            let url = try XCTUnwrap(requests.first?.url)
            XCTAssertEqual(url.host, "management.us-east-1.kiro.dev")
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "profileArn" }?.value, profile)
        }
    }
}
