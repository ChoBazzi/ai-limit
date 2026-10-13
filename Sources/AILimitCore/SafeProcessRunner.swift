import Foundation
import Darwin

enum SelectedCLIEnvironment {
    static func configure(_ process: Process, executable: URL, arguments: [String], codexHome: URL?) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw UsageError.configuration("선택한 실행 파일을 찾을 수 없습니다. 다시 선택하세요.") }
        let runtime = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AI Limit/runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = runtime
        let env = ProcessInfo.processInfo.environment
        process.environment = ["HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(), "LANG": env["LANG"] ?? "en_US.UTF-8", "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        if let codexHome { process.environment?["CODEX_HOME"] = codexHome.path }
    }
}

private final class ChildState: @unchecked Sendable {
    let lock = NSLock(); let process = Process(); let input = Pipe(); let output = Pipe(); let errors = Pipe()
    var cancelled = false; var failure: UsageError?; var stdout = Data(); var finishedRPC = false
    func stop(_ error: UsageError? = nil) {
        lock.lock(); if let error, failure == nil { failure = error }; cancelled = true; let running = process.isRunning; let pid = process.processIdentifier; lock.unlock()
        try? input.fileHandleForWriting.close()
        if running { process.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in if process.isRunning { kill(pid, SIGKILL) } } }
    }
}
public struct SafeProcessRunner: ProcessRunning {
    public init() {}
    public func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        let state = ChildState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    do {
                        let process = state.process
                        try SelectedCLIEnvironment.configure(process, executable: request.executable, arguments: request.arguments, codexHome: request.codexHome)
                        process.standardInput = state.input; process.standardOutput = state.output; process.standardError = state.errors
                        state.lock.lock(); let cancelled = state.cancelled
                        if !cancelled { do { try process.run() } catch { state.lock.unlock(); throw UsageError.configuration("선택한 CLI를 실행할 수 없습니다.") } }
                        state.lock.unlock(); if cancelled { throw UsageError.cancelled }
                        let timer = DispatchWorkItem { state.stop(.timeout) }; DispatchQueue.global().asyncAfter(deadline: .now() + request.timeout, execute: timer)
                        let drains = DispatchGroup()
                        drains.enter(); DispatchQueue.global().async {
                            defer { drains.leave() }; var count = 0
                            while true { let data = state.errors.fileHandleForReading.availableData; if data.isEmpty { break }; count += data.count; if count > 1_048_576 { state.stop(.malformed) } }
                        }
                        drains.enter(); DispatchQueue.global().async {
                            defer { drains.leave() }; var pending = Data(); var expected = 0
                            while true {
                                let data = state.output.fileHandleForReading.availableData; if data.isEmpty { break }
                                guard data.count <= 1_048_576 - state.stdout.count else { state.stop(.malformed); continue }
                                state.stdout.append(data)
                                if request.codexRPC {
                                    pending.append(data)
                                    while let newline = pending.firstIndex(of: 10) {
                                        let line = pending.prefix(upTo: newline); pending.removeSubrange(...newline)
                                        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int else { continue }
                                        guard id == expected, object["error"] == nil, object["result"] != nil else { state.stop(.malformed); continue }
                                        expected += 1
                                        let next: String
                                        switch id {
                                        case 0: next = "{\"method\":\"initialized\",\"params\":{}}\n{\"id\":1,\"method\":\"account/read\",\"params\":{}}\n"
                                        case 1: next = "{\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":{}}\n"
                                        case 2: state.finishedRPC = true; state.stop(); next = ""
                                        default: state.stop(.malformed); next = ""
                                        }
                                        if !next.isEmpty { try? state.input.fileHandleForWriting.write(contentsOf: Data(next.utf8)) }
                                    }
                                }
                            }
                        }
                        if request.codexRPC { try state.input.fileHandleForWriting.write(contentsOf: Data("{\"id\":0,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"ai_limit\",\"title\":\"AI Limit\",\"version\":\"0.1.0\"}}}\n".utf8)) } else { try state.input.fileHandleForWriting.close() }
                        process.waitUntilExit(); drains.wait(); timer.cancel()
                        if let failure = state.failure { throw failure }
                        if request.codexRPC && !state.finishedRPC { throw UsageError.malformed }
                        continuation.resume(returning: ProcessOutput(stdout: state.stdout, status: request.codexRPC ? 0 : process.terminationStatus))
                    } catch { state.stop(); if state.process.isRunning { state.process.waitUntilExit() }; continuation.resume(throwing: error) }
                }
            }
        } onCancel: { state.stop(.cancelled) }
    }
}
