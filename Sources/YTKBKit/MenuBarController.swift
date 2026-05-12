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
        let image = NSImage(systemSymbolName: "text.book.closed", accessibilityDescription: "yt-kb")
        if appState.botCheckActive {
            // Color tint requires non-template image — switch off template flag
            // so contentTintColor takes effect.
            image?.isTemplate = false
            button.image = image
            button.contentTintColor = .systemRed
        } else {
            image?.isTemplate = true
            button.image = image
            button.contentTintColor = nil
        }
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
        if popover.isShown {
            popover.performClose(sender)
        } else {
            presentPopover()
        }
    }

    /// Programmatically open the popover (called from notification click).
    package func showPopover() {
        if !popover.isShown {
            presentPopover()
        }
    }

    /// Position the popover anchored to the status-bar button. Using `.zero`
    /// rather than `button.bounds` so AppKit derives the anchor from the
    /// button's actual on-screen frame (works even on macOS 15 where
    /// `button.bounds` can return an empty rect on first call).
    private func presentPopover() {
        guard let button = statusItem.button, let window = button.window else { return }
        // Force layout so the button has a valid frame in the menu bar window
        button.needsLayout = true
        window.layoutIfNeeded()

        // Use button.bounds when non-zero, otherwise fall back to a 1×1 rect
        // at the button's mid-x/min-y so the popover still anchors to the icon.
        let anchorRect: NSRect
        if button.bounds.width > 0 && button.bounds.height > 0 {
            anchorRect = button.bounds
        } else {
            anchorRect = NSRect(x: 0, y: 0, width: 1, height: 1)
        }

        popover.show(relativeTo: anchorRect, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
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
