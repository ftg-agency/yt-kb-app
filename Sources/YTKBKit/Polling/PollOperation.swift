import Foundation

enum PollOutcome: Equatable {
    case ok(detail: String)
    case skipped
    case noSubs(detail: String)
    case error(message: String)
}

/// Result of polling one channel: counters + first error + retry-queue mutations.
struct PollChannelReport {
    var counts: [String: Int] = ["ok": 0, "skipped": 0, "no_subs": 0, "error": 0]
    var firstError: String?
    var botCheckHit: Bool = false
    var cancelled: Bool = false
    /// YouTube-reported total video count (sum across /videos + /shorts +
    /// /streams). Captured during channel resolve, used by PollingCoordinator
    /// to update TrackedChannel.videoCount.
    var reportedChannelTotal: Int?
    /// True iff this cycle went through a full yt-dlp enumeration (initial
    /// indexing, weekly reconcile, or RSS fallback). PollingCoordinator stamps
    /// `TrackedChannel.lastFullReconcileAt = Date()` when this is true.
    var didFullReconcile: Bool = false
    /// Channel-id (UC...) that we picked up during a full enumeration. nil if
    /// channel went through RSS path (we already had the id). Coordinator
    /// persists this onto `TrackedChannel.channelId` for channels added before
    /// channelId was captured.
    var resolvedChannelId: String?
    /// New entries to add to retry_queue (no_subs videos seen for the first time).
    var newRetries: [RetryQueueEntry] = []
    /// Entries to update (after a retry attempt: success → remove via `resolvedRetries`, no_subs → bump attempts).
    var updatedRetries: [RetryQueueEntry] = []
    /// Retry entries whose video was successfully transcribed; remove from queue.
    var resolvedRetries: [String] = []  // video_ids
    /// Folder name (relative to kbRoot) where this channel's files were
    /// written this cycle. Set when at least one video was processed and the
    /// channel had no pinned `folderName` yet — coordinator persists it onto
    /// `TrackedChannel.folderName` so subsequent polls reuse the same folder.
    var resolvedFolderName: String?
}

/// Lightweight signal emitted from PollOperation each time a video is
/// successfully transcribed and written to disk. PollingCoordinator turns these
/// into recent-videos entries.
package struct IndexedVideoEvent: Sendable {
    package let videoId: String
    package let title: String?
}

/// Per-video processing result. `resolvedFolderName` is the folder name
/// derived from this video's metadata — set when the channel had no pinned
/// folder yet, so the caller can persist it onto TrackedChannel.
private struct VideoProcessOutcome: Sendable {
    let outcome: PollOutcome
    let resolvedFolderName: String?
}

/// Monotonic counter used to drive ChannelProgress.current when videos
/// complete out of order (TaskGroup with sliding window).
private actor ProgressCounter {
    private var value = 0
    func advance() -> Int { value += 1; return value }
}

