import Foundation

/// Owns the singleton actor that prevents overlapping polls.
actor PollingCoordinator {
    static let shared = PollingCoordinator()

    private var isPolling = false

    private init() {}

    /// Poll all enabled channels sequentially. Idempotent: a second concurrent call
    /// returns immediately if a poll is already running.
    func pollAll(appState: AppState) async {
        if isPolling {
            Logger.shared.info("pollAll: skipped (already polling)")
            return
        }
        isPolling = true
        defer { isPolling = false }

        let (channels, kbRoot, settings) = await MainActor.run {
            (appState.channelStore.channels, appState.settings.kbDirectory, appState.settings)
        }
        guard let kbRoot else {
            await MainActor.run { appState.lastError = "База знаний не настроена" }
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

        // Hold security-scoped access for the duration
        let started = kbRoot.startAccessingSecurityScopedResource()
        defer { if started { kbRoot.stopAccessingSecurityScopedResource() } }

        let op = PollOperation(runner: YTDLPRunner.shared, settings: settings)
        for ch in channels where ch.enabled {
            await pollOneInternal(channel: ch, op: op, kbRoot: kbRoot, appState: appState)
        }
    }

    func pollOne(channel: TrackedChannel, appState: AppState) async {
        if isPolling {
            Logger.shared.info("pollOne: skipped (already polling)")
            return
        }
        isPolling = true
        defer { isPolling = false }

        let (kbRoot, settings) = await MainActor.run {
            (appState.settings.kbDirectory, appState.settings)
        }
        guard let kbRoot else {
            await MainActor.run { appState.lastError = "База знаний не настроена" }
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

        let op = PollOperation(runner: YTDLPRunner.shared, settings: settings)
        await pollOneInternal(channel: channel, op: op, kbRoot: kbRoot, appState: appState)
    }

    private func pollOneInternal(
        channel: TrackedChannel,
        op: PollOperation,
        kbRoot: URL,
        appState: AppState
    ) async {
        await MainActor.run {
            appState.pollingChannelURL = channel.url
        }
        Logger.shared.info("Polling \(channel.name) (\(channel.url))")
        let (counts, firstError) = await op.pollChannel(
            channel: channel,
            kbRoot: kbRoot,
            progress: { _ in /* future: per-step UI updates */ }
        )

        var built = channel
        built.lastPolledAt = Date()
        if let err = firstError, (counts["ok"] ?? 0) == 0 {
            built.lastPollStatus = "error"
            built.lastPollError = String(err.prefix(200))
        } else {
            built.lastPollStatus = "ok"
            built.lastPollError = nil
        }
        let updated = built
        let summary = counts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        Logger.shared.info("Poll done: \(channel.name) · \(summary)")
        let okCount = counts["ok"] ?? 0
        let errSnapshot = firstError
        await MainActor.run {
            appState.channelStore.updateChannel(updated)
            if okCount == 0, let err = errSnapshot {
                appState.lastError = err
            }
        }
    }
}
