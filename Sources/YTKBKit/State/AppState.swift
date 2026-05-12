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
    package var total: Int        // total to process this cycle (videos yt-dlp returned)
    package var label: String?    // current video title (or nil)
    package var isInitialIndexing: Bool = false  // set when channel has never been polled
    /// YouTube's reported total video count for the channel. If this is
    /// larger than `total`, yt-dlp couldn't enumerate the full channel and
    /// the UI shows "X of total (channel has reportedTotal)".
    package var reportedChannelTotal: Int? = nil
    /// Number of videos for this channel already on disk at the start of
    /// this cycle. Used by the UI to display channel-wide progress
    /// (`alreadyIndexed + current` out of `reportedChannelTotal`) instead of
    /// cycle-local progress (which resets to 0 every poll and confuses
    /// users on channels that were partially indexed in a previous install).
    package var alreadyIndexed: Int = 0

    package init(phase: Phase, current: Int, total: Int, label: String? = nil, isInitialIndexing: Bool = false, reportedChannelTotal: Int? = nil, alreadyIndexed: Int = 0) {
        self.phase = phase
        self.current = current
        self.total = total
        self.label = label
        self.isInitialIndexing = isInitialIndexing
        self.reportedChannelTotal = reportedChannelTotal
        self.alreadyIndexed = alreadyIndexed
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
    private var nestedSubscriptions: Set<AnyCancellable> = []

    @Published var isPolling: Bool = false
    /// Convenience: URL of the currently-polling channel when concurrency=1.
    /// With parallel polling use `pollingChannelURLs` instead — kept for
    /// backward compat with existing notification routing.
    @Published var pollingChannelURL: String?
    /// Set of channel URLs currently being polled (concurrency-aware).
    @Published var pollingChannelURLs: Set<String> = []
    /// Channels waiting in the coordinator's queue (not yet started). Drives
    /// the small "+N в очереди" hint in the popover footer.
    @Published var queuedChannelCount: Int = 0
    @Published var lastError: String?
    @Published var needsOnboarding: Bool = false

    /// Per-channel progress while polling. Keyed by channel URL.
    @Published var channelProgress: [String: ChannelProgress] = [:]

    /// True while NSPopover is shown.
    @Published var isPopoverOpen: Bool = false

    /// True when YouTube returned a bot-check on the most recent poll attempt.
    /// Drives the red banner in the popover and the red tint on the menu-bar
    /// icon. Cleared when any video gets indexed successfully on a later poll.
    @Published var botCheckActive: Bool = false

    /// True when KB directory is accessible. Goes false if external disk unmounted etc.
    /// Polling pauses while false; UI shows a warning banner.
    @Published var kbDirectoryAvailable: Bool = true

    /// When non-nil, popover should highlight this channel briefly (set on
    /// notification-click deep link).
    @Published var focusChannelURL: String?

    /// Latest update found by UpdateChecker, if newer than running version.
    /// Surfaced as a banner button above "Выход" in the popover.
    @Published var availableUpdate: AppUpdate?

    /// Progress of an active update install (download/mount/swap).
    @Published var updateInstallProgress: UpdateInstaller.Progress?

    /// Last error from a manual or scheduled update check, surfaced in Settings.
    @Published var updateCheckError: String?

    /// True while a release-check request is in flight; drives the spinner
    /// next to "Проверить сейчас" so the user gets feedback that something
    /// is happening even when the app is already on the latest version.
    @Published var isCheckingUpdate: Bool = false

    /// Wall-clock timestamp of the last completed release check (success or
    /// failure). Settings shows "проверено: HH:mm" so the user knows the
    /// "Версия актуальная" text reflects a real check, not a stale default.
    @Published var lastUpdateCheckAt: Date?

    /// Set by AppDelegate after scheduler is constructed.
    var scheduler: PollingScheduler?

    /// Set by AppDelegate to expose its showPopover() callback to other components.
    var showPopover: (() -> Void)?

    func bootstrap() {
        settings.load()
        channelStore.load()

        // Forward nested ObservableObject changes (Settings, ChannelStore) up
        // to AppState's objectWillChange. SwiftUI views observe AppState but
        // read nested @Published properties (e.g. appState.settings.kbDirectory);
        // without forwarding, those reads don't trigger re-renders when the
        // nested object mutates. This was the cause of "selected KB folder
        // doesn't display in Onboarding" and similar issues.
        settings.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &nestedSubscriptions)
        channelStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &nestedSubscriptions)

        // Onboarding triggers when:
        //   1. user never completed it (UserDefaults bool), OR
        //   2. state.json doesn't exist (fresh install — AppCleaner / new machine /
        //      first install) — even if a stale `onboardingCompleted=true` is
        //      sitting in UserDefaults from a prior install.
        let freshInstall = !channelStore.stateFileExistedAtBoot
        needsOnboarding = !settings.onboardingCompleted || freshInstall
        if freshInstall && settings.onboardingCompleted {
            Logger.shared.info("Fresh install detected (no state.json); forcing onboarding despite stale UserDefaults")
        }

        runKBConsolidationIfNeeded(freshInstall: freshInstall)

        Logger.shared.info("Bootstrap done. channels=\(channelStore.channels.count) onboarding=\(needsOnboarding) freshInstall=\(freshInstall)")
    }

    /// Run the one-time KB-layout migration if the persisted version is
    /// behind the current one. Renames legacy folders (`<slug>-<id-suffix>`
    /// from yt-kb.py) into clean slugs and merges duplicates created after the
    /// recent slug fix. Pins the resulting folder name on each channel so
    /// future polls don't drift again. Silent on success — only logs.
    private func runKBConsolidationIfNeeded(freshInstall: Bool) {
        let target = Settings.currentKBConsolidationVersion
        guard settings.kbConsolidationVersion < target else { return }

        // Fresh install: nothing on disk yet, just stamp the current version.
        if freshInstall {
            settings.setKBConsolidationVersion(target)
            return
        }
        guard let kbRoot = settings.kbDirectory else {
            // KB not configured (rare for non-fresh installs). Don't stamp —
            // try again next launch when it's hopefully set.
            return
        }
        guard !channelStore.channels.isEmpty else {
            // No tracked channels yet; nothing to consolidate against.
            settings.setKBConsolidationVersion(target)
            return
        }

        let started = kbRoot.startAccessingSecurityScopedResource()
        defer { if started { kbRoot.stopAccessingSecurityScopedResource() } }

        let report = KBConsolidator.consolidate(kbRoot: kbRoot, channels: channelStore.channels)
        for outcome in report.outcomes {
            guard let folderName = outcome.folderName else { continue }
            guard let existing = channelStore.channels.first(where: { $0.url == outcome.channelURL }) else { continue }
            if existing.folderName == folderName { continue }
            var updated = existing
            updated.folderName = folderName
            channelStore.updateChannel(updated)
        }
        Logger.shared.info("KBConsolidator: pinned=\(report.pinnedChannels) renamed=\(report.renamedFolders) merged=\(report.mergedFolders) errors=\(report.totalErrors)")
        settings.setKBConsolidationVersion(target)
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

    /// Trigger an update check against GitHub Releases. Sets `availableUpdate`
    /// on success (if newer than current). Also sets `updateCheckError` on
    /// failure for surfacing in Settings.
    func checkForUpdate(manual: Bool = false) {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        Task { [weak self] in
            do {
                let update = try await UpdateChecker.shared.checkLatest()
                await MainActor.run {
                    self?.availableUpdate = update
                    self?.updateCheckError = nil
                    self?.isCheckingUpdate = false
                    self?.lastUpdateCheckAt = Date()
                }
            } catch {
                Logger.shared.warn("UpdateChecker failed: \(error)")
                await MainActor.run {
                    self?.updateCheckError = "\(error)"
                    self?.isCheckingUpdate = false
                    self?.lastUpdateCheckAt = Date()
                    if manual { /* surface only on manual check; auto = quiet */ }
                }
            }
        }
    }

    /// Begin downloading + installing the update found by `checkForUpdate`.
    /// On success the app terminates and the helper script relaunches.
    func installAvailableUpdate() {
        guard let update = availableUpdate else { return }
        Task { [weak self] in
            do {
                try await UpdateInstaller.shared.install(update: update) { progress in
                    self?.updateInstallProgress = progress
                }
            } catch {
                Logger.shared.error("UpdateInstaller failed: \(error)")
                await MainActor.run {
                    self?.updateInstallProgress = nil
                    self?.updateCheckError = "Не удалось установить обновление: \(error)"
                }
            }
        }
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
                enabled: true,
                folderName: d.folderName
            )
            channelStore.addChannel(tracked)
        }
    }
}
