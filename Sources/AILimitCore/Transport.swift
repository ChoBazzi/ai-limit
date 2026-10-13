import Foundation
import AILimitShared

public enum UsageError: Error, Sendable, LocalizedError {
    case authentication, unavailable(String), malformed, rateLimited(Date), transport, timeout, cancelled, configuration(String)
    public var errorDescription: String? { switch self { case .authentication: "로그인이 만료되었거나 권한이 없습니다. 다시 연결하세요."; case .unavailable(let text), .configuration(let text): text; case .malformed: "응답 형식이 변경되었거나 올바르지 않습니다."; case .rateLimited: "요청 제한으로 다음 갱신까지 기다립니다."; case .transport: "연결에 실패했습니다. 네트워크와 설정을 확인하세요."; case .timeout: "조회 시간이 초과되었습니다."; case .cancelled: "조회가 취소되었습니다." } }
}
public struct HTTPRequest: Sendable {
    public let url: URL; public var method: String = "GET"; public var headers: [String: String] = [:]; public var body: Data?; public var timeout: TimeInterval = 20
    public init(_ url: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 20) { self.url = URL(string: url)!; self.method = method; self.headers = headers; self.body = body; self.timeout = timeout }
}
public struct HTTPResponse: Sendable {
    public let status: Int; public let headers: [String: String]; public let body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data) { self.status = status; self.headers = headers; self.body = body }
    public func checked(now: Date) throws -> Data {
        let html = String(decoding: body.prefix(4096), as: UTF8.self).lowercased()
        if html.contains("<html") && (html.contains("cloudflare") || html.contains("challenge")) { throw UsageError.unavailable("서비스 접속 제한(Cloudflare). 웹에서 접속 상태를 확인하세요.") }
        if status == 401 || status == 403 { throw UsageError.authentication }
        if status == 429 {
            let value = headers.first { $0.key.lowercased() == "retry-after" }?.value ?? ""
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            let seconds = Double(value).flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
            throw UsageError.rateLimited(seconds.map { now.addingTimeInterval($0) } ?? formatter.date(from: value).flatMap { $0 > now ? $0 : nil } ?? now.addingTimeInterval(300))
        }
        guard (200..<300).contains(status) else { throw UsageError.transport }
        return body
    }
}
public protocol HTTPTransport: Sendable { func send(_ request: HTTPRequest) async throws -> HTTPResponse }
final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    static func permits(from original: URL?, to destination: URL?) -> Bool {
        guard let original, let destination else { return false }
        return original.scheme == "https" && destination.scheme == "https" && destination.host == original.host && (destination.port ?? 443) == (original.port ?? 443)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        completionHandler(Self.permits(from: original, to: request.url) ? request : nil)
    }
}
public struct SecureHTTPTransport: HTTPTransport {
    public init() {}
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let origins: Set<String> = [
            "claude.ai", "api.anthropic.com", "platform.claude.com", "console.anthropic.com",
            "auth.openai.com", "chatgpt.com", "cursor.com", "api2.cursor.sh",
            "windsurf.com", "api.devin.ai", "server.codeium.com", "www.perplexity.ai",
            "auth.x.ai", "cli-chat-proxy.grok.com", "github.com", "api.github.com",
            "oauth2.googleapis.com", "www.googleapis.com", "cloudcode-pa.googleapis.com",
            "oidc.us-east-1.amazonaws.com", "management.us-east-1.kiro.dev"
        ]
        guard request.url.scheme == "https", let host = request.url.host, origins.contains(host), request.url.port == nil || request.url.port == 443 else { throw UsageError.configuration("허용되지 않은 서비스 주소") }
        if host == "github.com" {
            guard request.method == "POST", ["/login/device/code", "/login/oauth/access_token"].contains(request.url.path), request.url.query == nil else { throw UsageError.configuration("허용되지 않은 OAuth 주소") }
        }
        let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.timeoutIntervalForRequest = request.timeout; config.timeoutIntervalForResource = request.timeout
        let session = URLSession(configuration: config, delegate: RedirectPolicy(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        var wire = URLRequest(url: request.url); wire.httpMethod = request.method; wire.httpBody = request.body; wire.allHTTPHeaderFields = request.headers
        do {
            let (bytes, response) = try await session.bytes(for: wire)
            guard let response = response as? HTTPURLResponse else { throw UsageError.transport }
            var data = Data(); for try await byte in bytes { guard data.count < 2 * 1024 * 1024 else { throw UsageError.malformed }; data.append(byte) }
            return HTTPResponse(status: response.statusCode, headers: response.allHeaderFields.reduce(into: [:]) { $0[String(describing: $1.key)] = String(describing: $1.value) }, body: data)
        } catch let error as UsageError { throw error } catch is CancellationError { throw UsageError.cancelled } catch { throw UsageError.transport }
    }
}
public struct ProcessRequest: Sendable {
    public let executable: URL; public let arguments: [String]; public var timeout: TimeInterval; public var codexRPC: Bool; public var codexHome: URL?
    public init(executable: URL, arguments: [String], timeout: TimeInterval = 30, codexRPC: Bool = false, codexHome: URL? = nil) { self.executable = executable; self.arguments = arguments; self.timeout = timeout; self.codexRPC = codexRPC; self.codexHome = codexHome }
}
public struct ProcessOutput: Sendable { public let stdout: Data; public let status: Int32; public init(stdout: Data, status: Int32) { self.stdout = stdout; self.status = status } }
public protocol ProcessRunning: Sendable { func run(_ request: ProcessRequest) async throws -> ProcessOutput }
public protocol UsageProvider: Sendable { var id: ProviderID { get }; func fetch(context: FetchContext) async throws -> UsageSnapshot }
public struct FetchContext: Sendable {
    public var connection: Connection; public var secrets: any SecretStore; public var http: any HTTPTransport; public var process: any ProcessRunning; public var now: @Sendable () -> Date
    public init(connection: Connection, secrets: any SecretStore, http: any HTTPTransport = SecureHTTPTransport(), process: any ProcessRunning = SafeProcessRunner(), now: @escaping @Sendable () -> Date = { Date() }) { self.connection = connection; self.secrets = secrets; self.http = http; self.process = process; self.now = now }
    public func secret() throws -> String { guard let value = try secrets.load(connection.id), !value.isEmpty else { throw UsageError.authentication }; return value }
    public func execute(_ arguments: [String], timeout: TimeInterval = 30, rpc: Bool = false) async throws -> ProcessOutput { guard connection.enabled, connection.consentedAt != nil, let url = connection.executable else { throw UsageError.configuration("실행 파일 선택과 읽기 동의가 필요합니다.") }; return try await process.run(ProcessRequest(executable: url, arguments: arguments, timeout: timeout, codexRPC: rpc, codexHome: connection.codexHome)) }
    public func get(_ request: HTTPRequest) async throws -> Data { try await http.send(request).checked(now: now()) }
}
