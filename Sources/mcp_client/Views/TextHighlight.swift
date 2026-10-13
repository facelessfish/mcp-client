import AppKit
import Foundation

// MARK: - Highlighting for the text surfaces
//
// Both builders here do one linear pass over the text and hand back an
// immutable NSAttributedString that a text surface sets exactly once per
// content change. Nothing in this file runs during layout, and nothing is
// cached — there is nothing left to run twice (the reply is highlighted when
// it is first shown, and that is the only time it is shown from scratch).
//
// Colours are *dynamic* NSColors, resolved per appearance at draw time: a
// light/dark flip costs nothing here, because the highlighted string stays
// valid and the system simply redraws it.
//
// The scanner walks UTF-16 code units on purpose — that is the coordinate
// system NSAttributedString ranges use, so the token ranges become NSRange
// values with no conversion and no run bookkeeping. (The AttributedString
// version this replaces had to convert character offsets to UTF-8 offsets per
// range, which is what turned colouring a formatted reply into hundreds of
// milliseconds.)

enum TextFont {
    static let code = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let prose = NSFont.systemFont(ofSize: 12.5)
    /// The macOS `.callout` text style — the face `Prose` renders short text in
    /// when SwiftUI lays it out (`.font(.callout)`), so the surface a long
    /// passage folds into can wear the same one and the two read as one thing.
    static let callout = NSFont.preferredFont(forTextStyle: .callout)
    /// Line advance the block-height clamps are derived from (mono 12 pt).
    static let codeLineHeight: CGFloat = 15
}

/// The face and base colour a text surface dresses its text in. They are
/// always chosen together — a surface that shows text as *secondary reading
/// matter* rather than as the document (a long tool description folded into a
/// disclosure) wears the chrome that same text gets when SwiftUI lays it out
/// inline, so folding changes the box and not the words.
enum TextChrome: Equatable {
    /// A document: the mode's own face (code, or prose) in the label colour.
    case standard
    /// Secondary reading matter: the `.callout` face in the secondary label
    /// colour — the styling of an inline `Prose`.
    case secondary

    var foreground: NSColor { self == .secondary ? .secondaryLabelColor : .textColor }

    /// The face for a mode. Only `.standard` keeps the mode's own: secondary
    /// chrome is proportional reading text whatever mode painted it with,
    /// which is how the inline `Text` shows it.
    func font(for mode: TextSurface.Mode) -> NSFont {
        if self == .secondary { return TextFont.callout }
        switch mode {
        case .code:     return TextFont.code
        case .markdown: return TextFont.prose
        }
    }
}

/// The Catppuccin palette in AppKit colours — the same six colours as the
/// SwiftUI `Catppuccin` palette that labels and chips use: Frappé for light,
/// Mocha for dark. Keys blue, strings green, numbers peach, literals yellow.
enum CodePalette {
    static let key = dynamic(0x8CAAEE, 0x89B4FA)
    static let string = dynamic(0xA6D189, 0xA6E3A1)
    static let number = dynamic(0xEF9F76, 0xFAB387)
    static let literal = dynamic(0xE5C890, 0xF9E2AF)

    private static func swatch(_ hex: UInt) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    private static func dynamic(_ light: UInt, _ dark: UInt) -> NSColor {
        let lightColor = swatch(light)
        let darkColor = swatch(dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }
    }
}

// MARK: - JSON

enum JSONHighlight {
    /// How far the colouring pass walks. The bound is cosmetic, never
    /// censorial: beyond it the text is still shown in full, selectable,
    /// ⌘F-findable and copied — it simply stays in the base colour, the same
    /// way an editor stops highlighting a megabyte of base64. It is what keeps
    /// the highlight pass cheap no matter what a server decides to return.
    static let scanLimit = 600_000

