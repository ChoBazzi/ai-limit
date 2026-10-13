import XCTest
@testable import AILimitCore
import AILimitShared

private actor ResetCreditHTTP: HTTPTransport {
    enum Reply: Sendable {
        case response(HTTPResponse)
        case transportFailure
        case cancellation
        case usageCancellation
    }
    private var replies: [Reply]
    private(set) var requests: [HTTPRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw UsageError.transport }
        switch replies.removeFirst() {
        case .response(let response): return response
        case .transportFailure: throw UsageError.transport
        case .cancellation: throw CancellationError()
        case .usageCancellation: throw UsageError.cancelled
        }
    }
}

@MainActor
final class CodexResetCreditDirectTests: XCTestCase {
    private func reply(_ body: String, status: Int = 200) -> ResetCreditHTTP.Reply {
        .response(HTTPResponse(status: status, body: Data(body.utf8)))
    }
    private func usage(_ summary: String = "", account: String = "original") -> String {
        """
        {"account_id":"\(account)","rate_limit":{"primary_window":{"used_percent":25}},"credits":{"balance":"12.5"}\(summary)}
        """
    }
    private func fetch(_ http: ResetCreditHTTP, account: String? = "original") async throws -> UsageSnapshot {
        let context = FetchContext(connection: Connection(provider: .codex, enabled: true, consentedAt: fixedNow),
                                   secrets: SuppliedSecret("not-used"), http: http, now: { fixedNow })
        let credential = DirectCredential(provider: .codex, accessToken: "fixture-access", expiresAt: fixedNow.addingTimeInterval(3600),
                                          metadata: account.map { ["accountID": $0] } ?? [:])
        return try await CodexDirectProvider().fetch(context: context, credential: credential)
    }

