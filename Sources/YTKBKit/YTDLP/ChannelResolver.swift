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

/// Lightweight resolve result used by the "Add channel" flow. Holds only the
/// data needed to show "канал найден" + persist as TrackedChannel.
package struct ResolvedChannelLite: Sendable {
    package let name: String
    package let channelId: String?
    package let channelURL: String
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

    /// Tabs we enumerate when the user adds a channel "base" URL. Big channels
    /// like Hormozi publish thousands of shorts that don't appear under
    /// `/videos`, so we have to scan all three and dedup. `/live` is omitted —
    /// it's the same content as `/streams` on most channels.
    private static let enumerableTabs: [String] = ["videos", "shorts", "streams"]

    private static func isChannelBase(_ url: String) -> Bool {
        ["/@", "/channel/", "/c/", "/user/"].contains(where: { url.contains($0) })
    }

    private static func hasChannelTab(_ url: String) -> Bool {
        let stripped = url.hasSuffix("/") ? String(url.dropLast()) : url
        return channelTabSuffixes.contains(where: { stripped.hasSuffix($0) })
    }

    private static func stripTrailingSlash(_ s: String) -> String {
        s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    /// Returns the URLs to enumerate. If user passed a tab-specific URL we
    /// respect it. Otherwise we expand to videos + shorts + streams so the
    /// channel's full catalog is covered.
    package static func enumerationURLs(for url: String) -> [String] {
        if !isChannelBase(url) || hasChannelTab(url) {
            return [url]
        }
        let base = stripTrailingSlash(url)
        return enumerableTabs.map { "\(base)/\($0)" }
    }

    package static func normaliseChannelURL(_ url: String) -> String {
        if isChannelBase(url) && !hasChannelTab(url) {
            let trimmed = url.hasSuffix("/") ? String(url.dropLast()) : url
            return trimmed + "/videos"
        }
        return url
    }

    func resolveMetadata(channelURL: String) async throws -> ResolvedChannel {
        let merged = try await fetchAllTabs(channelURL: channelURL)
        return ResolvedChannel(
            name: merged.displayName,
            channelId: merged.channelId,
            channelURL: merged.channelURL ?? channelURL,
            videos: merged.videos,
            reportedTotalCount: merged.reportedTotal
        )
    }

    /// Fast path for "Add channel": single yt-dlp call with `--playlist-items 0`
    /// so yt-dlp returns channel-level metadata without enumerating any entries.
    /// Saves up to ~15 heavyweight enumerations vs. `resolveMetadata`. Caller
    /// should fall back to `resolveMetadata` on any failure (geoblock, weird
    /// channel URL, missing fields).
    func quickResolve(channelURL: String) async throws -> ResolvedChannelLite {
        let t0 = Date()
        let normalised = Self.normaliseChannelURL(channelURL)
        Logger.shared.info("quickResolve ▶ url=\(channelURL) → normalised=\(normalised)")
        // Минимальный args — без cookies (channel metadata публично,
        // декриптование Chrome keychain съедает ~5-8с) и без --sleep-requests
        // (один запрос, rate-limit не нужен). Если упало — fallback на
        // resolveMetadata уже c полным config.baseArgs.
        let args = [
            "--flat-playlist",
            "--playlist-items", "0",
            "--dump-single-json",
            "--no-warnings",
            normalised
        ]
        let result: YTDLPResult
        do {
            result = try await runner.run(args, timeout: 20)
        } catch {
            Logger.shared.warn("quickResolve ◀ runner threw after \(ms(since: t0)): \(error)")
            throw error
        }
        guard result.exitCode == 0 else {
            Logger.shared.warn("quickResolve ◀ exit=\(result.exitCode) after \(ms(since: t0)): \(result.stderr.lastNonEmptyLine.prefix(160))")
            throw YTDLPError.nonZeroExit(result.exitCode, result.stderr.lastNonEmptyLine)
        }
        let response: FlatPlaylistResponse
        do {
            response = try JSONDecoder().decode(FlatPlaylistResponse.self, from: result.stdout)
        } catch {
            Logger.shared.warn("quickResolve ◀ JSON decode FAIL after \(ms(since: t0)) (stdout=\(result.stdout.count)B): \(error)")
            throw YTDLPError.decodeFailed("quickResolve: \(error)")
        }
        let name = response.displayName
        guard !name.isEmpty, name != "Unknown" else {
            Logger.shared.warn("quickResolve ◀ no channel name after \(ms(since: t0))")
            throw YTDLPError.decodeFailed("quickResolve: имя канала не получено")
        }
        let channelId = response.channelId ?? response.uploaderId
        let url = response.channelUrl ?? normalised
        Logger.shared.info("quickResolve ◀ ok in \(ms(since: t0)): \(name) (\(channelId ?? "no-id"))")
        return ResolvedChannelLite(name: name, channelId: channelId, channelURL: url)
    }

    private nonisolated func ms(since: Date) -> String {
        "\(Int(Date().timeIntervalSince(since) * 1000))ms"
    }

    /// Detects yt-dlp's "channel does not have a {shorts,streams,live} tab"
    /// stderr message. Deterministic — same answer regardless of player_client,
    /// so detecting it lets fetchEntries skip the rest of the cascade.
    private static func isMissingTabError(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("does not have a shorts tab")
            || lower.contains("does not have a streams tab")
            || lower.contains("does not have a live tab")
            || lower.contains("does not have a videos tab")
            || (lower.contains("this channel does not have") && lower.contains("tab"))
    }

    func listVideos(channelURL: String) async throws -> [VideoRef] {
        let merged = try await fetchAllTabs(channelURL: channelURL)
        return merged.videos
    }

    /// Same as `listVideos` but also returns YouTube's reported total count
    /// summed across enumerated tabs (or nil). Used by PollOperation to surface
    /// "we got X of Y" diagnostics.
    func listVideosWithCount(channelURL: String) async throws -> (videos: [VideoRef], reportedTotal: Int?) {
        let merged = try await fetchAllTabs(channelURL: channelURL)
        return (merged.videos, merged.reportedTotal)
    }

    private struct MergedTabs {
        let videos: [VideoRef]
        let displayName: String
        let channelId: String?
        let channelURL: String?
        let reportedTotal: Int?
    }

    /// Tuple sent across actor boundaries from each per-tab Task. Errors are
    /// logged + reduced to a String inside the task so we don't have to send
    /// `any Error` (non-Sendable) through the TaskGroup result.
    private struct TabFetchResult: Sendable {
        let url: String
        let response: FlatPlaylistResponse?
        let errorMessage: String?
    }

    /// Enumerate every tab in `enumerationURLs` for the given URL in parallel,
    /// dedup by video_id (preserving first occurrence so chronological order
    /// from /videos wins for channels where it matters), and merge metadata.
    private func fetchAllTabs(channelURL: String) async throws -> MergedTabs {
        let t0 = Date()
        let urls = Self.enumerationURLs(for: channelURL)
        Logger.shared.info("fetchAllTabs ▶ \(urls.count) tabs: \(urls)")
        defer { Logger.shared.info("fetchAllTabs ◀ total \(ms(since: t0))") }

        var responses: [(url: String, response: FlatPlaylistResponse)] = []
        var lastErrorMessage: String?

        // Parallel fetch across tabs. A 404 / "no shorts on this channel"
        // failure is non-fatal — channel may simply not have that tab. We only
        // surface an error if EVERY tab failed.
        await withTaskGroup(of: TabFetchResult.self) { group in
            for u in urls {
                group.addTask {
                    do {
                        let r = try await self.fetchEntries(channelURL: u)
                        return TabFetchResult(url: u, response: r, errorMessage: nil)
                    } catch {
                        Logger.shared.warn("ChannelResolver: tab \(u) failed: \(error)")
                        return TabFetchResult(url: u, response: nil, errorMessage: "\(error)")
                    }
                }
            }
            for await item in group {
                if let r = item.response {
                    responses.append((item.url, r))
                } else if let msg = item.errorMessage {
                    lastErrorMessage = msg
                }
            }
        }

        guard !responses.isEmpty else {
            throw YTDLPError.decodeFailed(lastErrorMessage ?? "ChannelResolver: all tabs failed")
        }

        var seen = Set<String>()
        var merged: [VideoRef] = []
        var totalReported = 0
        var hasReported = false
        for (_, r) in responses {
            let refs = await extractVideos(from: r.entries ?? [])
            for v in refs where seen.insert(v.videoId).inserted { merged.append(v) }
            if let pc = r.playlistCount, pc > 0 { totalReported += pc; hasReported = true }
        }

        // Channel display metadata: take from the first tab that has it
        // (typically /videos).
        let firstWithName = responses.first { $0.response.displayName != "Unknown" }?.response ?? responses[0].response
        return MergedTabs(
            videos: merged,
            displayName: firstWithName.displayName,
            channelId: firstWithName.channelId ?? firstWithName.uploaderId,
            channelURL: firstWithName.channelUrl,
            reportedTotal: hasReported ? totalReported : nil
        )
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
        let tStart = Date()
        let normalised = Self.normaliseChannelURL(channelURL)
        Logger.shared.info("fetchEntries ▶ \(normalised)")

        var lastError: Error?
        var bestResponse: FlatPlaylistResponse?
        var bestCount = 0
        var allCounts: [(client: String, count: Int)] = []

        for clients in Self.playerClientCascade {
            let tClient = Date()
            do {
                let response = try await fetchOnce(url: normalised, playerClients: clients)
                let count = response.entries?.count ?? 0
                let reported = response.playlistCount ?? -1
                allCounts.append((clients, count))
                Logger.shared.info("fetchEntries · clients=\(clients) → \(count) entries (reported=\(reported)) in \(ms(since: tClient))")
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
                Logger.shared.warn("fetchEntries · clients=\(clients) FAIL in \(ms(since: tClient)): \(error)")
                lastError = error
                // Deterministic "no such tab" — don't waste 4 more player_clients
                // (yt-dlp returns same answer for all, each call ~17-27s due to
                // --sleep-requests). Abort cascade for this tab.
                if Self.isMissingTabError("\(error)") {
                    Logger.shared.info("fetchEntries · tab отсутствует — обрываем каскад")
                    break
                }
                continue
            }
        }

        if let best = bestResponse {
            let reported = best.playlistCount ?? -1
            let summary = allCounts.map { "\($0.client)=\($0.count)" }.joined(separator: ", ")
            if reported > 0 && bestCount < reported - 5 {
                Logger.shared.warn("fetchEntries ◀ BEST=\(bestCount)/\(reported) reported (incomplete) in \(ms(since: tStart)). Per-client: \(summary)")
            } else {
                Logger.shared.info("fetchEntries ◀ BEST=\(bestCount) entries in \(ms(since: tStart)). Per-client: \(summary)")
            }
            return best
        }
        Logger.shared.warn("fetchEntries ◀ all clients failed in \(ms(since: tStart))")
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
