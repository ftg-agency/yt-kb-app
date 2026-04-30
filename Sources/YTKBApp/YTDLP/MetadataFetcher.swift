import Foundation

/// Layered metadata fetcher mirroring `fetch_metadata` in yt-kb.py.
///
/// Layer 1: simple call (cookies + sleep).
/// Layer 2: same call without cookies (for "Requested format is not available"
///          recovery, OR when subs come back empty with cookies).
/// Layer 3: aggressive — `--extractor-args player_client=web_safari,web,android`
///          + `-f bv*+ba/b/best/bestvideo/bestaudio/worst`.
actor MetadataFetcher {
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

    func fetch(url: String) async throws -> VideoMetadata {
        // === Layer 1 ===
        do {
            let data = try await runOnce(url: url, withCookies: true, aggressive: false)
            // Cookies-hide-subs recovery: if cookies present but subs empty, try anonymously.
            if hasCookies, !data.hasAnySubs {
                if let anon = try? await runOnce(url: url, withCookies: false, aggressive: false),
                   anon.hasAnySubs {
                    return anon
                }
            }
            return data
        } catch let error as YTDLPError {
            // Format-error path → Layer 2
            if case .nonZeroExit(_, let msg) = error, msg.lowercased().contains("format is not available") {
                if hasCookies {
                    if let layer2 = try? await runOnce(url: url, withCookies: false, aggressive: false) {
                        return layer2
                    }
                }
                // Layer 3: aggressive
                return try await runOnce(url: url, withCookies: true, aggressive: true)
            }
            // Non-format error: propagate
            throw error
        }
    }

    private func runOnce(url: String, withCookies: Bool, aggressive: Bool) async throws -> VideoMetadata {
        var args = withCookies ? baseArgs : argsWithoutCookies()
        args.append(contentsOf: [
            "--dump-single-json",
            "--no-warnings",
            "--skip-download",
            "--ignore-no-formats-error"
        ])
        if aggressive {
            args.append(contentsOf: [
                "--extractor-args", "youtube:player_client=web_safari,web,android",
                "-f", "bv*+ba/b/best/bestvideo/bestaudio/worst"
            ])
        }
        args.append(url)
        let result = try await runner.run(args, timeout: 240)
        guard result.exitCode == 0 else {
            throw YTDLPError.nonZeroExit(result.exitCode, result.stderr.lastNonEmptyLine)
        }
        do {
            return try JSONDecoder().decode(VideoMetadata.self, from: result.stdout)
        } catch {
            throw YTDLPError.decodeFailed("\(error)")
        }
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
