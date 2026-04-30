import Foundation

struct DownloadedSubFile {
    let url: URL
    let ext: String
}

/// Layered subtitle downloader mirroring `_download_subs` in yt-kb.py.
///
/// Layer 1: simple call with current cookies.
/// Layer 2: same call without cookies (only on format-error).
/// Layer 3: aggressive (`--extractor-args` + permissive `-f`).
actor SubsDownloader {
    private let runner: YTDLPRunner
    private let baseArgs: [String]
    private let hasCookies: Bool

    init(runner: YTDLPRunner, settings: Settings) {
        self.runner = runner
        var args: [String] = []
        var ck = false
        if let key = settings.browser.ytDlpKey {
            args.append(contentsOf: ["--cookies-from-browser", key])
            ck = true
        }
        if settings.sleepRequests > 0 {
            args.append(contentsOf: ["--sleep-requests", String(settings.sleepRequests)])
        }
        self.baseArgs = args
        self.hasCookies = ck
    }

    func download(
        url: String,
        langKey: String,
        isAuto: Bool,
        into tmpDir: URL
    ) async throws -> DownloadedSubFile {
        // === Layer 1 ===
        do {
            return try await attempt(url: url, langKey: langKey, isAuto: isAuto, tmpDir: tmpDir, withCookies: true, aggressive: false)
        } catch let error as YTDLPError {
            let msg: String
            if case .nonZeroExit(_, let m) = error { msg = m }
            else if case .decodeFailed(let m) = error { msg = m }
            else { throw error }

            // Only format-not-available is recoverable. Other errors propagate.
            guard msg.lowercased().contains("format is not available") else {
                throw error
            }

            // === Layer 2: drop cookies ===
            if hasCookies {
                do {
                    return try await attempt(url: url, langKey: langKey, isAuto: isAuto, tmpDir: tmpDir, withCookies: false, aggressive: false)
                } catch let layer2Err as YTDLPError {
                    if case .nonZeroExit(_, let m2) = layer2Err, !m2.lowercased().contains("format is not available") {
                        throw layer2Err
                    }
                }
            }

            // === Layer 3: aggressive ===
            return try await attempt(url: url, langKey: langKey, isAuto: isAuto, tmpDir: tmpDir, withCookies: true, aggressive: true)
        }
    }

    private func attempt(
        url: String,
        langKey: String,
        isAuto: Bool,
        tmpDir: URL,
        withCookies: Bool,
        aggressive: Bool
    ) async throws -> DownloadedSubFile {
        var args = withCookies ? baseArgs : argsWithoutCookies()
        args.append(contentsOf: [
            "--skip-download",
            isAuto ? "--write-auto-subs" : "--write-subs",
            "--sub-langs", langKey,
            "--sub-format", "vtt/srv3/json3/best",
            "--ignore-no-formats-error",
            "-o", tmpDir.appendingPathComponent("%(id)s.%(ext)s").path
        ])
        if aggressive {
            args.append(contentsOf: [
                "--extractor-args", "youtube:player_client=web_safari,web,android",
                "-f", "bv*+ba/b/best/bestvideo/bestaudio/worst"
            ])
        }
        args.append(url)

        let result = try await runner.run(args, timeout: 240)
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

    private func argsWithoutCookies() -> [String] {
        var out: [String] = []
        var i = 0
        while i < baseArgs.count {
            let opt = baseArgs[i]
            if opt == "--cookies-from-browser" || opt == "--cookies" {
                i += 2
                continue
            }
            out.append(opt)
            i += 1
        }
        return out
    }
}
