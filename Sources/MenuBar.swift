import AppKit

/// JustGit lives in the menu bar: no Dock icon and no main window. The panel is
/// the same view the window used to hold, re-parented into a popover hung off
/// the status item.
final class MenuBarController: NSObject {

    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private weak var main: MainController?

    private override init() { super.init() }

    // MARK: - setup

    func install(main controller: MainController) {
        main = controller

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "arrow.triangle.branch",
                                   accessibilityDescription: "JustGit")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeft
            button.toolTip = "JustGit"
            button.target = self
            button.action = #selector(clicked(_:))
            _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        // The popover owns the panel; the window it came from is never shown.
        let host = NSViewController()
        host.view = controller.contentRoot
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 860, height: 620)
        // Alerts, open panels and sheets must not dismiss the panel underneath.
        popover.behavior = .applicationDefined
        popover.animates = false

        controller.onRepoChange = { [weak self] name in self?.show(repo: name) }

        NotificationCenter.default.addObserver(self, selector: #selector(skinChanged),
                                               name: Skin.changed, object: nil)
    }

    // MARK: - status item

    private func show(repo name: String?) {
        statusItem?.button?.title = name.map { " " + $0 } ?? ""
    }

    @objc private func skinChanged() {
        guard let view = popover.contentViewController?.view else { return }
        Skin.repaint(view)
        if let window = view.window { Skin.repaint(window) }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if secondary { showMenu() } else { toggle() }
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Panel 显示面板", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Setup…", action: #selector(setup), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Skin…", action: #selector(skin), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit JustGit", action: #selector(quit), keyEquivalent: "q").target = self
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    // MARK: - panel

    @objc func open() {
        guard let button = statusItem?.button else { return }
        guard !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let view = popover.contentViewController?.view {
            Skin.repaint(view)
            if let window = view.window {
                Skin.repaint(window)
                // A popover floats at the pop-up-menu level, far above anything a
                // modal alert or an ordinary window ever reaches. Left there, every
                // dialog the panel opens — Squash's questions, the folder picker,
                // Setup, Skin — is drawn *behind* the panel, and an alert has no
                // title bar to drag it out from under one. This panel is the app's
                // main UI, so it joins ordinary window ordering instead of floating.
                window.level = .normal
            }
        }
        main?.panelDidAppear()
    }

    func toggle() {
        if popover.isShown { close() } else { open() }
    }

    /// Never pull the panel out from under a running git command.
    func close() {
        if main?.operationInProgress == true {
            UI.info("Operation in progress",
                    "Wait for the current command to finish before closing the panel.")
            return
        }
        popover.performClose(nil)
    }

    // MARK: - menu actions

    @objc private func setup() { main?.openSetup() }
    @objc private func skin()  { main?.openSkin() }
    @objc private func quit()  { NSApp.terminate(nil) }
}
