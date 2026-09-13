import AppKit

// MARK: - the skin file
//
// Skins customize colours and type, not layout constraints.

struct Theme: Equatable {

    var name        = "Atelier"

    var fontDisplay = "system"        // the repo name and window headings
    var fontUI      = "system"        // buttons, labels — family name, or "system"
    var fontMono    = "Menlo"          // paths, remote URL, the log
    var sizeDisplay = 19.0             // clamped 13…26
    var sizeUI      = 12.5             // clamped 10…17
    var sizeMono    = 11.5             // clamped 9…15

    var canvas      = "#F4F5F6"        // window background
    var panel       = "#FFFFFF"       // fields
    var ink         = "#202428"        // primary text
    var inkSoft     = "#59636D"        // secondary text
    var inkFaint    = "#707981"        // hints, the Chinese half of a label
    var rule        = "#D9DEE2"        // hairlines, borders
    var accent      = "#216B54"        // headings, focus, the one filled button
    var positive    = "#286843"        // success
    var negative    = "#B13D45"        // danger, force operations
    var caution     = "#8B540C"        // dirty tree, warnings
    var consoleBg   = "#FFFFFF"        // the log well
    var consoleInk  = "#303940"        // log text

    /// Allowed keys and descriptions for the clipboard prompt.
    static let glossary: [(String, String)] = [
        ("name",        "what to call this skin"),
        ("fontDisplay", "the repo name and headings"),
        ("fontUI",      "buttons and labels, or \"system\""),
        ("fontMono",    "monospaced family for paths and the log, or \"system\""),
        ("sizeDisplay", "heading size, 13-26"),
        ("sizeUI",      "UI text size, 10-17"),
        ("sizeMono",    "log text size, 9-15"),
        ("canvas",      "window background"),
        ("panel",       "text fields"),
        ("ink",         "primary text"),
        ("inkSoft",     "secondary text"),
        ("inkFaint",    "hints, and the Chinese half of every label"),
        ("rule",        "hairlines and button borders"),
        ("accent",      "headings, focus, the one filled button"),
        ("positive",    "success messages"),
        ("negative",    "errors and the force-push buttons"),
        ("caution",     "uncommitted changes, warnings"),
        ("consoleBg",   "the log well"),
        ("consoleInk",  "log text"),
    ]

    static let keys: Set<String> = Set(glossary.map { $0.0 })
}

// MARK: - reading a skin file

extension Theme {

    /// What came back from reading a pasted skin.
    struct ParseResult {
        let theme: Theme
        let problems: [String]
        /// False only when the text was not JSON at all — the one case where
        /// nothing was applied. Callers must not sniff `problems` for this.
        let isJSON: Bool
    }

