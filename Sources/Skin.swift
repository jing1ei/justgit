import AppKit

// MARK: - the live palette
//
// Skin owns the one Theme the app is currently wearing, hands out resolved
// NSColors/NSFonts, and tells every control to repaint when it changes.

enum Skin {

    static let changed = Notification.Name("SkinChanged")
    private static let storeKey = "skinJSON"
    private static let modeKey = "appearanceMode"
    private static var appearanceObservation: NSKeyValueObservation?
    private(set) static var automatic = true

    private(set) static var theme = Theme.opal
    private(set) static var c = Palette(.opal)

    struct Palette {
        let canvas, panel, ink, inkSoft, inkFaint, rule: NSColor
        let accent, positive, negative, caution: NSColor
        let consoleBg, consoleInk: NSColor

        init(_ t: Theme) {
            func c(_ s: String, _ fallback: NSColor) -> NSColor { Hex.color(s) ?? fallback }
            canvas     = c(t.canvas,     .white)
            panel      = c(t.panel,      .white)
            ink        = c(t.ink,        .black)
            inkSoft    = c(t.inkSoft,    .darkGray)
            inkFaint   = c(t.inkFaint,   .gray)
            rule       = c(t.rule,       .lightGray)
            accent     = c(t.accent,     .systemBlue)
            positive   = c(t.positive,   .systemGreen)
            negative   = c(t.negative,   .systemRed)
            caution    = c(t.caution,    .systemOrange)
            consoleBg  = c(t.consoleBg,  .black)
            consoleInk = c(t.consoleInk, .white)
        }
    }

    /// Dark skins need the system chrome (traffic lights, scrollbars, alerts,
    /// the text caret) to flip too, or half the app stops being readable.
    static var isDark: Bool { Hex.luminance(c.canvas) < 0.45 }

    // MARK: fonts

    static func display(_ delta: CGFloat = 0, _ weight: NSFont.Weight = .regular) -> NSFont {
        font(theme.fontDisplay, CGFloat(theme.sizeDisplay) + delta, mono: false, weight: weight)
    }

    static func ui(_ delta: CGFloat = 0, _ weight: NSFont.Weight = .regular) -> NSFont {
        font(theme.fontUI, CGFloat(theme.sizeUI) + delta, mono: false, weight: weight)
    }

    static func mono(_ delta: CGFloat = 0, _ weight: NSFont.Weight = .regular) -> NSFont {
        font(theme.fontMono, CGFloat(theme.sizeMono) + delta, mono: true, weight: weight)
    }

    private static func font(_ family: String, _ size: CGFloat, mono: Bool, weight: NSFont.Weight) -> NSFont {
        let size = max(8, size)
        if family.isEmpty || family.caseInsensitiveCompare("system") == .orderedSame {
            return mono ? .monospacedSystemFont(ofSize: size, weight: weight)
                        : .systemFont(ofSize: size, weight: weight)
        }
        guard let base = NSFont(name: family, size: size) else {
            return mono ? .monospacedSystemFont(ofSize: size, weight: weight)
                        : .systemFont(ofSize: size, weight: weight)
        }
        if weight.rawValue >= NSFont.Weight.semibold.rawValue {
            return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        }
        return base
    }

    // MARK: load / save

