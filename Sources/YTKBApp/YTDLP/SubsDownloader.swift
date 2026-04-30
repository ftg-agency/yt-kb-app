import Foundation

struct DownloadedSubFile {
    let url: URL
    let ext: String
}

actor SubsDownloader {
    private let runner: YTDLPRunner
    private let baseArgs: [String]

    init(runner: YTDLPRunner, settings: Settings) {
        self.runner = runner
        var args: [String] = []
        if let key = settings.browser.ytDlpKey {
            args.append(contentsOf: ["--cookies-from-browser", key])
        }
        if settings.sleepRequests > 0 {
            args.append(contentsOf: ["--sleep-requests", String(settings.sleepRequests)])
        }
        self.baseArgs = args
    }

    /// Phase-1 Layer 1 only. Returns downloaded sub file or throws.
    func download(
        url: String,
        langKey: String,
        isAuto: Bool,
        into tmpDir: URL
    ) async throws -> DownloadedSubFile {
        var args = baseArgs
        args.append(contentsOf: [
            "--skip-download",
            isAuto ? "--write-auto-subs" : "--write-subs",
            "--sub-langs", langKey,
            "--sub-format", "vtt/srv3/json3/best",
            "--ignore-no-formats-error",
            "-o", tmpDir.appendingPathComponent("%(id)s.%(ext)s").path,
            url
        ])
        let result = try await runner.run(args, timeout: 180)
        if result.exitCode != 0 {
            throw YTDLPError.nonZeroExit(result.exitCode, result.stderr.lastNonEmptyLine)
        }
        for ext in ["vtt", "srv3", "json3"] {
            let candidates = (try? FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)) ?? []
            if let match = candidates.first(where: { $0.pathExtension == ext }) {
                return DownloadedSubFile(url: match, ext: ext)
            }
        }
        let hint = result.stderr.lastNonEmptyLine
        throw YTDLPError.decodeFailed("yt-dlp вернул 0 но файла нет: \(hint.prefix(120))")
    }
}