    /// Parses whatever the user pasted. Never throws, never returns something
    /// unusable: unknown keys are ignored, missing keys keep their current
    /// value, bad values are replaced and reported.
    static func parse(_ raw: String, base: Theme = Theme()) -> ParseResult {
        var t = base
        var problems: [String] = []

        // Valid JSON can itself contain backticks or braces inside strings.
        let rawData = raw.data(using: .utf8)
        let validJSON = rawData.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) } != nil
        let body = validJSON ? raw : stripFences(raw)
        guard let data = body.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any] else {
            return ParseResult(theme: base,
                               problems: ["That is not valid JSON. 这段不是合法的 JSON。"],
                               isJSON: false)
        }

        func string(_ key: String) -> String? {
            guard let v = dict[key] else { return nil }
            if let s = v as? String { return s.trimmingCharacters(in: .whitespaces) }
            problems.append("\(key): expected text, ignored")
            return nil
        }

        func number(_ key: String, _ lo: Double, _ hi: Double) -> Double? {
            guard let v = dict[key] else { return nil }
            var d: Double?
            if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { d = n.doubleValue }
            if let s = v as? String { d = Double(s) }
            guard let got = d, got.isFinite else {
                problems.append("\(key): expected a finite number, ignored")
                return nil
            }
            if got < lo || got > hi {
                let fixed = min(max(got, lo), hi)
                problems.append("\(key) \(trim(got)) is outside \(trim(lo))–\(trim(hi)), used \(trim(fixed))")
                return fixed
            }
            return got
        }

        func colour(_ key: String, _ current: String) -> String {
            guard let s = string(key) else { return current }
            guard let normalised = Hex.normalise(s) else {
                problems.append("\(key): “\(s)” is not a colour, kept \(current)")
                return current
            }
            return normalised
        }

        func family(_ key: String, _ current: String) -> String {
            guard let s = string(key), !s.isEmpty else { return current }
            if s.caseInsensitiveCompare("system") == .orderedSame { return "system" }
            if NSFont(name: s, size: 12) == nil {
                problems.append("\(key): “\(s)” is not installed on this Mac, used the system font")
                return "system"
            }
            return s
        }

        if let s = string("name"), !s.isEmpty {
            // one line, no control characters — it goes into a single-line label
            let flat = s.unicodeScalars.map { $0.value < 0x20 ? " " : Character($0) }
            t.name = String(String(flat).trimmingCharacters(in: .whitespaces).prefix(40))
            if t.name.isEmpty { t.name = base.name }
        }
        t.fontDisplay = family("fontDisplay", t.fontDisplay)
        t.fontUI      = family("fontUI", t.fontUI)
        t.fontMono    = family("fontMono", t.fontMono)
        if let d = number("sizeDisplay", 13, 26) { t.sizeDisplay = d }
        if let d = number("sizeUI", 10, 17) { t.sizeUI = d }
        if let d = number("sizeMono", 9, 15) { t.sizeMono = d }

        t.canvas     = colour("canvas", t.canvas)
        t.panel      = colour("panel", t.panel)
        t.ink        = colour("ink", t.ink)
        t.inkSoft    = colour("inkSoft", t.inkSoft)
        t.inkFaint   = colour("inkFaint", t.inkFaint)
        t.rule       = colour("rule", t.rule)
        t.accent     = colour("accent", t.accent)
        t.positive   = colour("positive", t.positive)
        t.negative   = colour("negative", t.negative)
        t.caution    = colour("caution", t.caution)
        t.consoleBg  = colour("consoleBg", t.consoleBg)
        t.consoleInk = colour("consoleInk", t.consoleInk)

        let unknown = dict.keys.filter { !Theme.keys.contains($0) }.sorted()
        if !unknown.isEmpty {
            problems.append("ignored unknown key(s): " + unknown.joined(separator: ", "))
        }
        problems.append(contentsOf: t.legibilityWarnings())
        return ParseResult(theme: t, problems: problems, isJSON: true)
    }

    /// LLMs love wrapping things in ``` and adding a sentence of preamble.
    private static func stripFences(_ s: String) -> String {
        var body = s
        if let a = body.range(of: "```") {
            body = String(body[a.upperBound...])
            if let nl = body.firstIndex(of: "\n"), body[body.startIndex..<nl].count < 12 {
                body = String(body[body.index(after: nl)...])   // drop the "json" tag
            }
            if let b = body.range(of: "```") { body = String(body[..<b.lowerBound]) }
        }
        // keep only the outermost { … }
        if let open = body.firstIndex(of: "{"), let close = body.lastIndex(of: "}"), open < close {
            body = String(body[open...close])
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Warn — but never refuse — when a skin would be hard to read.
    func legibilityWarnings() -> [String] {
        var out: [String] = []
        func check(_ a: String, _ b: String, _ what: String, min: Double) {
            guard let x = Hex.color(a), let y = Hex.color(b) else { return }
            let r = Hex.contrast(x, y)
            if r < min {
                out.append(String(format: "%@ contrast is only %.1f:1 — hard to read", what, r))
            }
        }
        check(ink, canvas, "ink on canvas", min: 4.0)
        check(consoleInk, consoleBg, "console text", min: 4.0)
        check(inkSoft, canvas, "inkSoft on canvas", min: 2.5)
        check(accent, canvas, "accent on canvas", min: 2.0)
        return out
    }
}

// MARK: - writing a skin file

extension Theme {

    /// Pretty, aligned, stable key order — this is what the user copies, so it
    /// has to be valid JSON even when a skin is called `He said "hi"\`.
    var json: String {
        var lines: [String] = ["{"]
        func row(_ key: String, _ value: String, quoted: Bool, last: Bool = false) {
            let pad = String(repeating: " ", count: max(0, 14 - key.count))
            let v = quoted ? Theme.escaped(value) : value
            lines.append("  \"\(key)\":\(pad)\(v)" + (last ? "" : ","))
        }
        row("name", name, quoted: true)
        lines.append("")
        row("fontDisplay", fontDisplay, quoted: true)
        row("fontUI", fontUI, quoted: true)
        row("fontMono", fontMono, quoted: true)
        row("sizeDisplay", trim(sizeDisplay), quoted: false)
        row("sizeUI", trim(sizeUI), quoted: false)
        row("sizeMono", trim(sizeMono), quoted: false)
        lines.append("")
        row("canvas", canvas, quoted: true)
        row("panel", panel, quoted: true)
        row("ink", ink, quoted: true)
        row("inkSoft", inkSoft, quoted: true)
        row("inkFaint", inkFaint, quoted: true)
        row("rule", rule, quoted: true)
        lines.append("")
        row("accent", accent, quoted: true)
        row("positive", positive, quoted: true)
        row("negative", negative, quoted: true)
        row("caution", caution, quoted: true)
        lines.append("")
        row("consoleBg", consoleBg, quoted: true)
        row("consoleInk", consoleInk, quoted: true, last: true)
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// A JSON string literal, quotes included.
    static func escaped(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"":  out += "\\\""
            case "\\":  out += "\\\\"
            case "\n":  out += "\\n"
            case "\r":  out += "\\r"
            case "\t":  out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) }
                else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }

    /// The whole clipboard payload: instructions the model can follow, then the file.
    var briefForLLM: String {
        var s = """
        Restyle JustGit using the colour and font settings below.

        Rules:
        - Return the complete JSON and nothing else.
        - Keep exactly these keys, spelled the same way. Do not add or remove any.
        - Colours are "#RRGGBB". Fonts are a macOS family name, or "system".
          Choose installed font families, for example Hoefler Text, Baskerville,
          Didot, Palatino, Optima, Avenir Next, Futura, Georgia, Charter,
          American Typewriter, Menlo, Monaco, Courier New, PingFang SC.
        - sizeDisplay must be 13-26, sizeUI 10-17, sizeMono 9-15.
        - Keep ink/canvas and consoleInk/consoleBg at least 4:1 in contrast so the
          app stays readable, and keep inkFaint clearly lighter than ink.
        - There is no key here that can move, resize or reorder anything, and that
          is deliberate. Do not try.

        What each key paints:

        """
        for (k, why) in Theme.glossary {
            let pad = String(repeating: " ", count: max(1, 13 - k.count))
            s += "  \(k)\(pad)\(why)\n"
        }
        s += """

        Describe the look you want below, then apply it:

            <-- say what you're after here, e.g. "a gallery at night: deep
                aubergine paper, aged brass accent, Didot headings" -->

        \(json)
        """
        return s
    }
}