    static func attributed(_ text: String, chrome: TextChrome = .standard) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: chrome.font(for: .code),
            .foregroundColor: chrome.foreground,
        ])
        let u = Array(text.utf16.prefix(scanLimit))
        let n = u.count
        guard n > 1 else { return out }

        func paint(_ from: Int, _ to: Int, _ color: NSColor) {
            out.addAttribute(.foregroundColor, value: color,
                             range: NSRange(location: from, length: to - from))
        }
        func blank(_ c: UTF16.CodeUnit) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        func digit(_ c: UTF16.CodeUnit) -> Bool { c >= 0x30 && c <= 0x39 }
        func numberChar(_ c: UTF16.CodeUnit) -> Bool {
            digit(c) || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x65 || c == 0x45
        }
        // Letters only: an identifier cannot continue into the token after it.
        // Anything non-ASCII counts as a letter — a surrogate pair is always
        // above 0x7F, so it can never be mistaken for a delimiter either.
        func letter(_ c: UTF16.CodeUnit) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c >= 0x80
        }
        func word(_ w: [UTF16.CodeUnit], at i: Int) -> Bool {
            guard i + w.count <= n else { return false }
            for k in 0..<w.count where u[i + k] != w[k] { return false }
            let after = i + w.count
            return after >= n || !letter(u[after])
        }

        let trueWord: [UTF16.CodeUnit] = Array("true".utf16)
        let falseWord: [UTF16.CodeUnit] = Array("false".utf16)
        let nullWord: [UTF16.CodeUnit] = Array("null".utf16)

        out.beginEditing()
        var i = 0
        while i < n {
            let c = u[i]
            if c == 0x22 {                                  // "  string, with escapes
                var j = i + 1
                while j < n {
                    if u[j] == 0x5C { j += 2; continue }     // "  \x" — skip the escaped unit
                    if u[j] == 0x22 { break }
                    j += 1
                }
                let end = Swift.min(j + 1, n)
                var k = end
                while k < n, blank(u[k]) { k += 1 }
                paint(i, end, (k < n && u[k] == 0x3A) ? CodePalette.key : CodePalette.string)
                i = end
            } else if digit(c) || (c == 0x2D && i + 1 < n && digit(u[i + 1])) {
                var j = i + 1
                while j < n, numberChar(u[j]) { j += 1 }
                paint(i, j, CodePalette.number)
                i = j
            } else if word(trueWord, at: i) {
                paint(i, i + 4, CodePalette.literal); i += 4
            } else if word(falseWord, at: i) {
                paint(i, i + 5, CodePalette.literal); i += 5
            } else if word(nullWord, at: i) {
                paint(i, i + 4, CodePalette.literal); i += 4
            } else {
                i += 1                                       // punctuation, whitespace: base colour
            }
        }
        out.endEditing()
        return out
    }
}

// MARK: - Markdown (inline only, line breaks kept)

enum ProseHighlight {
    /// Foundation's markdown parser leaves its verdict as *presentation
    /// intents* (bold / italic / code) plus links; AppKit needs real fonts and
    /// colours, so the runs are walked once and mapped. Blocks (`#`, lists)
    /// stay verbatim — this is a debugger, the source is never far away.
    static func attributed(_ markdown: String, chrome: TextChrome = .standard) -> NSAttributedString {
        let parsed = (try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)

        let base = chrome.font(for: .markdown)
        let out = NSMutableAttributedString()
        out.beginEditing()
        for run in parsed.runs {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font(for: run.inlinePresentationIntent ?? [], base: base),
                .foregroundColor: chrome.foreground,
            ]
            if let url = run.link {
                attrs[.link] = url
                attrs[.foregroundColor] = NSColor.linkColor
            }
            // A run gives a range into the characters view; that is how its
            // text is read back out.
            out.append(NSAttributedString(string: String(parsed.characters[run.range]),
                                          attributes: attrs))
        }
        out.endEditing()
        return out
    }

    /// `base` is the chrome's face — prose for a document, callout for
    /// secondary reading matter. Code spans stay monospaced whatever it is.
    private static func font(for intent: InlinePresentationIntent, base: NSFont) -> NSFont {
        if intent.contains(.code) { return TextFont.code }
        var font = base
        let manager = NSFontManager.shared
        if intent.contains(.stronglyEmphasized) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if intent.contains(.emphasized) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }
}
