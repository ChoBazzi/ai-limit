import XCTest
@testable import AILimitCore
import AILimitShared

struct FixtureHTTP: HTTPTransport {
    var responses: [String: HTTPResponse]
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { guard let response = responses[request.url.path] else { throw UsageError.transport }; return response }
}
struct FixtureProcess: ProcessRunning {
    var data: Data
    func run(_ request: ProcessRequest) async throws -> ProcessOutput { ProcessOutput(stdout: request.arguments == ["--version"] ? Data("agy 1.1.11".utf8) : data, status: 0) }
}
func fixture(_ name: String) throws -> Data { try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name)) }
let fixedNow = Date(timeIntervalSince1970: 1_790_553_600)
func testContext(_ id: ProviderID, responses: [String: HTTPResponse] = [:], cli: Data = Data(), secret: String = "sessionKey=test", org: String? = nil) -> FetchContext {
    FetchContext(connection: Connection(provider: id, enabled: true, executable: URL(fileURLWithPath: "/fixture/cli"), claudeOrganization: org, consentedAt: fixedNow), secrets: SuppliedSecret(secret), http: FixtureHTTP(responses: responses), process: FixtureProcess(data: cli), now: { fixedNow })
}
func response(_ text: String, status: Int = 200) -> HTTPResponse { HTTPResponse(status: status, body: Data(text.utf8)) }

