import Foundation

actor MetadataFetcher {
    private let runner: YTDLPRunner
    private let config: YTDLPConfig

    package init(runner: YTDLPRunner, config: YTDLPConfig) {
        self.runner = runner
        self.config = config
    }

    func fetch(url: String) async throws -> VideoMetadata {
        // === Layer 1 ===
        do {
            let data = try await runOnce(url: url, withCookies: true, aggressive: false)
            if config.hasCookies, !data.hasAnySubs {
                if let anon = try? await runOnce(url: url, withCookies: false, aggressive: false),
                   anon.hasAnySubs {
                    return anon
                }
            }
            return data
        } catch let error as YTDLPError {
            if case .nonZeroExit(_, let msg) = error, msg.lowercased().contains("format is not available") {
                if config.hasCookies {
                    if let layer2 = try? await runOnce(url: url, withCookies: false, aggressive: false) {
                        return layer2
                    }
                }
                return try await runOnce(url: url, withCookies: true, aggressive: true)
            }
            throw error
        }
    }

    private func runOnce(url: String, withCookies: Bool, aggressive: Bool) async throws -> VideoMetadata {
        var args = withCookies ? config.baseArgs : config.argsWithoutCookies
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
}