actor PollOperation {
    private let runner: YTDLPRunner
    private let metadata: MetadataFetcher
    private let subs: SubsDownloader
    private let resolver: ChannelResolver
    private let languagePriority: [String]
    private let maxConcurrentVideos: Int

    package init(runner: YTDLPRunner, config: YTDLPConfig, maxConcurrentVideos: Int = 5) {
        self.runner = runner
        self.metadata = MetadataFetcher(runner: runner, config: config)
        self.subs = SubsDownloader(runner: runner, config: config)
        self.resolver = ChannelResolver(runner: runner, config: config)
        self.languagePriority = config.languagePriority
        self.maxConcurrentVideos = max(1, min(8, maxConcurrentVideos))
    }

    /// Process one channel: list videos → diff vs existing → for each new, fetch+subs+write.
    /// Also attempts re-download for `priorRetries` whose backoff has expired.
    /// `progress` is called with structured ChannelProgress events that the UI
    /// turns into a per-row progress bar.
    func pollChannel(
        channel: TrackedChannel,
        kbRoot: URL,
        priorRetries: [RetryQueueEntry],
        cancellation: CancellationFlag,
        progress: @Sendable (ChannelProgress) -> Void,
        onIndexed: (@Sendable (IndexedVideoEvent) -> Void)? = nil
    ) async -> PollChannelReport {
        var report = PollChannelReport()
        let isInitial = channel.lastPolledAt == nil
        let tStart = Date()

        if cancellation.isCancelled { report.cancelled = true; return report }

        progress(ChannelProgress(phase: .resolving, current: 0, total: 0, label: nil, isInitialIndexing: isInitial))

        // === Pick listing path ===
        // - First-ever poll on this channel → full enumeration (we want
        //   everything historical).
        // - lastFullReconcileAt missing or older than 7 days → full enum as
        //   a safety net against missed RSS deltas.
        // - channelId missing (channel added before we captured it) → full
        //   enum so we can populate it.
        // - otherwise → RSS feed, fallback to full on any RSS error.
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        let needsWeeklyReconcile = (channel.lastFullReconcileAt ?? .distantPast) < weekAgo
        let hasChannelId = (channel.channelId?.hasPrefix("UC") == true)
        let preferFull = isInitial || needsWeeklyReconcile || !hasChannelId

        let pathDecision = preferFull
            ? "full (isInitial=\(isInitial) weekly=\(needsWeeklyReconcile) hasChId=\(hasChannelId))"
            : "rss (channelId=\(channel.channelId!.prefix(20)))"
        Logger.shared.info("pollChannel ▶ [\(channel.name)] path=\(pathDecision) lastPolled=\(channel.lastPolledAt.map { "\($0)" } ?? "never")")

        let videos: [VideoRef]
        let reportedTotal: Int?
        var didFullEnum = false
        let tResolve = Date()

        if preferFull {
            do {
                let resolved = try await resolver.resolveMetadata(channelURL: channel.url)
                videos = resolved.videos
                reportedTotal = resolved.reportedTotalCount
                report.reportedChannelTotal = reportedTotal
                report.resolvedChannelId = resolved.channelId
                didFullEnum = true
                Logger.shared.info("pollChannel · [\(channel.name)] full resolve ok in \(msSince(tResolve)): videos=\(videos.count) reported=\(reportedTotal.map(String.init) ?? "—")")
            } catch {
                if cancellation.isCancelled { report.cancelled = true; return report }
                Logger.shared.error("pollChannel · [\(channel.name)] full resolve FAIL in \(msSince(tResolve)): \(error)")
                report.firstError = "не удалось получить список видео: \(error)"
                report.botCheckHit = isBotCheck(report.firstError ?? "")
                return report
            }
        } else {
            do {
                let rss = try await RSSFetcher.shared.fetchLatest(channelId: channel.channelId!)
                videos = rss.map { VideoRef(videoId: $0.videoId, title: $0.title) }
                reportedTotal = nil
                didFullEnum = false
                Logger.shared.info("pollChannel · [\(channel.name)] RSS ok in \(msSince(tResolve)): \(videos.count) видео")
            } catch {
                Logger.shared.warn("pollChannel · [\(channel.name)] RSS FAIL (\(error)) — fallback to full enumeration")
                let tFull = Date()
                do {
                    let resolved = try await resolver.resolveMetadata(channelURL: channel.url)
                    videos = resolved.videos
                    reportedTotal = resolved.reportedTotalCount
                    report.reportedChannelTotal = reportedTotal
                    report.resolvedChannelId = resolved.channelId
                    didFullEnum = true
                    Logger.shared.info("pollChannel · [\(channel.name)] fallback full resolve ok in \(msSince(tFull))")
                } catch {
                    if cancellation.isCancelled { report.cancelled = true; return report }
                    Logger.shared.error("pollChannel · [\(channel.name)] fallback full ALSO FAIL: \(error)")
                    report.firstError = "RSS + full enumeration оба упали: \(error)"
                    report.botCheckHit = isBotCheck(report.firstError ?? "")
                    return report
                }
            }
        }
        report.didFullReconcile = didFullEnum

        if cancellation.isCancelled { report.cancelled = true; return report }

        progress(ChannelProgress(phase: .scanning, current: 0, total: 0, label: nil, isInitialIndexing: isInitial, reportedChannelTotal: reportedTotal))
        let existing = KBScanner.scanExistingIds(in: kbRoot)
        let retryIds = Set(priorRetries.map(\.videoId))
        let toProcess = videos.filter { existing[$0.videoId] == nil && !retryIds.contains($0.videoId) }
        let reportedSummary = reportedTotal.map { " channelTotal=\($0)" } ?? ""
        let pathLabel = didFullEnum ? "full" : "rss"
        Logger.shared.info("[\(channel.name)] source=\(pathLabel) found=\(videos.count) new=\(toProcess.count) retries=\(priorRetries.count)\(reportedSummary)")

        let eligible = RetryProcessor.eligibleEntries(priorRetries)
        let totalSteps = toProcess.count + eligible.count
        let counter = ProgressCounter()
        Logger.shared.info("pollChannel · [\(channel.name)] toProcess=\(toProcess.count) eligibleRetries=\(eligible.count) maxParallel=\(maxConcurrentVideos)")

        // === New videos in parallel ===
        if !toProcess.isEmpty {
            await runParallel(
                items: toProcess.map { ($0, nil as RetryQueueEntry?) },
                isRetry: false,
                totalSteps: totalSteps,
                isInitial: isInitial,
                reportedTotal: reportedTotal,
                kbRoot: kbRoot,
                channel: channel,
                cancellation: cancellation,
                counter: counter,
                progress: progress,
                onIndexed: onIndexed,
                report: &report
            )
        }
        if report.botCheckHit || report.cancelled { return report }

        // === Retry queue in parallel (after new videos finish) ===
        if !eligible.isEmpty {
            Logger.shared.info("pollChannel · [\(channel.name)] processing \(eligible.count) retries")
            let items = eligible.map { (VideoRef(videoId: $0.videoId, title: $0.videoTitle), $0 as RetryQueueEntry?) }
            await runParallel(
                items: items,
                isRetry: true,
                totalSteps: totalSteps,
                isInitial: false,
                reportedTotal: reportedTotal,
                kbRoot: kbRoot,
                channel: channel,
                cancellation: cancellation,
                counter: counter,
                progress: progress,
                onIndexed: onIndexed,
                report: &report
            )
        }

        Logger.shared.info("pollChannel ◀ [\(channel.name)] DONE in \(msSince(tStart)) · ok=\(report.counts["ok"] ?? 0) skipped=\(report.counts["skipped"] ?? 0) noSubs=\(report.counts["no_subs"] ?? 0) error=\(report.counts["error"] ?? 0) botCheck=\(report.botCheckHit)")
        return report
    }

    nonisolated private func msSince(_ date: Date) -> String {
        "\(Int(Date().timeIntervalSince(date) * 1000))ms"
    }

    /// Sliding-window TaskGroup over a list of video refs. Mutations of
    /// `report` happen on the consumer side of `group.next()` so there are no
    /// data races — TaskGroup children just call processVideo and return.
    private func runParallel(
        items: [(VideoRef, RetryQueueEntry?)],
        isRetry: Bool,
        totalSteps: Int,
        isInitial: Bool,
        reportedTotal: Int?,
        kbRoot: URL,
        channel: TrackedChannel,
        cancellation: CancellationFlag,
        counter: ProgressCounter,
        progress: @Sendable (ChannelProgress) -> Void,
        onIndexed: (@Sendable (IndexedVideoEvent) -> Void)?,
        report: inout PollChannelReport
    ) async {
        let maxConc = maxConcurrentVideos
        let phase: ChannelProgress.Phase = isRetry ? .retrying : .processing

        // Pull a snapshot from inout into local lets so we can read/write
        // report without the body closure capturing inout from the outer
        // function — Swift 6's strict concurrency dislikes inout captures
        // crossing the withTaskGroup body boundary. Merge back at the end.
        var localReport = report
        let kb = kbRoot
        let ch = channel

        await withTaskGroup(of: (VideoRef, RetryQueueEntry?, VideoProcessOutcome).self) { group in
            var nextIndex = 0
            var inFlight = 0
            var stopped = false

            // Seed initial burst
            while inFlight < maxConc && nextIndex < items.count && !stopped {
                if cancellation.isCancelled { stopped = true; break }
                let (ref, priorEntry) = items[nextIndex]
                nextIndex += 1
                inFlight += 1
                group.addTask { [self] in
                    let outcome = await self.processVideo(ref: ref, kbRoot: kb, channel: ch)
                    return (ref, priorEntry, outcome)
                }
            }

            while let (ref, priorEntry, vpo) = await group.next() {
                inFlight -= 1
                let current = await counter.advance()
                let label = ref.title.map { String($0.prefix(60)) } ?? ref.videoId
                progress(ChannelProgress(
                    phase: phase,
                    current: current,
                    total: totalSteps,
                    label: label,
                    isInitialIndexing: isInitial,
                    reportedChannelTotal: reportedTotal
                ))

                applyOutcome(
                    vpo.outcome,
                    ref: ref,
                    channelURL: ch.url,
                    channelName: ch.name,
                    isRetry: isRetry,
                    report: &localReport,
                    priorEntry: priorEntry
                )

                if localReport.resolvedFolderName == nil, let pin = vpo.resolvedFolderName {
                    localReport.resolvedFolderName = pin
                }
                if case .ok = vpo.outcome {
                    onIndexed?(IndexedVideoEvent(videoId: ref.videoId, title: ref.title))
                }
                if cancellation.isCancelled {
                    localReport.cancelled = true
                    stopped = true
                    group.cancelAll()
                    continue
                }
                if localReport.botCheckHit {
                    stopped = true
                    group.cancelAll()
                    continue
                }

                // Refill the window
                while inFlight < maxConc && nextIndex < items.count && !stopped {
                    if cancellation.isCancelled { stopped = true; break }
                    let (ref2, priorEntry2) = items[nextIndex]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask { [self] in
                        let outcome = await self.processVideo(ref: ref2, kbRoot: kb, channel: ch)
                        return (ref2, priorEntry2, outcome)
                    }
                }
            }
        }

        report = localReport
    }

    private func applyOutcome(
        _ outcome: PollOutcome,
        ref: VideoRef,
        channelURL: String,
        channelName: String,
        isRetry: Bool,
        report: inout PollChannelReport,
        priorEntry: RetryQueueEntry? = nil
    ) {
        let label = ref.title.map { String($0.prefix(40)) } ?? ref.videoId
        switch outcome {
        case .ok(let detail):
            report.counts["ok", default: 0] += 1
            Logger.shared.info("ok · \(label) · \(detail)")
            if isRetry { report.resolvedRetries.append(ref.videoId) }
        case .skipped:
            report.counts["skipped", default: 0] += 1
        case .noSubs(let detail):
            report.counts["no_subs", default: 0] += 1
            Logger.shared.info("no_subs · \(label) · \(detail)")
            if isRetry, let prior = priorEntry {
                var updated = prior
                updated.attempts += 1
                updated.lastAttempt = Date()
                if RetryProcessor.shouldMarkPermanent(updated) {
                    updated.status = "permanent_no_subs"
                }
                report.updatedRetries.append(updated)
            } else {
                let entry = RetryQueueEntry(
                    channelURL: channelURL,
                    videoId: ref.videoId,
                    videoTitle: ref.title,
                    firstSeen: Date(),
                    lastAttempt: Date(),
                    attempts: 1,
                    status: "no_subs"
                )
                report.newRetries.append(entry)
            }
        case .error(let msg):
            report.counts["error", default: 0] += 1
            Logger.shared.error("error · \(label) · \(msg)")
            if report.firstError == nil { report.firstError = msg }
            if isBotCheck(msg) {
                report.botCheckHit = true
            }
        }
    }

    /// One-video pipeline: fetch metadata → download subs → render markdown →
    /// atomic write → rebuild channel index. Pure async (no actor isolation),
    /// safe to invoke concurrently from a TaskGroup.
    nonisolated private func processVideo(ref: VideoRef, kbRoot: URL, channel: TrackedChannel) async -> VideoProcessOutcome {
        let tStart = Date()
        let videoURL = ref.url
        Logger.shared.info("processVideo ▶ \(ref.videoId) · \(ref.title?.prefix(60) ?? "—")")
        let meta: VideoMetadata
        let tMeta = Date()
        do {
            meta = try await metadata.fetch(url: videoURL)
            Logger.shared.info("processVideo · \(ref.videoId) meta ok in \(msSince(tMeta))")
        } catch {
            Logger.shared.warn("processVideo · \(ref.videoId) meta FAIL in \(msSince(tMeta)): \(error)")
            return VideoProcessOutcome(outcome: .error(message: "метаданные: \(error)"), resolvedFolderName: nil)
        }

        let derivedDir = FileNaming.channelDirName(meta: meta)
        let dirName = channel.folderName ?? derivedDir
        let channelDir = kbRoot.appendingPathComponent(dirName)
        let videoFileName = FileNaming.videoFileName(meta: meta)
        let videoPath = channelDir.appendingPathComponent(videoFileName)
        if FileManager.default.fileExists(atPath: videoPath.path) {
            return VideoProcessOutcome(outcome: .skipped, resolvedFolderName: nil)
        }

        let plan = SubsPlanner.buildPlan(meta: meta, languagePriority: languagePriority)
        if plan.attempts.isEmpty {
            Logger.shared.info("processVideo · \(ref.videoId) no-subs (empty plan) in \(msSince(tStart))")
            return VideoProcessOutcome(
                outcome: .noSubs(detail: "нет ни авто, ни ручных сабов в метаданных"),
                resolvedFolderName: nil
            )
        }
        Logger.shared.info("processVideo · \(ref.videoId) plan=\(plan.attempts.count) attempts")

        var failures: [String] = []
        let originalLang = meta.language ?? meta.originalLanguage

        for attempt in plan.attempts {
            let kindLabel = attempt.isAuto ? "auto" : "manual"
            let tAttempt = Date()
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ytkb-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let downloaded: DownloadedSubFile
            do {
                downloaded = try await subs.download(
                    url: videoURL,
                    langKey: attempt.langKey,
                    isAuto: attempt.isAuto,
                    into: tmpDir
                )
            } catch {
                let msg = "\(kindLabel)-subs:\(attempt.langKey) — \(error)"
                failures.append(msg)
                Logger.shared.warn("processVideo · \(ref.videoId) subs FAIL (\(kindLabel) \(attempt.langKey)) in \(msSince(tAttempt)): \(error)")
                if isBotCheck("\(error)") {
                    Logger.shared.error("processVideo · \(ref.videoId) BOT-CHECK detected, aborting")
                    return VideoProcessOutcome(outcome: .error(message: "\(error)"), resolvedFolderName: nil)
                }
                continue
            }

            let segments = SubsDispatcher.parse(downloaded)
            if segments.isEmpty {
                failures.append("\(kindLabel)-subs:\(attempt.langKey) — \(downloaded.ext) скачался, но 0 сегментов")
                Logger.shared.warn("processVideo · \(ref.videoId) subs empty (\(kindLabel) \(attempt.langKey))")
                continue
            }
            Logger.shared.info("processVideo · \(ref.videoId) subs ok (\(kindLabel) \(attempt.langKey)) → \(segments.count) segments in \(msSince(tAttempt))")

            let isFallback = SubsPlanner.isFallback(attempt.langKey, original: originalLang)
            let transcript = Transcript(
                segments: segments,
                language: attempt.langKey,
                source: attempt.isAuto ? "auto-subs" : "manual-subs",
                isFallback: isFallback
            )

            do {
                try FileManager.default.createDirectory(at: channelDir, withIntermediateDirectories: true)
                let body = MarkdownRenderer.render(meta: meta, transcript: transcript)
                let tmp = videoPath.appendingPathExtension("tmp")
                try body.write(to: tmp, atomically: true, encoding: .utf8)
                _ = try FileManager.default.replaceItemAt(videoPath, withItemAt: tmp)
            } catch {
                return VideoProcessOutcome(outcome: .error(message: "запись файла: \(error)"), resolvedFolderName: nil)
            }

            ChannelIndexBuilder.rebuild(
                channelDir: channelDir,
                channelName: meta.displayChannel,
                channelURL: meta.displayChannelURL
            )

            var detail = "\(transcript.source):\(attempt.langKey) (\(segments.count) сегм.)"
            if isFallback {
                detail += " [fallback с \(originalLang ?? "?")]"
            }
            // Return derived folder name only when channel had no prior pin —
            // consumer will persist it onto TrackedChannel.
            let folderPin = channel.folderName == nil ? derivedDir : nil
            Logger.shared.info("processVideo ◀ \(ref.videoId) OK total \(msSince(tStart))")
            return VideoProcessOutcome(outcome: .ok(detail: detail), resolvedFolderName: folderPin)
        }

        let first = failures.first.map { String($0.prefix(140)) } ?? "никаких субтитров"
        let extra = failures.count > 1 ? " (+\(failures.count - 1) ещё)" : ""
        Logger.shared.info("processVideo ◀ \(ref.videoId) no-subs total \(msSince(tStart))")
        return VideoProcessOutcome(outcome: .noSubs(detail: first + extra), resolvedFolderName: nil)
    }

    private nonisolated func isBotCheck(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("sign in to confirm") || m.contains("not a bot")
    }
}
