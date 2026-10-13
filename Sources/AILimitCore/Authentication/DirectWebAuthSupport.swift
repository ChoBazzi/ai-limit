import Foundation

// Unverified JWT claims are only expiry hints, never identity/authorization evidence.
enum DirectWebAuthSupport {
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let json = try? JSON(data: data),
              let seconds = try? json["exp"].number(), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func token(_ json: JSON, _ key: String) throws -> String {
        guard let value = json[key].string, !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw UsageError.malformed }
        return value
    }

    static func url(_ base: String, parameters: [String: String]) throws -> URL {
        guard var components = URLComponents(string: base) else { throw UsageError.malformed }
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw UsageError.malformed }
        return url
    }

    static func formRequest(_ url: String, parameters: [String: String]) -> HTTPRequest {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = parameters.sorted { $0.key < $1.key }.map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        return HTTPRequest(url, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json", "x-grok-client-surface": "ui"], body: Data(body.utf8))
    }
}
