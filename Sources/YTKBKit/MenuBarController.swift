import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private weak var delegate: AppDelegate?
    private let appState: AppState
    private var cancellables: Set<AnyCancellable> = []

    package init(appState: AppState, delegate: AppDelegate) {
        self.appState = appState
        self.delegate = delegate
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()
        configureStatusItem()
        configurePopover()
        observeState()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "text.book.closed",
                accessibilityDescription: "yt-kb"
            )
            image?.isTemplate = true
            button.image = image
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
    }

    private func observeState() {
        appState.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async { self?.updateIconState() }
            }
            .store(in: &cancellables)
    }

    private func updateIconState() {
        guard let button = statusItem.button else { return }
        if appState.isPolling {
            startPulseAnimation(button)
        } else {
            stopPulseAnimation(button)
        }
        // Error badge: tint icon orange-ish if any channel is in error state
        let hasError = appState.channelStore.channels.contains { $0.lastPollStatus == "error" }
        let symbol = hasError ? "text.book.closed" : "text.book.closed"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "yt-kb")
        image?.isTemplate = true
        button.image = image
    }

    private func startPulseAnimation(_ button: NSStatusBarButton) {
        button.layer?.removeAllAnimations()
        button.wantsLayer = true
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.4
        anim.duration = 0.9
        anim.autoreverses = true
        anim.repeatCount = .infinity
        button.layer?.add(anim, forKey: "pulse")
    }

    private func stopPulseAnimation(_ button: NSStatusBarButton) {
        button.layer?.removeAnimation(forKey: "pulse")
        button.layer?.opacity = 1.0
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        let view = PopoverView(
            appState: appState,
            onSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.delegate?.showSettings()
            },
            onQuit: { [weak self] in
                self?.delegate?.quit()
            }
        )
        popover.contentViewController = NSHostingController(rootView: view)
        popover.contentSize = NSSize(width: 360, height: 480)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Programmatically open the popover (called from notification click).
    package func showPopover() {
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverWillShow(_ notification: Notification) {
        appState.isPopoverOpen = true
    }

    func popoverDidClose(_ notification: Notification) {
        appState.isPopoverOpen = false
        appState.focusChannelURL = nil
    }
}