    static func load() {
        let raw = UserDefaults.standard.string(forKey: storeKey)
        automatic = UserDefaults.standard.string(forKey: modeKey).map { $0 == "automatic" } ?? (raw == nil)
        if let raw = raw {
            theme = Theme.parse(raw, base: .opal).theme
        }
        if automatic { theme = systemTheme(dark: systemIsDark) }
        c = Palette(theme)
        applyAppearance()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            DispatchQueue.main.async { refreshSystemAppearance() }
        }
    }

    private static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func systemTheme(dark: Bool) -> Theme {
        dark ? .systemDark : .opal
    }

    static func followSystem() {
        automatic = true
        if !SelfTest.headless { UserDefaults.standard.set("automatic", forKey: modeKey) }
        apply(systemTheme(dark: systemIsDark))
    }

    static func refreshSystemAppearance(dark: Bool? = nil) {
        guard automatic else { return }
        let next = systemTheme(dark: dark ?? systemIsDark)
        if next != theme { apply(next) }
    }

    /// Apply themes to app content, leaving system-owned menu-bar windows alone.
    static func set(_ t: Theme) {
        automatic = false
        if !SelfTest.headless {
            UserDefaults.standard.set(t.json, forKey: storeKey)
            UserDefaults.standard.set("custom", forKey: modeKey)
        }
        apply(t)
    }

    private static func apply(_ t: Theme) {
        theme = t
        c = Palette(t)
        applyAppearance()
        for w in NSApp.windows { repaint(w) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func reset() { followSystem() }

    private static func applyAppearance() {
        // A global override also changes AppKit's status-item window.
        // Theme individual content windows; the menu bar follows macOS.
        NSApp.appearance = nil
    }

    /// Walk a window and let every skin-aware control repaint itself.
    static func repaint(_ window: NSWindow) {
        guard let content = window.contentView, containsAppContent(content) else { return }
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.backgroundColor = c.canvas
        repaint(content)
        UI.fit(window)
    }

    private static func containsAppContent(_ view: NSView) -> Bool {
        view is SkinView || view.subviews.contains(where: containsAppContent)
    }

    /// A scroll view's documentView is already reachable through its clip view,
    /// so plain subview recursion covers the whole tree exactly once.
    static func repaint(_ view: NSView) {
        (view as? Skinnable)?.restyle()
        for sub in view.subviews { repaint(sub) }
    }
}

/// Anything that paints itself from the palette.
protocol Skinnable: AnyObject {
    func restyle()
}

// MARK: - text styling

enum StyledText {
    static func readable(_ preferred: NSColor, on background: NSColor) -> NSColor {
        if Hex.contrast(preferred, background) >= 4.5 { return preferred }
        return Hex.contrast(.black, background) >= Hex.contrast(.white, background) ? .black : .white
    }
    static func attributed(_ text: String, font: NSFont, colour: NSColor,
                           tracking: CGFloat = 0, uppercased: Bool = false,
                           alignment: NSTextAlignment = .natural,
                           breakMode: NSLineBreakMode = .byTruncatingTail) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = breakMode
        paragraph.lineSpacing = breakMode == .byWordWrapping ? 2 : 0
        return NSAttributedString(string: uppercased ? text.uppercased() : text, attributes: [
            .font: font, .foregroundColor: colour, .paragraphStyle: paragraph, .kern: tracking,
        ])
    }
}

// MARK: - controls

/// A non-editable piece of text.
final class SkinLabel: NSTextField, Skinnable {

    enum Tone { case ink, soft, faint, accent, positive, negative, caution }
    enum Face { case ui, mono, display }

    var tone: Tone = .ink { didSet { restyle() } }
    var face: Face = .ui
    var sizeDelta: CGFloat = 0
    var weight: NSFont.Weight = .regular
    var tracking: CGFloat = 0
    var uppercased = false
    /// Off for mono text, where a smaller second font would break the grid.
    var styled = true

    private var text = ""
    private var styling = false

    override var stringValue: String {
        get { super.stringValue }
        set {
            guard !styling else { super.stringValue = newValue; return }
            text = newValue
            restyle()
        }
    }

    convenience init(_ text: String, tone: Tone = .ink, delta: CGFloat = 0,
                     weight: NSFont.Weight = .regular, mono: Bool = false) {
        self.init(labelWithString: "")
        self.tone = tone
        self.face = mono ? .mono : .ui
        self.sizeDelta = delta
        self.weight = weight
        self.styled = !mono
        self.text = text
        lineBreakMode = .byTruncatingTail
        restyle()
    }

    func restyle() {
        let font: NSFont
        switch face {
        case .ui:      font = Skin.ui(sizeDelta, weight)
        case .mono:    font = Skin.mono(sizeDelta, weight)
        case .display: font = Skin.display(sizeDelta, weight)
        }
        let colour = Skin.color(for: tone)
        styling = true
        if styled {
            attributedStringValue = StyledText.attributed(
                text, font: font, colour: colour,
                tracking: tracking, uppercased: uppercased, breakMode: lineBreakMode)
        } else {
            self.font = font
            textColor = colour
            super.stringValue = text
        }
        styling = false
    }
}

extension Skin {
    static func color(for tone: SkinLabel.Tone) -> NSColor {
        switch tone {
        case .ink:      return c.ink
        case .soft:     return c.inkSoft
        case .faint:    return c.inkFaint
        case .accent:   return c.accent
        case .positive: return c.positive
        case .negative: return c.negative
        case .caution:  return c.caution
        }
    }
}

