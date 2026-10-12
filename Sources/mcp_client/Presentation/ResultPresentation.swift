import AppKit
import Foundation
import SwiftUI

// MARK: - What a call result looks like
//
// The Result tab shows the reply's MAIN body: the main text document —
// `structuredContent` when the server sent one, otherwise the `content` text
// blocks unescaped, pretty-printed too when the text itself is JSON, because
// servers that stringify their payload (GitHub does it in `content[].text`)
// mean it as data — and the decoded image content blocks, always rendered
// below that text when the reply carries any. An image-only reply shows
// just the pixels. The Raw tab remains the source of truth for the complete
// envelope — `_meta`, the base64 behind every image, the JSON-RPC wrapper,
// everything the main view deliberately leaves out is one tab away and one
// Copy away.
//
// The derivation happens once per reply, in this file, when the result lands
// (ServerModel.callTool attaches it); no walk of a JSON tree, no
// pretty-printing, no base64 decode and no counting of lines happens in a
// view body.
//
// That one rule is why this app has no render cache. The caches it used to
// have existed because the derivations ran inside `body`, which runs on every
// update and on every resize tick — and those caches paid for themselves with
// a deep hash of the payload on every lookup. Work that happens once per call
// needs no cache at all: a pretty-print is about a millisecond per hundred
// kilobytes, an image decode a handful per megabyte, and both are paid once.

/// Everything the Result and Raw tabs show about one call.
struct ResultPresentation {
    /// The main text document: the `structuredContent` object, the content
    /// text (pretty-printed when the text is itself JSON), or the whole
    /// `result` object as the never-blank fallback. Empty only when the
    /// reply's whole body is images — then the deck is the reply. For a
    /// JSON-RPC error: its code, message and `data`; otherwise the failure
    /// text.
    var document: String = ""
    /// How the text document is rendered: printed JSON takes the code
    /// colours, unescaped text blocks take prose.
    var documentMode: TextSurface.Mode = .code
    /// Hard line count of the document (capped) — the height it is given
    /// when it shares the pane with an image deck and cannot simply fill it.
    var documentLines: Int = 0
    /// The reply's image content blocks, decoded once when it landed — the
    /// pixels the server sent, not the base64 that carries them (Raw owns
    /// those bytes). Rendered below the text document whenever non-empty.
    var images: [NSImage] = []
    /// The reply as text: the wire body when there is one, the printed result
    /// when there is none (a cancelled or failed call has no body). What the
    /// Raw tab shows and what Copy takes.
    var asText: String = ""

    /// Nothing derived — the state of a `CallResult` before the model attaches
    /// a presentation to it (which it always does; this exists so the field can
    /// be non-optional, and so nothing downstream has to unwrap). Declaring
    /// `init(result:)` above would otherwise have taken this one away.
    init() {}

    init(result: CallResult) {
        switch result.outcome {
        case .success(let value), .toolError(let value):
            // The reply's pixels, whenever it announces them — they render
            // below the text, or alone when the text is nothing.
            images = Self.mainImages(from: value)
            // The main text, in order of trust:
            //   structuredContent — the machine-readable body, when present;
            //   content[].text    — the human body, unescaped (decoding the
            //                       wire already undid the JSON escapes);
            //                       when the text parses as a JSON object or
            //                       array it is the machine body in a string,
            //                       so it is printed like one;
            //   (images)          — nothing above and pixels here: the deck
            //                       is the reply, no text document;
            //   the whole result  — everything else (undecodable images,
            //                       empty content…), and an empty pane helps
            //                       no one debugging.
            if let structured = value["structuredContent"], !structured.isNull {
                document = structured.prettyString
                documentMode = .code
            } else if let text = Self.mainText(from: value) {
                if let pretty = Self.prettyJSON(in: text) {
                    document = pretty
                    documentMode = .code
                } else {
                    document = text
                    documentMode = .markdown
                }
            } else if images.isEmpty {
                document = value.prettyString
                documentMode = .code
            }
            documentLines = document.isEmpty ? 0 : TextMetrics.lines(document, cap: 40)
            asText = result.rawText.isEmpty ? value.prettyString : result.rawText
        case .rpcError(let code, let message, let data):
            // The error document itself never survives the transport as a
            // body, so the document says what the client read off the wire:
            // code, message, and `data` printed when the server sent one.
            document = "JSON-RPC error \(code): \(message)"
                + (data.map { "\n\n" + $0.prettyString } ?? "")
            documentLines = TextMetrics.lines(document, cap: 40)
            asText = result.rawText
        // No wire body for these two, so the document says what happened
        // instead of showing an empty pane.
        case .transportError(let text):
            asText = result.rawText.isEmpty ? text : result.rawText
            document = asText
            documentLines = TextMetrics.lines(document, cap: 40)
        case .cancelled:
            asText = result.rawText.isEmpty
                ? "Cancelled — the HTTP stream was closed"
                : result.rawText
            document = asText
            documentLines = TextMetrics.lines(document, cap: 40)
        }
    }

    /// The reply's human body: every `content[]` block of type `"text"`,
    /// joined with a blank line. The block's `text` is already the unescaped
    /// string value, so what comes out is what the server's tool actually
    /// printed. nil when the reply has no text blocks at all, so the caller
    /// can fall back to the next kind.
    static func mainText(from value: JSONValue) -> String? {
        guard let blocks = value["content"]?.array else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"]?.string == "text", let text = block["text"]?.string else { return nil }
            return text
        }
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: "\n\n")
    }

    /// The text as a printed JSON document — when the text IS JSON: an
    /// object or array that parses whole, nothing else. Prose that happens
    /// to open with `{`, a bare number, a date string: all stay prose, so a
    /// plain `"27"` never becomes a highlighted scalar.
    static func prettyJSON(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") || t.hasPrefix("[") else { return nil }
        guard let data = t.data(using: .utf8),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data),
              v.object != nil || v.array != nil else { return nil }
        return v.prettyString
    }

    /// The reply's pixels: every `content[]` block of type `"image"` whose
    /// base64 `data` decodes. Decoded once, here, when the reply lands —
    /// the view just draws finished pixels. An undecodable block contributes
    /// nothing; its base64 is still whole in Raw.
    static func mainImages(from value: JSONValue) -> [NSImage] {
        guard let blocks = value["content"]?.array else { return [] }
        return blocks.compactMap { block in
            guard block["type"]?.string == "image",
                  let payload = block["data"]?.string,
                  let image = Pixels.base64(payload) else { return nil }
            return image
        }
    }
}
