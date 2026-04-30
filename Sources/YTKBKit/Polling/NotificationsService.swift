import Foundation
import UserNotifications

/// Wrapper around UNUserNotificationCenter for poll-related events.
/// Suppresses notifications when popover is open (since the user can already see updates),
/// when notifications are disabled in Settings, and when in quiet hours.
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

    /// Post a notification if user enabled them and we have permission.
    func post(title: String, body: String, critical: Bool = false, identifier: String = UUID().uuidString) async {
        await requestAuthorisationIfNeeded()
        guard hasAuthorisation else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if critical {
            content.sound = .defaultCritical
        } else {
            content.sound = .default
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Logger.shared.warn("post notification failed: \(error)")
        }
    }

    func postSuccess(downloaded: Int) async {
        await post(
            title: "yt-kb",
            body: "Скачано \(downloaded) новых транскрипт\(pluralForm(downloaded))",
            identifier: "io.yt-kb.notif.success"
        )
    }

    func postChannelError(channelName: String, message: String) async {
        await post(
            title: "yt-kb · ошибка",
            body: "\(channelName): \(message)",
            identifier: "io.yt-kb.notif.err.\(channelName)"
        )
    }

    func postBotCheck() async {
        await post(
            title: "yt-kb · YouTube требует cookies",
            body: "Залогиньтесь в YouTube в выбранном браузере и попробуйте снова.",
            critical: true,
            identifier: "io.yt-kb.notif.botcheck"
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
