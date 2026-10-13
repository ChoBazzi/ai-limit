import Foundation
import AILimitShared

// Exact Basic literal (NOT base64), metadata and field numbers from CLIProxyAPI
// acdace936fa7df2905500c7f5e0a97d683138dea/internal/auth/devin/user_status.go.
public struct WindsurfDirectProvider: Sendable {
    public init() {}
    public func fetch(context: FetchContext, credential: DirectCredential) async throws -> UsageSnapshot {
        guard credential.provider == .windsurf else { throw UsageError.authentication }
        let token = credential.accessToken
        let headers = ["Authorization": "Basic " + token + "-" + token, "Connect-Protocol-Version": "1", "Content-Type": "application/proto", "Accept": "*/*", "User-Agent": ""]
        let response = try await context.http.send(HTTPRequest("https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus", method: "POST", headers: headers, body: Self.request(token)))
        if response.status == 403 || response.status == 404 {
            throw UsageError.unavailable("Devin 로그인은 완료됐지만 이 계정에서 Windsurf/Codeium seat 한도에 접근할 수 없습니다. 계정·조직 호환성을 확인하세요.")
        }
        return try Self.decode(response.checked(now: context.now()), now: context.now())
    }

    static func request(_ token: String) -> Data {
        var metadata = Data()
        // chisel and its version identify the observed wire protocol, not an installed editor.
        let fields: [(UInt64, String)] = [(1, "chisel"), (2, "3000.10.21"), (3, token), (4, "en"), (5, "darwin"), (7, "3000.10.21"), (12, "chisel")]
        for (field, value) in fields {
            metadata.append(WindsurfProto.bytes(field, Data(value.utf8)))
        }
        // Deliberately omit field 31: no fabricated hardware/device fingerprint.
        return WindsurfProto.bytes(1, metadata)
    }

    static func decode(_ data: Data, now: Date) throws -> UsageSnapshot {
        let root = try WindsurfProto.decode(data)
        guard let userData = try WindsurfProto.payload(root, 1) else { throw UsageError.malformed }
        let user = try WindsurfProto.decode(userData)
        guard let planData = try WindsurfProto.payload(user, 13) else {
            throw UsageError.unavailable("이 Devin 계정에서 Windsurf/Codeium seat 구독이 제공되지 않습니다.")
        }
        let status = try WindsurfProto.decode(planData)
        var plan: String?
        if let info = try WindsurfProto.payload(status, 1), let name = try WindsurfProto.payload(WindsurfProto.decode(info), 2) {
            guard let decoded = String(data: name, encoding: .utf8) else { throw UsageError.malformed }
            plan = decoded
        }
        let start = try WindsurfProto.timestamp(WindsurfProto.payload(status, 2))
        let end = try WindsurfProto.timestamp(WindsurfProto.payload(status, 3))
        var windows: [QuotaWindow] = []
        for (field, resetField, id, title) in [(14, 17, "daily", "일간 seat 한도"), (15, 18, "weekly", "주간 seat 한도")] {
            guard let remaining = try WindsurfProto.integer(status, field) else { continue }
            guard remaining <= 100 else { throw UsageError.malformed }
            var reset: Date?
            if let seconds = try WindsurfProto.integer(status, resetField) {
                guard seconds <= UInt64(Int64.max) else { throw UsageError.malformed }
                reset = Date(timeIntervalSince1970: Double(seconds))
            }
            let period = [start.map { "구독 시작 " + $0.formatted(date: .numeric, time: .omitted) }, end.map { "구독 종료 " + $0.formatted(date: .numeric, time: .omitted) }].compactMap { $0 }.joined(separator: " · ")
            windows.append(QuotaWindow(id: id, title: title, usedPercent: 100 - Double(remaining), resetsAt: reset, resetDescription: period.isEmpty ? nil : period))
        }
        guard !windows.isEmpty else { throw UsageError.unavailable("로그인했지만 Windsurf/Codeium seat 사용량이 제공되지 않습니다. Devin cloud 작업 수나 API 잔액은 조회하지 않습니다.") }
        return UsageSnapshot(provider: .windsurf, plan: plan, windows: windows, balances: [], source: .unofficialWeb, fetchedAt: now)
    }
}
