import Foundation

struct ResolvedChannel {
    let name: String
    let channelId: String?
    let channelURL: String
    let videos: [VideoRef]
    /// YouTube's reported total — may be larger than `videos.count` if yt-dlp
    /// can't enumerate the full channel history. nil if not known.
    let reportedTotalCount: Int?
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
            videos: videos,
            reportedTotalCount: entries.playlistCount
        )
    }

    func listVideos(channelURL: String) async throws -> [VideoRef] {
        let entries = try await fetchEntries(channelURL: channelURL)
        return await extractVideos(from: entries.entries ?? [])
    }

    /// Same as `listVideos` but also returns YouTube's reported total count
    /// (or nil). Used by PollOperation to surface "we got X of Y" diagnostics.
    func listVideosWithCount(channelURL: String) async throws -> (videos: [VideoRef], reportedTotal: Int?) {
        let entries = try await fetchEntries(channelURL: channelURL)
        let videos = await extractVideos(from: entries.entries ?? [])
        return (videos, entries.playlistCount)
    }

    /// Player-client cascade for channel listings. Some channels return only
    /// ~500 entries on `web`, but the same channel via `tv_simply` returns the
    /// full history. We try the most permissive client first; if it fails or
    /// returns suspiciously few entries we fall back. Keep order from
    /// most-permissive to most-compatible.
    /// Player-client cascade for channel listings. YouTube's continuation
    /// tokens behave differently per client; some return the full channel
    /// history (4000+ videos) while others cap at a few hundred. We try every
    /// variant and keep the response with the most entries.
    private static let playerClientCascade: [String] = [
        "tv_simply",
        "tv,web",
        "mweb,web",
        "ios,android",
        "web,web_safari"
    ]

    private func fetchEntries(channelURL: String) async throws -> FlatPlaylistResponse {
        let normalised = Self.normaliseChannelURL(channelURL)

        var lastError: Error?
        var bestResponse: FlatPlaylistResponse?
        var bestCount = 0
        var allCounts: [(client: String, count: Int)] = []

        for clients in Self.playerClientCascade {
            do {
                let response = try await fetchOnce(url: normalised, playerClients: clients)
                let count = response.entries?.count ?? 0
                let reported = response.playlistCount ?? -1
                allCounts.append((clients, count))
                Logger.shared.info("ChannelResolver: clients=\(clients) → \(count) entries (yt-dlp reports playlist_count=\(reported))")
                if count > bestCount {
                    bestResponse = response
                    bestCount = count
                }
                // If this attempt returned the channel's reported total (within
                // a few entries — channels add/remove videos during enumeration),
                // there's no point trying more clients.
                if reported > 0 && count >= reported - 5 {
                    break
                }
            } catch {
                Logger.shared.warn("ChannelResolver: clients=\(clients) failed: \(error)")
                lastError = error
                continue
            }
        }

        if let best = bestResponse {
            let reported = best.playlistCount ?? -1
            let summary = allCounts.map { "\($0.client)=\($0.count)" }.joined(separator: ", ")
            if reported > 0 && bestCount < reported - 5 {
                Logger.shared.warn("ChannelResolver: BEST got \(bestCount) of \(reported) reported (yt-dlp can't enumerate the rest). Per-client: \(summary)")
            } else {
                Logger.shared.info("ChannelResolver: BEST = \(bestCount) entries. Per-client: \(summary)")
            }
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
            "-I", "1:99999",
            url
        ])
        // 10 minutes — very large channels (5000+ videos) take a while
        let result = try await runner.run(args, timeout: 600)
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
