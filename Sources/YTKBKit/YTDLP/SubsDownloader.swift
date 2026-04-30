import Foundation

package struct DownloadedSubFile {
    package let url: URL
    package let ext: String
    package init(url: URL, ext: String) {
        self.url = url
        self.ext = ext
    }
}

actor SubsDownloader {
    private let runner: YTDLPRunner
    private let config: YTDLPConfig

    package init(runner: YTDLPRunner, config: YTDLPConfig) {
        self.runner = runner
        self.config = config
    }

    package func download(
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

            guard msg.lowercased().contains("format is not available") else {
                throw error
            }

            // === Layer 2: drop cookies ===
            if config.hasCookies {
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
        var args = withCookies ? config.baseArgs : config.argsWithoutCookies
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
}