/// Flat, borderless, quietly expensive-looking.
final class SkinButton: NSButton, Skinnable {
    private final class TitleCell: NSButtonCell {
        override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
            guard let button = controlView as? SkinButton else { return super.drawTitle(title, withFrame: frame, in: controlView) }
            // AppKit otherwise dims disabled titles a second time and can substitute
            // system highlight colors for our custom background.
            let bounds = controlView.bounds.insetBy(dx: button.padH, dy: 0)
            let height = min(button.attributedTitle.size().height, bounds.height)
            let textFrame = NSRect(x: bounds.minX, y: bounds.midY - height / 2,
                                   width: bounds.width, height: height)
            button.attributedTitle.draw(in: textFrame)
            return textFrame
        }
    }

    enum Kind { case primary, normal, quiet, micro, danger }

    var kind: Kind = .normal { didSet { restyle() } }
    private var hovering = false
    private var padH: CGFloat {
        switch kind {
        case .quiet, .micro: return 7
        default:             return 14
        }
    }
    /// Grows with the skin's UI size so a large font is never clipped, but
    /// never shrinks below the values the layout was designed around.
    private var height: CGFloat {
        let pt = Skin.ui(fontDelta).pointSize
        switch kind {
        case .quiet, .micro: return max(20, ceil(pt * 1.8))
        default:             return max(28, ceil(pt * 2.1))
        }
    }
    private var fontDelta: CGFloat {
        switch kind {
        case .micro: return -2.5
        case .quiet: return -1.5
        default:     return -0.5
        }
    }

    convenience init(_ title: String, _ target: AnyObject?, _ action: Selector?,
                     kind: Kind = .normal, key: String = "", tooltip: String = "") {
        self.init(title: title, target: target, action: action)
        let titleCell = TitleCell(textCell: title)
        titleCell.setButtonType(.momentaryPushIn)
        cell = titleCell
        self.title = title
        self.target = target
        self.action = action
        self.kind = kind
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = kind == .micro || kind == .quiet ? 3 : 4
        layer?.masksToBounds = true
        if !key.isEmpty {
            keyEquivalent = key
            // AppKit defaults the modifier mask to nothing, which makes a bare
            // "o" fire while the user is typing in a text field. Every shortcut
            // here is a Command shortcut; Return alone stays reserved for the
            // field that has focus.
            keyEquivalentModifierMask = [.command]
        }
        if !tooltip.isEmpty { toolTip = tooltip }
        restyle()
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.length > 0
            ? attributedTitle.size().width
            : (title as NSString).size(withAttributes: [.font: Skin.ui()]).width
        return NSSize(width: ceil(text) + padH * 2, height: height)
    }

    override var isEnabled: Bool { didSet { if oldValue != isEnabled { paint() } } }
    override var isHighlighted: Bool { didSet { paint() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; paint() }
    override func mouseExited(with e: NSEvent) { hovering = false; paint() }

    func restyle() {
        paint()
        invalidateIntrinsicContentSize()
    }

    static func colors(kind: Kind, enabled: Bool, highlighted: Bool, hovering: Bool) -> (face: NSColor, text: NSColor) {
        var face = kind == .primary && enabled ? Skin.c.accent : Skin.c.panel
        if enabled && (highlighted || hovering) {
            face = face.blended(withFraction: highlighted ? 0.12 : 0.05,
                                of: Skin.isDark ? .white : .black) ?? face
        }
        let colour: NSColor
        switch kind {
        case .primary: colour = enabled ? (Skin.isDark ? Skin.c.canvas : .white) : Skin.c.inkSoft
        case .normal:  colour = Skin.c.ink
        case .quiet:   colour = Skin.c.inkSoft
        case .micro:   colour = Skin.c.inkFaint
        case .danger:  colour = Skin.c.negative
        }
        return (face, StyledText.readable(enabled ? colour : Skin.c.inkSoft, on: face))
    }

    private func paint() {
        guard let layer = layer else { return }
        let colors = Self.colors(kind: kind, enabled: isEnabled, highlighted: isHighlighted, hovering: hovering)
        attributedTitle = StyledText.attributed(
            title,
            font: Skin.ui(fontDelta, kind == .primary ? .medium : .regular),
            colour: colors.text,
            tracking: kind == .micro ? 1.1 : 0.2,
            uppercased: kind == .micro,
            alignment: .center)
        let border = kind == .danger && isEnabled ? Skin.c.negative : Skin.c.rule
        layer.backgroundColor = colors.face.cgColor
        layer.borderColor = border.cgColor
        layer.borderWidth = kind == .quiet || kind == .micro ? 0 : 1
        alphaValue = 1
        needsDisplay = true
    }
}

/// Editable text with breathing room and an accent underline on focus.
final class SkinField: NSTextField, Skinnable {

