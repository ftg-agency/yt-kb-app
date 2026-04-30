import Foundation
import Combine

/// Progress snapshot for one channel currently being polled. Drives the
/// in-row progress bar in the popover.
package struct ChannelProgress: Equatable, Sendable {
    package enum Phase: Equatable, Sendable {
        case resolving           // listing channel videos via flat-playlist
        case scanning            // pre-scanning KB for existing IDs
        case processing          // fetching metadata + subs for one video
        case retrying            // working on retry-queue entry
    }
    package var phase: Phase
    package var current: Int      // 1-based index of the video being processed (0 for resolving/scanning)
    package var total: Int        // total to process this cycle
    package var label: String?    // current video title (or nil)
    package var isInitialIndexing: Bool = false  // set when channel has never been polled

    package init(phase: Phase, current: Int, total: Int, label: String? = nil, isInitialIndexing: Bool = false) {
        self.phase = phase
        self.current = current
        self.total = total
        self.label = label
        self.isInitialIndexing = isInitialIndexing
    }

    package var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(current) / Double(total))
    }
}

@MainActor
final class AppState: ObservableObject {
    let settings = Settings()
    let channelStore = ChannelStore()

    @Published var isPolling: Bool = false
    @Published var pollingChannelURL: String?
    @Published var lastError: String?
    @Published var needsOnboarding: Bool = false

    /// Per-channel progress while polling. Keyed by channel URL.
    @Published var channelProgress: [String: ChannelProgress] = [:]

    /// True while NSPopover is shown (so notifications can suppress themselves).
    @Published var isPopoverOpen: Bool = false

    /// True when KB directory is accessible. Goes false if external disk unmounted etc.
    /// Polling pauses while false; UI shows a warning banner.
    @Published var kbDirectoryAvailable: Bool = true

    /// When non-nil, popover should highlight this channel briefly (set on
    /// notification-click deep link).
    @Published var focusChannelURL: String?

    /// Set by AppDelegate after scheduler is constructed.
    var scheduler: PollingScheduler?

    /// Set by AppDelegate to expose its showPopover() callback to other components
    /// (notifications service uses this to open the UI when a notification is clicked).
    var showPopover: (() -> Void)?

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

    /// Check that the configured KB directory is reachable. Updates
    /// `kbDirectoryAvailable`. Call this before polling and on app foreground.
    @discardableResult
    func refreshKBAvailability() -> Bool {
        guard let kb = settings.kbDirectory else {
            kbDirectoryAvailable = false
            return false
        }
        let started = kb.startAccessingSecurityScopedResource()
        defer { if started { kb.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: kb.path, isDirectory: &isDir) && isDir.boolValue
        kbDirectoryAvailable = exists
        if !exists {
            Logger.shared.warn("KB directory unreachable: \(kb.path)")
        }
        return exists
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
