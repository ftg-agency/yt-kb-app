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
    /// New entries to add to retry_queue (no_subs videos seen for the first time).
    var newRetries: [RetryQueueEntry] = []
    /// Entries to update (after a retry attempt: success → remove via `resolvedRetries`, no_subs → bump attempts).
    var updatedRetries: [RetryQueueEntry] = []
    /// Retry entries whose video was successfully transcribed; remove from queue.
    var resolvedRetries: [String] = []  // video_ids
}

actor PollOperation {
    private let runner: YTDLPRunner
    private let metadata: MetadataFetcher
    private let subs: SubsDownloader
    private let resolver: ChannelResolver
    private let languagePriority: [String]

    init(runner: YTDLPRunner, settings: Settings) {
        self.runner = runner
        self.metadata = MetadataFetcher(runner: runner, settings: settings)
        self.subs = SubsDownloader(runner: runner, settings: settings)
        self.resolver = ChannelResolver(runner: runner, settings: settings)
        self.languagePriority = settings.languagePriority
    }

    /// Process one channel: list videos → diff vs existing → for each new, fetch+subs+write.
    /// Also attempts re-download for `priorRetries` whose backoff has expired.
    func pollChannel(
        channel: TrackedChannel,
        kbRoot: URL,
        priorRetries: [RetryQueueEntry],
        progress: @Sendable (String) -> Void
    ) async -> PollChannelReport {
        var report = PollChannelReport()

        progress("Резолвлю канал…")
        let videos: [VideoRef]
        do {
            videos = try await resolver.listVideos(channelURL: channel.url)
        } catch {
            report.firstError = "не удалось получить список видео: \(error)"
            report.botCheckHit = isBotCheck(report.firstError ?? "")
            return report
        }

        progress("Сканирую базу…")
        let existing = KBScanner.scanExistingIds(in: kbRoot)
        let retryIds = Set(priorRetries.map(\.videoId))
        let toProcess = videos.filter { existing[$0.videoId] == nil && !retryIds.contains($0.videoId) }
        Logger.shared.info("[\(channel.name)] found=\(videos.count) new=\(toProcess.count) retries=\(priorRetries.count)")

        // First, process new videos
        for (idx, ref) in toProcess.enumerated() {
            let label = ref.title.map { String($0.prefix(40)) } ?? ref.videoId
            progress("[\(idx + 1)/\(toProcess.count)] \(label)")
            let outcome = await processVideo(ref: ref, kbRoot: kbRoot)
            applyOutcome(outcome, ref: ref, channelURL: channel.url, channelName: channel.name, isRetry: false, report: &report)
            if report.botCheckHit { return report }
        }

        // Then, process eligible retry-queue entries
        let eligible = RetryProcessor.eligibleEntries(priorRetries)
        if !eligible.isEmpty {
            Logger.shared.info("[\(channel.name)] processing \(eligible.count) retry entries")
        }
        for (idx, entry) in eligible.enumerated() {
            let ref = VideoRef(videoId: entry.videoId, title: entry.videoTitle)
            let label = entry.videoTitle.map { String($0.prefix(40)) } ?? entry.videoId
            progress("[retry \(idx + 1)/\(eligible.count)] \(label)")
            let outcome = await processVideo(ref: ref, kbRoot: kbRoot)
            applyOutcome(outcome, ref: ref, channelURL: channel.url, channelName: channel.name, isRetry: true, report: &report, priorEntry: entry)
            if report.botCheckHit { return report }
        }

        return report
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

    private func processVideo(ref: VideoRef, kbRoot: URL) async -> PollOutcome {
        let videoURL = ref.url
        let meta: VideoMetadata
        do {
            meta = try await metadata.fetch(url: videoURL)
        } catch {
            return .error(message: "метаданные: \(error)")
        }

        let channelDir = kbRoot.appendingPathComponent(FileNaming.channelDirName(meta: meta))
        let videoFileName = FileNaming.videoFileName(meta: meta)
        let videoPath = channelDir.appendingPathComponent(videoFileName)
        if FileManager.default.fileExists(atPath: videoPath.path) {
            return .skipped
        }

        let plan = SubsPlanner.buildPlan(meta: meta, languagePriority: languagePriority)
        if plan.attempts.isEmpty {
            return .noSubs(detail: "нет ни авто, ни ручных сабов в метаданных")
        }

        var failures: [String] = []
        let originalLang = meta.language ?? meta.originalLanguage

        for attempt in plan.attempts {
            let kindLabel = attempt.isAuto ? "auto" : "manual"
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
                if isBotCheck("\(error)") {
                    return .error(message: "\(error)")
                }
                continue
            }

            let segments = SubsDispatcher.parse(downloaded)
            if segments.isEmpty {
                failures.append("\(kindLabel)-subs:\(attempt.langKey) — \(downloaded.ext) скачался, но 0 сегментов")
                continue
            }

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
                return .error(message: "запись файла: \(error)")
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
            return .ok(detail: detail)
        }

        let first = failures.first.map { String($0.prefix(140)) } ?? "никаких субтитров"
        let extra = failures.count > 1 ? " (+\(failures.count - 1) ещё)" : ""
        return .noSubs(detail: first + extra)
    }

    private func isBotCheck(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("sign in to confirm") || m.contains("not a bot")
    }
}
