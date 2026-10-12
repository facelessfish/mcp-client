import Foundation
import SwiftUI
import AppKit

/// The Server tab: the current connection as a readable profile — identity,
/// protocol era, transport details, and what the server announced about
/// itself — instead of a raw JSON dump. The JSON never gets far away: the raw
/// initialize result stays behind a disclosure, the Raw tab keeps the exact
/// payload, and Copy on the tab bar still yields the text form.
struct ServerProfileView: View {
    let server: ServerModel
    @Environment(\.colorScheme) private var scheme

    private var pal: Catppuccin.Palette { Catppuccin.palette(for: scheme) }
    private var connected: Bool { server.status.isConnected }
    private var initResult: JSONValue? { server.lastInitResult }

    private var discover: JSONValue? { server.statelessDiscover }

    /// Server identity, wherever the negotiated era publishes it: the session
    /// era answers it in initialize; the stateless era in `server/discover`
    /// or, failing that, in a result's `_meta`.
    private var advertised: JSONValue? {
        if let si = initResult?["serverInfo"], si.object != nil { return si }
        if let si = discover?["_meta"]?["io.modelcontextprotocol/serverInfo"], si.object != nil { return si }
        if let si = server.statelessServerInfo, si.object != nil { return si }
        return nil
    }

    private var capabilities: [String] {
        (initResult?["capabilities"] ?? discover?["capabilities"])?.object?.keys.sorted() ?? []
    }

    private var instructions: String? {
        let s = (initResult?["instructions"] ?? discover?["instructions"])?.string?.trimmed
        return (s?.isEmpty == false) ? s : nil
    }

