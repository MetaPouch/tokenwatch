import Foundation

/// Runs a short-lived CLI subprocess with a wall-clock timeout and an output size cap, shared by
/// every provider that shells out to a locally installed CLI (Amp, Antigravity). Never throws on
/// process failure -- callers get a `nil` on any spawn error, timeout, or non-zero exit so a
/// missing/misbehaving CLI degrades to "not configured" instead of crashing the refresh.
enum BoundedSubprocess {
    struct Result {
        let stdout: Data
        let exitCode: Int32
    }

    /// Resolves `executable` (a bare name) against `PATH`, returning the first executable match.
    static func resolveOnPath(_ names: [String], extraDirectories: [String] = [], environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fileManager = FileManager.default
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories.append(contentsOf: extraDirectories)
        for directory in directories {
            for name in names {
                let full = directory + "/" + name
                if fileManager.isExecutableFile(atPath: full) {
                    return full
                }
            }
        }
        return nil
    }

    static func run(executablePath: String, arguments: [String], timeout: TimeInterval = 90, maxOutputBytes: Int = 1_048_576) async -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let readTask = Task { () -> Data in
            var collected = Data()
            let handle = stdout.fileHandleForReading
            while collected.count < maxOutputBytes {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                collected.append(chunk)
            }
            return collected
        }

        let timedOut = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                _ = await readTask.value
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return true
            }
            let first = await group.next() ?? true
            group.cancelAll()
            return first
        }

        if timedOut {
            if process.isRunning { process.terminate() }
            readTask.cancel()
            return nil
        }

        process.waitUntilExit()
        let data = await readTask.value
        return Result(stdout: data, exitCode: process.terminationStatus)
    }
}
