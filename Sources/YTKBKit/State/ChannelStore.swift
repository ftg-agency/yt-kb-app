import Foundation
import Combine

package struct TrackedChannel: Codable, Identifiable, Equatable, Sendable {
    package var id: String { url }
    package var url: String
    package var channelId: String?
    package var name: String
    package var addedAt: Date
    package var lastPolledAt: Date?
    package var lastPollStatus: String?
    package var lastPollError: String?
    package var enabled: Bool = true

    /// YouTube's reported total video count, captured at the most recent
    /// successful resolve. nil before first poll. Surfaced in the widget so
    /// user always sees "X videos on YouTube" without having to start a poll.
    package var videoCount: Int? = nil

    /// Folder name (relative to kbRoot) where this channel's .md files live.
    /// nil means the path hasn't been pinned yet — callers must fall back to
    /// recomputing from the channel name. Pinned at adopt-time, at first
    /// successful poll, and by KBConsolidator on bootstrap.
    package var folderName: String? = nil

    /// Number of new transcripts written by the most recent poll cycle. Drives
    /// the "+3 новых" badge in the channel row.
    package var lastPollDownloaded: Int = 0
    /// Number of videos skipped (already-on-disk) by the most recent cycle.
    package var lastPollSkipped: Int = 0
    /// Total videos counted in the channel's KB folder. Refreshed after each
    /// successful poll. Used together with `videoCount` to display "X / Y".
    package var indexedCount: Int = 0
    /// Timestamp of the last full-enumeration poll (via ChannelResolver). nil
    /// for channels added before v2.0.0. Used to decide when to fall back from
    /// the lightweight RSS path to a full yt-dlp pass — once per ~7 days as a
    /// safety net against missed RSS deltas.
    package var lastFullReconcileAt: Date? = nil

    package init(
        url: String,
        channelId: String? = nil,
        name: String,
        addedAt: Date,
        lastPolledAt: Date? = nil,
        lastPollStatus: String? = nil,
        lastPollError: String? = nil,
        enabled: Bool = true,
        videoCount: Int? = nil,
        folderName: String? = nil,
        lastPollDownloaded: Int = 0,
        lastPollSkipped: Int = 0,
        indexedCount: Int = 0,
        lastFullReconcileAt: Date? = nil
    ) {
        self.url = url
        self.channelId = channelId
        self.name = name
        self.addedAt = addedAt
        self.lastPolledAt = lastPolledAt
        self.lastPollStatus = lastPollStatus
        self.lastPollError = lastPollError
        self.enabled = enabled
        self.videoCount = videoCount
        self.folderName = folderName
        self.lastPollDownloaded = lastPollDownloaded
        self.lastPollSkipped = lastPollSkipped
        self.indexedCount = indexedCount
        self.lastFullReconcileAt = lastFullReconcileAt
    }

    /// Custom decoder so older state.json files (without newer fields) decode
    /// cleanly with sensible defaults instead of throwing keyNotFound. Old
    /// `pollIntervalSeconds` field is silently ignored — JSONDecoder doesn't
    /// fail on extra unknown keys.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        channelId = try c.decodeIfPresent(String.self, forKey: .channelId)
        name = try c.decode(String.self, forKey: .name)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        lastPolledAt = try c.decodeIfPresent(Date.self, forKey: .lastPolledAt)
        lastPollStatus = try c.decodeIfPresent(String.self, forKey: .lastPollStatus)
        lastPollError = try c.decodeIfPresent(String.self, forKey: .lastPollError)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        videoCount = try c.decodeIfPresent(Int.self, forKey: .videoCount)
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName)
        lastPollDownloaded = try c.decodeIfPresent(Int.self, forKey: .lastPollDownloaded) ?? 0
        lastPollSkipped = try c.decodeIfPresent(Int.self, forKey: .lastPollSkipped) ?? 0
        indexedCount = try c.decodeIfPresent(Int.self, forKey: .indexedCount) ?? 0
        lastFullReconcileAt = try c.decodeIfPresent(Date.self, forKey: .lastFullReconcileAt)
    }

    /// True if this channel is due for a scheduled poll right now.
    /// Never-polled channels return true. Per-channel override removed in
    /// v2.0.0 — all channels use the single global interval from Settings.
    package func isDueForScheduledPoll(now: Date = Date(), globalSeconds: TimeInterval) -> Bool {
        guard let last = lastPolledAt else { return true }
        return now.timeIntervalSince(last) >= globalSeconds
    }
}

package struct RetryQueueEntry: Codable, Identifiable, Equatable, Sendable {
    package var id: String { videoId }
    package var channelURL: String
    package var videoId: String
    package var videoTitle: String?
    package var firstSeen: Date
    package var lastAttempt: Date?
    package var attempts: Int
    package var status: String

    package init(channelURL: String, videoId: String, videoTitle: String?, firstSeen: Date, lastAttempt: Date?, attempts: Int, status: String) {
        self.channelURL = channelURL
        self.videoId = videoId
        self.videoTitle = videoTitle
        self.firstSeen = firstSeen
        self.lastAttempt = lastAttempt
        self.attempts = attempts
        self.status = status
    }
}

