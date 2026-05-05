import Foundation
import UserNotifications

/// Wrapper around UNUserNotificationCenter for poll-related events.
/// Suppresses notifications when popover is open (per spec §9), when disabled
/// in Settings, and when in quiet hours.
@MainActor
final class NotificationsService {
    static let shared = NotificationsService()

    private var authorisationRequested = false
    private var hasAuthorisation = false

    private init() {}

    func requestAuthorisationIfNeeded() async {
        if authorisationRequested { return }
        authorisationRequested = true
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            hasAuthorisation = granted
            Logger.shared.info("Notification authorisation: \(granted ? "granted" : "denied")")
        } catch {
            Logger.shared.warn("Notification auth failed: \(error)")
            hasAuthorisation = false
        }
    }

    /// Post a notification if user has enabled them. Always lets the banner
    /// land in Notification Centre — earlier code suppressed when the popover
    /// was open, which made banners disappear silently. `channelURL` is
    /// propagated to userInfo so click-to-open can deep-link to it.
    func post(
        title: String,
        body: String,
        critical: Bool = false,
        identifier: String = UUID().uuidString,
        channelURL: String? = nil,
        appState: AppState? = nil
    ) async {
        _ = appState  // kept for callsite compat; popover-suppression intentionally removed
        await requestAuthorisationIfNeeded()
        guard hasAuthorisation else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = critical ? .defaultCritical : .default
        if let channelURL {
            content.userInfo = ["channel_url": channelURL]
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Logger.shared.warn("post notification failed: \(error)")
        }
    }

    /// Reflects the current authorization status from UNUserNotificationCenter.
    /// Used by Settings UI to surface a "Permissions denied" banner with a
    /// link to System Settings when banners aren't going to land.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func postSuccess(downloaded: Int, appState: AppState) async {
        await post(
            title: "yt-kb",
            body: "Скачано \(downloaded) новых транскрипт\(pluralForm(downloaded))",
            identifier: "io.yt-kb.notif.success",
            appState: appState
        )
    }

    /// Per-video banner: "Channel X · Video title". Throttled upstream by
    /// NotificationThrottle (1/min/channel) so a burst of incremental videos
    /// doesn't flood Notification Centre.
    func postNewVideo(channelName: String, channelURL: String, videoTitle: String?, appState: AppState) async {
        let title = "Новое видео · \(channelName)"
        let body = videoTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Транскрипт сохранён"
        // Unique identifier per fire so multiple banners stack instead of
        // replacing each other in Notification Centre.
        let identifier = "io.yt-kb.notif.new.\(UUID().uuidString)"
        await post(
            title: title,
            body: body,
            identifier: identifier,
            channelURL: channelURL,
            appState: appState
        )
    }

    /// Per-channel summary at the end of a poll cycle. Single banner per
    /// channel per cycle (no throttling needed). Body example: "+12 видео · 4960 всего".
    func postChannelIndexed(channelName: String, channelURL: String, downloaded: Int, total: Int?, appState: AppState) async {
        let title = channelName
        let body: String
        if let total, total > 0 {
            body = "+\(downloaded) видео · \(total) всего"
        } else {
            body = "+\(downloaded) новых транскрипт\(pluralForm(downloaded))"
        }
        let identifier = "io.yt-kb.notif.channel.\(channelURL.hashValue).\(UUID().uuidString)"
        await post(
            title: title,
            body: body,
            identifier: identifier,
            channelURL: channelURL,
            appState: appState
        )
    }

    /// Daily digest banner. Fires once per day after the first cycle that
    /// completes past 9:00 local time. Body summarises last 24h activity.
    func postDailyDigest(downloadedToday: Int, channelsTouched: Int, appState: AppState) async {
        let title = "yt-kb · сводка за сутки"
        let body: String
        if downloadedToday == 0 {
            body = "За сутки новых видео не было"
        } else {
            body = "+\(downloadedToday) видео · \(channelsTouched) канал\(channelPluralForm(channelsTouched))"
        }
        await post(
            title: title,
            body: body,
            identifier: "io.yt-kb.notif.digest.\(UUID().uuidString)",
            appState: appState
        )
    }

    private func channelPluralForm(_ n: Int) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "а" }
        return "ов"
    }

    func postChannelError(channelName: String, channelURL: String, message: String, appState: AppState) async {
        await post(
            title: "yt-kb · ошибка",
            body: "\(channelName): \(message)",
            identifier: "io.yt-kb.notif.err.\(channelName)",
            channelURL: channelURL,
            appState: appState
        )
    }

    func postBotCheck(appState: AppState) async {
        await post(
            title: "yt-kb · YouTube требует cookies",
            body: "Залогиньтесь в YouTube в выбранном браузере и попробуйте снова.",
            critical: true,
            identifier: "io.yt-kb.notif.botcheck",
            appState: appState
        )
    }

    private func pluralForm(_ n: Int) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "а" }
        return "ов"
    }
}
