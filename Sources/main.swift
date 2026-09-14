import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var main: MainController?
    private var pendingFolder: String?

    func applicationDidFinishLaunching(_ n: Notification) {
        Skin.load()
        buildMenu()
        let c = MainController(restoreLast: pendingFolder == nil)
        main = c
        if let folder = pendingFolder {
            pendingFolder = nil
            c.open(folder)
        }
        MenuBarController.shared.install(main: c)
        MenuBarController.shared.open()
    }

    // The panel is a popover, not a window: closing it must not quit the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MenuBarController.shared.open()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard main?.operationInProgress == true || SetupWindow.shared.operationInProgress else { return .terminateNow }
        UI.info("Operation in progress", "Wait for the current command to finish before quitting JustGit.")
        return .terminateCancel
    }

    /// dropping a folder onto the dock icon opens it; a file opens its folder
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard let f = filenames.first, let dir = Paths.folder(for: f) else {
            sender.reply(toOpenOrPrint: .failure)
            return
        }
        if let main = main { main.open(dir); MenuBarController.shared.open() }
        else { pendingFolder = dir }
        sender.reply(toOpenOrPrint: .success)
    }

    private func buildMenu() {
        let bar = NSMenu()

        let appItem = NSMenuItem()
        bar.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About JustGit", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Setup…", action: #selector(setup), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Skin…", action: #selector(skin), keyEquivalent: "k").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide JustGit", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit JustGit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        bar.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        // Without a Window menu there is no ⌘W or ⌘M, which every mac user tries.
        let windowItem = NSMenuItem()
        bar.addItem(windowItem)
        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windows
        NSApp.windowsMenu = windows

        NSApp.mainMenu = bar
    }

    @objc private func about() {
        UI.info("JustGit", "A very small git front-end for macOS.\n一个很小的 macOS git 面板。\n\n"
                        + "HTTPS URLs entered in Remote are converted to SSH.\n\n"
                        + "Skin: \(Skin.theme.name)")
    }

    @objc private func setup() { main?.openSetup() }
    @objc private func skin() { main?.openSkin() }
}

// Keep command-line checks independent of AppKit's application event loop.
if SelfTest.headless { SelfTest.run() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only: no Dock icon
app.run()