private func trim(_ d: Double) -> String {
    String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), d)
}

// MARK: - hex colours

enum Hex {

    /// "#abc", "abcdef", "#AABBCCDD" → "#RRGGBB" / "#RRGGBBAA"; nil if nonsense.
    static func normalise(_ s: String) -> String? {
        var h = s.trimmingCharacters(in: .whitespaces).uppercased()
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.allSatisfy({ "0123456789ABCDEF".contains($0) }) else { return nil }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        if h.count == 4 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8 else { return nil }
        return "#" + h
    }

    static func color(_ s: String) -> NSColor? {
        guard let h = normalise(s) else { return nil }
        let hex = String(h.dropFirst())
        guard let v = UInt64(hex, radix: 16) else { return nil }
        let wide = hex.count == 8
        let r = CGFloat((v >> (wide ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (wide ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (wide ? 8 : 0)) & 0xFF) / 255
        let a = wide ? CGFloat(v & 0xFF) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// WCAG relative luminance, 0 (black) … 1 (white).
    static func luminance(_ c: NSColor) -> Double {
        guard let s = c.usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ v: CGFloat) -> Double {
            let d = Double(v)
            return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

// MARK: - built-in skins

extension Theme {

    static let atelier = Theme()   // the defaults above

    static let noir = Theme(
        name: "Noir",
        fontDisplay: "Didot", fontUI: "Avenir Next", fontMono: "Menlo",
        sizeDisplay: 20, sizeUI: 12.5, sizeMono: 11,
        canvas: "#141210", panel: "#1E1B18", ink: "#EFE9DC", inkSoft: "#9A9186",
        inkFaint: "#6A6259", rule: "#302B26", accent: "#C9A227",
        positive: "#84A56F", negative: "#C2685C", caution: "#D8A44A",
        consoleBg: "#0D0C0B", consoleInk: "#CFC7B8")

    static let vellum = Theme(
        name: "Vellum",
        fontDisplay: "Baskerville", fontUI: "Palatino", fontMono: "Menlo",
        sizeDisplay: 21, sizeUI: 13.5, sizeMono: 11,
        canvas: "#F7F3E8", panel: "#FFFDF7", ink: "#241E18", inkSoft: "#6F6152",
        inkFaint: "#A99D89", rule: "#E4DAC6", accent: "#7A3B2E",
        positive: "#4A6249", negative: "#8E2F26", caution: "#9C6B1F",
        consoleBg: "#F0E9D9", consoleInk: "#5C5040")

    static let celadon = Theme(
        name: "Celadon",
        fontDisplay: "Optima", fontUI: "Optima", fontMono: "Menlo",
        sizeDisplay: 21, sizeUI: 13.5, sizeMono: 11,
        canvas: "#EEF1EC", panel: "#FAFBF9", ink: "#1E2622", inkSoft: "#5E6B63",
        inkFaint: "#96A199", rule: "#D7DFD7", accent: "#2E6B5E",
        positive: "#3F6B4F", negative: "#8A3B36", caution: "#9A7420",
        consoleBg: "#E5EAE5", consoleInk: "#4A554E")

    static let presets: [Theme] = [atelier, noir, vellum, celadon]
}
