import AppKit
import SwiftUI
import UserNotifications

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    let appState = AppState()
    var menuBarController: MenuBarController!
    var settingsWindow: NSWindow?
    var onboardingWindow: NSWindow?
    private var keyEventMonitor: Any?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.shared.info("yt-kb launching")
        appState.bootstrap()

        menuBarController = MenuBarController(appState: appState, delegate: self)
        appState.showPopover = { [weak self] in self?.menuBarController?.showPopover() }

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
    /// (Without this, clicks-to-open work but the banner is suppressed.)
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // If popover is open, suppress (per spec §9 — user already sees state in UI)
        if appState.isPopoverOpen {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
        }
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
            .frame(minWidth: 480, minHeight: 320)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "yt-kb · Настройки"
        win.contentView = NSHostingView(rootView: view)
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
        .frame(width: 520, height: 380)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
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
}
