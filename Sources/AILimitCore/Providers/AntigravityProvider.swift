import Foundation
import AILimitShared
public struct AntigravityProvider: UsageProvider {
    public let id: ProviderID = .antigravity
    public init() {}
    public func fetch(context: FetchContext) async throws -> UsageSnapshot {
        let version = String(decoding: try requireCLI(await context.execute(["--version"])), as: UTF8.self)
        let regex = try NSRegularExpression(pattern: #"\b(\d+)\.(\d+)\.(\d+)\b"#)
        guard let match = regex.firstMatch(in: version, range: NSRange(version.startIndex..., in: version)) else { throw UsageError.configuration("agy 1.1.11 이상으로 업데이트하세요.") }
        let parts = (1...3).map { Int((version as NSString).substring(with: match.range(at: $0))) ?? 0 }
        guard !parts.lexicographicallyPrecedes([1, 1, 11]) else { throw UsageError.configuration("agy 1.1.11 이상으로 업데이트하세요.") }
        let json = try JSON(data: requireCLI(await context.execute(["-p", "/usage", "--output-format", "json"], timeout: 90)))
        guard json["status"].string == "SUCCESS", json["command"]["name"].string == "usage" else { throw UsageError.malformed }
        var windows: [QuotaWindow] = []
        for (groupIndex, group) in json["command"]["data"]["groups"].array.enumerated() {
            let groupName = group.alias("displayName", "display_name").string ?? group["name"].string ?? "그룹"
            for (index, bucket) in group["buckets"].array.enumerated() where bucket["disabled"].bool != true {
                var fraction = bucket.alias("remainingFraction", "remaining_fraction")
                if fraction.isNull { fraction = bucket["remaining"].alias("remainingFraction", "remaining_fraction") }
                if fraction.isNull, ["remainingFraction", "remaining_fraction"].contains(bucket["remaining"]["case"].string ?? "") { fraction = bucket["remaining"]["value"] }
                guard let value = try fraction.number(), value <= 1 else { continue }
                let name = bucket.alias("displayName", "display_name").string ?? bucket["name"].string ?? bucket["window"].string ?? "한도"
                windows.append(QuotaWindow(id: "\(groupIndex)." + (bucket.alias("bucketId", "bucket_id").string ?? bucket["id"].string ?? String(index)), title: groupName + " · " + name, usedPercent: (1 - value) * 100, resetsAt: bucket.alias("resetTime", "reset_time").date, resetPrecision: .exact, resetDescription: bucket["description"].string))
            }
        }
        guard !windows.isEmpty else { throw UsageError.unavailable("CLI가 알려진 사용 한도를 제공하지 않습니다.") }
        return snapshot(id, context, windows: windows)
    }
}
