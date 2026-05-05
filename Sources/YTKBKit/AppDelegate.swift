import AppKit
import SwiftUI
import UserNotifications
import ServiceManagement

extension Notification.Name {
    package static let ytkbShowOnboarding = Notification.Name("io.yt-kb.showOnboarding")
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    let appState = AppState()
    var menuBarController: MenuBarController!
    var settingsWindow: NSWindow?
    var onboardingWindow: NSWindow?
    private var keyEventMonitor: Any?
    private var updateCheckTimer: Timer?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.shared.info("yt-kb launching")
        appState.bootstrap()

        menuBarController = MenuBarController(appState: appState, delegate: self)
        appState.showPopover = { [weak self] in self?.menuBarController?.showPopover() }

        // Sync the launch-at-login toggle with system truth, then opt the user
        // in by default the first time the app boots from a location where
        // SMAppService.register() actually succeeds (i.e. /Applications).
        // We only flip `launchAtLoginPrompted` after success so an early run
        // from a temp build dir doesn't permanently skip the auto-enable.
        LoginItemController.refreshState(settings: appState.settings)
        if !appState.settings.launchAtLoginPrompted {
            LoginItemController.setEnabled(true, settings: appState.settings)
            if appState.settings.launchAtLogin {
                appState.settings.setLaunchAtLoginPrompted(true)
            }
        }

        // Wake-from-sleep catch-up: if a scheduled tick was missed while the
        // Mac slept, run it now.
        registerWakeObserver()

        // Initial KB availability check
        appState.refreshKBAvailability()

        // Wire scheduler — only starts polling cycles if backgroundPollingEnabled
        let scheduler = PollingScheduler(appState: appState)
        appState.scheduler = scheduler
        scheduler.start()

        // Verify embedded yt-dlp integrity (SHA256 anti-tamper, spec §6.1)
        BinaryIntegrity.verifyEmbedded()

        // Notification center delegate for click-handling
        UNUserNotificationCenter.current().delegate = self

        // Request notification authorisation in the background
        Task { await NotificationsService.shared.requestAuthorisationIfNeeded() }

        // Listen for "show onboarding again" requests from SettingsView
        NotificationCenter.default.addObserver(
            forName: .ytkbShowOnboarding,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showOnboarding() }
        }

        // App-wide Cmd+V/C/X/A handler. LSUIElement apps have no main menu so
        // standard Edit-menu shortcuts aren't routed. We catch the Cmd+letter
        // events and fire the corresponding NSText action via the responder
        // chain (NSApp.sendAction(_, to: nil, from: nil) walks first-responder
        // and ancestors). When a focused NSTextField handles it, sendAction
        // returns true and we consume the event. Otherwise we let it pass.
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleEditShortcut(event) ?? event
        }

        if appState.needsOnboarding {
            showOnboarding()
        }

        // Auto-update: check on launch + every 6 hours
        if appState.settings.autoUpdateEnabled {
            // Slight delay so onboarding isn't competing for attention
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.appState.checkForUpdate()
            }
            updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.appState.settings.autoUpdateEnabled {
                        self.appState.checkForUpdate()
                    }
                }
            }
        }
    }

    /// Returns nil when the event has been consumed; the original event otherwise.
    private func handleEditShortcut(_ event: NSEvent) -> NSEvent? {
        // Require Command, no Ctrl/Option (pure ⌘V etc.)
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags == .command, let chars = event.charactersIgnoringModifiers else {
            return event
        }
        let action: Selector
        switch chars {
        case "v": action = #selector(NSText.paste(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        case "z":
            // Undo / Redo. Cmd+Shift+Z is redo; we use modifierFlags to detect.
            if event.modifierFlags.contains(.shift) {
                action = Selector(("redo:"))
            } else {
                action = Selector(("undo:"))
            }
        default:
            return event
        }
        if NSApp.sendAction(action, to: nil, from: nil) {
            return nil  // event consumed
        }
        return event
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Called when user clicks a notification banner. We extract `channel_url`
    /// from userInfo and ask MenuBarController to open the popover focused on it.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let channelURL = info["channel_url"] as? String
        Task { @MainActor in
            if let channelURL { appState.focusChannelURL = channelURL }
            menuBarController?.showPopover()
            completionHandler()
        }
    }

    /// Required so notifications still appear when our app is in foreground.
    /// Always show the banner — Notification Centre is the user's reliable
    /// archive of "what got indexed today". Earlier code suppressed when the
    /// popover happened to be open; that swallowed messages even though the
    /// popover doesn't show a cycle-results history.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func showSettings() {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(appState: appState)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "yt-kb · Настройки"
        win.contentView = NSHostingView(rootView: view)
        win.contentMinSize = NSSize(width: 720, height: 480)
        // No .fullScreenPrimary: a menu-bar app shouldn't let Settings hide
        // the menu bar — the user couldn't get back to the popover.
        win.collectionBehavior = [.fullScreenAuxiliary]
        win.center()
        win.isReleasedWhenClosed = false
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showOnboarding() {
        if let win = onboardingWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(appState: appState) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Добро пожаловать в yt-kb"
        win.contentView = NSHostingView(rootView: view)
        win.center()
        win.isReleasedWhenClosed = false
        onboardingWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func quit() {
        Logger.shared.info("Quitting")
        NSApp.terminate(nil)
    }

    // MARK: - Wake observer

    private func registerWakeObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.appState.settings.backgroundPollingEnabled else { return }
                if self.appState.settings.isInQuietHours() { return }
                let interval = self.appState.settings.pollInterval.seconds
                let last = self.appState.settings.lastScheduledRunAt ?? .distantPast
                guard Date().timeIntervalSince(last) >= interval else { return }
                Logger.shared.info("Wake observer: running catch-up scheduled poll (last=\(last))")
                await PollingCoordinator.shared.pollAll(appState: self.appState, trigger: .wake)
            }
        }
    }
}

/// Wraps SMAppService.mainApp for the launch-at-login toggle. macOS 13+ only;
/// the legacy SMLoginItemSetEnabled API is deprecated. Failure to register is
/// non-fatal — we just leave the toggle off and log.
@MainActor
enum LoginItemController {
    static func refreshState(settings: Settings) {
        let registered = SMAppService.mainApp.status == .enabled
        if settings.launchAtLogin != registered {
            settings.setLaunchAtLogin(registered)
        }
    }

    static func setEnabled(_ enabled: Bool, settings: Settings) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            settings.setLaunchAtLogin(enabled)
            Logger.shared.info("LoginItem: set to \(enabled)")
        } catch {
            Logger.shared.warn("LoginItem toggle failed: \(error)")
            // Reflect actual system state so the toggle doesn't lie
            settings.setLaunchAtLogin(SMAppService.mainApp.status == .enabled)
        }
    }
}
