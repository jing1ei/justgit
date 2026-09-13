import AppKit

// MARK: - tiny dialog helpers

enum UI {

    private static func dress(_ a: NSAlert) {
        a.window.appearance = NSAppearance(named: Skin.isDark ? .darkAqua : .aqua)
    }

    static func info(_ title: String, _ body: String = "") {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .informational
        a.addButton(withTitle: "OK")
        dress(a)
        a.runModal()
    }

    static func error(_ title: String, _ body: String = "") {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .warning
        a.addButton(withTitle: "OK")
        dress(a)
        a.runModal()
    }

    /// returns true if the user confirmed
    static func confirm(_ title: String, _ body: String, okTitle: String = "Continue 继续", destructive: Bool = false) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = destructive ? .critical : .warning
        let ok = a.addButton(withTitle: okTitle)
        a.addButton(withTitle: "Cancel 取消")
        if destructive, #available(macOS 11.0, *) { ok.hasDestructiveAction = true }
        dress(a)
        return a.runModal() == .alertFirstButtonReturn
    }

    /// one-line text prompt; nil when cancelled
    static func prompt(_ title: String, _ body: String = "", value: String = "", placeholder: String = "", okTitle: String = "OK") -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: okTitle)
        a.addButton(withTitle: "Cancel 取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        field.font = Skin.ui()
        a.accessoryView = field
        a.window.initialFirstResponder = field
        dress(a)
        let r = a.runModal()
        guard r == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// n-way choice; returns the index of the option picked, nil when cancelled.
    static func choose(_ title: String, _ body: String, _ options: [String]) -> Int? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        for o in options { a.addButton(withTitle: o) }
        a.addButton(withTitle: "Cancel 取消")
        dress(a)
        let r = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        // an aborted or stopped modal returns something far outside the range,
        // and a negative index here would be read as a real answer
        return options.indices.contains(r) ? r : nil
    }

    static func pickFolder(_ title: String = "Choose a folder 选择文件夹") -> String? {
        let p = NSOpenPanel()
        p.title = title
        p.prompt = "Select"
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = true
        p.appearance = NSAppearance(named: Skin.isDark ? .darkAqua : .aqua)
        return p.runModal() == .OK ? p.url?.path : nil
    }

    static func select(_ title: String, _ body: String, _ options: [String]) -> Int? {
        guard !options.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "Choose")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        popup.addItems(withTitles: options)
        alert.accessoryView = popup
        dress(alert)
        return alert.runModal() == .alertFirstButtonReturn ? popup.indexOfSelectedItem : nil
    }

    static func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func fit(_ window: NSWindow) {
        guard let content = window.contentView else { return }
        let size = content.fittingSize
        window.contentMinSize = NSSize(width: max(520, ceil(size.width)),
                                       height: max(480, ceil(size.height)))
        let current = content.frame.size
        window.setContentSize(NSSize(width: max(current.width, window.contentMinSize.width),
                                     height: max(current.height, window.contentMinSize.height)))
    }
}

// MARK: - small view builders
//
// Everything here returns a skin-aware control, so a theme change repaints the
// whole app without any view needing to know about it.

enum V {

    static func label(_ text: String, tone: SkinLabel.Tone = .ink, delta: CGFloat = 0,
                      weight: NSFont.Weight = .regular, mono: Bool = false) -> SkinLabel {
        SkinLabel(text, tone: tone, delta: delta, weight: weight, mono: mono)
    }

    /// A heading in the display face.
    static func title(_ text: String, delta: CGFloat = 0) -> SkinLabel {
        let l = SkinLabel(text)
        l.face = .display
        l.sizeDelta = delta
        l.restyle()
        return l
    }

    /// Tiny, tracked, uppercase — the section marks that carry the whole layout.
    static func eyebrow(_ text: String) -> SkinLabel {
        let l = SkinLabel(text, tone: .faint, delta: -3)
        l.tracking = 1.4
        l.uppercased = true
        l.restyle()
        return l
    }

    static func button(_ title: String, _ target: AnyObject, _ action: Selector,
                       kind: SkinButton.Kind = .normal, key: String = "", tooltip: String = "") -> SkinButton {
        SkinButton(title, target, action, kind: kind, key: key, tooltip: tooltip)
    }

    static func field(_ placeholder: String) -> SkinField {
        SkinField(placeholder)
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 8, align: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = align
        s.spacing = spacing
        return s
    }

    static func vstack(_ views: [NSView], spacing: CGFloat = 8, align: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = align
        s.spacing = spacing
        return s
    }

    static func hairline() -> Hairline { Hairline() }
}
