import XCTest
@testable import AILimitCore
import AILimitShared

private actor DirectBoundaryHTTP: HTTPTransport {
    let replies: [String: HTTPResponse]
    private(set) var requests = 0
    init(_ replies: [String: HTTPResponse] = [:]) { self.replies = replies }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests += 1
        return replies[request.url.path] ?? HTTPResponse(status: 503, body: Data())
    }
}

@MainActor
final class DirectAuthenticationTests: XCTestCase {
    private func context(_ provider: ProviderID, credential: DirectCredential, http: any HTTPTransport) throws -> FetchContext {
        var connection = Connection(provider: provider, enabled: true, consentedAt: fixedNow)
        connection.directAuthentication = true
        return FetchContext(connection: connection, secrets: PendingCredentialStore(try credential.encoded(), for: connection.id), http: http, now: { fixedNow })
    }
    func testCredentialCannotCrossProviderBoundary() async throws {
        let http = DirectBoundaryHTTP()
        let context = try context(.perplexity, credential: DirectCredential(provider: .grok, accessToken: "other-provider-secret"), http: http)
        do { _ = try await Providers.make(.perplexity).fetch(context: context); XCTFail("Cross-provider credential accepted") }
        catch UsageError.authentication {} catch { XCTFail("Wrong error: \(error)") }
        let requests = await http.requests
        XCTAssertEqual(requests, 0)
    }
    func testNonrefreshableSessionExpiresAtActualDeadlineNotRefreshSkew() async throws {
        let http = DirectBoundaryHTTP(["/rest/billing/credits": response(#"{"balance_cents":1234}"#)])
        let fresh = DirectCredential(provider: .perplexity, accessToken: "__Secure-next-auth.session-token=fixture", expiresAt: fixedNow.addingTimeInterval(30))
        let value = try await Providers.make(.perplexity).fetch(context: context(.perplexity, credential: fresh, http: http))
        XCTAssertEqual(value.balances.first?.amount, Decimal(string: "12.34"))
        var expired = fresh; expired.expiresAt = fixedNow
        do { _ = try await Providers.make(.perplexity).fetch(context: context(.perplexity, credential: expired, http: http)); XCTFail("Expired session fetched quota") }
        catch UsageError.authentication {} catch { XCTFail("Wrong error: \(error)") }
        let requests = await http.requests
        XCTAssertEqual(requests, 1)
    }
    func testRotatedTokenSurvivesSubsequentQuotaFailure() async throws {
        let http = DirectBoundaryHTTP([
            "/oauth2/token": response(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}"#),
            "/v1/billing": response("{}", status: 403)
        ])
        let old = DirectCredential(provider: .grok, accessToken: "old-access", refreshToken: "old-refresh", expiresAt: fixedNow)
        let context = try context(.grok, credential: old, http: http)
        do { _ = try await Providers.make(.grok).fetch(context: context); XCTFail("Denied quota accepted") }
        catch {}
        let stored = try DirectCredential.decode(XCTUnwrap(context.secrets.load(context.connection.id)), for: .grok)
        XCTAssertEqual(stored.refreshToken, "rotated-refresh")
        XCTAssertEqual(stored.accessToken, "new-access")
    }
    func testRevokedOAuthGrantIsAuthenticationWithoutRemoteErrorText() async throws {
        let http = DirectBoundaryHTTP(["/token": response(#"{"error":"invalid_grant","error_description":"secret remote content"}"#, status: 400)])
        do {
            try await Task.detached {
                _ = try await DirectHTTP(http: http).form("https://oauth2.googleapis.com/token", ["grant_type": "refresh_token"])
            }.value
            XCTFail("Revoked grant accepted")
        } catch UsageError.authentication {} catch { XCTFail("Wrong error: \(error)") }
    }
}
