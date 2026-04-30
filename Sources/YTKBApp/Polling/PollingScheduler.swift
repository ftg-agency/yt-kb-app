import Foundation

/// Schedules background polling via NSBackgroundActivityScheduler.
/// Re-schedules itself when the user changes the interval or toggles the feature.
@MainActor
final class PollingScheduler {
    private var activity: NSBackgroundActivityScheduler?
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        stop()
        guard let appState else { return }
        guard appState.settings.backgroundPollingEnabled else {
            Logger.shared.info("Background polling disabled in settings")
            return
        }
        let interval = appState.settings.pollInterval.seconds
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
