import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    let settings = Settings()
    let channelStore = ChannelStore()

    @Published var isPolling: Bool = false
    @Published var pollingChannelURL: String?
    @Published var lastError: String?
    @Published var needsOnboarding: Bool = false

    /// Set by AppDelegate after scheduler is constructed.
    var scheduler: PollingScheduler?

    func bootstrap() {
        settings.load()
        channelStore.load()
        needsOnboarding = !settings.onboardingCompleted
        Logger.shared.info("Bootstrap done. channels=\(channelStore.channels.count) onboarding=\(needsOnboarding)")
    }

    /// Restart the background scheduler — call after settings change (interval, enabled).
    func restartScheduler() {
        scheduler?.stop()
        scheduler?.start()
    }

    /// Discover channels in the configured KB folder and offer to add new ones.
    /// Returns the list of channels not currently tracked.
    func discoverNewChannels() -> [DiscoveredChannel] {
        guard let kb = settings.kbDirectory else { return [] }
        let started = kb.startAccessingSecurityScopedResource()
        defer { if started { kb.stopAccessingSecurityScopedResource() } }
        let discovered = AutoDiscovery.discover(in: kb)
        let trackedURLs = Set(channelStore.channels.map(\.url))
        return discovered.filter { !trackedURLs.contains($0.url) }
    }

    /// Add the given discovered channels as tracked.
    func adoptDiscovered(_ channels: [DiscoveredChannel]) {
        for d in channels {
            let tracked = TrackedChannel(
                url: d.url,
                channelId: nil,
                name: d.name,
                addedAt: Date(),
                lastPolledAt: nil,
                lastPollStatus: nil,
                lastPollError: nil,
                enabled: true
            )
            channelStore.addChannel(tracked)
        }
    }
}
