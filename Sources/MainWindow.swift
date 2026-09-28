import AppKit
import QuartzCore

// A view that accepts a dropped folder.
final class DropView: SkinView {
    var onDrop: ((String) -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func folder(_ sender: NSDraggingInfo) -> String? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
              options: [.urlReadingFileURLsOnly: true]) as? [URL], let u = urls.first else { return nil }
        return Paths.folder(for: u.path)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = folder(sender) != nil
        return highlighted ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard let p = folder(sender) else { return false }
        onDrop?(p)
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard highlighted else { return }
        Skin.c.accent.withAlphaComponent(0.08).setFill()
        bounds.fill()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 10, yRadius: 10)
        p.lineWidth = 1.5
        Skin.c.accent.setStroke()
        p.stroke()
    }
}

enum Paths {
    /// A folder we can run git in: the path itself if it is a directory, its
    /// parent if a file was handed to us, nil if it does not exist.
    static func folder(for path: String) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        let dir = isDir.boolValue ? path : (path as NSString).deletingLastPathComponent
        return URL(fileURLWithPath: dir).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func validRecents(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory),
                  directory.boolValue, let folder = folder(for: path),
                  seen.insert(folder).inserted else { return nil }
            return folder
        }
    }

    static func abbrev(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p == home || p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }
}

