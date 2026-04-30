import Foundation

enum PollOutcome: Equatable {
    case ok(detail: String)
    case skipped
    case noSubs(detail: String)
    case error(message: String)
}

actor PollOperation {
    private let runner: YTDLPRunner
    private let metadata: MetadataFetcher
    private let subs: SubsDownloader
    private let resolver: ChannelResolver

    init(runner: YTDLPRunner, settings: Settings) {
        self.runner = runner
        self.metadata = MetadataFetcher(runner: runner, settings: settings)
        self.subs = SubsDownloader(runner: runner, settings: settings)
        self.resolver = ChannelResolver(runner: runner, settings: settings)
    }

    /// Process one channel: list videos → diff vs existing → for each new, fetch+subs+write.
    /// Calls `progress` with a human label as it advances.
    func pollChannel(
        channel: TrackedChannel,
        kbRoot: URL,
        progress: @Sendable (String) -> Void
    ) async -> (counts: [String: Int], firstError: String?) {
        var counts: [String: Int] = ["ok": 0, "skipped": 0, "no_subs": 0, "error": 0]
        var firstError: String?

        progress("Резолвлю канал…")
        let videos: [VideoRef]
        do {
            videos = try await resolver.listVideos(channelURL: channel.url)
        } catch {
            return (counts, "не удалось получить список видео: \(error)")
        }

        // Pre-scan KB once
        progress("Сканирую базу…")
        let existing = KBScanner.scanExistingIds(in: kbRoot)
        let toProcess = videos.filter { existing[$0.videoId] == nil }
        Logger.shared.info("[\(channel.name)] found \(videos.count) videos, \(toProcess.count) new")

        if toProcess.isEmpty {
            progress("всё уже в базе")
            return (counts, nil)
        }

        for (idx, ref) in toProcess.enumerated() {
            let label = ref.title.map { String($0.prefix(40)) } ?? ref.videoId
            progress("[\(idx + 1)/\(toProcess.count)] \(label)")
            let outcome = await processVideo(ref: ref, kbRoot: kbRoot)
            switch outcome {
            case .ok(let detail):
                counts["ok", default: 0] += 1
                Logger.shared.info("ok · \(label) · \(detail)")
            case .skipped:
                counts["skipped", default: 0] += 1
            case .noSubs(let detail):
                counts["no_subs", default: 0] += 1
                Logger.shared.info("no_subs · \(label) · \(detail)")
            case .error(let msg):
                counts["error", default: 0] += 1
                Logger.shared.error("error · \(label) · \(msg)")
                if firstError == nil { firstError = msg }
                if isBotCheck(msg) {
                    return (counts, "YouTube включил bot-detection. Проверьте, что вы залогинены в YouTube в выбранном браузере.")
                }
            }
        }
        return (counts, firstError)
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

        // Try subs by plan
        let plan = SubsPlanner.buildPlan(meta: meta)
        if plan.attempts.isEmpty {
            return .noSubs(detail: "нет ни авто, ни ручных сабов в метаданных")
        }

        var failures: [String] = []
        let originalLang = meta.language ?? meta.originalLanguage

        for attempt in plan.attempts {
            let kindLabel = attempt.isAuto ? "auto" : "manual"
            // Per-attempt tmp dir
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
                failures.append("\(kindLabel)-subs:\(attempt.langKey) — \(error)")
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

            // Write .md
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