/// Single newly-indexed video event. Persisted ring-buffer in state.json so
/// the popover's "Новое" section survives relaunches and the user always sees
/// what arrived since they last looked.
package struct RecentVideo: Codable, Identifiable, Equatable, Sendable {
    package var id: String { videoId }
    package var videoId: String
    package var title: String?
    package var channelURL: String
    package var channelName: String
    package var indexedAt: Date

    package init(videoId: String, title: String?, channelURL: String, channelName: String, indexedAt: Date) {
        self.videoId = videoId
        self.title = title
        self.channelURL = channelURL
        self.channelName = channelName
        self.indexedAt = indexedAt
    }

    package var youtubeURL: String { "https://www.youtube.com/watch?v=\(videoId)" }
}

struct PersistedState: Codable {
    var channels: [TrackedChannel] = []
    var retryQueue: [RetryQueueEntry] = []
    var recentVideos: [RecentVideo] = []

    enum CodingKeys: String, CodingKey {
        case channels, retryQueue, recentVideos
    }

    init(channels: [TrackedChannel] = [], retryQueue: [RetryQueueEntry] = [], recentVideos: [RecentVideo] = []) {
        self.channels = channels
        self.retryQueue = retryQueue
        self.recentVideos = recentVideos
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channels = try c.decodeIfPresent([TrackedChannel].self, forKey: .channels) ?? []
        retryQueue = try c.decodeIfPresent([RetryQueueEntry].self, forKey: .retryQueue) ?? []
        recentVideos = try c.decodeIfPresent([RecentVideo].self, forKey: .recentVideos) ?? []
    }
}

@MainActor
final class ChannelStore: ObservableObject {
    @Published private(set) var channels: [TrackedChannel] = []
    @Published private(set) var retryQueue: [RetryQueueEntry] = []
    /// FIFO ring-buffer of the most recently indexed videos across all channels.
    /// Capped at `maxRecentVideos` (oldest evicted on append). Persisted.
    @Published private(set) var recentVideos: [RecentVideo] = []
    private let maxRecentVideos = 50

    /// True if a state.json file existed at bootstrap time. False on a fresh
    /// install (or after AppCleaner removed Application Support). AppDelegate
    /// uses this to decide whether to show onboarding regardless of stale
    /// UserDefaults values that AppCleaner may have left behind.
    private(set) var stateFileExistedAtBoot: Bool = false

    private let fileURL: URL = {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yt-kb", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        return supportDir.appendingPathComponent("state.json")
    }()

    func load() {
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        stateFileExistedAtBoot = exists
        guard exists else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let state = try dec.decode(PersistedState.self, from: data)
            self.channels = state.channels
            self.retryQueue = state.retryQueue
            self.recentVideos = state.recentVideos
            Logger.shared.info("State loaded: channels=\(channels.count) retry=\(retryQueue.count) recents=\(recentVideos.count)")
        } catch {
            Logger.shared.error("Failed to load state.json: \(error)")
        }
    }

    func save() {
        let state = PersistedState(channels: channels, retryQueue: retryQueue, recentVideos: recentVideos)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(state)
            // atomic write
            let tmp = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } catch {
            Logger.shared.error("Failed to save state.json: \(error)")
        }
    }

    func addChannel(_ channel: TrackedChannel) {
        if !channels.contains(where: { $0.url == channel.url }) {
            channels.append(channel)
            save()
        }
    }

    func removeChannel(url: String) {
        channels.removeAll { $0.url == url }
        save()
    }

    func updateChannel(_ updated: TrackedChannel) {
        if let idx = channels.firstIndex(where: { $0.url == updated.url }) {
            channels[idx] = updated
            save()
        }
    }

    // MARK: - Retry queue

    func addRetryEntry(_ entry: RetryQueueEntry) {
        if !retryQueue.contains(where: { $0.videoId == entry.videoId }) {
            retryQueue.append(entry)
            save()
        }
    }

    func updateRetryEntry(_ entry: RetryQueueEntry) {
        if let idx = retryQueue.firstIndex(where: { $0.videoId == entry.videoId }) {
            retryQueue[idx] = entry
            save()
        }
    }

    func removeRetryEntry(videoId: String) {
        retryQueue.removeAll { $0.videoId == videoId }
        save()
    }

    func retryEntriesFor(channelURL: String) -> [RetryQueueEntry] {
        retryQueue.filter { $0.channelURL == channelURL }
    }

    // MARK: - Recent videos

    func appendRecentVideo(_ video: RecentVideo) {
        // Dedup: same videoId already at the head of the list (rapid double-fire)
        if recentVideos.first?.videoId == video.videoId { return }
        recentVideos.insert(video, at: 0)
        if recentVideos.count > maxRecentVideos {
            recentVideos.removeLast(recentVideos.count - maxRecentVideos)
        }
        save()
    }

    func clearRecentVideos() {
        recentVideos.removeAll()
        save()
    }
}
