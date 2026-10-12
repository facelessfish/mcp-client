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
                case .raw:    TextSurface(text: rawText, mode: .code, primary: true).padding(10)
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
                return "[\(time)] \(entry.title)\n\(entry.detail ?? "\n")"
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let result = server.lastResult {
            VStack(spacing: 8) {
                header(result)

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
                            ImageDeck(images: result.presentation.images)
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

    /// Identity on the left — the icon the reply announces itself, or the
    /// tool's, or no icon and no space — the tool's wire name in the editor's
    /// headline font. The call's facts on the right: duration, time, and the
    /// outcome, time sitting immediately left of the outcome label.
    private func header(_ result: CallResult) -> some View {
        HStack(spacing: 8) {
            if let icon = headerIcon(result), icon.image != nil || icon.needsFetch {
                IconTile(ref: icon, side: 28, cornerRadius: 6)
            }
            Text(result.toolName).font(.headline)
            Spacer(minLength: 8)
            Text("\(Int(result.duration * 1000)) ms")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(result.date, style: .time)
                .font(.caption).foregroundStyle(.secondary)
            statusLabel(result)
        }
    }

    /// Which icon names this reply, in order: one the reply announces itself
    /// (`_meta`'s serverInfo icons — the theme pick, light/dark when present,
    /// lives in `IconRef.resolve`), else the tool's announced icon, else none.
    /// An announcement whose pixels are undecodable is "none", and the header
    /// reserves no space for it.
    private func headerIcon(_ result: CallResult) -> IconRef? {
        let dark = scheme == .dark
        if let icons = result.replyValue?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["icons"]?
            .array?.filter({ $0.object != nil }),
           let announced = IconRef.resolve(from: icons, dark: dark) {
            return announced
        }
        return server.tools.first { $0.name == result.toolName }?.icon(dark: dark)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func statusLabel(_ r: CallResult) -> some View {
        switch r.outcome {
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

/// The reply's image content blocks as decoded pixels — the base64 that
/// carries them stays in Raw. Always rendered when the reply carries images:
/// below the text document when there is one, alone when the reply is just
/// pixels. Sized to the pane's width (aspect-fit — an image taller than the
/// pane simply extends the outer scroll), stacked top-down when the server
/// sent several, bordered like every text surface. The pixels were decoded
/// when the reply landed (`ResultPresentation.mainImages`); this view only
/// draws them.
private struct ImageDeck: View {
    let images: [NSImage]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
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
                    if entry.detail != nil {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
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
