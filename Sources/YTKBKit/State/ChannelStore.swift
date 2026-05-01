import Foundation
import Combine

package struct TrackedChannel: Codable, Identifiable, Equatable {
    package var id: String { url }
    package var url: String
    package var channelId: String?
    package var name: String
    package var addedAt: Date
    package var lastPolledAt: Date?
    package var lastPollStatus: String?
    package var lastPollError: String?
    package var enabled: Bool = true

    /// Per-channel poll interval. Semantics:
    /// - nil   → use global Settings.pollInterval
    /// - 0     → manual only (scheduler skips this channel)
    /// - > 0   → poll every N seconds
    package var pollIntervalSeconds: Int? = nil

    /// YouTube's reported total video count, captured at the most recent
    /// successful resolve. nil before first poll. Surfaced in the widget so
    /// user always sees "X videos on YouTube" without having to start a poll.
    package var videoCount: Int? = nil

    package init(
        url: String,
        channelId: String? = nil,
        name: String,
        addedAt: Date,
        lastPolledAt: Date? = nil,
        lastPollStatus: String? = nil,
        lastPollError: String? = nil,
        enabled: Bool = true,
        pollIntervalSeconds: Int? = nil,
        videoCount: Int? = nil
    ) {
        self.url = url
        self.channelId = channelId
        self.name = name
        self.addedAt = addedAt
        self.lastPolledAt = lastPolledAt
        self.lastPollStatus = lastPollStatus
        self.lastPollError = lastPollError
        self.enabled = enabled
        self.pollIntervalSeconds = pollIntervalSeconds
        self.videoCount = videoCount
    }

    /// Returns the effective interval in seconds (or nil if "manual only").
    package func effectivePollInterval(globalSeconds: TimeInterval) -> TimeInterval? {
        guard let v = pollIntervalSeconds else { return globalSeconds }
        return v == 0 ? nil : TimeInterval(v)
    }

    /// True if this channel is due for a scheduled poll right now.
    /// "Manual only" channels return false. Never-polled channels return true.
    package func isDueForScheduledPoll(now: Date = Date(), globalSeconds: TimeInterval) -> Bool {
        guard let interval = effectivePollInterval(globalSeconds: globalSeconds) else { return false }
        guard let last = lastPolledAt else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}

package struct RetryQueueEntry: Codable, Identifiable, Equatable {
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

struct PersistedState: Codable {
    var channels: [TrackedChannel] = []
    var retryQueue: [RetryQueueEntry] = []
}

@MainActor
final class ChannelStore: ObservableObject {
    @Published private(set) var channels: [TrackedChannel] = []
    @Published private(set) var retryQueue: [RetryQueueEntry] = []

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
            Logger.shared.info("State loaded: channels=\(channels.count) retry=\(retryQueue.count)")
        } catch {
            Logger.shared.error("Failed to load state.json: \(error)")
        }
    }

    func save() {
        let state = PersistedState(channels: channels, retryQueue: retryQueue)
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
}
