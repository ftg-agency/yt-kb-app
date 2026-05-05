import Foundation
import Combine

final class Settings: ObservableObject {
    enum BrowserChoice: String, CaseIterable, Identifiable {
        case chrome, safari, firefox, brave, edge, opera, vivaldi, none
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .chrome: return "Chrome"
            case .safari: return "Safari"
            case .firefox: return "Firefox"
            case .brave: return "Brave"
            case .edge: return "Edge"
            case .opera: return "Opera"
            case .vivaldi: return "Vivaldi"
            case .none: return "Без cookies"
            }
        }
        var ytDlpKey: String? { self == .none ? nil : rawValue }
    }

    enum PollInterval: Int, CaseIterable, Identifiable {
        case hourly = 3600
        case every3h = 10800
        case every6h = 21600
        case daily = 86400
        var id: Int { rawValue }
        var displayName: String {
            switch self {
            case .hourly: return "Каждый час"
            case .every3h: return "Каждые 3 часа"
            case .every6h: return "Каждые 6 часов"
            case .daily: return "Раз в день"
            }
        }
        /// Lowercase short form used inside other labels.
        var shortLabel: String {
            switch self {
            case .hourly: return "каждый час"
            case .every3h: return "каждые 3 часа"
            case .every6h: return "каждые 6 часов"
            case .daily: return "раз в день"
            }
        }
        var seconds: TimeInterval { TimeInterval(rawValue) }
    }

    private let defaults = UserDefaults.standard
    private struct Keys {
        static let kbBookmark = "kbBookmark"
        static let browser = "browser"
        static let sleepRequests = "sleepRequests"
        static let onboardingCompleted = "onboardingCompleted"
        static let pollInterval = "pollInterval"
        static let backgroundPollingEnabled = "backgroundPollingEnabled"
        static let notificationsEnabled = "notificationsEnabled"
        static let quietHoursEnabled = "quietHoursEnabled"
        static let quietHoursStart = "quietHoursStart"  // 0..23
        static let quietHoursEnd = "quietHoursEnd"
        static let languagePriority = "languagePriority"  // [String], top-down
        static let preventSleepDuringPoll = "preventSleepDuringPoll"
        static let maxConcurrentChannels = "maxConcurrentChannels"
        static let autoUpdateEnabled = "autoUpdateEnabled"
        static let kbConsolidationVersion = "kbConsolidationVersion"
        static let launchAtLogin = "launchAtLogin"
        static let launchAtLoginPrompted = "launchAtLoginPrompted"
        static let lastScheduledRunAt = "lastScheduledRunAt"
        static let lastDigestPostedAt = "lastDigestPostedAt"
    }

    /// Bump when a new one-time KB-layout migration ships. KBConsolidator runs
    /// at bootstrap iff the persisted value is below this.
    static let currentKBConsolidationVersion: Int = 1

    @Published var kbDirectory: URL?
    @Published var browser: BrowserChoice = .chrome
    @Published var sleepRequests: Double = 1.0
    @Published var onboardingCompleted: Bool = false
    @Published var pollInterval: PollInterval = .every3h
    @Published var backgroundPollingEnabled: Bool = true
    @Published var notificationsEnabled: Bool = true
    @Published var quietHoursEnabled: Bool = false
    @Published var quietHoursStart: Int = 0
    @Published var quietHoursEnd: Int = 7
    /// Top-down preferred language order. Special tokens: "@original", "@english", "@any".
    @Published var languagePriority: [String] = ["@original", "@english", "@any"]
    /// While polling is active, hold an `idleSystemSleepDisabled` activity so
    /// the Mac doesn't sleep mid-cycle (a 5000-video channel can take hours).
    /// Released when the cycle ends. NSBackgroundActivityScheduler still wakes
    /// the system periodically via Power Nap when on AC power.
    @Published var preventSleepDuringPoll: Bool = true
    /// Max number of channels processed in parallel during a polling cycle.
    /// Each channel is one yt-dlp pipeline. Higher values = faster on
    /// multi-channel batches BUT increase chance of YouTube bot-detection
    /// (more concurrent requests from same IP/cookies).
    /// Range 1...4, default 2.
    @Published var maxConcurrentChannels: Int = 2
    /// Auto-check GitHub Releases for newer versions every 6 hours.
    /// User can also trigger a manual check via Settings → О приложении.
    @Published var autoUpdateEnabled: Bool = true
    /// Version of the most recent one-time KB-layout migration that has run on
    /// this install. Compared against `currentKBConsolidationVersion` at
    /// bootstrap to decide whether to run KBConsolidator.
    @Published var kbConsolidationVersion: Int = 0
    /// True iff the app is registered to launch automatically at login. Mirrors
    /// SMAppService.mainApp.status — kept in @Published so the toggle in
    /// Settings reflects the system truth.
    @Published var launchAtLogin: Bool = false
    /// Whether we've already auto-enabled launch-at-login on a fresh install.
    /// Avoids re-toggling after the user explicitly turned it off.
    @Published var launchAtLoginPrompted: Bool = false
    /// Timestamp of the last completed scheduled or wake-triggered poll cycle.
    /// Used by the wake observer to fast-track a catch-up cycle when the Mac
    /// returns from sleep and a scheduled tick was missed.
    @Published var lastScheduledRunAt: Date?
    /// Timestamp of the last daily-digest banner. Used to ensure we fire it at
    /// most once per calendar day, after 09:00 local time.
    @Published var lastDigestPostedAt: Date?

    func load() {
        if let raw = defaults.string(forKey: Keys.browser),
           let choice = BrowserChoice(rawValue: raw) {
            browser = choice
        }
        sleepRequests = defaults.object(forKey: Keys.sleepRequests) as? Double ?? 1.0
        onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)
        if let raw = defaults.object(forKey: Keys.pollInterval) as? Int,
           let pi = PollInterval(rawValue: raw) {
            pollInterval = pi
        }
        backgroundPollingEnabled = defaults.object(forKey: Keys.backgroundPollingEnabled) as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        quietHoursEnabled = defaults.bool(forKey: Keys.quietHoursEnabled)
        quietHoursStart = defaults.object(forKey: Keys.quietHoursStart) as? Int ?? 0
        quietHoursEnd = defaults.object(forKey: Keys.quietHoursEnd) as? Int ?? 7
        if let stored = defaults.array(forKey: Keys.languagePriority) as? [String], !stored.isEmpty {
            languagePriority = stored
        }
        preventSleepDuringPoll = defaults.object(forKey: Keys.preventSleepDuringPoll) as? Bool ?? true
        let storedConc = defaults.object(forKey: Keys.maxConcurrentChannels) as? Int ?? 2
        maxConcurrentChannels = max(1, min(4, storedConc))
        autoUpdateEnabled = defaults.object(forKey: Keys.autoUpdateEnabled) as? Bool ?? true
        kbConsolidationVersion = defaults.object(forKey: Keys.kbConsolidationVersion) as? Int ?? 0
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        launchAtLoginPrompted = defaults.bool(forKey: Keys.launchAtLoginPrompted)
        if let ts = defaults.object(forKey: Keys.lastScheduledRunAt) as? Double {
            lastScheduledRunAt = Date(timeIntervalSince1970: ts)
        }
        if let ts = defaults.object(forKey: Keys.lastDigestPostedAt) as? Double {
            lastDigestPostedAt = Date(timeIntervalSince1970: ts)
        }
        kbDirectory = resolveBookmark()
    }

    func setLastDigestPostedAt(_ date: Date) {
        lastDigestPostedAt = date
        defaults.set(date.timeIntervalSince1970, forKey: Keys.lastDigestPostedAt)
    }

    func setLaunchAtLogin(_ value: Bool) {
        launchAtLogin = value
        defaults.set(value, forKey: Keys.launchAtLogin)
    }

    func setLaunchAtLoginPrompted(_ value: Bool) {
        launchAtLoginPrompted = value
        defaults.set(value, forKey: Keys.launchAtLoginPrompted)
    }

    func setLastScheduledRunAt(_ date: Date) {
        lastScheduledRunAt = date
        defaults.set(date.timeIntervalSince1970, forKey: Keys.lastScheduledRunAt)
    }

    func setKBConsolidationVersion(_ value: Int) {
        kbConsolidationVersion = value
        defaults.set(value, forKey: Keys.kbConsolidationVersion)
    }

    func setAutoUpdateEnabled(_ value: Bool) {
        autoUpdateEnabled = value
        defaults.set(value, forKey: Keys.autoUpdateEnabled)
    }

    func setPreventSleepDuringPoll(_ value: Bool) {
        preventSleepDuringPoll = value
        defaults.set(value, forKey: Keys.preventSleepDuringPoll)
    }

    func setMaxConcurrentChannels(_ value: Int) {
        let clamped = max(1, min(4, value))
        maxConcurrentChannels = clamped
        defaults.set(clamped, forKey: Keys.maxConcurrentChannels)
    }

    func setPollInterval(_ value: PollInterval) {
        pollInterval = value
        defaults.set(value.rawValue, forKey: Keys.pollInterval)
    }

    func setBackgroundPollingEnabled(_ value: Bool) {
        backgroundPollingEnabled = value
        defaults.set(value, forKey: Keys.backgroundPollingEnabled)
    }

    func setNotificationsEnabled(_ value: Bool) {
        notificationsEnabled = value
        defaults.set(value, forKey: Keys.notificationsEnabled)
    }

    func setQuietHours(enabled: Bool, start: Int, end: Int) {
        quietHoursEnabled = enabled
        quietHoursStart = max(0, min(23, start))
        quietHoursEnd = max(0, min(23, end))
        defaults.set(enabled, forKey: Keys.quietHoursEnabled)
        defaults.set(quietHoursStart, forKey: Keys.quietHoursStart)
        defaults.set(quietHoursEnd, forKey: Keys.quietHoursEnd)
    }

    func setLanguagePriority(_ value: [String]) {
        languagePriority = value
        defaults.set(value, forKey: Keys.languagePriority)
    }

    /// Returns true if current time is inside the configured quiet hours window.
    func isInQuietHours(now: Date = Date()) -> Bool {
        guard quietHoursEnabled else { return false }
        let hour = Calendar.current.component(.hour, from: now)
        if quietHoursStart == quietHoursEnd { return false }
        if quietHoursStart < quietHoursEnd {
            return hour >= quietHoursStart && hour < quietHoursEnd
        }
        // Wraps midnight (e.g. 22 → 7)
        return hour >= quietHoursStart || hour < quietHoursEnd
    }

    func setBrowser(_ choice: BrowserChoice) {
        browser = choice
        defaults.set(choice.rawValue, forKey: Keys.browser)
    }

    func setSleepRequests(_ value: Double) {
        sleepRequests = value
        defaults.set(value, forKey: Keys.sleepRequests)
    }

    func markOnboardingComplete() {
        onboardingCompleted = true
        defaults.set(true, forKey: Keys.onboardingCompleted)
    }

    func setKBDirectory(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Keys.kbBookmark)
        kbDirectory = url
        Logger.shared.info("KB directory set: \(url.path)")
    }

    private func resolveBookmark() -> URL? {
        guard let data = defaults.data(forKey: Keys.kbBookmark) else { return nil }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return url
        } catch {
            Logger.shared.warn("Failed to resolve KB bookmark: \(error)")
            return nil
        }
    }

    /// Calls `body` while holding security-scoped access to KB. Safe to nest.
    func withKBAccess<T>(_ body: (URL) throws -> T) throws -> T {
        guard let url = kbDirectory else {
            throw NSError(
                domain: "YTKB",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "KB directory not configured"]
            )
        }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    func defaultKBDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yt-kbs")
    }
}
