import Foundation
import Observation

/// Per-server UI state + connection orchestration. MainActor-isolated;
/// URLSession async I/O runs off-main, so the UI never blocks.
@MainActor
@Observable
final class ServerModel: Identifiable {
    var config: ServerConfig
    /// Stored Sendable `let` is nonisolated, so it satisfies `Identifiable`
    /// without crossing into the main-actor-isolated `config` (Swift 6 ready).
    let id: UUID

    private(set) var status: ConnectionStatus = .disconnected
    private(set) var ready: ReadyInfo?
    private(set) var tools: [Tool] = []
    private(set) var transcript: [TranscriptEntry] = []
    private(set) var lastInitResult: JSONValue?
    /// Server identity a stateless (2026-07-28) server publishes in the
    /// `_meta` of a result (tools/list, server/discover) — the handshake-free
    /// counterpart of lastInitResult. Shown by the Server profile.
    private(set) var statelessServerInfo: JSONValue?
    /// Full `server/discover` result from connect time (stateless era):
    /// supportedVersions + capabilities + instructions + _meta.serverInfo.
    private(set) var statelessDiscover: JSONValue?
    private(set) var lastResult: CallResult?
    private(set) var isCalling = false
    private(set) var callProgress: String?

    var lastError: String?
    var lastArgsError: String?
    var selectedToolID: String?
    var argsDrafts: [String: String] = [:]
    /// Tools ⇆ editor split position (fraction of pane height above the
    /// divider) — the live value while the sash is dragged, so the drag itself
    /// never touches persisted state. The copy that survives a restart lives in
    /// AppModel (`toolsSplit(for:)`), which the view falls back to when this is
    /// nil; nil here with nothing persisted means the untouched 50/50 default.
    var toolsSplitFraction: Double?

    private var connection: Connection?
    private var callTask: Task<Void, Never>?

    private static let maxTranscriptEntries = 600

    init(config: ServerConfig) {
        self.id = config.id
        self.config = config
    }

    // MARK: - Connection lifecycle

    func toggleConnect() async {
        if status.isConnected { await disconnect() } else { await connect() }
    }

    func connect() async {
        status = .connecting
        lastError = nil
        lastInitResult = nil
        statelessServerInfo = nil
        statelessDiscover = nil
        tools = []
        let conn = Connection(config: config) { [weak self] entry in
            Task { @MainActor in self?.log(entry) }
        }
        connection = conn
        do {
            let info = try await conn.connect(preferredEra: config.era)
            guard connection === conn else { return }
            ready = info
            // The handshake result only exists for the session era; `nil` here means
            // stateless (no initialize), which serverInfoText renders as a note.
            lastInitResult = conn.lastInitResultJSON
            let fetched: [Tool]
            if let preloaded = conn.connectedTools {
                fetched = preloaded
            } else {
                fetched = try await conn.listTools()
            }
            // Disconnect / config edit happened mid-flight: this conn is gone, and
            // publishing its tools or .ready would light up a dead connection.
            guard connection === conn else { return }
            tools = fetched
            statelessServerInfo = conn.metaServerInfo
            // Stateless era: server/discover is the mandatory discovery RPC —
            // where a 2026 server advertises capabilities, instructions and
            // identity without a handshake. Best-effort: a server that does
            // not implement it simply has nothing to advertise (Auto-2025
            // fallback servers reject it, which is expected).
            if ready?.mode == "stateless" {
                _ = try? await conn.discover()
                statelessDiscover = conn.discoverResult
                statelessServerInfo = conn.metaServerInfo
            }
            status = .ready
            if selectedToolID == nil { selectedToolID = tools.first?.name }
        } catch is CancellationError {
            guard connection === conn else { return }
            status = .disconnected
        } catch {
            guard connection === conn else { return }
            let message = describe(error)
            lastError = message
            status = .failed(message)
            ready = nil
            connection = nil
        }
    }

    func disconnect() async {
        callTask?.cancel()
        callTask = nil
        isCalling = false
        if let connection { await connection.terminateSession() }
        connection = nil
        ready = nil
        tools = []
        lastResult = nil
        lastInitResult = nil
        statelessServerInfo = nil
        statelessDiscover = nil
        selectedToolID = nil
        status = .disconnected
        appendNote("disconnected")
    }

    func refreshTools() async {
        guard let connection, status.isConnected else { return }
        do {
            let fetched = try await connection.listTools()
            guard self.connection === connection else { return }   // superseded by a reconnect
            tools = fetched
            lastError = nil
            if selectedToolID == nil { selectedToolID = tools.first?.name }
        } catch {
            guard self.connection === connection else { return }
            lastError = describe(error)
        }
    }