final class MainController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    // state
    private var git: Git?
    private var st = RepoStatus()
    private var busy = false
    private var loadingRepository = false
    private var commitDrafts: [String: String] = [:]
    private var pageView: NSView?
    private var pendingPath: String?
    private var completionMessage: String?
    /// Bumped on every refresh so a reply that arrives after the user has
    /// already moved to another repo is dropped instead of painting stale data.
    private var refreshGeneration = 0
    private let defaults = UserDefaults.standard
    private let recentsKey = "recentRepos"

    // views
    let window: NSWindow
    private let root = DropView()
    private let repoTitle = V.title("No repository selected")
    private let repoTable = NSTableView()
    private var listedRepositories: [String] = []
    private var updatingRepositories = false
    private var organizationButton = SkinButton()
    private var repositoryGroups: [String] {
        get { defaults.stringArray(forKey: "repositoryGroups") ?? [] }
        set { defaults.set(newValue, forKey: "repositoryGroups") }
    }
    private var repositoryMembership: [String: String] {
        get { defaults.dictionary(forKey: "repositoryMembership") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "repositoryMembership") }
    }
    private static let groupPrefix = "group:"

    private let branchLabel = V.label("—", weight: .medium)
    private let countsLabel = V.label("", tone: .soft, delta: -1)
    private let remoteLabel = V.label("origin  — none yet", tone: .soft, mono: true)
    private var initButton = SkinButton()
    private let msgField = V.field("Commit message (leave blank to use the date)")
    private let spinner = NSProgressIndicator()
    private let logView = SkinTextView()
    private let changesView = SkinTextView()
    private let historyView = SkinTextView()
    private let detailTabs = NSTabView()
    private var detailSelector = NSSegmentedControl()
    private let activityLabel = V.label("Ready", tone: .soft, delta: -1)
    private let guidanceLabel = V.label("Open or drop a repository folder to get started.", tone: .soft, delta: -1)
    private var recoveryRow = NSStackView()
    private var advancedButton = SkinButton()
    private var advancedItems: [NSMenuItem] = []
    private var actionButtons: [NSButton] = []
    private var navigationButtons: [NSButton] = []
    private var branchButtons: [NSButton] = []
    private var continueButton = SkinButton()
    private var abortButton = SkinButton()
    private var resolveButton = SkinButton()
    private var newBranchButton = SkinButton()

    init(restoreLast: Bool = true) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "JustGit"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 960, height: 540)
        window.titlebarAppearsTransparent = true
        window.delegate = self
        window.center()
        if restoreLast { window.setFrameAutosaveName("JustGitMain") }
        buildUI()
        Skin.repaint(window)
        NotificationCenter.default.addObserver(self, selector: #selector(skinChanged),
                                               name: Skin.changed, object: nil)
        if restoreLast { openLastOrPrompt() }
        else { rebuildRepositories(); setEnabled(false) }
    }

    // MARK: - build

    private func buildUI() {
        root.onDrop = { [weak self] p in self?.open(p) }
        window.contentView = root

        repoTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        repoTitle.lineBreakMode = .byTruncatingMiddle
        let openBtn = V.button("Add repository…", self, #selector(openFolder), key: "o",
                               tooltip: "⌘O — choose a folder (or drop one onto this window)")
        let refreshBtn = V.button("↻", self, #selector(refreshClicked), kind: .quiet, key: "r",
                                  tooltip: "⌘R — refresh")
        refreshBtn.setAccessibilityLabel("Refresh repository")
        navigationButtons = [openBtn, refreshBtn]
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let top = V.hstack([repoTitle, NSView(), refreshBtn], spacing: 10)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("repository"))
        column.width = 190
        column.minWidth = 40
        column.resizingMask = .autoresizingMask
        repoTable.addTableColumn(column)
        repoTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        repoTable.autoresizingMask = [.width]
        repoTable.intercellSpacing = .zero
        repoTable.style = .plain
        repoTable.headerView = nil
        repoTable.rowHeight = RepositoryRowMetrics.height
        repoTable.delegate = self
        repoTable.dataSource = self
        repoTable.allowsEmptySelection = false
        repoTable.setAccessibilityLabel("Repositories")
        let repositoryScroll = SkinWell()
        repositoryScroll.hasHorizontalScroller = false
        repositoryScroll.documentView = repoTable
        organizationButton = V.button("Organize…", self, #selector(organizeRepositories), kind: .quiet)
        let sidebar = V.vstack([V.eyebrow("Repositories"), openBtn, repositoryScroll, organizationButton], spacing: 12)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        for view in sidebar.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            sidebar.widthAnchor.constraint(equalToConstant: 200),
            repositoryScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])

        // status
        initButton = SkinButton("Initialize repository", self, #selector(initRepo), kind: .primary)
        initButton.isHidden = true
        newBranchButton = V.button("New branch…", self, #selector(newBranch), kind: .quiet)
        branchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let line1 = V.hstack([branchLabel, countsLabel, NSView(), initButton, newBranchButton])

        let remoteBtn = V.button("Remote…", self, #selector(setRemote), kind: .quiet,
                                 tooltip: "Set origin to SSH or a local repository path")
        let line2 = V.hstack([remoteLabel, NSView(), remoteBtn])
        remoteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // commit row
        msgField.target = self
        msgField.action = #selector(commitOnly)
        let commitBtn = V.button("Commit", self, #selector(commitOnly))
        let commitPushBtn = V.button("Commit & Push", self, #selector(commitAndPush),
                                     kind: .primary, key: "\r", tooltip: "⌘↩")
        msgField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // actions
        let pull = V.button("Pull", self, #selector(pullClicked), tooltip: "Fetch origin, then rebase with autostash")
        let push = V.button("Push", self, #selector(pushClicked), tooltip: "Push this branch to origin")
        let sync = V.button("Sync", self, #selector(syncClicked), tooltip: "Commit if dirty, then pull, then push")
        advancedButton = V.button("Advanced…", self, #selector(showAdvanced(_:)), kind: .quiet)
        for (title, action) in [("Squash…", #selector(squashClicked)),
                                ("Force Push…", #selector(forcePushClicked)),
                                ("Force Pull…", #selector(forcePullClicked))] {
            let item = NSMenuItem(title: title, action: #selector(advancedPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            advancedItems.append(item)
        }
        let finder = V.button("Finder", self, #selector(revealInFinder), kind: .micro)
        let term = V.button("Terminal", self, #selector(openTerminal), kind: .micro)
        let actions = V.hstack([commitBtn, commitPushBtn, NSView(), pull, push, sync])
        actionButtons = [commitBtn, commitPushBtn, pull, push, sync, remoteBtn]
        branchButtons = [commitPushBtn, pull, push, sync]
        continueButton = V.button("Continue", self, #selector(continueOperation), kind: .quiet)
        abortButton = V.button("Abort…", self, #selector(abortOperation), kind: .danger)
        resolveButton = V.button("Resolve files…", self, #selector(resolveFiles), kind: .quiet)
        recoveryRow = V.hstack([V.label("Recovery", tone: .caution), resolveButton, continueButton, abortButton, NSView()])

        // log
        detailTabs.tabViewType = .noTabsNoBorder
        for (title, view) in [("Changes", changesView), ("History", historyView), ("Activity", logView)] {
            let scroll = SkinWell()
            view.isEditable = false
            view.isRichText = view === logView
            view.textContainerInset = NSSize(width: 14, height: 12)
            view.restyle()
            view.autoresizingMask = [.width]
            view.isVerticallyResizable = true
            view.textContainer?.widthTracksTextView = true
            scroll.documentView = view
            let tab = NSTabViewItem(identifier: title)
            tab.view = scroll
            detailTabs.addTabViewItem(tab)
        }
        changesView.string = "No repository selected"
        historyView.string = "No repository selected"
        detailSelector = NSSegmentedControl(labels: ["Changes", "History", "Activity"],
                                            trackingMode: .selectOne, target: self, action: #selector(selectDetail(_:)))
        detailSelector.selectedSegment = 0
        let detailHeader = V.hstack([detailSelector, NSView(), advancedButton])
        guidanceLabel.lineBreakMode = .byWordWrapping
        guidanceLabel.maximumNumberOfLines = 3

        let rows: [NSView] = [
            top, V.hairline(),
            line1, line2,
            recoveryRow, guidanceLabel,
            V.eyebrow("Commit message"), msgField, actions,
            V.hairline(), detailHeader, detailTabs,
            V.hstack([spinner, activityLabel, NSView(), finder, term]),
        ]
        let stack = V.vstack(rows, spacing: 8, align: .leading)
        pageView = stack
        stack.wantsLayer = true
        stack.distribution = .fill
        // A section mark sits close to what it labels; the air goes above it.
        for (i, r) in rows.enumerated() where (r as? SkinLabel)?.uppercased == true {
            stack.setCustomSpacing(4, after: r)
            if i > 0 { stack.setCustomSpacing(18, after: rows[i - 1]) }
        }
        stack.setCustomSpacing(6, after: rows[0])    // masthead sits on its rule
        stack.setCustomSpacing(14, after: rows[1])
        stack.setCustomSpacing(3, after: line1)      // branch + remote read as one block
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
        for r in rows {
            r.translatesAutoresizingMaskIntoConstraints = false
            r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        detailTabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        msgField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

    }

    @objc private func selectDetail(_ sender: NSSegmentedControl) {
        detailTabs.selectTabViewItem(at: sender.selectedSegment)
    }

    @objc private func showAdvanced(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in advancedItems { item.menu?.removeItem(item); menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    /// Open modal dialogs only after menu tracking has ended.
    @objc func advancedPicked(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? Selector else { return }
        perform(action, with: nil, afterDelay: 0, inModes: [.default])
    }

    // MARK: - logging

    private func onMain(_ b: @escaping () -> Void) {
        Thread.isMainThread ? b() : DispatchQueue.main.async(execute: b)
    }

    /// Keep attributed text and its backing lines bounded and synchronized.
    private struct LogLine {
        let text: String
        let tone: SkinLabel.Tone
        let bold: Bool
        let length: Int
    }
    private var logLines: [LogLine] = []
    private static let logCap = 600
    private static let logCharacterCap = 200_000

    private func log(_ s: String, _ tone: SkinLabel.Tone = .ink, bold: Bool = false) {
        guard !s.isEmpty else { return }
        onMain {
            guard let store = self.logView.textStorage else { return }
            let bounded = s.count > 32_000 ? String(s.prefix(32_000)) + "\n[output truncated]" : s
            let piece = self.render(bounded, tone, bold)
            store.append(piece)
            self.logLines.append(LogLine(text: bounded, tone: tone, bold: bold, length: piece.length))

            var over = max(0, self.logLines.count - MainController.logCap)
            var remaining = store.length - self.logLines.prefix(over).reduce(0) { $0 + $1.length }
            while remaining > MainController.logCharacterCap && over < self.logLines.count - 1 {
                remaining -= self.logLines[over].length
                over += 1
            }
            if over > 0 {
                let chars = self.logLines.prefix(over).reduce(0) { $0 + $1.length }
                store.deleteCharacters(in: NSRange(location: 0, length: min(chars, store.length)))
                self.logLines.removeFirst(over)
            }
            self.logView.scrollToEndOfDocument(nil)
        }
    }

    /// One console line in the current palette.
    private func render(_ s: String, _ tone: SkinLabel.Tone, _ bold: Bool) -> NSAttributedString {
        let text = s.hasSuffix("\n") ? s : s + "\n"
        let colour: NSColor
        switch tone {
        case .ink:  colour = Skin.c.consoleInk
        case .soft: colour = Skin.c.consoleInk.withAlphaComponent(0.62)
        default:    colour = Skin.color(for: tone)
        }
        return NSAttributedString(string: text, attributes: [
            .font: Skin.mono(0, bold ? .semibold : .regular),
            .foregroundColor: colour,
        ])
    }

    /// Redraw the whole console after a skin change.
    private func rerenderLog() {
        guard let store = logView.textStorage else { return }
        store.beginEditing()
        store.setAttributedString(NSAttributedString())
        var rebuilt: [LogLine] = []
        rebuilt.reserveCapacity(logLines.count)
        for l in logLines {
            let piece = render(l.text, l.tone, l.bold)
            store.append(piece)
            rebuilt.append(LogLine(text: l.text, tone: l.tone, bold: l.bold, length: piece.length))
        }
        store.endEditing()
        logLines = rebuilt
        logView.scrollToEndOfDocument(nil)
    }

    /// Refresh the attributed console and repository rows after a palette change.
    @objc private func skinChanged() {
        rerenderLog()
        rebuildRepositories()
    }

    private func section(_ title: String) { log("\n▌ " + title, .accent, bold: true) }
    private func ok(_ s: String) {
        log("✓ " + s, .positive)
        onMain { self.completionMessage = s }
    }
    private func bad(_ s: String) {
        log("✗ " + s, .negative)
        onMain {
            self.activityLabel.stringValue = "Action stopped · see Activity"
            self.activityLabel.tone = .negative
            self.detailSelector.selectedSegment = 2
            self.detailTabs.selectTabViewItem(at: 2)
        }
    }
    private func note(_ s: String) { log("· " + s, .soft) }

    /// run a git command, echo it, print its output
    @discardableResult
    private func gx(_ g: Git, _ args: [String]) -> RunResult {
        workflow(g).run(args)
    }

    // MARK: - recents

    private var recents: [String] {
        get { defaults.stringArray(forKey: recentsKey) ?? [] }
        set { defaults.set(newValue, forKey: recentsKey) }
    }

    private func remember(_ path: String) {
        var r = Paths.validRecents(recents)
        if !r.contains(path) { r.append(path) }
        recents = r
        defaults.set(path, forKey: "lastRepository")
        rebuildRepositories()
    }

    private func rebuildRepositories() {
        updatingRepositories = true
        defer { updatingRepositories = false }
        var paths = recents
        if let path = git?.path, !paths.contains(path) { paths.append(path) }
        let groups = repositoryGroups
        let membership = repositoryMembership
        listedRepositories = paths.filter { !groups.contains(membership[$0] ?? "") }
        for group in groups {
            listedRepositories.append(Self.groupPrefix + group)
            listedRepositories += paths.filter { membership[$0] == group }
        }
        repoTitle.stringValue = git.map { ($0.path as NSString).lastPathComponent } ?? "No repository selected"
        repoTable.backgroundColor = Skin.c.panel
        repoTable.rowHeight = RepositoryRowMetrics.height
        repoTable.reloadData()
        if let path = git?.path, let index = listedRepositories.firstIndex(of: path) {
            repoTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { listedRepositories.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RepositoryRowView()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !busy || loadingRepository }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let path = listedRepositories[row]
        if path.hasPrefix(Self.groupPrefix) {
            let name = String(path.dropFirst(Self.groupPrefix.count))
            return RepositoryCellView(title: name, location: "", current: false, fullPath: name)
        }
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return RepositoryCellView(title: (path as NSString).lastPathComponent, location: parent,
                                  current: path == git?.path, fullPath: path)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = repoTable.selectedRow
        guard (!busy || loadingRepository), !updatingRepositories, listedRepositories.indices.contains(row) else { return }
        let path = listedRepositories[row]
        if !path.hasPrefix(Self.groupPrefix), loadingRepository || path != git?.path { open(path) }
    }

    @objc private func organizeRepositories() {
        guard !busy else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let selected = repoTable.selectedRow
        let row = listedRepositories.indices.contains(selected) ? listedRepositories[selected] : nil
        let isGroup = row?.hasPrefix(Self.groupPrefix) == true
        for (title, action) in [("Move up", "up"), ("Move down", "down"), ("Move to group…", "assign"),
                                ("New group…", "new"), ("Rename group…", "rename"), ("Delete group…", "delete")] {
            let item = NSMenuItem(title: title, action: #selector(organizationPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            item.isEnabled = action == "new" || (row != nil && (action == "up" || action == "down" || (isGroup ? action != "assign" : action == "assign")))
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: organizationButton.bounds.height), in: organizationButton)
    }

    @objc private func organizationPicked(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        perform(#selector(editOrganization(_:)), with: action, afterDelay: 0, inModes: [.default])
    }

    @objc private func editOrganization(_ action: String) {
        guard !busy else { return }
        let selected = repoTable.selectedRow
        let row = listedRepositories.indices.contains(selected) ? listedRepositories[selected] : nil
        let isGroup = row?.hasPrefix(Self.groupPrefix) == true
        var groups = repositoryGroups
        var membership = repositoryMembership
        var paths = recents
        var selection = row
        if action == "new" || action == "rename" {
            let old = action == "rename" && isGroup ? String(row!.dropFirst(Self.groupPrefix.count)) : ""
            guard let name = UI.prompt(action == "new" ? "New group" : "Rename group", "Choose a unique name.", value: action == "rename" ? old : ""), !name.isEmpty else { return }
            guard name != "Ungrouped", name.count <= 60, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !groups.contains(name) || name == old else {
                UI.error("Choose a unique group name up to 60 characters."); return
            }
            if action == "new" { groups.append(name) }
            else if let index = groups.firstIndex(of: old) {
                groups[index] = name
                for (path, group) in membership where group == old { membership[path] = name }
            }
            selection = Self.groupPrefix + name
        } else if action == "assign", let path = row, !isGroup {
            guard let index = UI.select("Move repository", "Choose its group. Files stay where they are.", ["Ungrouped"] + groups) else { return }
            membership[path] = index == 0 ? nil : groups[index - 1]
        } else if action == "delete", let row = row, isGroup {
            let name = String(row.dropFirst(Self.groupPrefix.count))
            guard UI.confirm("Delete group “\(name)” ?", "Repositories return to Ungrouped. No files are deleted.", okTitle: "Delete group") else { return }
            groups.removeAll { $0 == name }
            membership = membership.filter { $0.value != name }
            selection = nil
        } else if let row = row, action == "up" || action == "down" {
            let delta = action == "up" ? -1 : 1
            if isGroup {
                let group = String(row.dropFirst(Self.groupPrefix.count))
                if let index = groups.firstIndex(of: group), groups.indices.contains(index + delta) { groups.swapAt(index, index + delta) }
            } else {
                let peers = paths.filter { membership[$0] == membership[row] }
                if let index = peers.firstIndex(of: row), peers.indices.contains(index + delta),
                   let a = paths.firstIndex(of: row), let b = paths.firstIndex(of: peers[index + delta]) { paths.swapAt(a, b) }
            }
        }
        repositoryGroups = groups
        repositoryMembership = membership
        recents = paths
        rebuildRepositories()
        if let selection = selection, let index = listedRepositories.firstIndex(of: selection) {
            updatingRepositories = true
            repoTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            updatingRepositories = false
        }
    }

    // MARK: - repo lifecycle

    private func openLastOrPrompt() {
        recents = Paths.validRecents(recents)
        rebuildRepositories()
        setEnabled(false)
        if !Git.installed {
            bad("Git is not installed. Open JustGit > Settings in the menu bar.")
        }
        if let last = defaults.string(forKey: "lastRepository").flatMap({ recents.contains($0) ? $0 : nil }) ?? recents.first, FileManager.default.fileExists(atPath: last) {
            open(last, silent: true, verbose: true)
        } else {
            log("Pick the folder you want to work in.", .soft)
            // first launch: go straight to the folder picker, that is the whole point
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self = self, self.git == nil, !SelfTest.headless else { return }
                self.openFolder()
            }
        }
    }

    func open(_ path: String, silent: Bool = false, verbose: Bool = false) {
        guard !busy else {
            pendingPath = path
            activityLabel.stringValue = loadingRepository
                ? "Opening \((path as NSString).lastPathComponent)…"
                : "Repository queued until this operation finishes"
            return
        }
        guard let dir = Paths.folder(for: path) else {
            recents = Paths.validRecents(recents)
            rebuildRepositories()
            bad("That path is unavailable: \(Paths.abbrev(path))")
            return
        }
        if let previous = git?.path { commitDrafts[previous] = msgField.stringValue }
        pageView?.layer?.removeAnimation(forKey: "repositoryTransition")
        git = Git(dir)
        rebuildRepositories()
        st = RepoStatus()
        logLines.removeAll()
        logView.textStorage?.setAttributedString(NSAttributedString())
        detailSelector.selectedSegment = 0
        detailTabs.selectTabViewItem(at: 0)
        changesView.string = "Loading…"
        historyView.string = "Loading…"
        branchLabel.stringValue = "Loading repository…"
        countsLabel.stringValue = ""
        remoteLabel.stringValue = ""
        guidanceLabel.stringValue = "Reading repository status…"
        onRepoChange?((dir as NSString).lastPathComponent)
        msgField.stringValue = commitDrafts[dir] ?? ""
        if !silent { section("Open " + Paths.abbrev(dir)) }
        loadingRepository = true
        setBusy(true)
        activityLabel.stringValue = "Opening \((dir as NSString).lastPathComponent)…"
        refresh(verbose: verbose || !silent) { [weak self] in
            guard let self = self, let g = self.git else { return }
            self.remember(g.path)               // the resolved toplevel, not the subfolder
            self.loadingRepository = false
            self.setBusy(false)
            self.animateRepositoryPage()
        }
    }

    private func animateRepositoryPage() {
        guard !SelfTest.headless, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = pageView?.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.55
        fade.toValue = 1
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "repositoryTransition")
    }

    @objc private func openFolder() {
        guard !busy || loadingRepository else { return }
        guard let p = UI.pickFolder() else { return }
        open(p)
    }

    @objc private func refreshClicked() {
        guard !busy else { return }
        section("Status")
        setBusy(true)
        refresh(verbose: true) { [weak self] in self?.setBusy(false) }
    }

    /// Reads the repo off the main thread and paints the result on it. Replies
    /// for a repo the user has since navigated away from are discarded.
    private func refresh(verbose: Bool = false, then: (() -> Void)? = nil) {
        guard let g = git else { then?(); return }
        refreshGeneration += 1
        let gen = refreshGeneration

        bg {
            let s = g.status()
            self.onMain {
                guard gen == self.refreshGeneration, self.git === g else { return }
                if self.loadingRepository, let next = self.pendingPath {
                    self.pendingPath = nil
                    self.loadingRepository = false
                    self.setBusy(false)
                    self.open(next)
                    return
                }
                // git reports the toplevel; adopt it so every later command runs there
                if s.isRepo, !s.top.isEmpty, s.top != g.path { self.git = Git(s.top) }
                self.st = s
                self.paint(verbose: verbose)
                then?()
            }
        }
    }

    private func paint(verbose: Bool) {
        guard let g = git else { return }
        let name = (g.path as NSString).lastPathComponent
        window.title = "JustGit — " + name
        window.representedFilename = g.path
        onRepoChange?(name)
        let changes = st.error.isEmpty
            ? (st.isRepo ? (st.shortStatus.isEmpty ? "Working tree clean" : st.shortStatus) : "Not a Git repository")
            : st.error
        // Leave selection and scroll position intact when a refresh changes nothing.
        if changesView.string != changes { changesView.string = changes }
        let history = !st.error.isEmpty ? "History unavailable" :
            (!st.isRepo ? "Open a repository to see its history." :
                (st.recentLog.isEmpty ? "No commits yet. Add files and Commit to create the first snapshot." : st.recentLog))
        if historyView.string != history { historyView.string = history }
        guidanceLabel.stringValue = st.guidance
        if !st.error.isEmpty {
            branchLabel.stringValue = "Repository unavailable"
            countsLabel.stringValue = "Check the path and permissions, then Refresh or Open another folder."
            remoteLabel.stringValue = ""
            initButton.isHidden = true
            setEnabled(false)
            bad(st.error)
            return
        }

        guard st.isRepo else {
            branchLabel.stringValue = "Not a Git repo yet"
            branchLabel.tone = .caution
            countsLabel.stringValue = Paths.abbrev(g.path)
            countsLabel.tone = .faint
            remoteLabel.stringValue = "—"
            remoteLabel.tone = .faint
            initButton.isHidden = false
            setEnabled(false)
            return
        }

        initButton.isHidden = true
        setEnabled(true)
        branchLabel.tone = st.detached ? .caution : .ink
        branchLabel.stringValue = "⎇ " + st.branch
        var bits: [String] = []
        if st.ahead > 0 { bits.append("↑\(st.ahead)") }
        if st.behind > 0 { bits.append("↓\(st.behind)") }
        if !st.operation.isEmpty { bits.append("\(st.operation) in progress") }
        if st.conflicts { bits.append("conflicts: use Resolve files") }
        bits.append(st.changed == 0 ? "clean" : "\(st.changed) changed")
        if !st.hasCommits { bits.append("no commits yet") }
        countsLabel.stringValue = bits.joined(separator: "   ")
        countsLabel.tone = st.dirty ? .ink : .faint

        if st.hasRemote {
            remoteLabel.stringValue = "origin  " + RemoteURL.redacted(st.remote)
            remoteLabel.tone = st.remoteIsSSH ? .soft : .caution
            remoteLabel.toolTip = RemoteURL.isHTTP(st.remote) ? "Use Remote to convert this URL to SSH." : nil
        } else {
            remoteLabel.stringValue = "origin  — none yet"
            remoteLabel.tone = .faint
        }

        if verbose {
            log(st.shortStatus.isEmpty ? "working tree clean" : st.shortStatus)
            if !st.recentLog.isEmpty { log("\n" + st.recentLog, .soft) }
        }
    }

    private func setEnabled(_ on: Bool) {
        let available = on && !busy && st.error.isEmpty
        let normal = available && st.operation.isEmpty && !st.conflicts
        for b in actionButtons { b.isEnabled = normal }
        for b in branchButtons {
            b.isEnabled = normal && !st.detached && st.hasRemote
            if b.action == #selector(pushClicked) { b.isEnabled = b.isEnabled && st.hasCommits }
        }
        msgField.isEnabled = normal
        initButton.isEnabled = !busy && git != nil && st.error.isEmpty
        for b in navigationButtons { b.isEnabled = !busy }
        navigationButtons.first?.isEnabled = !busy || loadingRepository
        navigationButtons.last?.isEnabled = !busy && git != nil

        organizationButton.isEnabled = !busy
        newBranchButton.isEnabled = normal && st.hasCommits
        resolveButton.isEnabled = available && st.conflicts
        continueButton.isEnabled = available && !st.operation.isEmpty && !st.conflicts
        abortButton.isEnabled = available && !st.operation.isEmpty
        recoveryRow.isHidden = st.operation.isEmpty && !st.conflicts
        advancedButton.isEnabled = normal && !st.detached && st.hasCommits
        for item in advancedItems {
            let squash = (item.representedObject as? Selector) == #selector(squashClicked)
            item.isEnabled = advancedButton.isEnabled && (squash || st.hasRemote)
        }
    }

    private func setBusy(_ on: Bool) {
        busy = on
        if on {
            completionMessage = nil
            activityLabel.stringValue = "Working…"
            activityLabel.tone = .soft
        } else if activityLabel.tone != .negative {
            activityLabel.stringValue = completionMessage.map { "✓ " + $0 } ?? "Ready"
            activityLabel.tone = completionMessage == nil ? .soft : .positive
            activityLabel.toolTip = activityLabel.stringValue
        }
        on ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        setEnabled(st.isRepo)
        if !on, let path = pendingPath {
            pendingPath = nil
            DispatchQueue.main.async { [weak self] in self?.open(path) }
        }
    }

    /// current repo, or complain
    /// `needBranch`: anything that talks to origin needs a real branch name,
    /// a detached HEAD would only produce a baffling git error.
    private func ready(needBranch: Bool = false, recovery: Bool = false) -> Git? {
        guard !busy else { return nil }
        guard let g = git else { UI.error("No folder selected", "Click “Open…” first."); return nil }
        guard st.isRepo else {
            UI.error("Not a Git repo", "Click “Initialize repository” first.")
            return nil
        }
        guard st.error.isEmpty else { UI.error("Repository unavailable", st.error); return nil }
        if !recovery && (!st.operation.isEmpty || st.conflicts) {
            UI.error("Unfinished operation", "Resolve files, then Continue, or Abort the current operation.")
            return nil
        }
        if needBranch && st.detached {
            UI.error("Detached HEAD", "You are not on a branch, so there is nothing to push or pull.\n"
                                    + "Use New branch to preserve this history on a branch.")
            return nil
        }
        return g
    }

    private func bg(_ block: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async(execute: block)
    }

    /// Finish an operation: re-read the repo, and only then hand the buttons
    /// back, so nothing can be clicked while the displayed state is stale.
    private func done() {
        onMain { self.refresh { self.setBusy(false) } }
    }

    private func workflow(_ g: Git) -> GitWorkflow {
        GitWorkflow(g, output: { [weak self] text in self?.log(text) })
    }

    // MARK: - actions

    @objc private func initRepo() {
        guard !busy, !st.isRepo, st.error.isEmpty, let g = git else { return }
        guard UI.confirm("Initialize repository?", "Start tracking this folder with Git:\n\(Paths.abbrev(g.path))\n\nFiles are saved in history only after you Commit.",
                         okTitle: "Initialize") else { return }
        section("Init " + Paths.abbrev(g.path))
        setBusy(true)
        bg {
            let r = g.initialize()
            self.log(r.text)
            guard r.ok else { self.bad("git init failed"); self.done(); return }
            do {
                try g.writeIgnore()
                self.ok("repo created on branch main")
            } catch {
                self.bad("Repo created, but .gitignore could not be written: \(error.localizedDescription)")
            }
            self.done()
            self.note("Use Remote to add origin when ready.")
        }
    }

    @objc private func commitOnly() { commit(push: false) }
    @objc private func commitAndPush() { commit(push: true) }

    /// The message the user typed, or a timestamp. Main thread only.
    private func commitMessage() -> String {
        let typed = msgField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "update " + f.string(from: Date())
    }

    /// Stage everything, then ask git — not our cached status — whether there
    /// is actually anything to commit. Files change behind the app's back.
    @discardableResult
    private func doCommit(_ g: Git, message: String) -> GitWorkflow.CommitOutcome {
        let result = workflow(g).commit(message: message)
        if result == .failed {
            bad("commit failed")
        } else if result == .committed {
            ok("committed: \(message)")
            onMain { self.msgField.stringValue = "" }
        }
        return result
    }

    private func commit(push: Bool) {
        guard let g = ready(needBranch: push) else { return }
        guard g.identityOK else {
            UI.error("Tell git who you are first",
                     "Every commit records a name and email. Configure these in Settings.")
            openSetup()
            return
        }
        let msg = commitMessage()
        let branch = st.branch
        section(push ? "Commit & Push" : "Commit")
        setBusy(true)
        bg {
            // a failed commit must not be followed by a push
            guard self.doCommit(g, message: msg) != .failed else { self.done(); return }
            if push { self.doPush(g, branch: branch) }
            self.done()
        }
    }

    private func doPush(_ g: Git, branch: String) {
        let r = workflow(g).push(branch: branch)
        if r.ok { ok("pushed"); return }
        bad("push rejected")
        if r.text.contains("non-fast-forward") || r.text.contains("fetch first") || r.text.contains("behind") {
            note("Remote has commits you don't have → click Pull (or Sync).")
            note("If you rewrote history on purpose → Force Push.")
        }
    }

    private func doPull(_ g: Git, branch: String) {
        let r = workflow(g).pull(branch: branch)
        if r.ok { ok("up to date"); return }
        bad("pull stopped")
        if r.text.contains("CONFLICT") || r.text.contains("could not apply") {
            note("Edit the conflicted files, use Resolve files to mark them resolved, then Continue. Abort cancels an in-progress rebase.")
        }
    }

    @objc private func pushClicked() {
        guard let g = ready(needBranch: true) else { return }
        section("Push")
        setBusy(true)
        let b = st.branch
        bg { self.doPush(g, branch: b); self.done() }
    }

    @objc private func pullClicked() {
        guard let g = ready(needBranch: true) else { return }
        section("Pull")
        setBusy(true)
        let b = st.branch
        bg { self.doPull(g, branch: b); self.done() }
    }

    @objc private func syncClicked() {
        guard let g = ready(needBranch: true) else { return }
        section("Sync (commit → pull → push)")
        setBusy(true)
        // every value the background work needs, read on the main thread
        let b = st.branch
        let msg = commitMessage()
        bg {
            let result = self.workflow(g).sync(branch: b, message: msg)
            if result.ok {
                self.ok("synced")
                self.onMain { self.msgField.stringValue = "" }
            } else { self.bad("Sync stopped. See the failed step above.") }
            self.done()
        }
    }

    // MARK: squash

    @objc private func squashClicked() {
        guard let g = ready() else { return }
        guard st.hasCommits else { UI.error("No commits yet"); return }
        guard !st.detached else {
            UI.error("Detached HEAD", "Check out a branch first.")
            return
        }
        if st.dirty {
            UI.error("Commit first", "Squash needs a clean working tree.")
            return
        }
        setBusy(true)
        var launched = false
        defer { if !launched { setBusy(false) } }
        let branch = st.branch
        let expectedHead = g.run(["rev-parse", "--verify", "HEAD"]).value
        let total = g.totalCommits
        guard let choice = UI.choose("Squash",
                                     "\(total) first-parent commits on \(branch). Merge side histories are included in the selected range.",
                                     ["Last N", "All into one", "Amend last"]) else { return }

        let lastMsg = g.run(["log", "--format=%s", "-n", "1"]).value
        var n = 0
        var msg = ""

        switch choice {
        case 0:
            guard total >= 2 else { UI.error("Only one commit"); return }
            guard let typed = UI.prompt("How many commits?", "2 … \(total)", value: "2") else { return }
            guard let k = Int(typed), k >= 2, k <= total else {
                UI.error("Need a whole number between 2 and \(total)", "“\(typed)” is not a whole number from 2 to \(total).")
                return
            }
            n = k
            let old = g.run(["log", "--format=%s", "-n", "1", "HEAD~\(k - 1)"]).value
            guard let m = UI.prompt("New commit message", value: old.isEmpty ? lastMsg : old) else { return }
            msg = m
        case 1:
            guard let m = UI.prompt("New commit message", value: "squash: all history") else { return }
            n = total
            msg = m
        default:
            guard let m = UI.prompt("Rewrite last message", value: lastMsg) else { return }
            n = 1
            msg = m
        }
        if msg.isEmpty { msg = lastMsg }
        if msg.isEmpty { msg = "squash" }        // git refuses an empty message

        section("Squash")
        launched = true
        bg {
            let result = self.workflow(g).squash(count: n, message: msg, branch: branch, expectedHead: expectedHead)
            if result.ok {
                self.ok("history rewritten")
                self.note("If this history was already pushed, review Force Push before publishing.")
            } else { self.bad("squash stopped; see the recovery branch above if one was created") }
            self.done()
        }
    }

    // MARK: force

    @objc private func forcePushClicked() {
        guard let g = ready(needBranch: true) else { return }
        guard st.hasRemote else { UI.error("No remote yet"); return }
        section("Force Push")
        setBusy(true)
        let b = st.branch
        bg {
            let workflow = self.workflow(g)
            guard let preview = workflow.previewForcePush(branch: b) else {
                self.bad("Could not verify origin. Nothing was pushed.")
                self.done(); return
            }
            self.onMain {
                let body: String
                if preview.remoteHead.isEmpty {
                    body = "origin has no branch “\(b)” yet — this just creates it."
                } else if preview.lost.isEmpty {
                    body = "Remote has nothing that you don't already have."
                } else {
                    body = "These remote commits will be GONE:\n\n\(preview.lost.prefix(8000))"
                }
                guard let pick = UI.choose("Overwrite origin/\(b) with your local branch?", body,
                                           ["Force push (safe)", "Force push (hard)"]) else {
                    self.note("cancelled"); self.done(); return
                }
                self.bg {
                    let r = workflow.forcePush(preview, hard: pick == 1)
                    if r.ok { self.ok("remote overwritten") }
                    else {
                        self.bad("force push failed")
                        if pick == 0 { self.note("The remote may have changed. Refresh the preview and review the new commits before retrying.") }
                    }
                    self.done()
                }
            }
        }
    }

    @objc private func forcePullClicked() {
        guard let g = ready(needBranch: true) else { return }
        guard st.hasRemote else { UI.error("No remote yet"); return }
        setBusy(true)
        var launched = false
        defer { if !launched { setBusy(false) } }
        let b = st.branch
        let body = """
        Your local branch becomes an exact copy of origin/\(b).

        Before that, JustGit saves your work:
        • a backup branch named backup-<time>
        • git stash of uncommitted and ignored files (large ignored folders can take time)
        """
        guard UI.confirm("Overwrite local \(b) with origin/\(b)?", body,
                         okTitle: "Overwrite local", destructive: true) else { return }
        section("Force Pull")
        launched = true
        bg {
            if self.workflow(g).forcePull(branch: b).ok {
                self.ok("local now matches origin/\(b)")
            } else {
                self.bad("Force Pull stopped. See the failed step and any recovery references above.")
            }
            self.done()
        }
    }

    // MARK: remote

    @objc private func setRemote() {
        guard let g = ready() else { return }
        setBusy(true)
        var launched = false
        defer { if !launched { setBusy(false) } }
        let current = st.remote
        guard let raw = UI.prompt("Remote URL",
                                  "Enter an HTTPS/SSH URL or a local repository path. HTTPS converts to SSH.",
                                  value: current,
                                  placeholder: "https://github.com/org/repo"),
              !raw.isEmpty else { return }
        let url = (RemoteURL.toSSH(raw) as NSString).expandingTildeInPath
        let local = url.hasPrefix("/") || url.hasPrefix(".") || url.hasPrefix("~") || url.hasPrefix("file://")
        guard (RemoteURL.isSSH(url) || local), !url.hasPrefix("-"), !url.contains("\n"), !url.contains("\r") else {
            UI.error("Invalid remote", "Use an SSH/HTTPS URL or a local repository path.")
            return
        }
        guard UI.confirm("Set origin?", "Fetch and push will use \(RemoteURL.redacted(url)).\nExisting origin URL overrides and fetch mappings will be replaced.",
                         okTitle: "Set origin") else { return }
        section("Remote")
        if url != raw { note("\(RemoteURL.redacted(raw))  →  \(RemoteURL.redacted(url))") }
        launched = true
        bg {
            let set = self.workflow(g).setOrigin(url)
            guard set.ok else { self.bad("could not set origin"); self.done(); return }
            self.ok("origin = \(RemoteURL.redacted(url))")
            if RemoteURL.isSSH(url) {
                let t = GitEnv.testConnection(host: url)
                let head = t.text.split(separator: "\n").prefix(2).joined(separator: "\n")
                if !head.isEmpty { self.log(head, .soft) }
                if !GitEnv.connectionSucceeded(t) {
                    self.bad("SSH test failed. Check the error above, the host/port in Remote, and your key in Settings.")
                }
            }
            self.done()
        }
    }

    // MARK: misc

    @objc private func newBranch() {
        guard let g = ready() else { return }
        setBusy(true)
        var launched = false
        defer { if !launched { setBusy(false) } }
        guard let name = UI.prompt("New branch", "Creates a branch at the current commit and keeps detached work.") else { return }
        guard g.run(["check-ref-format", "--branch", name]).ok else { UI.error("Invalid branch name"); return }
        launched = true
        bg {
            if !self.gx(g, ["switch", "-c", name]).ok { self.bad("Could not create the branch. Choose another name or inspect the error above.") }
            self.done()
        }
    }

    @objc private func continueOperation() { recover(abort: false) }
    @objc private func abortOperation() { recover(abort: true) }

    private func recover(abort: Bool) {
        guard let g = ready(recovery: true) else { return }
        setBusy(true)
        var launched = false
        defer { if !launched { setBusy(false) } }
        if abort && !UI.confirm("Abort the current operation?", "Conflict-resolution edits from this operation will be discarded.",
                                okTitle: "Abort", destructive: true) { return }
        launched = true
        bg {
            if !self.workflow(g).recover(abort: abort).ok { self.bad("Recovery stopped; inspect the error above.") }
            self.done()
        }
    }

    @objc private func resolveFiles() {
        guard let g = ready(recovery: true) else { return }
        setBusy(true)
        var launched = false
        defer { if !launched { setBusy(false) } }
        let result = g.run(["diff", "--name-only", "--diff-filter=U", "-z"])
        guard result.ok else { UI.error("Could not list conflicts", result.text); return }
        let files = result.out.split(separator: "\0").map(String.init)
        guard !files.isEmpty else {
            launched = true
            done()
            return
        }
        guard let index = UI.select("Resolve files", "Choose a file after editing it and removing conflict markers.", files),
              UI.confirm("Mark this file resolved?", files[index], okTitle: "Mark resolved") else { return }
        launched = true
        bg {
            if !self.workflow(g).resolve(file: files[index]).ok { self.bad("Could not mark the file resolved.") }
            self.done()
        }
    }

    @objc private func revealInFinder() {
        guard let g = git else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: g.path)
    }

    @objc private func openTerminal() {
        guard let g = git else { return }
        bg { _ = Shell.run("/usr/bin/open", ["-a", "Terminal", g.path], timeout: 20) }
    }

    @objc func openSetup() {
        SetupWindow.shared.show(log: { [weak self] s, isError in
            isError ? self?.bad(s) : self?.note(s)
        })
    }

    @objc func openSkin() { SkinWindow.shared.show() }

    /// The panel view. The menu bar popover hosts this instead of the window.
    var contentRoot: NSView { root }

    /// Exposed so the self-test can prove these still go through `advancedPicked`.
    var advancedMenuItems: [NSMenuItem] { advancedItems }

    /// Called when the repository changes, so the status item can name it.
    var onRepoChange: ((String?) -> Void)?

    /// The panel became visible; files may have changed behind our back.
    func panelDidAppear() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.busy, self.git != nil, NSApp.modalWindow == nil else { return }
            self.setBusy(true)
            self.refresh { self.setBusy(false) }
        }
    }

    // refresh whenever the user comes back to the window — files change behind our back
    func windowDidBecomeKey(_ n: Notification) { panelDidAppear() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if busy {
            UI.info("Operation in progress", "Wait for the current command to finish before closing JustGit.")
            return false
        }
        return true
    }

    var operationInProgress: Bool { busy }

    /// Exercise actual table/clip-view sizing without reading or writing user preferences.
    func verifySidebarLayout() -> Bool {
        guard SelfTest.headless else { return false }
        let saved = listedRepositories
        updatingRepositories = true
        defer { listedRepositories = saved; repoTable.reloadData(); updatingRepositories = false }
        listedRepositories = [Self.groupPrefix + String(repeating: "Long group ", count: 10)] +
            (0..<24).map { "/sample/" + String(repeating: "long-parent-", count: 8) + "/repository-\($0)-" + String(repeating: "wide-name-", count: 10) }
        repoTable.rowHeight = RepositoryRowMetrics.height
        repoTable.reloadData()
        root.layoutSubtreeIfNeeded()
        guard let scroll = repoTable.enclosingScrollView else { return false }
        for index in [0, 1, 12, 24] {
            repoTable.scrollRowToVisible(index)
            repoTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            repoTable.layoutSubtreeIfNeeded()
            guard let row = repoTable.rowView(atRow: index, makeIfNecessary: true),
                  let cell = repoTable.view(atColumn: 0, row: index, makeIfNecessary: true) as? RepositoryCellView else { return false }
            cell.layoutSubtreeIfNeeded()
            let selection = RepositoryRowMetrics.selection(in: row.bounds)
            let visible = row.convert(scroll.contentView.bounds, from: scroll.contentView)
            guard selection.minX >= visible.minX - 1, selection.maxX <= visible.maxX + 1 else { return false }
            for label in [cell.titleLabel, cell.pathLabel] where !label.isHidden {
                guard selection.contains(row.convert(label.bounds, from: label)) else { return false }
            }
        }
        return true
    }

    /// Render the actual panel from a disposable repository without restoring user settings.
    func documentationSnapshot(git source: Git, tab: Int, to path: String) throws {
        guard SelfTest.headless else { return }
        git = source
        st = source.status()
        guard st.error.isEmpty else { throw NSError(domain: "JustGit", code: 1,
            userInfo: [NSLocalizedDescriptionKey: st.error]) }
        listedRepositories = [source.path]
        repoTitle.stringValue = (source.path as NSString).lastPathComponent
        repoTable.reloadData()
        repoTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        paint(verbose: false)
        detailSelector.selectedSegment = tab
        detailTabs.selectTabViewItem(at: tab)
        window.setContentSize(NSSize(width: 1060, height: 640))
        root.layoutSubtreeIfNeeded()
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            throw NSError(domain: "JustGit", code: 2)
        }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "JustGit", code: 3)
        }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
