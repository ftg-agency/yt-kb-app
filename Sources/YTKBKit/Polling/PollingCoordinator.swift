import Foundation

enum PollTrigger {
    case manual
    case manualSingle
    case scheduled
}

/// Owns the singleton actor that prevents overlapping polls and aggregates results.
actor PollingCoordinator {
    static let shared = PollingCoordinator()

    private var isPolling = false
    package let cancellation = CancellationFlag()
    private init() {}

    /// Request that the currently running poll cycle stop ASAP. Sets the
    /// cancellation flag (checked between videos by PollOperation) AND
    /// terminates the running yt-dlp subprocess so blocking calls return
    /// immediately. After cancellation `pollAll` exits cleanly.
    package func cancel() async {
        guard isPolling else { return }
        Logger.shared.info("Cancellation requested by user")
        cancellation.cancel()
        await YTDLPRunner.shared.terminateAll()
    }

    /// Poll all enabled channels sequentially. Idempotent: a second concurrent call
    /// returns immediately if a poll is already running.
    func pollAll(appState: AppState, trigger: PollTrigger = .manual) async {
        if isPolling {
            Logger.shared.info("pollAll: skipped (already polling)")
            return
        }
        isPolling = true
        cancellation.reset()
        defer { isPolling = false }

        // Hold a power-management activity so the Mac doesn't sleep mid-cycle
        // (a 5000-video channel can take hours). Released automatically when
        // pollAll returns. User can opt out via Settings → Расписание.
        let preventSleep = await MainActor.run { appState.settings.preventSleepDuringPoll }
        let activityToken: NSObjectProtocol? = preventSleep
            ? ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "yt-kb: indexing channels"
            )
            : nil
        defer {
            if let activityToken { ProcessInfo.processInfo.endActivity(activityToken) }
        }

        let (kbRoot, config, kbAvailable) = await MainActor.run {
            appState.refreshKBAvailability()
            return (appState.settings.kbDirectory, appState.settings.ytdlpConfig, appState.kbDirectoryAvailable)
        }
        guard let kbRoot else {
            await MainActor.run { appState.lastError = "База знаний не настроена" }
            return
        }
        guard kbAvailable else {
            await MainActor.run { appState.lastError = "Папка базы знаний недоступна (диск отключён?)" }
            Logger.shared.warn("pollAll: KB unreachable, polling paused until directory comes back")
            return
        }

        await MainActor.run {
            appState.isPolling = true
            appState.lastError = nil
        }
        defer {
            Task { @MainActor in
                appState.isPolling = false
                appState.pollingChannelURL = nil
                appState.pollingChannelURLs.removeAll()
                appState.channelProgress.removeAll()
            }
        }

        let started = kbRoot.startAccessingSecurityScopedResource()
        defer { if started { kbRoot.stopAccessingSecurityScopedResource() } }

        let op = PollOperation(runner: YTDLPRunner.shared, config: config)
        var totalDownloaded = 0
        var botHit = false
        var processedURLs: Set<String> = []
        let maxConcurrent = await MainActor.run { appState.settings.maxConcurrentChannels }

        // Outer loop picks up channels added DURING this poll cycle. After we
        // finish the snapshot, we re-fetch the list and process anything new.
        // This is what makes "click Проверить → add channel mid-poll" work.
        outer: while !botHit {
            if cancellation.isCancelled { break outer }
            let pending: [TrackedChannel]
            if trigger == .scheduled {
                let globalSec = await MainActor.run { appState.settings.pollInterval.seconds }
                let now = Date()
                pending = await MainActor.run {
                    appState.channelStore.channels.filter { ch in
                        ch.enabled
                            && !processedURLs.contains(ch.url)
                            && ch.isDueForScheduledPoll(now: now, globalSeconds: globalSec)
                    }
                }
            } else {
                pending = await MainActor.run {
                    appState.channelStore.channels.filter { $0.enabled && !processedURLs.contains($0.url) }
                }
            }
            if pending.isEmpty { break outer }

            // Process up to `maxConcurrent` channels in parallel via TaskGroup.
            // Each yt-dlp pipeline runs in its own subprocess so OS-level
            // parallelism is real. Bounded by user setting (default 2) to
            // avoid YouTube rate-limiting from too many simultaneous requests.
            let batches = stride(from: 0, to: pending.count, by: maxConcurrent).map {
                Array(pending[$0..<min($0 + maxConcurrent, pending.count)])
            }
            for batch in batches {
                if cancellation.isCancelled { break outer }
                let reports = await withTaskGroup(of: PollChannelReport.self, returning: [PollChannelReport].self) { group in
                    for ch in batch {
                        group.addTask {
                            let priorRetries = await MainActor.run { appState.channelStore.retryEntriesFor(channelURL: ch.url) }
                            return await self.pollOneInternal(
                                channel: ch,
                                op: op,
                                kbRoot: kbRoot,
                                appState: appState,
                                priorRetries: priorRetries
                            )
                        }
                    }
                    var collected: [PollChannelReport] = []
                    for await r in group { collected.append(r) }
                    return collected
                }
                for ch in batch { processedURLs.insert(ch.url) }
                for report in reports {
                    totalDownloaded += report.counts["ok"] ?? 0
                    if report.cancelled { break outer }
                    if report.botCheckHit { botHit = true; break outer }
                }
            }
        }

        await postSummaryNotification(
            appState: appState,
            trigger: trigger,
            totalDownloaded: totalDownloaded,
            botHit: botHit
        )
    }

    func pollOne(channel: TrackedChannel, appState: AppState) async {
        if isPolling {
            Logger.shared.info("pollOne: skipped (already polling)")
            return
        }
        isPolling = true
        cancellation.reset()
        defer { isPolling = false }

        let preventSleep = await MainActor.run { appState.settings.preventSleepDuringPoll }
        let activityToken: NSObjectProtocol? = preventSleep
            ? ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "yt-kb: polling channel"
            )
            : nil
        defer {
            if let activityToken { ProcessInfo.processInfo.endActivity(activityToken) }
        }

        let (kbRoot, config, kbAvailable) = await MainActor.run {
            appState.refreshKBAvailability()
            return (appState.settings.kbDirectory, appState.settings.ytdlpConfig, appState.kbDirectoryAvailable)
        }
        guard let kbRoot else {
            await MainActor.run { appState.lastError = "База знаний не настроена" }
            return
        }
        guard kbAvailable else {
            await MainActor.run { appState.lastError = "Папка базы знаний недоступна" }
            return
        }

        await MainActor.run {
            appState.isPolling = true
            appState.lastError = nil
        }
        defer {
            Task { @MainActor in
                appState.isPolling = false
                appState.pollingChannelURL = nil
                appState.pollingChannelURLs.removeAll()
                appState.channelProgress.removeAll()
            }
        }

        let started = kbRoot.startAccessingSecurityScopedResource()
        defer { if started { kbRoot.stopAccessingSecurityScopedResource() } }

        let op = PollOperation(runner: YTDLPRunner.shared, config: config)
        let priorRetries = await MainActor.run { appState.channelStore.retryEntriesFor(channelURL: channel.url) }
        let report = await pollOneInternal(
            channel: channel,
            op: op,
            kbRoot: kbRoot,
            appState: appState,
            priorRetries: priorRetries
        )
        await postSummaryNotification(
            appState: appState,
            trigger: .manualSingle,
            totalDownloaded: report.counts["ok"] ?? 0,
            botHit: report.botCheckHit
        )
    }

    private func pollOneInternal(
        channel: TrackedChannel,
        op: PollOperation,
        kbRoot: URL,
        appState: AppState,
        priorRetries: [RetryQueueEntry]
    ) async -> PollChannelReport {
        let channelURL = channel.url
        await MainActor.run {
            appState.pollingChannelURL = channelURL
            appState.pollingChannelURLs.insert(channelURL)
            // Seed progress immediately so the row shows "starting…" without flicker
            appState.channelProgress[channelURL] = ChannelProgress(
                phase: .resolving,
                current: 0, total: 0, label: nil,
                isInitialIndexing: channel.lastPolledAt == nil
            )
        }
        defer {
            Task { @MainActor in
                appState.pollingChannelURLs.remove(channelURL)
            }
        }
        Logger.shared.info("Polling \(channel.name) (\(channel.url))")
        let report = await op.pollChannel(
            channel: channel,
            kbRoot: kbRoot,
            priorRetries: priorRetries,
            cancellation: cancellation,
            progress: { [appState, channelURL] event in
                Task { @MainActor in
                    appState.channelProgress[channelURL] = event
                }
            }
        )
        await MainActor.run {
            appState.channelProgress[channelURL] = nil
        }

        // Apply retry-queue mutations
        let resolved = report.resolvedRetries
        let newEntries = report.newRetries
        let updatedEntries = report.updatedRetries

        var built = channel
        built.lastPolledAt = Date()
        if let total = report.reportedChannelTotal {
            built.videoCount = total
        }
        if built.folderName == nil, let resolved = report.resolvedFolderName {
            built.folderName = resolved
        }
        let okCount = report.counts["ok"] ?? 0
        if let err = report.firstError, okCount == 0 {
            built.lastPollStatus = "error"
            built.lastPollError = String(err.prefix(200))
        } else {
            built.lastPollStatus = "ok"
            built.lastPollError = nil
        }
        let updatedChannel = built
        let summary = report.counts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        Logger.shared.info("Poll done: \(channel.name) · \(summary)")

        let errSnapshot = report.firstError
        await MainActor.run {
            appState.channelStore.updateChannel(updatedChannel)
            for vid in resolved { appState.channelStore.removeRetryEntry(videoId: vid) }
            for entry in newEntries { appState.channelStore.addRetryEntry(entry) }
            for entry in updatedEntries { appState.channelStore.updateRetryEntry(entry) }
            if okCount == 0, let err = errSnapshot {
                appState.lastError = err
            }
            // Trigger error notification once per channel
            if okCount == 0, let err = errSnapshot, !report.botCheckHit {
                let name = channel.name
                let url = channel.url
                let msg = String(err.prefix(120))
                Task { await NotificationsService.shared.postChannelError(channelName: name, channelURL: url, message: msg, appState: appState) }
            }
        }
        return report
    }

    private func postSummaryNotification(
        appState: AppState,
        trigger: PollTrigger,
        totalDownloaded: Int,
        botHit: Bool
    ) async {
        let notificationsEnabled = await MainActor.run { appState.settings.notificationsEnabled }
        guard notificationsEnabled else { return }
        if botHit {
            await NotificationsService.shared.postBotCheck(appState: appState)
            return
        }
        if trigger == .scheduled, totalDownloaded > 0 {
            await NotificationsService.shared.postSuccess(downloaded: totalDownloaded, appState: appState)
        }
    }
}
