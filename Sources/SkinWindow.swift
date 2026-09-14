import AppKit

/// The skin editor. Copy the file, hand it to an LLM, paste the answer back.
final class SkinWindow: NSObject {

    static let shared = SkinWindow()

    private(set) var window: NSWindow?
    private let editor = SkinTextView()
    private let status = SkinLabel("", tone: .soft, delta: -1)

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
        w.title = "Skin 皮肤"
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 520, height: 520)
        if !SelfTest.headless { w.setFrameAutosaveName("JustGitSkin") }

        let content = SkinView()
        w.contentView = content

        let title = V.title("Skin 皮肤", delta: 3)
        let blurb = SkinLabel("Colours and type only — a skin can never move anything.\n"
                            + "只改颜色和字体，不会动排版。",
                              tone: .soft, delta: -1)
        blurb.lineBreakMode = .byWordWrapping
        blurb.maximumNumberOfLines = 2

        // presets
        var presetButtons: [NSView] = [V.eyebrow("Start from 预设")]
        for (i, p) in Theme.presets.enumerated() {
            let b = SkinButton(p.name, self, #selector(usePreset(_:)), kind: .quiet)
            b.tag = i
            presetButtons.append(b)
        }
        presetButtons.append(NSView())
        let presets = V.hstack(presetButtons, spacing: 4)

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
        let copyBtn = SkinButton("Copy for LLM 复制给 LLM", self, #selector(copyForLLM), kind: .primary,
                                 tooltip: "Copies the skin plus instructions. Paste it to any chatbot.")
        let pasteBtn = SkinButton("Paste & Apply 粘贴应用", self, #selector(pasteAndApply),
                                  tooltip: "Reads the clipboard and applies it")
        let applyBtn = SkinButton("Apply 应用", self, #selector(applyEditor), key: "\r", tooltip: "⌘↩")
        let resetBtn = SkinButton("Reset 恢复默认", self, #selector(resetSkin), kind: .quiet)
        let row = V.hstack([copyBtn, pasteBtn, NSView()])
        let applyRow = V.hstack([applyBtn, resetBtn, NSView()])

        let how = SkinLabel("1 Copy · 2 tell the LLM what you want · 3 paste its answer back\n"
                          + "1 复制 · 2 告诉大模型你想要什么风格 · 3 把它给的 JSON 粘回来",
                            tone: .faint, delta: -1.5)
        how.lineBreakMode = .byWordWrapping
        how.maximumNumberOfLines = 2

        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 6

        let rows: [NSView] = [title, blurb, Hairline(), presets, scroll, row, applyRow, Hairline(), how, status]
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
    }

    /// Put the current skin in the editor. Callers that have something more
    /// specific to say set the status line themselves afterwards.
    private func reload() {
        editor.string = Skin.theme.json
        editor.restyle()
        status.tone = .soft
        status.stringValue = "Wearing “\(Skin.theme.name)”. 当前皮肤：\(Skin.theme.name)"
    }

    private func report(_ problems: [String]) {
        if problems.isEmpty {
            status.tone = .positive
            status.stringValue = "✓ Applied “\(Skin.theme.name)”. 已应用。"
        } else {
            status.tone = .caution
            status.stringValue = "Applied with notes 已应用，但有几点：\n· " + problems.joined(separator: "\n· ")
        }
    }

    // MARK: actions

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
        status.stringValue = "Copied. Paste it into any chatbot, say what you want, paste the answer back.\n"
                           + "已复制。粘给大模型，说清楚你要什么风格，再把它的回答粘回来。"
    }

    @objc private func pasteAndApply() {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else {
            status.tone = .negative
            status.stringValue = "Clipboard is empty. 剪贴板是空的。"
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
                               + "\nNothing changed. 没有改动。"
            return
        }
        Skin.set(result.theme)      // repaints every window, this one included
        editor.string = result.theme.json      // normalise what they see
        editor.restyle()
        report(result.problems)
    }

    @objc private func resetSkin() {
        Skin.reset()
        reload()
        status.tone = .soft
        status.stringValue = "Back to Atelier. 已恢复默认皮肤。"
    }
}
