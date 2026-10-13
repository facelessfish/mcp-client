import AppKit
import SwiftUI

// MARK: - The text surface
//
// Every piece of text longer than a label goes through this one view: the
// Result tab's document, the Raw tab, a transcript entry's body, the schema
// and annotations disclosures, the server profile's raw payload.
// Under the SwiftUI wrapper is a read-only, selectable NSTextView in its own
// NSScrollView, and two rules make the whole app fast:
//
//  1. Text layout happens in AppKit. NSTextView lays its own text out, caches
//     that layout, and does it again when — and only when — the width changes.
//     SwiftUI never measures a block of text, so it cannot measure it often.
//  2. A surface never grows to the height of its content. It is given a height
//     (all the space the pane offers, or a fixed one) and scrolls inside it.
//     A page of blocks is therefore a handful of constants tall no matter what
//     the server returned, and dragging the window's edge costs the same for a
//     2 KB reply as for a 2 MB one.
//
// The SwiftUI view this replaces — one `Text` with a megabyte-long attributed
// string, in a ScrollView, inside a greedy frame — had precisely the opposite
// properties: every candidate size of every layout pass re-wrapped the whole
// text, and animating a transcript row open re-laid it out once per frame.
//
// The string is handed to AppKit once per content change. That guard is what
// keeps unrelated updates (a log line arriving, a keystroke in another pane)
// free: comparing a String against the one already on screen is a pointer
// check when nothing changed, and only a walk of the text when something did.
// The chrome the text is painted with rides along in the same comparison, so a
// surface re-renders when either the words or their dress change — and on
// nothing else.

struct TextSurface: View {
    enum Mode {
        /// Monospaced, JSON colours.
        case code
        /// Proportional, inline markdown rendered (see `ProseHighlight`).
        case markdown
    }
    enum Height {
        /// All the space the pane offers, scrolling inside it.
        case fill
        /// A specific height, for a block inside a page of blocks. Derive it
        /// from the content's line count with `TextMetrics.blockHeight`.
        case fixed(CGFloat)
    }

    let text: String
    var mode: Mode = .code
    var height: Height = .fill
    /// Whether Find (⌘F, the toolbar button) may answer from this surface.
    /// The Server tab's payloads opt out — there is nothing there worth
    /// finding, and the tab hides the Find button.
    var findable: Bool = true
    /// The visible tab's main surface: when nothing has focus, Find aims at
    /// it. Open the Result tab and hit ⌘F without clicking anything — this
    /// is what answers.
    var primary: Bool = false
    /// Face and colour of the text. `.standard` is the surface as such; a
    /// passage that reads as secondary text (a long tool description, folded
    /// into a disclosure) asks for `.secondary` so it matches the inline `Text`
    /// the same words get when they are short — see `Prose`.
    var chrome: TextChrome = .standard

    var body: some View {
        sized
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }

    /// A surface takes the height it is given — never the height of its text.
    /// That single decision is what keeps a page of blocks, and every resize of
    /// it, independent of how big the payload is.
    @ViewBuilder private var sized: some View {
        let surface = Surface(text: text, mode: mode, findable: findable, primary: primary,
                              chrome: chrome)
        switch height {
        case .fill:
            surface.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .fixed(let points):
            surface.frame(maxWidth: .infinity).frame(height: points)
        }
    }

    /// ⌘F and the toolbar button: hand the find action to the text surface
    /// that should answer — see `TextFindRouter` for how it picks.
    static func showFind() {
        TextFindRouter.showFind()
    }
}

// MARK: - Who answers Find
//
// `performTextFinderAction:` is an NSTextView instance method, and the old
// responder-chain route reached a surface only when one happened to be first
// responder — after a toolbar click, a tab switch, or a click on any SwiftUI
// control, nothing was, and Find did nothing. The router instead keeps weak
// references to the surfaces themselves and aims at one directly: first
// responder if it is a searchable surface, else the last surface the user
// clicked, else the visible tab's primary surface — focusing it first so the
// find bar appears and typing goes straight in. A surface whose window is gone
// (its tab was switched away from) cannot answer, which is exactly why ⌘F does
// nothing on the Server and Log tabs: their surfaces opt out with
// `findable: false`, and the document tabs' surfaces are gone.

enum TextFindRouter {
    /// The last surface that actually had keyboard focus. `fileprivate`: the
    /// registry is storage for this file's surfaces (`WrapTextView` is
    /// private); the routing entry point `showFind()` is what the rest of
    /// the app calls.
    fileprivate static weak var lastFocused: WrapTextView?
    /// The most recently mounted `primary` surface — the visible tab's main one.
    fileprivate static weak var primary: WrapTextView?

