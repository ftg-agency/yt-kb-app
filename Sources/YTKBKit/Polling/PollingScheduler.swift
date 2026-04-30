import Foundation

/// Schedules background polling via NSBackgroundActivityScheduler.
/// Re-schedules itself when the user changes the interval or toggles the feature.
@MainActor
package final class PollingScheduler {
    private var activity: NSBackgroundActivityScheduler?
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    /// Compute the scheduler tick interval. With per-channel intervals, the
    /// scheduler must fire as often as the most-frequent channel — otherwise
    /// a per-channel "hourly" setting would be capped by a slower global rate.
    /// Take min over global interval and all per-channel non-manual intervals.
    package static func effectiveTickInterval(channels: [TrackedChannel], globalSeconds: TimeInterval) -> TimeInterval {
        let perChannel = channels.compactMap { ch -> TimeInterval? in
            guard let v = ch.pollIntervalSeconds else { return nil }  // uses global already
            if v == 0 { return nil }                                  // manual-only → ignore
            return TimeInterval(v)
        }
        let candidates = [globalSeconds] + perChannel
        return candidates.min() ?? globalSeconds
    }

    func start() {
        stop()
        guard let appState else { return }
        guard appState.settings.backgroundPollingEnabled else {
            Logger.shared.info("Background polling disabled in settings")
            return
        }
        let interval = Self.effectiveTickInterval(
            channels: appState.channelStore.channels,
            globalSeconds: appState.settings.pollInterval.seconds
        )
        let scheduler = NSBackgroundActivityScheduler(identifier: "io.yt-kb.poll")
        scheduler.repeats = true
        scheduler.interval = interval
        scheduler.tolerance = max(60, interval * 0.1)
        scheduler.qualityOfService = .background
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self, let appState = self.appState else {
                    completion(.finished)
                    return
                }
                if appState.settings.isInQuietHours() {
                    Logger.shared.info("Quiet hours: skipping scheduled poll")
                    completion(.deferred)
                    return
                }
                Logger.shared.info("Scheduled poll fired")
                await PollingCoordinator.shared.pollAll(appState: appState, trigger: .scheduled)
                completion(.finished)
            }
        }
        self.activity = scheduler
        Logger.shared.info("Background polling scheduled every \(Int(interval))s")
    }

    func stop() {
        activity?.invalidate()
        activity = nil
    }
}