    private final class PadCell: NSTextFieldCell {
        var xPad: CGFloat = 9
        private func inner(_ rect: NSRect) -> NSRect {
            let r = super.drawingRect(forBounds: rect)
            let h = min(r.height, cellSize(forBounds: rect).height)
            return NSRect(x: r.origin.x + xPad, y: r.origin.y + (r.height - h) / 2,
                          width: max(0, r.width - xPad * 2), height: h)
        }
        override func drawingRect(forBounds rect: NSRect) -> NSRect { inner(rect) }
        override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText,
                           delegate: Any?, event: NSEvent?) {
            super.edit(withFrame: inner(rect), in: view, editor: editor, delegate: delegate, event: event)
        }
        override func select(withFrame rect: NSRect, in view: NSView, editor: NSText,
                             delegate: Any?, start: Int, length: Int) {
            super.select(withFrame: inner(rect), in: view, editor: editor,
                         delegate: delegate, start: start, length: length)
        }
    }

    /// Kept separately: once placeholderAttributedString is set, reading
    /// placeholderString back no longer gives us the original text.
    private var placeholderText = ""
    private var heightConstraint: NSLayoutConstraint?

    convenience init(_ placeholder: String) {
        self.init(frame: .zero)
        let cell = PadCell(textCell: "")
        cell.isEditable = true
        cell.isSelectable = true
        cell.isScrollable = true
        cell.wraps = false
        cell.usesSingleLineMode = true
        cell.lineBreakMode = .byClipping
        self.cell = cell
        placeholderText = placeholder
        placeholderString = placeholder
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        wantsLayer = true
        let h = heightAnchor.constraint(equalToConstant: 28)
        h.isActive = true
        heightConstraint = h
        restyle()
    }

    /// currentEditor() is non-nil only while this field is the one being edited.
    private var focused: Bool { currentEditor() != nil }

    override func becomeFirstResponder() -> Bool {
        let r = super.becomeFirstResponder(); needsDisplay = true; return r
    }
    override func textDidEndEditing(_ n: Notification) {
        super.textDidEndEditing(n); needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        let body = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        Skin.c.panel.setFill()
        body.fill()
        // The rule belongs under the text, whichever way this view is hung.
        let h: CGFloat = focused ? 1.5 : 1
        let y = isFlipped ? bounds.height - h : 0
        (focused ? Skin.c.accent : Skin.c.rule).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: y, width: bounds.width, height: h)).fill()
        super.draw(dirty)
    }

    func restyle() {
        let f = Skin.ui()
        font = f
        textColor = Skin.c.ink
        // follow the skin's type size so a big font is never clipped
        heightConstraint?.constant = max(28, ceil(f.pointSize * 2.1))
        if !placeholderText.isEmpty {
            placeholderAttributedString = NSAttributedString(string: placeholderText, attributes: [
                .font: f, .foregroundColor: Skin.c.inkFaint,
            ])
        }
        if let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = Skin.c.accent
        }
        needsDisplay = true
    }
}

/// A 1px rule. Replaces NSBox so the colour is ours.
final class Hairline: NSView, Skinnable {
    convenience init() {
        self.init(frame: .zero)
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 1).isActive = true
        restyle()
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    func restyle() { layer?.backgroundColor = Skin.c.rule.cgColor }
}

/// A shallow well: the log, and the public key in Setup. One hairline, no shadow.
final class SkinWell: NSScrollView, Skinnable {
    var usesConsoleColours = true
    convenience init() {
        self.init(frame: .zero)
        hasVerticalScroller = true
        borderType = .noBorder
        drawsBackground = false
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        restyle()
    }
    func restyle() {
        layer?.borderWidth = 1
        layer?.borderColor = Skin.c.rule.cgColor
        layer?.backgroundColor = (usesConsoleColours ? Skin.c.consoleBg : Skin.c.panel).cgColor
    }
}

/// The log well and the public-key well.
final class SkinTextView: NSTextView, Skinnable {
    var usesConsoleColours = true
    func restyle() {
        drawsBackground = true
        backgroundColor = usesConsoleColours ? Skin.c.consoleBg : Skin.c.panel
        textColor = usesConsoleColours ? Skin.c.consoleInk : Skin.c.ink
        font = Skin.mono()
        insertionPointColor = Skin.c.accent
        selectedTextAttributes = [
            .backgroundColor: Skin.c.accent.withAlphaComponent(0.30),
            .foregroundColor: usesConsoleColours ? Skin.c.consoleInk : Skin.c.ink,
        ]
    }
}

/// Subtle frosted tint without backdrop blur or extra compositing layers.
class SkinView: NSView, Skinnable {
    func restyle() {
        wantsLayer = true
        layer?.backgroundColor = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let end = Skin.c.canvas.blended(withFraction: 0.72, of: Skin.c.panel) ?? Skin.c.panel
        NSGradient(starting: Skin.c.canvas, ending: end)?.draw(in: bounds, angle: -35)
    }
}
