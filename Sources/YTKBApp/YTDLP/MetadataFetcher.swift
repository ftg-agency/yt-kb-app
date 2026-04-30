import Foundation

actor MetadataFetcher {
    private let runner: YTDLPRunner
    private let baseArgs: [String]
    private let hasCookies: Bool

    init(runner: YTDLPRunner, settings: Settings) {
        self.runner = runner
        var args: [String] = []
        var hasCk = false
        if let key = settings.browser.ytDlpKey {
            args.append(contentsOf: ["--cookies-from-browser", key])
            hasCk = true
        }
        if settings.sleepRequests > 0 {
            args.append(contentsOf: ["--sleep-requests", String(settings.sleepRequests)])
        }
        self.baseArgs = args
        self.hasCookies = hasCk
    }

    /// Phase-1: Layer 1 only (simple call). Phase 2 will add Layer 2/3 cascade.
    func fetch(url: String) async throws -> VideoMetadata {
        var args = baseArgs
        args.append(contentsOf: [
            "--dump-single-json",
            "--no-warnings",
            "--skip-download",
            "--ignore-no-formats-error",
            url
        ])
        let result = try await runner.run(args, timeout: 180)
        guard result.exitCode == 0 else {
            throw YTDLPError.nonZeroExit(result.exitCode, result.stderr.lastNonEmptyLine)
        }
        do {
            return try JSONDecoder().decode(VideoMetadata.self, from: result.stdout)
        } catch {
            throw YTDLPError.decodeFailed("\(error)")
        }
    }
}