    /// The announced icon for the current appearance — the same pick and the
    /// same decoded-pixel cache as the tool rows (see Icons.swift), resolved
    /// again when the OS appearance flips.
    private var iconRef: IconRef? {
        IconRef.resolve(from: advertised?["icons"]?.array, dark: scheme == .dark)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if case .failed(let message) = server.status {
                    banner(message)
                }
                connectionCard
                configCard
                if let info = advertised {
                    announcedCard(info)
                }
                if !capabilities.isEmpty || instructions != nil {
                    capabilitiesCard
                }
                if let initResult {
                    rawResultCard("raw initialize result", initResult)
                } else if let discover {
                    rawResultCard("raw server/discover result", discover)
                }
                // Nothing announced, nothing shown — the status dot, transport
                // and tools rows already say all there is to say.
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ServerIconView(ref: iconRef, color: statusColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(server.config.name)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(server.displayURL)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    copyButton(server.displayURL)
                }
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Cards

    private var connectionCard: some View {
        card {
            VStack(alignment: .leading, spacing: 7) {
                row("protocol") {
                    if let ready = server.ready {
                        HStack(spacing: 6) {
                            Text(ready.protocolVersion)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                            Text(eraNickname(ready.protocolVersion))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else { emptyValue }
                }
                row("transport") {
                    if let ready = server.ready {
                        Text(ready.mode == "stateless"
                             ? "stateless — header routing, per-request metadata"
                             : "session — initialize handshake, Mcp-Session-Id")
                            .font(.callout)
                    } else { emptyValue }
                }
                if let versions = discover?["supportedVersions"]?.array, !versions.isEmpty {
                    row("supports") {
                        Text(versions.compactMap { $0.string }.joined(separator: ", "))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                row("session id") {
                    if let sid = server.ready?.sessionID {
                        HStack(spacing: 6) {
                            Text(sid)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                            copyButton(sid)
                        }
                    } else { emptyValue }
                }
                row("tools") {
                    Text(connected ? "\(server.tools.count) loaded" : "—").font(.callout)
                }
            }
        }
    }

    private var configCard: some View {
        card {
            VStack(alignment: .leading, spacing: 7) {
                row("url (saved)") {
                    Text(server.config.url)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
                row("protocol pref") {
                    Text(server.config.era.label).font(.callout)
                }
                row("timeout") {
                    Text(String(format: "%g", server.config.timeoutSeconds) + " s inactivity")
                        .font(.callout)
                }
                row("headers") {
                    if server.config.headers.isEmpty {
                        dimValue("none")
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(server.config.headers) { h in
                                HStack(spacing: 6) {
                                    Text(h.name).font(.system(size: 11, design: .monospaced))
                                    Text(Connection.masked(name: h.name, value: h.value))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                row("client sent") {
                    Text("\(server.config.clientName) v\(AppInfo.version)")
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func announcedCard(_ info: JSONValue) -> some View {
        return card {
            VStack(alignment: .leading, spacing: 7) {
                row("name") {
                    Text(info["name"]?.string ?? "—")
                        .font(.callout.weight(.semibold))
                        .textSelection(.enabled)
                }
                if let title = info["title"]?.string, !title.trimmed.isEmpty {
                    row("title") { Text(title).font(.callout).textSelection(.enabled) }
                }
                row("version") {
                    Text(info["version"]?.string ?? "—")
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let site = info["websiteUrl"]?.string, !site.isEmpty, let url = URL(string: site) {
                    row("website") { Link(site, destination: url).font(.callout) }
                }
                // icons[] is not listed as text: the header tile renders the
                // entry that matches the current appearance.
            }
        }
    }

    private var capabilitiesCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                if !capabilities.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("capabilities").font(labelFont).foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(capabilities, id: \.self) { cap in
                                Text(cap)
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(Capsule().fill(pal.blue.opacity(0.15)))
                                    .foregroundStyle(pal.blue)
                            }
                        }
                    }
                }
                if let instructions {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("instructions").font(labelFont).foregroundStyle(.secondary)
                        // Some servers ship a page of instructions; Prose bounds
                        // that instead of asking SwiftUI to measure it. The
                        // Server tab opts out of Find, instructions included.
                        Prose(instructions, findable: false)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Printed here rather than in the model: a handshake/discover result is a
    /// few kilobytes, and this view re-renders only when the connection state
    /// changes — not on log lines or keystrokes, which is the case that matters.
    /// The surface scrolls, so a bigger payload cannot push the page open.
    private func rawResultCard(_ title: String, _ value: JSONValue) -> some View {
        card {
            // TappableDisclosure, same as the tool editor's disclosures: the
            // whole title row toggles, chevron after the label.
            TappableDisclosure(title: title) {
                // findable: false — the Server tab is not a search space:
                // its payload is a few kilobytes in plain sight, and the
                // output toolbar hides Find here (⌘F finds no surface).
                TextSurface(text: value.prettyString, height: .fixed(220), findable: false)
            }
            .font(.callout)
        }
    }

    // MARK: - Building blocks

    private var labelFont: Font { .system(size: 11, design: .monospaced) }
    private var emptyValue: some View { Text("—").font(.callout).foregroundStyle(.secondary) }
    private func dimValue(_ s: String) -> some View { Text(s).font(.callout).foregroundStyle(.secondary) }

    private func row<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(labelFont)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            value()
            Spacer(minLength: 0)
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        // Closure, not value: CardBox's @ViewBuilder `content` memberwise init
        // takes `() -> Content`; `content()` here was already-evaluated C.
        CardBox { content() }
    }

    private func banner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copyButton(_ text: String) -> some View {
        Button { Clip.copy(text) } label: {
            Image(systemName: "doc.on.doc").font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Copy")
    }

    // MARK: - Status

    private var statusColor: Color {
        switch server.status {
        case .ready:        return .green
        case .connecting:   return .yellow
        case .failed:       return .red
        case .disconnected: return Color.secondary.opacity(0.6)
        }
    }

    private var statusText: String {
        switch server.status {
        case .ready:        return "connected"
        case .connecting:   return "connecting…"
        case .failed:       return "connection failed"
        case .disconnected: return "not connected"
        }
    }

    /// The spec versions servers by date only — no official names exist — so
    /// pair the wire value with the era's defining trait (see README).
    private func eraNickname(_ version: String) -> String {
        if version == ProtocolEra.statelessVersion { return "stateless era" }
        if version == "2024-11-05" { return "HTTP+SSE era (unsupported)" }
        if version.hasPrefix("2025") { return "session era" }
        return "unknown era"
    }
}

/// The profile's header tile: the server's announced icon — the spec's Icon
/// type, an http(s) URL or a base64 `data:` URI, optionally tagged with a
/// `theme` — as an `IconRef` already picked for the current appearance (its
/// `data:` pixels come with it; only a URL still needs fetching). No icon, an unreachable URL, or
/// undecodable pixels all fall back to the server.rack placeholder (the same
/// artwork the app icon uses: icons/AppIcon-1024.svg). An announced icon is
/// rendered untouched — original mode, nothing behind it — the status color
/// decorates only the placeholder. No tooltip: the src can be a megabyte of
/// base64 and the tile is decorative, not informational.
private struct ServerIconView: View {
    let ref: IconRef?
    let color: Color
    @State private var fetched: NSImage?

    private var image: NSImage? { ref?.image ?? fetched }

    var body: some View {
        ZStack {
            if let image {
                // Announced icon: pixels exactly as the server sent them,
                // no status-color layer underneath (a wash would bleed
                // through transparent PNGs) and no tint on top.
                Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // Placeholder only: this is where the status color lives.
                RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.15))
                Image(systemName: "server.rack")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(color)
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Only an http(s) src has anything to fetch — a data: URI arrived
        // already decoded in `ref`.
        .task(id: ref?.source) {
            guard let ref, ref.needsFetch else { return }
            fetched = await Pixels.remote(ref.source)
        }
    }
}
