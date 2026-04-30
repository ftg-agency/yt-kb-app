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

    private let defaults = UserDefaults.standard
    private struct Keys {
        static let kbBookmark = "kbBookmark"
        static let browser = "browser"
        static let sleepRequests = "sleepRequests"
        static let onboardingCompleted = "onboardingCompleted"
    }

    @Published var kbDirectory: URL?
    @Published var browser: BrowserChoice = .chrome
    @Published var sleepRequests: Double = 1.0
    @Published var onboardingCompleted: Bool = false

    func load() {
        if let raw = defaults.string(forKey: Keys.browser),
           let choice = BrowserChoice(rawValue: raw) {
            browser = choice
        }
        sleepRequests = defaults.object(forKey: Keys.sleepRequests) as? Double ?? 1.0
        onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)
        kbDirectory = resolveBookmark()
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
