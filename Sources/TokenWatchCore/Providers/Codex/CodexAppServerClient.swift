import Foundation

/// Fallback usage source when `auth.json` is missing/expired: speaks JSON-RPC 2.0 over stdin/
/// stdout to a `codex app-server` subprocess (`initialize`, then `account/rateLimits/read`).
/// This path could not be verified against a live `codex app-server` handshake during
/// implementation (no Codex CLI install available) -- per the plan's bounded-risk decision, any
/// spawn failure, timeout, or response shape mismatch fails closed to `.network(...)` rather
/// than risking a best-guess parse.
struct CodexAppServerClient {
    struct RateLimitsResult: Decodable {
        let primary: CodexUsageResponse.Window?
        let secondary: CodexUsageResponse.Window?
    }

    private let executableCandidates = ["codex"]
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    /// Runs the subprocess and returns parsed rate limits, or throws `ProviderError` on any
    /// failure (executable not found, timeout, malformed JSON-RPC response).
    func fetchRateLimits() async throws -> RateLimitsResult {
        guard let executablePath = resolveExecutable() else {
            throw ProviderError.credentialsMissing
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server"]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw ProviderError.network("could not launch codex app-server: \(error.localizedDescription)")
        }
        defer { if process.isRunning { process.terminate() } }

        let initRequest = jsonRPCLine(id: 1, method: "initialize", params: ["clientInfo": ["name": "TokenWatch", "version": "1.0"]])
        let rateLimitsRequest = jsonRPCLine(id: 2, method: "account/rateLimits/read", params: [:])

        guard let initData = initRequest.data(using: .utf8), let rateLimitsData = rateLimitsRequest.data(using: .utf8) else {
            throw ProviderError.parse("could not encode JSON-RPC request")
        }
        stdin.fileHandleForWriting.write(initData)
        stdin.fileHandleForWriting.write(rateLimitsData)

        let outputTask = Task { () -> Data in
            stdout.fileHandleForReading.readDataToEndOfFile()
        }

        let timeoutTask = Task { () -> Data in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return Data()
        }

        let winner = await firstFinished(outputTask, timeoutTask)
        timeoutTask.cancel()
        outputTask.cancel()
        try? stdin.fileHandleForWriting.close()

        guard let output = winner, !output.isEmpty else {
            throw ProviderError.network("codex app-server timed out or produced no output")
        }

        guard let result = Self.parseRateLimitsResult(from: output) else {
            throw ProviderError.parse("unexpected codex app-server response shape")
        }
        return result
    }

    private func resolveExecutable() -> String? {
        let fileManager = FileManager.default
        let pathVar = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathVar.split(separator: ":") {
            for candidate in executableCandidates {
                let full = String(directory) + "/" + candidate
                if fileManager.isExecutableFile(atPath: full) {
                    return full
                }
            }
        }
        return nil
    }

    private func jsonRPCLine(id: Int, method: String, params: [String: Any]) -> String {
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return "" }
        return (String(data: data, encoding: .utf8) ?? "") + "\n"
    }

    private func firstFinished(_ a: Task<Data, Never>, _ b: Task<Data, Never>) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask { await a.value }
            group.addTask { await b.value }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Scans stdout for a JSON-RPC response line whose `result` decodes as rate limits.
    private static func parseRateLimitsResult(from data: Data) -> RateLimitsResult? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let envelope = try? JSONDecoder().decode(JSONRPCResultEnvelope.self, from: lineData) else { continue }
            if let result = envelope.result {
                return result
            }
        }
        return nil
    }

    private struct JSONRPCResultEnvelope: Decodable {
        let result: RateLimitsResult?
    }
}