    @discardableResult
    static func showFind() -> Bool {
        if let responder = NSApp.keyWindow?.firstResponder as? WrapTextView,
           responder.findEnabled, responder.window != nil {
            responder.performTextFinderAction(findItem())
            return true
        }
        for candidate in [lastFocused, primary] {
            guard let view = candidate, view.findEnabled, view.window != nil else { continue }
            view.window?.makeFirstResponder(view)
            view.performTextFinderAction(findItem())
            return true
        }
        return false
    }

    /// `performTextFinderAction:` reads the requested action off the sender's
    /// tag — there is no SwiftUI find API to route this through, so the action
    /// travels in a throwaway menu item, aimed at a surface we hold rather
    /// than fired blind into the responder chain.
    private static func findItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        return item
    }
}

private struct Surface: NSViewRepresentable {
    let text: String
    let mode: TextSurface.Mode
    var findable: Bool = true
    var primary: Bool = false
    var chrome: TextChrome = .standard

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = WrapScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let view = WrapTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 20))
        // Wrap to the width, grow downwards: WrapScrollView pins this view's
        // width to the clip view's on every tiling pass, and the container
        // follows the view's width — so a resize re-wraps inside the pane,
        // without SwiftUI being consulted. Long lines (a pretty-JSON string in
        // the Result document, a transcript body in the Log) soft-wrap at word
        // boundaries; a token too long to fit on any line (base64, a URL) is
        // force-broken, which is the only wrap such a line can have.
        // No horizontal scroller, on purpose: a multi-megabyte single-line body
        // (base64 in Raw, a big SSE payload in the Log) would otherwise lay out
        // a layer millions of points wide, which AppKit drops as "bogus layer
        // size" and the content silently disappears.
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        // Size bounds stay unlimited (the resizable flags above stamp finite
        // ones as a side effect — re-applied afterwards so neither can cap the
        // width the clamp in WrapScrollView.tile() hands out).
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 320,
                                                   height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.lineBreakMode = .byWordWrapping
        view.textContainerInset = NSSize(width: 3, height: 8)

        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        // Both are only the fallback: every character of the attributed string
        // set below carries its own face and colour. They match the chrome so an
        // unstyled stretch reads as the rest of the surface.
        view.textColor = chrome.foreground
        view.font = chrome.font(for: mode)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.findEnabled = findable
        view.isFindPrimary = primary

        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let onScreen = context.coordinator.shown
        guard text != onScreen.text || chrome != onScreen.chrome else { return }
        context.coordinator.shown = (text, chrome)
        view.textColor = chrome.foreground
        view.font = chrome.font(for: mode)
        view.textStorage?.setAttributedString(Self.render(text, mode: mode, chrome: chrome))
        view.scrollToBeginningOfDocument(nil)
    }

    static func render(_ text: String, mode: TextSurface.Mode,
                       chrome: TextChrome = .standard) -> NSAttributedString {
        // Whole text, always: the only bound in the pipeline is the colouring
        // pass, and it paints a prefix — it never removes text.
        switch mode {
        case .code:     return JSONHighlight.attributed(text, chrome: chrome)
        case .markdown: return ProseHighlight.attributed(text, chrome: chrome)
        }
    }

    final class Coordinator {
        /// What is on screen: the string and the chrome it was painted with, so
        /// a re-render happens on a change of either and on nothing else.
        var shown: (text: String, chrome: TextChrome) = ("", .standard)
    }
}

// MARK: - The wrapping pair
//
// Wrapping at the pane's width cannot be left to heuristics. An AppKit text
// view happily reports a content-derived intrinsic size (as wide as its
// longest line), and a document view left to its own devices happily grows
// past the clip view. Either one turns "JSON that wraps" into "a pane wider
// than the window with horizontal scrolling" — so both halves are pinned:
// the views report no intrinsic content size at all, and every tiling pass
// re-clamps the document's width to the viewport's. That clamp is the width
// every line wraps inside, which is the whole guarantee this app needs from
// this file: content can never be wider than the pane showing it.

/// An `NSScrollView` whose document is always exactly as wide as the clip
/// view — horizontal overflow, and with it horizontal scrolling, cannot
/// happen inside a text surface.
private final class WrapScrollView: NSScrollView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func tile() {
        super.tile()
        guard let doc = documentView else { return }
        let width = contentView.bounds.width
        if width > 1, abs(doc.frame.width - width) >= 0.5 {
            doc.setFrameSize(NSSize(width: width, height: doc.frame.height))
        }
    }
}

