import Foundation
import Network

public enum OAuthLoopback {
    public static func authorize(authorizationURL: URL, redirectURL: URL, state: String,
                                 openURL: @escaping @Sendable (URL) async throws -> Void,
                                 timeout: TimeInterval = 600) async throws -> URL {
        guard authorizationURL.scheme == "https", redirectURL.scheme == "http",
              ["127.0.0.1", "localhost"].contains(redirectURL.host ?? ""),
              let port = redirectURL.port, (1024...65535).contains(port),
              redirectURL.user == nil, redirectURL.password == nil, redirectURL.query == nil,
              !state.isEmpty, timeout > 0, timeout.isFinite else { throw UsageError.configuration("잘못된 OAuth 콜백 설정") }
        let session = try LoopbackSession(authorizationURL: authorizationURL, redirectURL: redirectURL, state: state, port: UInt16(port), openURL: openURL)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: URL.self) { group in
                group.addTask { try await session.wait() }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    await session.stop(UsageError.timeout)
                    throw UsageError.timeout
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw UsageError.cancelled }
                return result
            }
        } onCancel: { Task { await session.stop(UsageError.cancelled) } }
    }
}

private actor LoopbackSession {
    let authorizationURL: URL
    let redirectURL: URL
    let state: String
    let openURL: @Sendable (URL) async throws -> Void
    let listener: NWListener
    private var continuation: CheckedContinuation<URL, any Error>?
    private var outcome: Result<URL, any Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var opened = false
    private let queue = DispatchQueue(label: "dev.bazzi.ai-limit.oauth-loopback")

    init(authorizationURL: URL, redirectURL: URL, state: String, port: UInt16, openURL: @escaping @Sendable (URL) async throws -> Void) throws {
        self.authorizationURL = authorizationURL; self.redirectURL = redirectURL; self.state = state; self.openURL = openURL
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        do { listener = try NWListener(using: parameters) }
        catch { throw UsageError.configuration("로컬 인증 포트를 열 수 없습니다. 다른 로그인 창을 닫고 다시 시도하세요.") }
    }
    func wait() async throws -> URL {
        if let outcome { return try outcome.get() }
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task {
                    if case .ready = state { await self?.ready() }
                    if case .failed = state { await self?.stop(UsageError.configuration("인증 콜백 포트를 사용할 수 없습니다. 다른 로그인 창을 닫고 다시 시도하세요.")) }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
            listener.start(queue: queue)
        }
    }
    private func ready() async {
        guard outcome == nil, !opened else { return }; opened = true
        do { try await openURL(authorizationURL) } catch { stop(error) }
    }
    private func accept(_ connection: NWConnection) {
        guard outcome == nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        receive(id, accumulated: Data())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            await self?.close(id)
        }
    }
    private func receive(_ id: UUID, accumulated: Data) {
        guard let connection = connections[id], outcome == nil else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384 - accumulated.count) { [weak self] bytes, _, complete, error in
            Task { await self?.received(id, accumulated: accumulated, bytes: bytes, complete: complete, failed: error != nil) }
        }
    }
    private func received(_ id: UUID, accumulated: Data, bytes: Data?, complete: Bool, failed: Bool) {
        guard outcome == nil, connections[id] != nil else { return }
        var data = accumulated; if let bytes { data.append(bytes) }
        guard data.count <= 16_384, !failed else { close(id); return }
        guard let request = String(data: data, encoding: .utf8), request.contains("\r\n\r\n") else {
            if complete || data.count == 16_384 { close(id) } else { receive(id, accumulated: data) }; return
        }
        let lines = request.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        let hostHeaders = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        guard first.count == 3, first[0] == "GET", first[1].hasPrefix("/"), !first[1].hasPrefix("//"),
              hostHeaders == ["\(redirectURL.host!):\(redirectURL.port!)"],
              let url = URL(string: String(first[1]), relativeTo: redirectURL)?.absoluteURL,
              url.host == redirectURL.host, url.port == redirectURL.port, url.path == redirectURL.path,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { respond(id, accepted: false); return }
        let items = components.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == state else { respond(id, accepted: false); return }
        if items.contains(where: { $0.name == "error" }) {
            respond(id, accepted: true, result: .failure(UsageError.authentication)); return
        }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty, code.count < 8192 else { respond(id, accepted: false); return }
        respond(id, accepted: true, result: .success(url))
    }
    private func respond(_ id: UUID, accepted: Bool, result: Result<URL, any Error>? = nil) {
        guard let connection = connections[id] else { return }
        let body = accepted ? "Return to AI Limit to finish connecting." : "Invalid callback. Return to the sign-in page."
        let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { await self?.responded(id, result: result) }
        })
    }
    private func responded(_ id: UUID, result: Result<URL, any Error>?) {
        close(id)
        if let result { finish(result) }
    }
    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
    func stop(_ error: any Error) { finish(.failure(error)) }
    private func finish(_ result: Result<URL, any Error>) {
        guard outcome == nil else { return }
        outcome = result
        listener.cancel(); listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil
        for connection in connections.values { connection.cancel() }; connections.removeAll()
        continuation?.resume(with: result); continuation = nil
    }
}
