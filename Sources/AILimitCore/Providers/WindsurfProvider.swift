import Foundation
import AILimitShared
public struct WindsurfProvider: UsageProvider {
    public let id: ProviderID = .windsurf
    public init() {}
    public func fetch(context: FetchContext) async throws -> UsageSnapshot {
        let auth = try JSON(data: Data(Credentials.validate(context.secret(), for: id).utf8)); let token = auth["devin_session_token"].string!
        var headers = ["Content-Type": "application/proto", "Connect-Protocol-Version": "1", "Origin": "https://windsurf.com", "Referer": "https://windsurf.com/profile", "x-auth-token": token]
        for key in ["devin_session_token", "devin_auth1_token", "devin_account_id", "devin_primary_org_id"] { headers["x-" + key.replacingOccurrences(of: "_", with: "-")] = auth[key].string! }
        var body = WindsurfProto.bytes(1, Data(token.utf8)); body.append(contentsOf: [16, 1])
        let wire = try await context.get(HTTPRequest("https://windsurf.com/_backend/exa.seat_management_pb.SeatManagementService/GetPlanStatus", method: "POST", headers: headers, body: body))
        let response = try WindsurfProto.decode(wire)
        guard let data = try WindsurfProto.payload(response, 1) else { throw UsageError.unavailable("현재 플랜 한도 미제공") }
        let status = try WindsurfProto.decode(data); var name: String?
        if let info = try WindsurfProto.payload(status, 1), let text = try WindsurfProto.payload(WindsurfProto.decode(info), 2) { name = String(data: text, encoding: .utf8) }
        let start = try WindsurfProto.timestamp(WindsurfProto.payload(status, 2)); let end = try WindsurfProto.timestamp(WindsurfProto.payload(status, 3)); var windows: [QuotaWindow] = []
        for (field, reset, title) in [(14, 17, "일간"), (15, 18, "주간")] {
            guard let percent = try WindsurfProto.integer(status, field) else { continue }; guard percent <= 100 else { throw UsageError.malformed }
            windows.append(QuotaWindow(id: String(field), title: title, usedPercent: 100 - Double(percent), resetsAt: try WindsurfProto.integer(status, reset).map { Date(timeIntervalSince1970: Double($0)) }, resetPrecision: .exact, resetDescription: [start.map { "시작 " + $0.formatted(date: .numeric, time: .omitted) }, end.map { "종료 " + $0.formatted(date: .numeric, time: .omitted) }].compactMap { $0 }.joined(separator: " · ")))
        }
        guard !windows.isEmpty else { throw UsageError.unavailable("현재 응답에 일간·주간 한도가 없습니다.") }
        return snapshot(id, context, plan: name, windows: windows)
    }
}
