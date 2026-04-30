import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private weak var delegate: AppDelegate?
    private let appState: AppState

    init(appState: AppState, delegate: AppDelegate) {
        self.appState = appState
        self.delegate = delegate
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()
        configureStatusItem()
        configurePopover()
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
}
