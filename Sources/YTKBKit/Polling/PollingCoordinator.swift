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
    private init() {}

    /// Poll all enabled channels sequentially. Idempotent: a second concurrent call
    /// returns immediately if a poll is already running.
    func pollAll(appState: AppState, trigger: PollTrigger = .manual) async {
        if isPolling {
            Logger.shared.info("pollAll: skipped (already polling)")
            return
        }
        isPolling = true
        defer { isPolling = false }

        let (channels, kbRoot, config, kbAvailable) = await MainActor.run {
            appState.refreshKBAvailability()
            return (appState.channelStore.channels, appState.settings.kbDirectory, appState.settings.ytdlpConfig, appState.kbDirectoryAvailable)
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
            }
        }

        let started = kbRoot.startAccessingSecurityScopedResource()
        defer { if started { kbRoot.stopAccessingSecurityScopedResource() } }

        let op = PollOperation(runner: YTDLPRunner.shared, config: config)
        var totalDownloaded = 0
        var botHit = false

        for ch in channels where ch.enabled {
            let priorRetries = await MainActor.run { appState.channelStore.retryEntriesFor(channelURL: ch.url) }
            let report = await pollOneInternal(
                channel: ch,
                op: op,
                kbRoot: kbRoot,
                appState: appState,
                priorRetries: priorRetries
            )
            totalDownloaded += report.counts["ok"] ?? 0
            if report.botCheckHit {
                botHit = true
                break
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
        defer { isPolling = false }

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
        await MainActor.run {
            appState.pollingChannelURL = channel.url
        }
        Logger.shared.info("Polling \(channel.name) (\(channel.url))")
        let report = await op.pollChannel(
            channel: channel,
            kbRoot: kbRoot,
            priorRetries: priorRetries,
            progress: { _ in }
        )

        // Apply retry-queue mutations
        let resolved = report.resolvedRetries
        let newEntries = report.newRetries
        let updatedEntries = report.updatedRetries

        var built = channel
        built.lastPolledAt = Date()
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
