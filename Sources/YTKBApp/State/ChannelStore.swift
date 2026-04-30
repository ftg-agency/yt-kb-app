import Foundation
import Combine

struct TrackedChannel: Codable, Identifiable, Equatable {
    var id: String { url }
    var url: String
    var channelId: String?
    var name: String
    var addedAt: Date
    var lastPolledAt: Date?
    var lastPollStatus: String?
    var lastPollError: String?
    var enabled: Bool = true
}

struct RetryQueueEntry: Codable, Identifiable, Equatable {
    var id: String { videoId }
    var channelURL: String
    var videoId: String
    var videoTitle: String?
    var firstSeen: Date
    var lastAttempt: Date?
    var attempts: Int
    var status: String
}

struct PersistedState: Codable {
    var channels: [TrackedChannel] = []
    var retryQueue: [RetryQueueEntry] = []
}

@MainActor
final class ChannelStore: ObservableObject {
    @Published private(set) var channels: [TrackedChannel] = []
    @Published private(set) var retryQueue: [RetryQueueEntry] = []

    private let fileURL: URL = {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yt-kb", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        return supportDir.appendingPathComponent("state.json")
    }()

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
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
}
