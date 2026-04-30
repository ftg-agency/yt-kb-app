import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    let settings = Settings()
    let channelStore = ChannelStore()

    @Published var isPolling: Bool = false
    @Published var pollingChannelURL: String?
    @Published var lastError: String?
    @Published var needsOnboarding: Bool = false

    func bootstrap() {
        settings.load()
        channelStore.load()
        needsOnboarding = !settings.onboardingCompleted
        Logger.shared.info("Bootstrap done. channels=\(channelStore.channels.count) onboarding=\(needsOnboarding)")
    }
}
