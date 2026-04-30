import AppKit
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var menuBarController: MenuBarController!
    var settingsWindow: NSWindow?
    var onboardingWindow: NSWindow?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.shared.info("yt-kb launching")
        appState.bootstrap()

        menuBarController = MenuBarController(appState: appState, delegate: self)

        // Wire scheduler — only starts polling cycles if backgroundPollingEnabled
        let scheduler = PollingScheduler(appState: appState)
        appState.scheduler = scheduler
        scheduler.start()

        // Request notification authorisation in the background
        Task { await NotificationsService.shared.requestAuthorisationIfNeeded() }

        if appState.needsOnboarding {
            showOnboarding()
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
