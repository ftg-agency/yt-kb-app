import Foundation

struct ResolvedChannel {
    let name: String
    let channelId: String?
    let channelURL: String
    let videos: [VideoRef]
}

package actor ChannelResolver {
    private let runner: YTDLPRunner
    private let config: YTDLPConfig

    init(runner: YTDLPRunner, config: YTDLPConfig) {
        self.runner = runner
        self.config = config
    }

    private static let channelTabSuffixes = [
        "/videos", "/shorts", "/streams", "/live",
        "/playlists", "/community", "/featured", "/about"
    ]

    private static func isChannelBase(_ url: String) -> Bool {
        ["/@", "/channel/", "/c/", "/user/"].contains(where: { url.contains($0) })
    }

    private static func hasChannelTab(_ url: String) -> Bool {
        let stripped = url.hasSuffix("/") ? String(url.dropLast()) : url
        return channelTabSuffixes.contains(where: { stripped.hasSuffix($0) })
    }

    package static func normaliseChannelURL(_ url: String) -> String {
        if isChannelBase(url) && !hasChannelTab(url) {
            let trimmed = url.hasSuffix("/") ? String(url.dropLast()) : url
            return trimmed + "/videos"
        }
        return url
    }

    func resolveMetadata(channelURL: String) async throws -> ResolvedChannel {
        let entries = try await fetchEntries(channelURL: channelURL)
        let videos = await extractVideos(from: entries.entries ?? [])
        return ResolvedChannel(
            name: entries.displayName,
            channelId: entries.channelId ?? entries.uploaderId,
            channelURL: entries.channelUrl ?? channelURL,
            videos: videos
        )
    }

    func listVideos(channelURL: String) async throws -> [VideoRef] {
        let entries = try await fetchEntries(channelURL: channelURL)
        return await extractVideos(from: entries.entries ?? [])
    }

    /// Player-client cascade for channel listings. Some channels return only
    /// ~500 entries on `web`, but the same channel via `tv_simply` returns the
    /// full history. We try the most permissive client first; if it fails or
    /// returns suspiciously few entries we fall back. Keep order from
    /// most-permissive to most-compatible.
    private static let playerClientCascade: [String] = [
        "tv_simply,web,web_safari",
        "tv,web",
        "ios,web"
    ]

    private func fetchEntries(channelURL: String) async throws -> FlatPlaylistResponse {
        let normalised = Self.normaliseChannelURL(channelURL)

        var lastError: Error?
        var bestResponse: FlatPlaylistResponse?

        for (idx, clients) in Self.playerClientCascade.enumerated() {
            do {
                let response = try await fetchOnce(url: normalised, playerClients: clients)
                let count = response.entries?.count ?? 0
                Logger.shared.info("ChannelResolver: clients=\(clients) → \(count) entries from \(normalised)")
                if let best = bestResponse, (best.entries?.count ?? 0) >= count {
                    // Earlier cascade attempt returned more entries; keep it
                } else {
                    bestResponse = response
                }
                // If we got a non-suspicious count (>500 or no .web cascade left), stop
                if count > 500 || idx == Self.playerClientCascade.count - 1 {
                    break
                }
            } catch {
                Logger.shared.warn("ChannelResolver: clients=\(clients) failed: \(error)")
                lastError = error
                continue
            }
        }

        if let best = bestResponse {
            return best
        }
        throw lastError ?? YTDLPError.decodeFailed("ChannelResolver: all attempts failed")
    }

    private func fetchOnce(url: String, playerClients: String) async throws -> FlatPlaylistResponse {
        var args = config.baseArgs
        args.append(contentsOf: [
            "--flat-playlist",
            "--dump-single-json",
            "--no-warnings",
            "--extractor-args", "youtube:player_client=\(playerClients)",
            // Explicit slice — defensively ensures yt-dlp doesn't apply any
            // hidden default cap. `1:` means "all from index 1".
            "-I", "1:99999",
            url
        ])
        let result = try await runner.run(args, timeout: 360)
        guard result.exitCode == 0 else {
            throw YTDLPError.nonZeroExit(result.exitCode, result.stderr.lastNonEmptyLine)
        }
        do {
            return try JSONDecoder().decode(FlatPlaylistResponse.self, from: result.stdout)
        } catch {
            throw YTDLPError.decodeFailed("\(error)")
        }
    }

    private func extractVideos(from entries: [FlatPlaylistEntry]) async -> [VideoRef] {
        var refs: [VideoRef] = []
        for entry in entries {
            if entry._type == "playlist", let sub = entry.url ?? entry.webpageUrl {
                if let nested = try? await fetchEntries(channelURL: sub) {
                    let subRefs = await extractVideos(from: nested.entries ?? [])
                    refs.append(contentsOf: subRefs)
                }
                continue
            }
            guard let id = entry.id, id.count == 11 else { continue }
            refs.append(VideoRef(videoId: id, title: entry.title))
        }
        return refs
    }
}