    func testLatestCountIsIndependentOfCappedDetailsAndRequestsAreReadOnly() async throws {
        let http = ResetCreditHTTP([
            reply(usage(#", "rate_limit_reset_credits":{"available_count":7}"#)),
            reply(#"{"account_id":"original","available_count":12,"credits":[{"id":"private-id","reset_type":"codex_rate_limits","status":"available","expires_at":"2026-10-17T00:00:00Z"},{"reset_type":"codex_rate_limits","status":"available","expires_at":null}]}"#)
        ])
        let result = try await fetch(http)
        XCTAssertEqual(result.resetCredits?.availableCount, 12)
        let rows = try XCTUnwrap(result.resetCredits?.credits)
        XCTAssertEqual(rows.map(\.expiresAt), [Date(timeIntervalSince1970: 1792195200), nil])
        XCTAssertEqual(result.windows.map(\.remainingPercent), [75])
        XCTAssertEqual(result.balances.map(\.amount), [Decimal(string: "12.5")!])
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.url.absoluteString), [
            "https://chatgpt.com/backend-api/wham/usage",
            "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
        ])
        for request in requests {
            XCTAssertEqual(request.method, "GET")
            XCTAssertNil(request.body)
            XCTAssertEqual(request.headers["Authorization"], "Bearer fixture-access")
            XCTAssertEqual(request.headers["ChatGPT-Account-Id"], "original")
            XCTAssertNil(request.headers["x-openai-codex-luna-reserve"])
        }
        let shared = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(shared.contains("private-id"))
        XCTAssertFalse(shared.contains("fixture-access"))
    }

    func testAbsentInvalidAndExplicitZeroCountsRemainDistinct() async throws {
        for summary in ["", #", "rate_limit_reset_credits":null"#,
                        #", "rate_limit_reset_credits":{"available_count":null}"#,
                        #", "rate_limit_reset_credits":{"available_count":-1}"#,
                        #", "rate_limit_reset_credits":{"available_count":true}"#,
                        #", "rate_limit_reset_credits":{"available_count":1.5}"#] {
            let result = try await fetch(ResetCreditHTTP([reply(usage(summary)), reply("{}", status: 404)]))
            XCTAssertNil(result.resetCredits, summary)
            XCTAssertEqual(result.windows.first?.remainingPercent, 75)
        }
        let zero = try await fetch(ResetCreditHTTP([
            reply(usage(#", "rate_limit_reset_credits":{"available_count":0}"#)), .transportFailure
        ]))
        XCTAssertEqual(zero.resetCredits?.availableCount, 0)
        XCTAssertNil(zero.resetCredits?.credits)
        let detailsOnly = try await fetch(ResetCreditHTTP([
            reply(usage()), reply(#"{"available_count":0,"credits":[]}"#)
        ]))
        XCTAssertEqual(detailsOnly.resetCredits?.availableCount, 0)
        XCTAssertEqual(detailsOnly.resetCredits?.credits?.count, 0)
    }

    func testOnlyAvailableSupportedRowsWithExplicitValidExpiryAreIncluded() async throws {
        let details = #"""
        {"available_count":20,"credits":[
          {"reset_type":"codex_rate_limits","status":"available","expires_at":"2026-10-17T09:00:00.500+09:00"},
          {"reset_type":"codex_rate_limits","status":"available","expires_at":null},
          {"reset_type":"codex_rate_limits","status":"redeemed","expires_at":null},
          {"reset_type":"codex_rate_limits","status":"redeeming","expires_at":null},
          {"reset_type":"codex_rate_limits","status":"future-status","expires_at":null},
          {"reset_type":"future-type","status":"available","expires_at":null},
          {"reset_type":"codex_rate_limits","status":"available"},
          {"reset_type":"codex_rate_limits","status":"available","expires_at":"invalid"},
          {"reset_type":"codex_rate_limits","status":"available","expires_at":1792195200},
          {"reset_type":"codex_rate_limits","status":"available","expires_at":true},
          null
        ]}
        """#
        let result = try await fetch(ResetCreditHTTP([reply(usage()), reply(details)]))
        XCTAssertEqual(result.resetCredits?.availableCount, 20)
        XCTAssertEqual(result.resetCredits?.credits?.map(\.expiresAt), [Date(timeIntervalSince1970: 1792195200.5), nil])
    }

    func testOptionalNetworkAndMalformedDetailFailuresPreserveKnownCountAndQuota() async throws {
        let failures: [ResetCreditHTTP.Reply] = [
            .transportFailure, reply("{}", status: 401), reply("{}", status: 429), reply("{}", status: 500),
            reply("not json"), reply("null"), reply(#"{"available_count":-1,"credits":{}}"#)
        ]
        for failure in failures {
            let result = try await fetch(ResetCreditHTTP([
                reply(usage(#", "rate_limit_reset_credits":{"available_count":4}"#)), failure
            ]))
            XCTAssertEqual(result.resetCredits?.availableCount, 4)
            XCTAssertNil(result.resetCredits?.credits)
            XCTAssertEqual(result.windows.first?.remainingPercent, 75)
            XCTAssertEqual(result.balances.first?.amount, Decimal(string: "12.5"))
        }
    }

    func testMalformedDetailArrayDoesNotDiscardItsValidCount() async throws {
        for credits in ["null", "{}", "42"] {
            let result = try await fetch(ResetCreditHTTP([
                reply(usage(#", "rate_limit_reset_credits":{"available_count":4}"#)),
                reply("{\"available_count\":6,\"credits\":\(credits)}")
            ]))
            XCTAssertEqual(result.resetCredits?.availableCount, 6)
            XCTAssertNil(result.resetCredits?.credits)
        }
    }

    func testDetailRowsNeverInventCountButCanEnrichKnownSummary() async throws {
        let details = #"{"credits":[{"reset_type":"codex_rate_limits","status":"available","expires_at":null}]}"#
        let unknown = try await fetch(ResetCreditHTTP([reply(usage()), reply(details)]))
        XCTAssertNil(unknown.resetCredits)
        let known = try await fetch(ResetCreditHTTP([
            reply(usage(#", "rate_limit_reset_credits":{"available_count":3}"#)), reply(details)
        ]))
        XCTAssertEqual(known.resetCredits?.availableCount, 3)
        XCTAssertEqual(known.resetCredits?.credits?.count, 1)
        XCTAssertNil(known.resetCredits?.credits?.first?.expiresAt)
    }

    func testDetailResponseCannotCrossCredentialOrUsageAccount() async throws {
        for account: String? in ["original", nil] {
            let http = ResetCreditHTTP([
                reply(usage(#", "rate_limit_reset_credits":{"available_count":4}"#)),
                reply(#"{"account_id":"other","available_count":99,"credits":[]}"#)
            ])
            do {
                _ = try await fetch(http, account: account)
                XCTFail("Cross-account reset credits accepted")
            } catch UsageError.authentication {} catch { XCTFail("Wrong error: \(error)") }
        }
    }

    func testCancellationDuringOptionalDetailsIsNotConvertedToSuccess() async throws {
        for failure in [ResetCreditHTTP.Reply.cancellation, .usageCancellation] {
            let http = ResetCreditHTTP([
                reply(usage(#", "rate_limit_reset_credits":{"available_count":4}"#)), failure
            ])
            do {
                _ = try await fetch(http)
                XCTFail("Cancelled fetch published a snapshot")
            } catch is CancellationError {} catch UsageError.cancelled {} catch { XCTFail("Wrong error: \(error)") }
        }
    }
    func testResetOnlyResponseDoesNotInventQuota() async throws {
        let result = try await fetch(ResetCreditHTTP([
            reply(#"{"rate_limit_reset_credits":{"available_count":3}}"#), .transportFailure
        ]))
        XCTAssertEqual(result.resetCredits?.availableCount, 3)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.balances.isEmpty)
    }
}
