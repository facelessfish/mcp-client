import SwiftUI
import AppKit

enum OutputTab: String, CaseIterable, Identifiable {
    case result = "Result"
    case raw = "Raw"
    case log = "Log"
    case server = "Server"
    var id: String { rawValue }
}

struct OutputPane: View {
    let server: ServerModel
    @Environment(AppModel.self) private var app

    /// App-wide selection (see AppModel.outputTab) — survives server switches.
    private var tab: OutputTab { app.outputTab }

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $app.outputTab) {
                    ForEach(OutputTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)

                Button { Clip.copy(tabText) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy visible content")

                // Find belongs to the two document tabs only. The Server tab
                // holds small payloads in plain sight, and the Log is a list
                // of collapsible rows rather than one searchable text —
                // neither offers a surface for Find, and ⌘F there does
                // nothing.
                if tab == .result || tab == .raw {
                    Button { TextSurface.showFind() } label: { Image(systemName: "text.magnifyingglass") }
                        .help("Find in the text (⌘F)")
                }

                if tab == .log {
                    Button { server.clearLog() } label: { Image(systemName: "trash") }
                        .help("Clear log")
                }
                Spacer()
            }
            .padding(8)
            Divider()

            Group {
                switch tab {
                case .result: ResultTab(server: server)
                case .raw:    RawTab(server: server, text: rawText)
                case .log:    LogTab(entries: server.transcript)
                case .server: ServerProfileView(server: server)
                }
            }
            // Fill the remaining height so the tab bar stays pinned to the top
            // even when the content below is empty.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // A reply that comes back while you are sitting on the Server profile is
        // brought to you: that is the tab the app opens on and it holds nothing
        // of the call — the Result tab would otherwise stay unseen until you
        // found it. Any tab you chose yourself (Result, Raw, Log) is yours: a
        // call never moves you off it. Reacting to the result rather than to the
        // Call button also means the jump happens when there is something to
        // show, not into an empty pane while the call is still in flight.
        .onChange(of: server.lastResult?.id) { _, landed in
            guard landed != nil, app.outputTab == .server else { return }
            app.outputTab = .result
        }
    }

    /// The whole reply as text — the wire body when there is one, the printed
    /// result when there is not. `ResultPresentation` derived it once, when the
    /// call returned; this tab and Copy just hand the same string over.
    private var rawText: String {
        if let result = server.lastResult { return result.displayText }
        if let error = server.lastError { return error }
        return server.serverInfoText
    }

    private var tabText: String {
        switch tab {
        case .result: return server.lastResult?.displayText ?? ""
        case .raw:    return rawText
        case .log:
            return server.transcript.map { entry in
                let time = Self.timestampFormatter.string(from: entry.date)
                // The size rides the line the same way it rides the row. Plain
                // digits here, not the row's compact `12.4 KB`: a copied
                // transcript is pasted into a diff or a grep, where an exact
                // count is the useful form.
                let size = entry.bytes.map { " · \($0) bytes" } ?? ""
                return "[\(time)] \(entry.title)\(size)\n\(entry.detail ?? "\n")"
            }.joined(separator: "\n")
        case .server: return server.serverInfoText
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// MARK: - Result tab
//
// The reply's main body: the text document (`ResultPresentation` picked it
// once, when the call returned — structuredContent, the content text printed
// as JSON when the text itself is JSON, or the whole result as the never-
// blank fallback) and, whenever the reply carries images, the decoded image
// deck below it. Colourised, rendered as prose, or drawn as pixels — and
// nothing here derives from the payload: the header is a row of labels, the
// text scrolls inside a bounded surface, the images arrive already decoded.
// The page is therefore a handful of constants tall no matter what the server
// returned, which is why resizing the window while a 400 KB reply is on screen
// costs nothing.

struct ResultTab: View {
    let server: ServerModel

    var body: some View {
        if let result = server.lastResult {
            VStack(spacing: 8) {
                CallHeader(result: result, server: server)

                if !result.notifications.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        caption("Stream notifications (\(result.notifications.count))")
                        ForEach(Array(result.notifications.enumerated()), id: \.offset) { _, note in
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                    }
                }

                if result.presentation.images.isEmpty {
                    // No pixels: the text document fills the pane on its
                    // own and scrolls inside its surface, as always.
                    TextSurface(text: result.presentation.document,
                                mode: result.presentation.documentMode,
                                height: .fill,
                                primary: true)
                } else {
                    // Pixels present: one outer scroll, text document first
                    // (a bounded, self-scrolling surface — SwiftUI still
                    // never measures it) with the image deck below it. An
                    // image-only reply has no text document, so the deck
                    // stands alone.
                    ScrollView {
                        VStack(spacing: 10) {
                            if !result.presentation.document.isEmpty {
                                TextSurface(text: result.presentation.document,
                                            mode: result.presentation.documentMode,
                                            height: .fixed(TextMetrics.blockHeight(
                                                lines: result.presentation.documentLines)))
                            }
                            ImageDeck(images: result.presentation.images,
                                      toolName: result.toolName)
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            // Empty stays empty — no placeholder. The tab bar is pinned to the
            // top; call a tool and the reply appears under it.
            Color.clear
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

// MARK: - The header of a call
//
// One row, both document tabs: the Result tab and the Raw tab wear this exact
// header, so moving between a reply and its bytes does not move the frame you
// are reading it in — only the body underneath changes.
//
// Identity on the left — the icon the reply announces itself, or the tool's, or
// no icon and no space — the tool's wire name in the editor's headline font.
// The call's facts on the right, in the order you ask about them: how big, how
// long, when, and how it went.

struct CallHeader: View {
    let result: CallResult
    let server: ServerModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            if let icon = headerIcon, icon.image != nil || icon.needsFetch {
                IconTile(ref: icon, side: 28, cornerRadius: 6)
            }
            Text(result.toolName).font(.headline)
            Spacer(minLength: 8)
            if let bytes = result.wireBytes {
                Text(ByteSize.label(bytes))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("\(ByteSize.exact(bytes)) came back on the wire")
            }
            Text("\(Int(result.duration * 1000)) ms")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(result.date, style: .time)
                .font(.caption).foregroundStyle(.secondary)
            statusLabel
        }
    }

    /// Which icon names this reply, in order: one the reply announces itself
    /// (`_meta`'s serverInfo icons — the theme pick, light/dark when present,
    /// lives in `IconRef.resolve`), else the tool's announced icon, else none.
    /// An announcement whose pixels are undecodable is "none", and the header
    /// reserves no space for it.
    private var headerIcon: IconRef? {
        let dark = scheme == .dark
        if let icons = result.replyValue?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["icons"]?
            .array?.filter({ $0.object != nil }),
           let announced = IconRef.resolve(from: icons, dark: dark) {
            return announced
        }
        return server.tools.first { $0.name == result.toolName }?.icon(dark: dark)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch result.outcome {
        case .success:
            Label("Success", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case .toolError:
            Label("Tool error (isError)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
        case .rpcError, .transportError:
            Label("Failure", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.callout)
        case .cancelled:
            Label("Cancelled", systemImage: "slash.circle")
                .foregroundStyle(.secondary).font(.callout)
        }
    }
}

// MARK: - Raw tab
//
// The whole reply, byte for byte, in the same header the Result tab wears: the
// two tabs are the same call seen at two depths, and they say so identically.
// Below the header sits the body — the wire body when there is one, the
// printed result when the call never got a body back. With nothing to show
// except that last kind of text (a failure, or the profile of a fresh
// connection) there is no call to identify, so the surface stands alone.

struct RawTab: View {
    let server: ServerModel
    let text: String

    var body: some View {
        if let result = server.lastResult {
            VStack(spacing: 8) {
                CallHeader(result: result, server: server)
                TextSurface(text: text, mode: .code, primary: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            TextSurface(text: text, mode: .code, primary: true)
                .padding(10)
        }
    }
}

/// The reply's image content blocks as decoded pixels — the base64 that
/// carries them stays in Raw. Always rendered when the reply carries images:
/// below the text document when there is one, alone when the reply is just
/// pixels. Sized to the pane's width (aspect-fit — an image taller than the
/// pane simply extends the outer scroll), stacked top-down when the server
/// sent several, bordered like every text surface. The pixels were decoded
/// when the reply landed (`ResultPresentation.mainImages`); this view only
/// draws them, and points at `ImageActions` for everything else.
///
/// Two ways out of the window, both offered on the picture itself: the
/// right-click menu (Save Image… / Copy Image) and a drag, which carries the
/// image as a file — straight onto the Desktop. Both use the block's decoded
/// bytes rather than these pixels, so the file you get is the file the server
/// sent (`ImageActions`), named after the tool that sent it.
private struct ImageDeck: View {
    let images: [ReplyImage]
    /// The tool whose reply this is — the first word of every suggested name.
    let toolName: String

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                Image(nsImage: image.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25)))
                    .help("\(ImageActions.note(for: image)) — right-click to save, drag out to keep")
                    .contextMenu {
                        Button("Save Image…") { ImageActions.save(image, suggestedName: name(image, index)) }
                        Button("Copy Image") { ImageActions.copy(image) }
                    }
                    .onDrag { ImageActions.dragProvider(image, suggestedName: name(image, index)) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// `add-1.png` — the tool's wire name and the block's place in the reply,
    /// with the extension the bytes actually have.
    private func name(_ image: ReplyImage, _ index: Int) -> String {
        ImageActions.suggestedName(toolName: toolName, index: index, image: image)
    }
}

// MARK: - Log tab

struct LogTab: View {
    let entries: [TranscriptEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { entry in
                        TranscriptRow(entry: entry).id(entry.id)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: entries.count) { _, _ in
                if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

struct TranscriptRow: View {
    let entry: TranscriptEntry
    @Environment(\.colorScheme) private var scheme
    @State private var expanded = false

    /// Row timestamp: hour, minute **and seconds**. `Text(_, style: .time)`
    /// showed hour:minute only, which made an exchange of two lines seconds
    /// apart look simultaneous — the whole reason to read a log timestamp is
    /// to place one line against the next. Matches what Copy writes into a
    /// transcript (OutputPane's formatter), minus the milliseconds.
    private static let rowTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                guard entry.detail != nil else { return }
                // Deliberately not animated: the box below is as tall as the
                // body it holds, and animating that height used to re-lay the
                // whole body out once per frame of the animation. A chevron
                // that flips and a box that appears is the right speed for a
                // transcript anyway.
                expanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.rowTimeFormatter.string(from: entry.date))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(symbol)
                        .font(.caption.bold())
                        .foregroundStyle(color)
                        .frame(width: 12)
                    Text(entry.title)
                        .font(.callout)
                        .foregroundStyle(color)
                        .lineLimit(expanded ? nil : 1)
                        .multilineTextAlignment(.leading)
                    // The chevron stays glued to the title it opens: it belongs
                    // to the words, not to the row's edge.
                    if entry.detail != nil {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    // The size of the body this row's exchange moved — sent for
                    // a `→`, received for a `←` — alone at the right edge, in a
                    // column of its own: scroll the transcript top to bottom and
                    // the sizes read as a ledger of what the wire carried, one
                    // per row. Notes and bodyless failures have none, and take
                    // no space. Counted by the transport, never measured off the
                    // detail below, which is pretty-printed and therefore bigger.
                    if let bytes = entry.bytes {
                        Text(ByteSize.label(bytes))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .help(ByteSize.exact(bytes))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let detail = entry.detail, expanded {
                // findable: false — the Log is not a search space (like the
                // Server tab, no Find button and ⌘F stays silent); the full
                // text of any entry is searchable where it lives as a
                // document, on the Raw tab.
                TextSurface(text: detail, mode: .code, height: .fixed(
                    TextMetrics.blockHeight(lines: entry.detailLines, minimum: 120, maximum: 420)),
                    findable: false)
            }
        }
    }

    // Direction marker: → outgoing POST (we send it), ← incoming (the answer
    // comes back) — drawn along the wire instead of up/down, which reads as
    // request/response when the transcript is a vertical list of exchanges.
    // Errors point back as well (red ←: the color plus the HTTP status /
    // JSON-RPC code in the title carry the error; a "✕" marker was redundant).
    // Note: "invalid URL" errors are local — they appear as a red ← with no
    // preceding →, because the POST never went out.
    private var symbol: String {
        switch entry.direction {
        case .request:  "→"
        case .response: "←"
        case .note:     "•"
        case .error:    "←"
        }
    }
    /// Same palette as the JSON highlighting (Catppuccin light/dark).
    private var color: Color {
        let pal = Catppuccin.palette(for: scheme)
        switch entry.direction {
        case .request:  return pal.blue
        case .response: return pal.green
        case .note:     return pal.subtle
        case .error:    return pal.red
        }
    }
}
