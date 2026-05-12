import Foundation

enum PollTrigger {
    case manual
    case manualSingle
    case scheduled
    case wake
}

/// Coordinator for channel polls. Maintains a FIFO queue and a single worker
/// loop that drains it. Channels enqueued while a worker is running are picked
/// up by that same worker — so "add a channel mid-poll" works without any
/// scheduler tick. Cancellation flushes the queue and SIGTERMs subprocesses.
actor PollingCoordinator {
    static let shared = PollingCoordinator()

    package let cancellation = CancellationFlag()

    /// FIFO queue of channels waiting to be polled. Deduped by URL. Mutated
    /// only inside actor-isolated methods.
    private var queue: [TrackedChannel] = []
    /// URLs currently being processed (in-flight in the worker's TaskGroup).
    private var inflight: Set<String> = []
    /// True iff a worker loop is running. Set synchronously inside ensureWorker
    /// so concurrent callers never spawn duplicate workers.
    private var workerRunning = false

    private init() {}

    /// Stop the current cycle ASAP. Drops all queued channels, sets the
    /// cancellation flag (checked between videos by PollOperation) and SIGTERMs
    /// every running yt-dlp subprocess so blocking calls return immediately.
    package func cancel() async {
        Logger.shared.info("Cancellation requested by user")
        cancellation.cancel()
        queue.removeAll()
        await YTDLPRunner.shared.terminateAll()
    }

    /// Enqueue a single channel. Always succeeds — if a worker is already
    /// running, the channel joins the queue and is processed in turn. The
    /// previous behaviour (silent drop on `isPolling==true`) caused channels
    /// added mid-cycle to never be polled until the next scheduler tick.
    func pollOne(channel: TrackedChannel, appState: AppState) async {
        enqueueIfNeeded(channel)
        publishQueueSize(appState: appState)
        ensureWorker(appState: appState, trigger: .manualSingle)
    }

    /// Enqueue every eligible channel in a single batch. For `.scheduled` only
    /// channels whose per-channel interval is due are added.
    func pollAll(appState: AppState, trigger: PollTrigger = .manual) async {
        let channels = await MainActor.run { () -> [TrackedChannel] in
            switch trigger {
            case .scheduled, .wake:
                let globalSec = appState.settings.pollInterval.seconds
                let now = Date()
                return appState.channelStore.channels.filter { ch in
                    ch.enabled && ch.isDueForScheduledPoll(now: now, globalSeconds: globalSec)
                }
            case .manual, .manualSingle:
                return appState.channelStore.channels.filter { $0.enabled }
            }
        }
        for ch in channels { enqueueIfNeeded(ch) }
        publishQueueSize(appState: appState)
        ensureWorker(appState: appState, trigger: trigger)
    }

    private func enqueueIfNeeded(_ channel: TrackedChannel) {
        if inflight.contains(channel.url) { return }
        if queue.contains(where: { $0.url == channel.url }) { return }
        queue.append(channel)
    }

    private func publishQueueSize(appState: AppState) {
        let count = queue.count
        Task { @MainActor in appState.queuedChannelCount = count }
    }

    /// Ensure exactly one worker loop is running. If `workerRunning` is already
    /// true the current worker will pick up newly-queued items naturally.
    private func ensureWorker(appState: AppState, trigger: PollTrigger) {
        if workerRunning { return }
        workerRunning = true
        Task { [weak self] in
            await self?.runWorker(appState: appState, initialTrigger: trigger)
        }
    }

    /// Drain the queue until empty (or cancelled / bot-checked). Holds power
    /// activity, KB security-scoped access, and publishes the polling state.
    /// Channels enqueued during awaits inside this loop ARE picked up — the
    /// `while !queue.isEmpty` check re-evaluates after every batch.
    private func runWorker(appState: AppState, initialTrigger: PollTrigger) async {
        let tWorkerStart = Date()
        Logger.shared.info("runWorker ▶ trigger=\(initialTrigger) queue=\(queue.count)")
        defer {
            workerRunning = false
            Logger.shared.info("runWorker ◀ done in \(Int(Date().timeIntervalSince(tWorkerStart) * 1000))ms")
        }
        cancellation.reset()

        let (kbRoot, config, kbAvailable) = await MainActor.run {
            appState.refreshKBAvailability()
            return (appState.settings.kbDirectory, appState.settings.ytdlpConfig, appState.kbDirectoryAvailable)
        }
        guard let kbRoot else {
            await MainActor.run { appState.lastError = "База знаний не настроена" }
            queue.removeAll()
            await MainActor.run { appState.queuedChannelCount = 0 }
            return
        }
        guard kbAvailable else {
            await MainActor.run { appState.lastError = "Папка базы знаний недоступна (диск отключён?)" }
            Logger.shared.warn("runWorker: KB unreachable, polling paused until directory comes back")
            queue.removeAll()
            await MainActor.run { appState.queuedChannelCount = 0 }
            return
        }

        let preventSleep = await MainActor.run { appState.settings.preventSleepDuringPoll }
        let activityToken: NSObjectProtocol? = preventSleep
            ? ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "yt-kb: indexing channels"
            )
            : nil
        defer { if let activityToken { ProcessInfo.processInfo.endActivity(activityToken) } }

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
                appState.queuedChannelCount = 0
            }
        }

        let started = kbRoot.startAccessingSecurityScopedResource()
        defer { if started { kbRoot.stopAccessingSecurityScopedResource() } }

        // Parallelism is hardcoded — see plan: один канал в работе (FIFO
        // очередь), 5 видео параллельно внутри канала. Default from
        // PollOperation init is 5.
        let op = PollOperation(runner: YTDLPRunner.shared, config: config)
        var totalDownloaded = 0
        var botHit = false

        // Outer loop drains the queue. We may exit it briefly to await on
        // post-cycle housekeeping, then re-check — channels enqueued during
        // those awaits would otherwise hang until the next manual trigger.
        drain: while true {
            while !queue.isEmpty {
                if cancellation.isCancelled { queue.removeAll(); break drain }
                // Hardcoded — один канал в работе, остальные в FIFO очереди.
                let maxConcurrent = 1
                let batchSize = min(maxConcurrent, queue.count)
                let batch = Array(queue.prefix(batchSize))
                queue.removeFirst(batchSize)
                for ch in batch { inflight.insert(ch.url) }
                publishQueueSize(appState: appState)
                Logger.shared.info("runWorker · batch=\(batch.count) (\(batch.map(\.name).joined(separator: ", "))) maxConcChannels=\(maxConcurrent)")

                let reports = await withTaskGroup(of: PollChannelReport.self, returning: [PollChannelReport].self) { group in
                    for ch in batch {
                        group.addTask { [self] in
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
                for ch in batch { inflight.remove(ch.url) }
                for report in reports {
                    totalDownloaded += report.counts["ok"] ?? 0
                    if report.botCheckHit { botHit = true; queue.removeAll(); break drain }
                }
                publishQueueSize(appState: appState)
            }

            // Stamp last successful scheduled run for the wake observer.
            if initialTrigger == .scheduled || initialTrigger == .wake {
                let now = Date()
                await MainActor.run { appState.settings.setLastScheduledRunAt(now) }
            }
            // Re-check queue after that await — anything enqueued during the
            // suspension is processed before we exit and clear workerRunning.
            if queue.isEmpty { break drain }
        }

        Logger.shared.info("Poll cycle done: downloaded=\(totalDownloaded) botHit=\(botHit) trigger=\(initialTrigger)")
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
            },
            onIndexed: { [channel] indexed in
                Logger.shared.info("indexed · \(channel.name) · \(indexed.videoId) · \(indexed.title ?? "—")")
            }
        )
        await MainActor.run {
            appState.channelProgress[channelURL] = nil
        }

        let resolved = report.resolvedRetries
        let newEntries = report.newRetries
        let updatedEntries = report.updatedRetries

        var built = channel
        built.lastPolledAt = Date()
        if let total = report.reportedChannelTotal {
            built.videoCount = total
        }
        if built.folderName == nil, let resolvedFolder = report.resolvedFolderName {
            built.folderName = resolvedFolder
        }
        if built.channelId == nil, let rid = report.resolvedChannelId, !rid.isEmpty {
            built.channelId = rid
        }
        if report.didFullReconcile {
            built.lastFullReconcileAt = Date()
        }
        let okCount = report.counts["ok"] ?? 0
        let skippedCount = report.counts["skipped"] ?? 0
        built.lastPollDownloaded = okCount
        built.lastPollSkipped = skippedCount
        // Count actual files on disk so the X/Y badge reflects reality after
        // each cycle — not just incremental deltas. Cheap (one folder enum).
        if let folder = built.folderName {
            let dir = kbRoot.appendingPathComponent(folder)
            built.indexedCount = KBScanner.countIndexedVideos(in: dir)
        }
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
            if report.botCheckHit {
                appState.botCheckActive = true
            } else if okCount > 0 {
                appState.botCheckActive = false
            }
        }
        return report
    }
}
