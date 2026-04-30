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

    private func fetchEntries(channelURL: String) async throws -> FlatPlaylistResponse {
        let normalised = Self.normaliseChannelURL(channelURL)
        var args = config.baseArgs
        args.append(contentsOf: ["--flat-playlist", "--dump-single-json", "--no-warnings", normalised])
        let result = try await runner.run(args, timeout: 120)
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
