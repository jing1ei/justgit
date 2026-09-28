import AppKit

/// Hosts the repository panel in the menu bar.
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
            button.image = AppIcon.menuBar
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
        popover.contentSize = NSSize(width: 1060, height: 640)
        // Alerts, open panels and sheets must not dismiss the panel underneath.
        popover.behavior = .applicationDefined
        popover.animates = false

        controller.onRepoChange = { [weak self] name in self?.show(repo: name) }

        NotificationCenter.default.addObserver(self, selector: #selector(skinChanged),
                                               name: Skin.changed, object: nil)
    }

    // MARK: - status item

    private func show(repo name: String?) {
        statusItem?.button?.title = name.map { " " + Self.shortTitle($0) } ?? ""
        statusItem?.button?.toolTip = name.map { "JustGit — " + $0 } ?? "JustGit"
    }

    static func shortTitle(_ name: String) -> String {
        name.count > 24 ? String(name.prefix(23)) + "…" : name
    }

    @objc private func skinChanged() {
        guard let view = popover.contentViewController?.view else { return }
        // Skin.set already repaints visible windows; a hidden panel still needs its palette.
        if view.window == nil { Skin.repaint(view) }
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
        menu.addItem(withTitle: "Show Panel", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(setup), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Appearance…", action: #selector(skin), keyEquivalent: "").target = self
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
                // Keep modal dialogs above the panel.
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
