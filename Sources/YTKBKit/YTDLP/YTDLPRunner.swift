import Foundation

struct YTDLPResult {
    let exitCode: Int32
    let stdout: Data
    let stderr: String
}

actor YTDLPRunner {
    static let shared = YTDLPRunner()

    private var ytdlpURL: URL?
    private var chmoddedOnce = false
    /// Currently-running subprocesses, kept so `terminateAll()` can SIGTERM them
    /// when the user clicks Stop.
    private var runningProcesses: [Process] = []

    private init() {}

    /// Send SIGTERM to every currently-running yt-dlp process. Used by
    /// PollingCoordinator.cancel() so blocking subprocess calls return fast
    /// instead of hanging until natural completion.
    package func terminateAll() {
        for p in runningProcesses where p.isRunning {
            p.terminate()
        }
        runningProcesses.removeAll()
    }

    private func register(_ p: Process) { runningProcesses.append(p) }
    private func unregister(_ p: Process) { runningProcesses.removeAll { $0 === p } }

    func resolveBinary() throws -> URL {
        if let url = ytdlpURL { return url }
        guard let bundled = Bundle.main.url(forResource: "yt-dlp", withExtension: nil) else {
            throw YTDLPError.binaryNotFound
        }
        if !chmoddedOnce {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
            chmoddedOnce = true
        }
        ytdlpURL = bundled
        return bundled
    }

    /// Substrings in stderr that signal a transient network failure worth retrying.
    /// Bot-check ("Sign in to confirm…") and format-error patterns are NOT in this set —
    /// they're handled by the cascade in MetadataFetcher / SubsDownloader instead.
    private static let networkErrorMarkers: [String] = [
        "unable to download",
        "connection reset",
        "connection refused",
        "timed out",
        "network is unreachable",
        "could not resolve host",
        "name or service not known",
        "the read operation timed out",
        "tls handshake",
        "ssl: ",
        "operation timed out",
        "remote end closed connection without response"
    ]

    private static func isTransientNetworkError(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        // Bot-check is NOT transient — never retry it
        if lower.contains("sign in to confirm") || lower.contains("not a bot") { return false }
        // Format-error is handled by cascade — don't retry at this level
        if lower.contains("requested format is not available") { return false }
        return Self.networkErrorMarkers.contains(where: { lower.contains($0) })
    }

    /// Run yt-dlp with the given args; returns stdout/stderr and exit code.
    /// Never throws on non-zero exit — caller decides how to interpret stderr.
    /// Transient network failures (DNS, connection reset, timeout) are retried
    /// up to 3 times with exponential backoff (1s, 2s, 4s).
    func run(_ args: [String], timeout: TimeInterval = 300) async throws -> YTDLPResult {
        var attempt = 0
        let maxAttempts = 3
        let preview = Self.argsPreview(args)
        while true {
            attempt += 1
            let t0 = Date()
            Logger.shared.info("yt-dlp ▶ attempt=\(attempt)/\(maxAttempts) args=\(preview)")
            let result = try await runOnce(args: args)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if result.exitCode == 0 {
                Logger.shared.info("yt-dlp ◀ ok in \(ms)ms (stdout=\(result.stdout.count)B)")
                return result
            }
            Logger.shared.warn("yt-dlp ◀ exit=\(result.exitCode) in \(ms)ms · stderr=\(result.stderr.lastNonEmptyLine.prefix(160))")
            if attempt < maxAttempts, Self.isTransientNetworkError(result.stderr) {
                let delaySeconds = UInt64(pow(2.0, Double(attempt - 1)))  // 1, 2, 4
                Logger.shared.warn("yt-dlp transient retry (attempt \(attempt)/\(maxAttempts)) backoff=\(delaySeconds)s")
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                continue
            }
            return result
        }
    }

    /// Single-line preview of args for logs. Truncates the URL so the line
    /// stays readable, keeps every flag.
    private static func argsPreview(_ args: [String]) -> String {
        let joined = args.joined(separator: " ")
        if joined.count <= 200 { return joined }
        return String(joined.prefix(200)) + "…"
    }

    private func runOnce(args: [String]) async throws -> YTDLPResult {
        let binary = try resolveBinary()
        let process = Process()
        process.executableURL = binary
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" }
        process.environment = env

        // Register on the actor BEFORE spawning the detached drain task so
        // terminateAll() called from another actor method has access to the
        // process reference.
        register(process)
        defer { unregister(process) }

        return try await Task.detached(priority: .userInitiated) { () -> YTDLPResult in
            do {
                try process.run()
            } catch {
                throw YTDLPError.spawnFailed(error)
            }
            // Drain pipes concurrently to avoid blocking on full buffers.
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            return YTDLPResult(
                exitCode: process.terminationStatus,
                stdout: outData,
                stderr: stderr
            )
        }.value
    }

    /// Build base args: `yt-dlp` global flags (cookies, sleep) prepended, then user args.
    @MainActor
    static func baseArgs(settings: Settings) -> [String] {
        var args: [String] = []
        if let key = settings.browser.ytDlpKey {
            args.append(contentsOf: ["--cookies-from-browser", key])
        }
        if settings.sleepRequests > 0 {
            args.append(contentsOf: ["--sleep-requests", String(settings.sleepRequests)])
        }
        return args
    }
}

enum YTDLPError: Error, CustomStringConvertible {
    case binaryNotFound
    case spawnFailed(Error)
    case nonZeroExit(Int32, String)
    case decodeFailed(String)

    var description: String {
        switch self {
        case .binaryNotFound:
            return "yt-dlp бинарник не найден в bundle"
        case .spawnFailed(let err):
            return "Не удалось запустить yt-dlp: \(err)"
        case .nonZeroExit(let code, let msg):
            return "yt-dlp exit \(code): \(msg)"
        case .decodeFailed(let msg):
            return "Не удалось распарсить ответ yt-dlp: \(msg)"
        }
    }
}

extension String {
    /// Last non-empty line — often the most informative part of yt-dlp stderr.
    var lastNonEmptyLine: String {
        for line in self.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return self.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
