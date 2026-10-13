import AppKit
import Foundation
import SwiftUI

// MARK: - Announced icons (spec Icon[]) and image content blocks
//
// Servers announce icons for themselves (serverInfo.icons) and per tool
// (tools[].icons). An Icon is {src: http(s) URL or base64 data: URI, mimeType?,
// theme? ("light"/"dark")}. One implementation backs both the Server-tab tile
// and the tool rows, so the selection rule cannot drift between them:
// theme match → themeless entry → first icon with a usable src (the opposite-
// theme one still beats nothing). Undecodable or unreachable pixels leave the
// slot empty rather than falling back to placeholder artwork.
//
// The pick and the base64 decode happen **once per tool**, when tools/list
// lands (`Tool.withResolvedIcons`, off the main actor) — not once per row per
// view update. A GitHub-sized list announces two base64 PNGs for each of 46
// tools; decoding them while SwiftUI rebuilds the list, on every filter
// keystroke, was what made a tool list cost seconds. What a row reads is a
// finished NSImage. http(s) icons stay lazy (they need the network) and are
// the only case where a tile runs a task.

enum Pixels {
    /// Pixels for a base64 payload exactly as a content block sends it
    /// (`data`), with no `data:` header. nil = not renderable; never cached,
    /// because the presentation that decodes it holds the result anyway.
    static func base64(_ payload: String) -> NSImage? { decoded(payload)?.image }

    /// Both halves of a decoded payload: the **bytes** behind it — what a save or
    /// a drag writes, so the file is what the server sent — and the pixels drawn
    /// from them (nil = not an image at all). One decode, both consumers: an
    /// image that is only ever re-derived from its `NSImage` loses the bytes, and
    /// with them the answer to "what did it actually send?".
    static func decoded(_ payload: String) -> (data: Data, image: NSImage)? {
        guard !payload.isEmpty, let data = Data(base64Encoded: payload),
              let image = NSImage(data: data) else { return nil }
        return (data, image)
    }

    /// Pixels for an Icon.src that is a `data:` URI — decoded once per src, so
    /// the two theme entries of one tool and an appearance flip share the work.
    static func dataURI(_ src: String) -> NSImage? {
        let key = src as NSString
        if let hit = iconCache.object(forKey: key) { return hit }
        guard let comma = src.firstIndex(of: ","),
              let image = base64(String(src[src.index(after: comma)...])) else { return nil }
        iconCache.setObject(image, forKey: key)
        return image
    }

    /// http(s) icon, fetched once per src. Failures are not cached, so a
    /// transient network error can succeed on the next view.
    static func remote(_ src: String) async -> NSImage? {
        guard let url = URL(string: src), url.scheme == "http" || url.scheme == "https" else { return nil }
        let key = src as NSString
        if let hit = iconCache.object(forKey: key) { return hit }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let image = NSImage(data: data) else { return nil }
        iconCache.setObject(image, forKey: key)
        return image
    }

    /// Successes only — a cache that could hold nil could not tell "decoded
    /// nothing" apart from "never tried", and a transient failure has to be
    /// free to succeed on the next view.
    private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()
}

/// An announced icon, already resolved to pixels for one appearance.
struct IconRef {
    let source: String
    let image: NSImage?

    /// Theme pick + decode. `nil` when nothing was announced or nothing in
    /// `icons[]` has a usable src.
    static func resolve(from icons: [JSONValue]?, dark: Bool) -> IconRef? {
        guard let src = pickSource(from: icons, dark: dark) else { return nil }
        return IconRef(source: src, image: src.hasPrefix("data:") ? Pixels.dataURI(src) : nil)
    }

    /// `src` of the announced icon matching the current appearance, or nil:
    /// theme match → themeless entry → first icon with a usable src.
    static func pickSource(from icons: [JSONValue]?, dark: Bool) -> String? {
        guard let icons else { return nil }
        func src(_ icon: JSONValue) -> String? {
            let s = icon["src"]?.string?.trimmed
            return (s?.isEmpty == false) ? s : nil
        }
        func theme(_ icon: JSONValue) -> String? {
            let t = icon["theme"]?.string?.trimmed.lowercased()
            return (t?.isEmpty == false) ? t : nil
        }
        let want = dark ? "dark" : "light"
        let pick = icons.first { theme($0) == want && src($0) != nil }
            ?? icons.first { theme($0) == nil && src($0) != nil }
            ?? icons.first { src($0) != nil }
        return pick.flatMap { src($0) }
    }

    /// An announced icon whose pixels are still to be fetched (an http(s) src).
    /// A `data:` URI was decoded when the icon was resolved, so this is the
    /// only case in which a tile runs a task.
    var needsFetch: Bool { image == nil && source.hasPrefix("http") }
}

/// An announced icon as a fixed square — the tool-list row badge and the
/// tool-editor header tile. The slot is reserved at a constant size whether or
/// not an icon exists or loads, so rows with and without icons stay aligned.
/// Rendered as sent (original mode, no tint): an announced icon is the
/// server's own pixels.
struct IconTile: View {
    let ref: IconRef?
    var side: CGFloat = 20
    var cornerRadius: CGFloat = 4
    @State private var fetched: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        // Only a remote src has anything to do here — a data: URI was decoded
        // when the icon was resolved, so the common case is a plain lookup.
        .task(id: ref?.source) {
            guard let ref, ref.needsFetch else { return }
            fetched = await Pixels.remote(ref.source)
        }
    }

    private var image: NSImage? { ref?.image ?? fetched }
}