    /// Called by AppModel when the user saves edits to this server's config.
    func updateConfig(_ newConfig: ServerConfig) {
        let wasConnected = status.isConnected
        callTask?.cancel()
        config = newConfig
        connection = nil
        ready = nil
        tools = []
        lastResult = nil
        lastInitResult = nil
        statelessServerInfo = nil
        statelessDiscover = nil
        selectedToolID = nil
        status = .disconnected
        appendNote("configuration updated")
        if wasConnected {
            Task { await self.connect() }
        }
    }

    // MARK: - Tool calls

    func callTool(_ tool: Tool, argsText: String) {
        guard !isCalling else { return }
        lastArgsError = nil
        var args: JSONValue = .object([:])
        let trimmed = argsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard let data = trimmed.data(using: .utf8),
                  let v = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                lastArgsError = "Arguments are not valid JSON"
                return
            }
            guard v.object != nil || v.isNull else {
                lastArgsError = "Arguments must be a JSON object"
                return
            }
            if !v.isNull { args = v }
        }
        guard let connection else { lastArgsError = "Not connected"; return }

        isCalling = true
        lastResult = nil
        callProgress = nil
        callTask = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                let result = try await connection.callTool(name: tool.name, arguments: args) { note in
                    Task { @MainActor in self.callProgress = note }
                }
                // One pass over the reply to derive how it looks — the main
                // document, the decoded images, the text form — right here, so
                // that painting the Result tab afterwards is a read, never a
                // parse (see ResultPresentation).
                self.lastResult = result.withPresentation()
            } catch is CancellationError {
                self.lastResult = CallResult(
                    toolName: tool.name, date: started,
                    duration: Date().timeIntervalSince(started),
                    outcome: .cancelled, rawText: "", notifications: []
                ).withPresentation()
                self.appendNote("tools/call “\(tool.name)” cancelled — stream closed")
            } catch {
                self.lastResult = CallResult(
                    toolName: tool.name, date: started,
                    duration: Date().timeIntervalSince(started),
                    outcome: .transportError(describe(error)),
                    rawText: "", notifications: []
                ).withPresentation()
            }
            self.isCalling = false
            self.callProgress = nil
            self.callTask = nil
        }
    }

    func cancelCall() {
        guard isCalling, let connection else { return }
        if let rpcID = connection.inFlightRPCRequestID {
            Task { await connection.sendCancelNotification(rpcRequestID: rpcID) }
        }
        callTask?.cancel()
    }

    // MARK: - Transcript / misc

    /// URL as shown in the window subtitle and the sidebar rows: always with an
    /// explicit scheme (http:// is assumed when the config omits one, same rule
    /// the connection applies on the wire), minus a trailing slash.
    var displayURL: String {
        var s = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        if s.hasSuffix("/") && s.count > 8 { s = String(s.dropLast()) }
        return s
    }

    func clearLog() {
        transcript.removeAll()
    }

    private func appendNote(_ text: String) {
        log(TranscriptEntry(date: Date(), direction: .note, title: text, detail: nil))
    }

    /// Append, keeping the newest `maxTranscriptEntries` rows. The cap is on
    /// ROWS, never on content: a kept row holds its body whole — nothing is
    /// truncated and no body is ever dropped, so everything still in the
    /// window is searchable at full length.
    private func log(_ entry: TranscriptEntry) {
        transcript.append(entry)
        if transcript.count > Self.maxTranscriptEntries {
            transcript.removeFirst(transcript.count - Self.maxTranscriptEntries)
        }
    }

    var serverInfoText: String {
        guard let ready else { return "(not connected)" }
        var o: [String: JSONValue] = [
            "transport": .string(ready.mode),
            "protocolVersion": .string(ready.protocolVersion),
            "toolsLoaded": .int(tools.count),
        ]
        if let sid = ready.sessionID { o["sessionId"] = .string(sid) }
        if let discover = statelessDiscover {
            o["discoverResult"] = discover
        } else if let si = statelessServerInfo {
            o["serverInfoFromResultMeta"] = si
        }
        if let lastInitResult {
            o["initializeResult"] = lastInitResult
        } else if ready.mode == "session" {
            o["note"] = .string("initialize returned no result to show")
        } else {
            o["note"] = .string("stateless mode: 2026-07-28 has no initialize handshake — server identity travels per-request in _meta/Mcp-Name")
        }
        return JSONValue.object(o).prettyString
    }
}
