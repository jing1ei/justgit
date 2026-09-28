import AppKit

/// The skin editor. Copy the file, hand it to an LLM, paste the answer back.
final class SkinWindow: NSObject {

    static let shared = SkinWindow()

    private(set) var window: NSWindow?
    private let editor = SkinTextView()
    private let status = SkinLabel("", tone: .soft, delta: -1)
    private let modeLabel = SkinLabel("", tone: .soft, delta: -1)
    private var loadedCode = ""

    func show() {
        if window == nil {
            build()
            window?.center()          // only the first time; after that the frame is remembered
            reload()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: build

    func build() {
        guard window == nil else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 660),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Appearance"
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 520, height: 520)
        if !SelfTest.headless { w.setFrameAutosaveName("JustGitSkin") }

        let content = SkinView()
        w.contentView = content

        let title = V.title("Appearance", delta: 3)
        let blurb = SkinLabel("Follow your system, choose a preset, or edit style code. Layout stays fixed.",
                              tone: .soft, delta: -1)
        blurb.lineBreakMode = .byWordWrapping
        blurb.maximumNumberOfLines = 2

        // presets
        var presetButtons: [NSView] = [V.eyebrow("Start from")]
        for (i, p) in Theme.presets.enumerated() {
            let b = SkinButton(p.name, self, #selector(usePreset(_:)), kind: .quiet)
            b.tag = i
            presetButtons.append(b)
        }
        presetButtons.append(NSView())
        let presets = V.hstack(presetButtons, spacing: 4)
        let automaticRow = V.hstack([V.button("Automatic", self, #selector(useAutomatic)), modeLabel, NSView()])

        // editor
        editor.usesConsoleColours = false
        editor.isEditable = true
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.restyle()

        let scroll = SkinWell()
        scroll.usesConsoleColours = false
        scroll.documentView = editor
        scroll.restyle()

        // actions — ⌘↩ applies; a bare Return has to stay free for the editor
        let copyBtn = SkinButton("Copy for LLM", self, #selector(copyForLLM), kind: .primary,
                                 tooltip: "Copies the skin plus instructions. Paste it to any chatbot.")
        let codeBtn = SkinButton("Copy code", self, #selector(copyCode),
                                 tooltip: "Copy the editable JSON without instructions.")
        let pasteBtn = SkinButton("Paste & Apply", self, #selector(pasteAndApply),
                                  tooltip: "Reads the clipboard and applies it")
        let applyBtn = SkinButton("Apply", self, #selector(applyEditor), key: "\r", tooltip: "⌘↩")
        let resetBtn = SkinButton("Reset to automatic", self, #selector(resetSkin), kind: .quiet)
        let row = V.hstack([codeBtn, copyBtn, pasteBtn, NSView()])
        let applyRow = V.hstack([applyBtn, resetBtn, NSView()])

        let how = SkinLabel("Copy code and edit it yourself, or Copy for LLM. Paste & Apply the result, or edit above and press Apply.",
                            tone: .faint, delta: -1.5)
        how.lineBreakMode = .byWordWrapping
        how.maximumNumberOfLines = 2

        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 6

        let rows: [NSView] = [title, blurb, automaticRow, Hairline(), presets, scroll, row, applyRow, Hairline(), how, status]
        let stack = V.vstack(rows, spacing: 10, align: .leading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        for r in rows {
            r.translatesAutoresizingMaskIntoConstraints = false
            r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        window = w
        Skin.repaint(w)
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged), name: Skin.changed, object: nil)
    }

    /// Put the current skin in the editor. Callers that have something more
    /// specific to say set the status line themselves afterwards.
    private func reload() {
        editor.string = Skin.theme.json
        loadedCode = editor.string
        editor.restyle()
        status.tone = .soft
        status.stringValue = "Edit here, or copy code to revise elsewhere."
        updateMode()
    }

    private func updateMode() {
        modeLabel.stringValue = Skin.automatic ? "Following system · \(Skin.isDark ? "Dark" : "Light")" : "Custom · \(Skin.theme.name)"
    }

    @objc private func appearanceChanged() {
        updateMode()
        if editor.string == loadedCode {
            editor.string = Skin.theme.json
            loadedCode = editor.string
        }
    }

    @objc private func useAutomatic() { Skin.followSystem(); reload() }

    private func report(_ problems: [String]) {
        if problems.isEmpty {
            status.tone = .positive
            status.stringValue = "✓ Applied “\(Skin.theme.name)”."
        } else {
            status.tone = .caution
            status.stringValue = "Applied with notes:\n· " + problems.joined(separator: "\n· ")
        }
    }

    // MARK: actions

    @objc private func copyCode() {
        UI.copyToClipboard(editor.string)
        status.tone = .positive
        status.stringValue = "Style code copied. Edit it, then use Paste & Apply."
    }

    @objc private func usePreset(_ sender: NSButton) {
        guard Theme.presets.indices.contains(sender.tag) else { return }
        Skin.set(Theme.presets[sender.tag])
        reload()
        status.tone = .positive
        status.stringValue = "✓ \(Skin.theme.name)"
    }

    @objc private func copyForLLM() {
        // copy exactly what is on screen, so hand-edits travel too
        let result = Theme.parse(editor.string, base: Skin.theme)
        guard result.isJSON else {
            status.tone = .negative
            status.stringValue = result.problems.joined(separator: "\n")
            return
        }
        UI.copyToClipboard(result.theme.briefForLLM)
        status.tone = .positive
        status.stringValue = "Copied. Paste it into any chatbot, say what you want, paste the answer back."
    }

    @objc private func pasteAndApply() {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else {
            status.tone = .negative
            status.stringValue = "Clipboard is empty."
            return
        }
        editor.string = s
        applyEditor()
    }

    @objc private func applyEditor() {
        let result = Theme.parse(editor.string, base: Skin.theme)
        guard result.isJSON else {
            status.tone = .negative
            status.stringValue = (result.problems.first ?? "Could not read that.")
                               + "\nNothing changed."
            return
        }
        Skin.set(result.theme)      // repaints every window, this one included
        editor.string = result.theme.json      // normalise what they see
        loadedCode = editor.string
        editor.restyle()
        report(result.problems)
    }

    @objc private func resetSkin() {
        Skin.reset()
        reload()
        status.tone = .soft
        status.stringValue = "Following the system appearance."
    }
}