@MainActor
final class ProviderTests: XCTestCase {
    func testCodexCountersPlansDedupAndPrivacy() async throws {
        let value = try await CodexProvider().fetch(context: testContext(.codex, cli: fixture("codex.jsonl")))
        XCTAssertEqual(value.windows.count, 2); XCTAssertEqual(value.windows[0].remainingPercent, 75); XCTAssertEqual(value.windows[0].resetsAt, Date(timeIntervalSince1970: 1790812800)); XCTAssertEqual(value.plan, "pro"); XCTAssertEqual(value.balances[0].amount, Decimal(string: "12.34"))
        let data = try SharedSnapshot(updatedAt: fixedNow, providers: [ProviderState(provider: .codex, lastSuccess: value)]).encoded()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("never-share")); XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sessionKey"))
    }
    func testCodexRejectsMissingAccountAPIKeyAndWrongIDs() async throws {
        for account in ["null", "{\"type\":\"apiKey\"}"] {
            let data = Data("{\"id\":0,\"result\":{}}\n{\"id\":1,\"result\":{\"account\":\(account)}}\n{\"id\":2,\"result\":{}}\n".utf8)
            do { _ = try await CodexProvider().fetch(context: testContext(.codex, cli: data)); XCTFail("Must reject non-subscription account") } catch {}
        }
        do { _ = try await CodexProvider().fetch(context: testContext(.codex, cli: Data("{\"id\":99,\"result\":{}}\n".utf8))); XCTFail("Wrong reply accepted") } catch {}
    }
    func testClaudeNullWindowsModelsAndOptionalMoney() async throws {
        let org = "11111111-1111-1111-1111-111111111111"; let base = "/api/organizations/" + org
        var responses = ["/api/organizations": HTTPResponse(status: 200, body: try fixture("claude-orgs.json")), base + "/usage": HTTPResponse(status: 200, body: try fixture("claude.json")), base + "/overage_spend_limit": response("{\"is_enabled\":true,\"used_credits\":125,\"monthly_credit_limit\":1000,\"currency\":\"USD\"}")]
        let value = try await ClaudeProvider().fetch(context: testContext(.claude, responses: responses, org: org))
        XCTAssertEqual(value.windows.map(\.id), ["seven_day", "seven_day_sonnet", "seven_day_opus", "overage"]); XCTAssertEqual(value.windows[0].remainingPercent, 60); XCTAssertEqual(value.windows[3].used, Decimal(string: "1.25")); XCTAssertEqual(value.windows[3].unit, .currency(code: "USD"))
        responses[base + "/overage_spend_limit"] = response("{}", status: 500)
        let without = try await ClaudeProvider().fetch(context: testContext(.claude, responses: responses, org: org)); XCTAssertEqual(without.windows.count, 3)
        do { _ = try await ClaudeProvider().fetch(context: testContext(.claude, responses: responses, org: "removed")); XCTFail("Missing organization silently changed") } catch {}
    }
    func testAntigravityUsesFractionOnly() async throws {
        let value = try await AntigravityProvider().fetch(context: testContext(.antigravity, cli: fixture("antigravity.json")))
        XCTAssertEqual(value.windows.count, 1); XCTAssertEqual(value.windows[0].remainingPercent, 25); XCTAssertTrue(value.windows[0].title.contains("Gemini"))
        do { _ = try await AntigravityProvider().fetch(context: testContext(.antigravity, cli: Data("{\"status\":\"SUCCESS\",\"command\":{\"name\":\"prompt\"}}".utf8))); XCTFail("Wrong command accepted") } catch {}
    }
    func testCursorKeepsPercentScaleAndCents() async throws {
        let value = try await CursorProvider().fetch(context: testContext(.cursor, responses: ["/api/usage-summary": HTTPResponse(status: 200, body: try fixture("cursor.json"))], secret: "cursor=test"))
        XCTAssertEqual(value.windows[0].used, Decimal(string: "12.50")); XCTAssertEqual(value.windows[0].limit, 20); XCTAssertEqual(value.windows[0].usedPercent, 62.5); XCTAssertEqual(value.windows.first { $0.id == "autoPercentUsed" }?.usedPercent, 0.36)
    }
    func testCopilotPlaceholderAndSingleCreditPool() async throws {
        var body = Data("HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n".utf8); body.append(try fixture("copilot.json"))
        let value = try await CopilotProvider().fetch(context: testContext(.copilot, cli: body)); XCTAssertEqual(value.windows.count, 1); XCTAssertEqual(value.windows[0].remainingPercent, 75); XCTAssertNil(value.windows[0].resetsAt); XCTAssertEqual(value.balances[0].amount, 31)
        let over = try await CopilotProvider().fetch(context: testContext(.copilot, cli: Data("HTTP/2.0 200 OK\n\n{\"quota_snapshots\":{\"chat\":{\"percent_remaining\":-25}}}".utf8))); XCTAssertEqual(over.windows[0].usedPercent, 125)
    }
    func testWindsurfPresenceAndBounds() async throws {
        var status = Data([112, 70, 120, 40]); status.append(WindsurfProto.varint(17 << 3)); status.append(WindsurfProto.varint(1790812800))
        let payload = WindsurfProto.bytes(1, status)
        let secret = "{\"devin_session_token\":\"test\",\"devin_auth1_token\":\"test\",\"devin_account_id\":\"test\",\"devin_primary_org_id\":\"test\"}"
        let value = try await WindsurfProvider().fetch(context: testContext(.windsurf, responses: ["/_backend/exa.seat_management_pb.SeatManagementService/GetPlanStatus": HTTPResponse(status: 200, body: payload)], secret: secret))
        XCTAssertEqual(value.windows.map(\.remainingPercent), [70, 40]); XCTAssertEqual(value.windows[0].resetsAt, Date(timeIntervalSince1970: 1790812800)); XCTAssertNil(value.windows[1].resetsAt)
        XCTAssertNil(try WindsurfProto.integer(WindsurfProto.decode(Data()), 14)); XCTAssertEqual(try WindsurfProto.integer(WindsurfProto.decode(Data([112, 0])), 14), 0)
        for bad in [Data([10, 5, 1]), Data(repeating: 255, count: 11), Data([0]), Data([15])] { XCTAssertThrowsError(try WindsurfProto.decode(bad)) }
    }
    func testPerplexityCreditUnitsExpiredGrantAndCookies() async throws {
        let value = try await PerplexityProvider().fetch(context: testContext(.perplexity, responses: ["/rest/billing/credits": HTTPResponse(status: 200, body: try fixture("perplexity.json"))], secret: "authjs.session-token.1=b; authjs.session-token.0=a"))
        XCTAssertEqual(value.balances.map(\.amount), [Decimal(string: "12.34")!, 5, 2, 20]); XCTAssertEqual(value.balances[0].unit, .credits); XCTAssertTrue(value.windows.isEmpty)
        XCTAssertThrowsError(try Credentials.validate("authjs.session-token.0=a; authjs.session-token.2=c", for: .perplexity))
        XCTAssertEqual(try Credentials.validate("authjs.session-token.1=b; authjs.session-token.0=a", for: .perplexity), "authjs.session-token.0=a; authjs.session-token.1=b")
    }
    func testGrokUsesConfirmedUSDCentsAndRejectsPeriodOnly() async throws {
        let value = try await GrokProvider().fetch(context: testContext(.grok, responses: ["/v1/billing": HTTPResponse(status: 200, body: try fixture("grok.json"))], secret: "bearer-token")); XCTAssertEqual(value.windows[0].remainingPercent, 70); XCTAssertEqual(value.windows[1].used, Decimal(string: "1.25")); XCTAssertEqual(value.windows[1].unit, .currency(code: "USD"))
        do {
            _ = try await GrokProvider().fetch(context: testContext(.grok, responses: ["/v1/billing": response("{\"config\":{\"billingPeriodEnd\":\"2026-10-01T00:00:00Z\"}}")], secret: "bearer-token"))
            XCTFail("A period without metrics is not quota access")
        } catch UsageError.unavailable {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testKiroPairsAndPlanOnly() async throws {
        let value = try await KiroProvider().fetch(context: testContext(.kiro, cli: fixture("kiro.txt"))); XCTAssertEqual(value.windows[0].used, 10); XCTAssertEqual(value.windows[0].limit, 50); XCTAssertEqual(value.windows[0].remainingPercent, 80); XCTAssertEqual(value.windows[1].used, 3)
        let plan = try await KiroProvider().fetch(context: testContext(.kiro, cli: Data("Plan: KIRO PRO MAX | 1 usage breakdowns\n████ 55%".utf8))); XCTAssertEqual(plan.plan, "KIRO PRO MAX"); XCTAssertTrue(plan.windows.isEmpty)
    }
    func testNumberAndCredentialBoundaries() throws {
        XCTAssertNil(try JSON(data: Data("null".utf8)).decimal()); XCTAssertEqual(try JSON(data: Data("0".utf8)).decimal(), 0)
        for value in ["-1", "\"NaN\"", "true"] { XCTAssertThrowsError(try JSON(data: Data(value.utf8)).decimal()) }
        XCTAssertThrowsError(try JSON(data: Data("9223372036854775808".utf8)).integer())
        XCTAssertNil(QuotaWindow(id: "zero", title: "zero", used: 0, limit: 0).usedPercent)
        for id in [ProviderID.claude, .cursor, .perplexity, .grok] { XCTAssertThrowsError(try Credentials.validate("a=b\r\nInjected: yes", for: id)) }
        XCTAssertThrowsError(try Credentials.validate("sk-ant-oat-secret", for: .claude)); XCTAssertThrowsError(try Credentials.validate("xai-secret", for: .grok)); XCTAssertThrowsError(try Credentials.validate("{}", for: .windsurf))
    }
    func testHTTPClassificationAndSchema() throws {
        XCTAssertThrowsError(try response("{}", status: 401).checked(now: fixedNow)) { guard case UsageError.authentication = $0 else { return XCTFail("Expected authentication") } }
        XCTAssertThrowsError(try response("<html>Cloudflare challenge</html>", status: 403).checked(now: fixedNow)) { guard case UsageError.unavailable = $0 else { return XCTFail("Challenge must not clear credential") } }
        XCTAssertThrowsError(try HTTPResponse(status: 429, headers: ["Retry-After":"0"], body: Data()).checked(now: fixedNow)) { guard case UsageError.rateLimited(let date) = $0 else { return XCTFail() }; XCTAssertEqual(date, fixedNow.addingTimeInterval(300)) }
        let encoded = try SharedSnapshot(updatedAt: fixedNow, providers: []).encoded()
        var invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        invalid["schemaVersion"] = 99
        XCTAssertThrowsError(try SharedSnapshot.decode(JSONSerialization.data(withJSONObject: invalid)))
    }
}