/// An `NSTextView` that tells no one how wide its text wants to be: given a
/// content-derived intrinsic width, SwiftUI sizes panes to the longest line
/// instead of wrapping the text at the pane's width. It also keeps the Find
/// router honest: it registers as the last-focused surface when it takes
/// focus, and as the tab's primary when one mounts and enters a window.
private final class WrapTextView: NSTextView {
    /// Opt out of Find entirely (the Server tab's payloads).
    var findEnabled = true
    /// The tab's main surface — Find's fallback when nothing has focus.
    var isFindPrimary = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, findEnabled { TextFindRouter.lastFocused = self }
        return ok
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, findEnabled, isFindPrimary {
            TextFindRouter.primary = self
        }
    }
}

// MARK: - Sizing what a surface shows
//
// A surface displays its text whole — no display cap exists any more, because
// a prefix cut does not just hide the tail, it removes it from the find bar's
// reach: a tool listed late in a huge tools/list must be ⌘F-findable on the
// Raw tab, which is where the whole wire bodies live. What stays bounded is
// only what cannot change the words on screen: the colouring pass
// (`JSONHighlight.scanLimit` — beyond it text is plain, never absent) and the
// layout heights below.

enum TextMetrics {
    /// Hard line count, capped: it stops as soon as the answer can no longer
    /// change the height, so counting lines costs the same for a 40-line block
    /// and a 40 000-line one.
    static func lines<S: StringProtocol>(_ text: S, cap: Int = 40) -> Int {
        var count = 1
        for byte in text.utf8 where byte == 0x0A {
            count += 1
            if count >= cap { return cap }
        }
        return count
    }

    /// Height of a self-scrolling block holding `lines` lines: exact for short
    /// content, clamped for long content — which then scrolls, instead of
    /// pushing the page out to the height of the payload.
    static func blockHeight(lines: Int, minimum: CGFloat = 84, maximum: CGFloat = 380) -> CGFloat {
        min(max(CGFloat(lines) * TextFont.codeLineHeight + 18, minimum), maximum)
    }

}

// MARK: - Prose
//
// A text content block, a tool description, the server's instructions: prose
// renders as prose. Short prose keeps exactly the shape it has always had —
// an inline, selectable Text that takes the height it needs, because a
// few-line paragraph is free to measure. Long prose (a README from a file
// tool) goes to a text surface with a bounded, self-scrolling height, because
// a single monolithic Text of 200 KB is what used to cost a second per resize
// tick. The threshold is where the second path becomes the cheaper one, not a
// rule about the content.

struct Prose: View {
    let source: String
    /// Passed through to the surface this becomes when the prose is long —
    /// the Server tab's instructions opt out of Find like its payload does.
    var findable: Bool = true
    /// Face and colour, applied on **both** paths. Short prose is SwiftUI's,
    /// long prose is AppKit's; the reader should not be able to tell which one
    /// a passage is, and before this the handover at `inlineLimit` came with a
    /// colour and a size change of its own.
    var chrome: TextChrome = .standard
    static let inlineLimit = 1_600

    init(_ source: String, findable: Bool = true, chrome: TextChrome = .standard) {
        self.source = source
        self.findable = findable
        self.chrome = chrome
    }

    /// The rule `body` branches on: short text stays inline, everything else
    /// goes to a surface. Exposed so the tool editor can fold a long
    /// description into a disclosure instead of a standing scroll box — one
    /// threshold, two consumers, so they cannot drift apart.
    static func fitsInline(_ text: String) -> Bool { text.utf8.count <= inlineLimit }

    var body: some View {
        if !Self.fitsInline(source) {
            TextSurface(
                text: source,
                mode: .markdown,
                height: .fixed(TextMetrics.blockHeight(
                    lines: TextMetrics.lines(source.prefix(20_000), cap: 40),
                    minimum: 64, maximum: 340)),
                findable: findable,
                chrome: chrome)
                .frame(maxWidth: .infinity)
        } else {
            // The SwiftUI spelling of the same chrome — `.callout` in the
            // secondary colour is exactly what `TextChrome.secondary` paints
            // into a surface. Two renderers, one look.
            let paragraph = Text(MarkdownInline.attributed(source))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch chrome {
            case .standard:  paragraph
            case .secondary: paragraph.font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Inline markdown for the small SwiftUI `Text`s of the app. Parsed per call:
/// at this size a parse is microseconds, and caching it was what dragged a
/// whole payload into a dictionary key once.
enum MarkdownInline {
    static func attributed(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
    }
}
