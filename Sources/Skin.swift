import AppKit

// MARK: - the live palette
//
// Skin owns the one Theme the app is currently wearing, hands out resolved
// NSColors/NSFonts, and tells every control to repaint when it changes.

enum Skin {

    static let changed = Notification.Name("SkinChanged")
    private static let storeKey = "skinJSON"

    private(set) static var theme = Theme.atelier
    private(set) static var c = Palette(.atelier)

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
        if let raw = UserDefaults.standard.string(forKey: storeKey) {
            theme = Theme.parse(raw, base: .atelier).theme
        }
        c = Palette(theme)
        applyAppearance()
    }

    /// Wear a theme: persist it, flip the system appearance, repaint every open
    /// window, then tell interested controllers. `set` is the only repainter —
    /// observers must not repaint their own window again or the app pays for
    /// the whole view tree twice on every keystroke in the skin editor.
    static func set(_ t: Theme) {
        guard t != theme else { return }
        theme = t
        c = Palette(t)
        UserDefaults.standard.set(t.json, forKey: storeKey)
        applyAppearance()
        for w in NSApp.windows { repaint(w) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func reset() { set(.atelier) }

    private static func applyAppearance() {
        NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    /// Walk a window and let every skin-aware control repaint itself.
    static func repaint(_ window: NSWindow) {
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.backgroundColor = c.canvas
        if let v = window.contentView { repaint(v) }
        UI.fit(window)
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

// MARK: - bilingual setting
//
// Every label in this app reads "Force Pull 强制覆盖本地". Setting the two halves
// in one weight and one colour makes the window look crowded. So: find where the
// Chinese starts, and set that half a shade lighter and a touch smaller. It costs
// nothing, and the eye reads the English line first and the gloss second.

enum Bilingual {

    static func split(_ s: String) -> (latin: String, han: String) {
        guard let i = s.unicodeScalars.firstIndex(where: isHan) else { return (s, "") }
        let cut = String.Index(i, within: s) ?? s.startIndex
        let latin = String(s[s.startIndex..<cut]).trimmingCharacters(in: .whitespaces)
        let han = String(s[cut...]).trimmingCharacters(in: .whitespaces)
        return latin.isEmpty ? (han, "") : (latin, han)
    }

    private static func isHan(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3000...0x303F,          // CJK punctuation （）、。
             0x3400...0x4DBF,          // extension A
             0x4E00...0x9FFF,          // the main block
             0xF900...0xFAFF,          // compatibility
             0xFF00...0xFFEF:          // fullwidth forms
            return true
        default:
            return false
        }
    }

    /// One line of type, English then Chinese, in the app's voice.
    static func attributed(_ s: String,
                           font: NSFont,
                           colour: NSColor,
                           soft: NSColor,
                           tracking: CGFloat = 0,
                           uppercased: Bool = false,
                           alignment: NSTextAlignment = .natural,
                           breakMode: NSLineBreakMode = .byTruncatingTail) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.alignment = alignment
        p.lineBreakMode = breakMode
        p.lineSpacing = breakMode == .byWordWrapping ? 2 : 0

        let (latin, han) = split(s)
        let out = NSMutableAttributedString()
        if !latin.isEmpty {
            out.append(NSAttributedString(string: uppercased ? latin.uppercased() : latin, attributes: [
                .font: font, .foregroundColor: colour, .paragraphStyle: p, .kern: tracking,
            ]))
        }
        if !han.isEmpty {
            let small = NSFontManager.shared.convert(font, toSize: max(9, font.pointSize - 1.5))
            if !latin.isEmpty && !latin.hasSuffix("\n") {
                out.append(NSAttributedString(string: "\u{2009}\u{2009}", attributes: [.font: small, .paragraphStyle: p]))
            }
            out.append(NSAttributedString(string: han, attributes: [
                .font: small, .foregroundColor: soft, .paragraphStyle: p,
            ]))
        }
        return out
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
    var bilingual = true

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
        self.bilingual = !mono
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
        if bilingual {
            attributedStringValue = Bilingual.attributed(
                text, font: font, colour: colour,
                soft: colour.blended(withFraction: 0.42, of: Skin.c.canvas) ?? colour,
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

    /// Only the dimming changes — rebuilding the attributed title here would
    /// re-lay-out every button each time the toolbar is enabled or disabled.
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
        let colour: NSColor
        switch kind {
        case .primary: colour = Skin.isDark ? Skin.c.canvas : Skin.c.panel
        case .normal:  colour = Skin.c.ink
        case .quiet:   colour = Skin.c.inkSoft
        case .micro:   colour = Skin.c.inkFaint
        case .danger:  colour = Skin.c.negative
        }
        // On the filled button the Chinese half is dimmed against the accent,
        // everywhere else against the paper.
        let ground = kind == .primary ? Skin.c.accent : Skin.c.canvas
        attributedTitle = Bilingual.attributed(
            title,
            font: Skin.ui(fontDelta, kind == .primary ? .medium : .regular),
            colour: colour,
            soft: colour.blended(withFraction: kind == .primary ? 0.30 : 0.40, of: ground) ?? colour,
            tracking: kind == .micro ? 1.1 : 0.2,
            uppercased: kind == .micro,
            alignment: .center)
        paint()
        invalidateIntrinsicContentSize()
    }

    private func paint() {
        guard let layer = layer else { return }
        var face = NSColor.clear
        var border = NSColor.clear

        switch kind {
        case .primary:       face = Skin.c.accent
        case .normal:        border = Skin.c.rule
        case .quiet, .micro: break
        case .danger:        border = Skin.c.negative.withAlphaComponent(0.30)
        }
        if isEnabled && (hovering || isHighlighted) {
            let lift: CGFloat = isHighlighted ? 0.16 : 0.07
            switch kind {
            case .primary:
                face = Skin.c.accent.blended(withFraction: lift,
                                             of: Skin.isDark ? .white : .black) ?? face
            case .normal, .quiet, .micro:
                face = Skin.c.ink.withAlphaComponent(lift * 0.85)
            case .danger:
                face = Skin.c.negative.withAlphaComponent(lift)
            }
        }
        layer.backgroundColor = face.cgColor
        layer.borderColor = border.cgColor
        layer.borderWidth = border == .clear ? 0 : 1
        alphaValue = isEnabled ? 1 : 0.32
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

/// Borderless popup — just the title and a small chevron. In `masthead` style
/// the part before the em dash is set in the display face and the path that
/// follows drops to faint mono, so the window has one clear heading.
final class SkinPopUp: NSPopUpButton, Skinnable {

    static let separator = "  —  "
    var isMasthead = false

    convenience init(masthead: Bool = false) {
        self.init(frame: .zero, pullsDown: false)
        isBordered = false
        isMasthead = masthead
        restyle()
    }

    func restyle() {
        font = isMasthead ? Skin.display() : Skin.ui()
        contentTintColor = Skin.c.ink
        for item in itemArray {
            item.attributedTitle = isMasthead ? masthead(item.title) : plain(item.title)
        }
    }

    private func plain(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: Skin.ui(), .foregroundColor: Skin.c.ink])
    }

    private func masthead(_ s: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingMiddle
        guard let r = s.range(of: SkinPopUp.separator) else {
            return NSAttributedString(string: s, attributes: [
                .font: Skin.display(), .foregroundColor: Skin.c.ink, .paragraphStyle: p,
            ])
        }
        let out = NSMutableAttributedString(string: String(s[s.startIndex..<r.lowerBound]), attributes: [
            .font: Skin.display(), .foregroundColor: Skin.c.ink, .paragraphStyle: p, .kern: 0.2,
        ])
        out.append(NSAttributedString(string: String(s[r.lowerBound...]), attributes: [
            .font: Skin.mono(-0.5), .foregroundColor: Skin.c.inkFaint, .paragraphStyle: p,
        ]))
        return out
    }
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

/// Plain themed background, used for window content views.
class SkinView: NSView, Skinnable {
    func restyle() {
        wantsLayer = true
        layer?.backgroundColor = Skin.c.canvas.cgColor
    }
}
