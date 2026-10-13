import XCTest
@testable import AILimitCore
import AILimitShared

@MainActor
final class DirectWebProviderTests: XCTestCase {
    func testWindsurfRejectsWrongCallbackStateBeforeTokenExchange() async throws {
        let ui = DirectSignInUI(openURL: { _ in }, showCode: { _, _ in }, authorize: { _, callback, _ in
            var components = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "state", value: "wrong"), URLQueryItem(name: "code", value: "code")]
            return components.url!
        })
        do {
            _ = try await WindsurfDirectAuth(http: FixtureHTTP(responses: [:])).signIn(ui: ui)
            XCTFail("Wrong state accepted")
        } catch UsageError.authentication {} catch { XCTFail("Callback was not rejected before HTTP: \(error)") }
    }

    func testCursorRefreshPreservesRefreshAndBindingWhenNotRotated() async throws {
        let old = DirectCredential(provider: .cursor, accessToken: "old", refreshToken: "refresh", metadata: ["account": "original"])
        let http = FixtureHTTP(responses: ["/auth/exchange_user_api_key": response(#"{"accessToken":"new"}"#)])
        let result = try await CursorDirectAuth(http: http, now: { fixedNow }).refresh(old)
        XCTAssertEqual(result.refreshToken, old.refreshToken)
        XCTAssertEqual(result.metadata, old.metadata)
        XCTAssertNil(result.expiresAt)
        let rejected = FixtureHTTP(responses: ["/auth/exchange_user_api_key": response("{}", status: 401)])
        do {
            _ = try await CursorDirectAuth(http: rejected).refresh(old)
            XCTFail("Rejected refresh must not return stale credentials")
        } catch UsageError.authentication {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCursorCentsPercentScaleAndUnknownPlan() throws {
        let data = Data(#"{"billingCycleEnd":"1790812800000","planUsage":{"includedSpend":1250,"limit":2000,"autoPercentUsed":0.36}}"#.utf8)
        let value = try CursorDirectProvider.decode(data, now: fixedNow)
        XCTAssertEqual(value.windows[0].used, Decimal(string: "12.50"))
        XCTAssertEqual(value.windows[0].limit, 20)
        XCTAssertEqual(value.windows[0].usedPercent, 62.5)
        XCTAssertEqual(value.windows[0].resetsAt, Date(timeIntervalSince1970: 1790812800))
        XCTAssertEqual(value.windows[1].usedPercent, 0.36)
        XCTAssertNil(value.plan)
    }

    func testCursorMissingQuotaDoesNotBecomeFullOrPro() throws {
        for text in [#"{"planUsage":{}}"#, #"{"spendLimitUsage":{"limitType":"team"}}"#] {
            XCTAssertThrowsError(try CursorDirectProvider.decode(Data(text.utf8), now: fixedNow)) { error in
                guard case UsageError.unavailable = error else { return XCTFail("Expected unavailable") }
            }
        }
        let value = try CursorDirectProvider.decode(Data(#"{"planUsage":{"limit":0,"includedSpend":0}}"#.utf8), now: fixedNow)
        XCTAssertNil(value.windows[0].usedPercent)
        XCTAssertFalse(value.windows[0].unlimited)
    }

    func testGrokDevicePendingSlowdownDenialAndExpiry() throws {
        var interval: Double = 5
        XCTAssertNil(try GrokDirectAuth.pollResult(response(#"{"error":"authorization_pending"}"#, status: 400), now: fixedNow, interval: &interval))
        XCTAssertNil(try GrokDirectAuth.pollResult(response(#"{"error":"slow_down"}"#, status: 400), now: fixedNow, interval: &interval))
        XCTAssertEqual(interval, 10)
        XCTAssertThrowsError(try GrokDirectAuth.pollResult(response(#"{"error":"access_denied"}"#, status: 400), now: fixedNow, interval: &interval)) { error in
            guard case UsageError.authentication = error else { return XCTFail("Expected denial") }
        }
        XCTAssertThrowsError(try GrokDirectAuth.pollResult(response(#"{"error":"expired_token"}"#, status: 400), now: fixedNow, interval: &interval)) { error in
            guard case UsageError.timeout = error else { return XCTFail("Expected expiration") }
        }
        XCTAssertThrowsError(try GrokDirectAuth.pollResult(response(#"{"error":"authorization_pending"}"#, status: 500), now: fixedNow, interval: &interval))
    }

    func testGrokRefreshKeepsAccountBindingAndRotatedToken() async throws {
        let old = DirectCredential(provider: .grok, accessToken: "old", refreshToken: "refresh-old", metadata: ["binding": "original"])
        let http = FixtureHTTP(responses: ["/oauth2/token": response(#"{"access_token":"new","refresh_token":"rotated","expires_in":300}"#)])
        let new = try await GrokDirectAuth(http: http, now: { fixedNow }).refresh(old)
        XCTAssertEqual(new.refreshToken, "rotated")
        XCTAssertEqual(new.expiresAt, fixedNow.addingTimeInterval(300))
        XCTAssertEqual(new.metadata, old.metadata)
        let missing = try GrokDirectAuth.credential(JSON(data: Data(#"{"access_token":"new"}"#.utf8)), now: fixedNow, previous: old)
        XCTAssertEqual(missing.refreshToken, "refresh-old")
        XCTAssertNil(missing.expiresAt)
    }

    func testGrokUSDAndOmittedScalarAreNotInvented() throws {
        let data = Data(#"{"config":{"creditUsagePercent":30,"onDemandUsed":{"val":125},"onDemandCap":{"val":2000},"prepaidBalance":{"val":500},"isUnifiedBillingUser":true}}"#.utf8)
        let value = try GrokDirectProvider.decode(data, now: fixedNow)
        XCTAssertEqual(value.windows[0].remainingPercent, 70)
        XCTAssertEqual(value.windows[1].used, Decimal(string: "1.25"))
        XCTAssertEqual(value.windows[1].limit, 20)
        XCTAssertEqual(value.windows[1].unit, .currency(code: "USD"))
        XCTAssertEqual(value.balances[0].amount, 5)
        XCTAssertEqual(value.balances[0].unit, .currency(code: "USD"))
        for text in [#"{"config":{"currentPeriod":{"end":"2026-10-01T00:00:00Z"}}}"#, #"{"config":{"onDemandUsed":{},"prepaidBalance":{}}}"#] {
            XCTAssertThrowsError(try GrokDirectProvider.decode(Data(text.utf8), now: fixedNow)) { error in
                guard case UsageError.unavailable = error else { return XCTFail("Missing metrics must not connect") }
            }
        }
        let moneyOnly = try GrokDirectProvider.decode(Data(#"{"config":{"onDemandUsed":{"val":0}}}"#.utf8), now: fixedNow)
        XCTAssertEqual(moneyOnly.windows.map(\.id), ["onDemand"])
        XCTAssertEqual(moneyOnly.windows[0].used, 0)
        XCTAssertNil(moneyOnly.windows[0].usedPercent)
    }

    func testWindsurfNestedSeatQuotaPreservesMissingAndZero() throws {
        var plan = Data([112, 70, 120, 0])
        plan.append(WindsurfProto.varint(17 << 3)); plan.append(WindsurfProto.varint(1790812800))
        let payload = WindsurfProto.bytes(1, WindsurfProto.bytes(13, plan))
        let value = try WindsurfDirectProvider.decode(payload, now: fixedNow)
        XCTAssertEqual(value.windows.map(\.remainingPercent), [70, 0])
        XCTAssertEqual(value.windows[0].resetsAt, Date(timeIntervalSince1970: 1790812800))
        XCTAssertNil(value.windows[1].resetsAt)
        let dailyOnly = try WindsurfDirectProvider.decode(WindsurfProto.bytes(1, WindsurfProto.bytes(13, Data([112, 70]))), now: fixedNow)
        XCTAssertEqual(dailyOnly.windows.map(\.id), ["daily"])
        for absent in [Data(), WindsurfProto.bytes(13, Data())] {
            XCTAssertThrowsError(try WindsurfDirectProvider.decode(WindsurfProto.bytes(1, absent), now: fixedNow)) { error in
                guard case UsageError.unavailable = error else { return XCTFail("Expected incompatible account/quota") }
            }
        }
        XCTAssertThrowsError(try WindsurfDirectProvider.decode(WindsurfProto.bytes(1, WindsurfProto.bytes(13, Data([112, 101]))), now: fixedNow))
        XCTAssertThrowsError(try WindsurfDirectProvider.decode(Data([10, 4, 106]), now: fixedNow))
    }

    func testWindsurfDoesNotRefreshExpiredSessionByPretendingPermanent() async throws {
        do {
            _ = try await WindsurfDirectAuth(now: { fixedNow }).refresh(DirectCredential(provider: .windsurf, accessToken: "session", expiresAt: fixedNow.addingTimeInterval(-1)))
            XCTFail("Expired session must require browser login")
        } catch UsageError.authentication {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
