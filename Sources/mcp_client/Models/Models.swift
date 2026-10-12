import Foundation

/// Identity the client puts on the wire (clientInfo in initialize / _meta).
/// The version is SINGLE-SOURCED here: `build.sh` greps this exact line into the
/// bundle's Info.plist, so bump the app by changing this value and nothing else.
enum AppInfo {
    static let clientName = "Faceless MCP Client"
    static let version = "0.2.0"
    static let repoURL = "https://github.com/facelessfish/mcp-client"
}

// MARK: - Server configuration

struct ServerConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = "New server"
    var url: String = "http://localhost:8000/mcp"
    var era: ProtocolEra = .auto
    var timeoutSeconds: Double = 120
    var clientName: String = AppInfo.clientName
    var headers: [HeaderEntry] = []

    init() {}

    // Custom decoder so future fields don't break old saved configs.
    private enum CodingKeys: String, CodingKey {
        case id, name, url, era, timeoutSeconds, clientName, headers
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Every field degrades to its default instead of throwing: servers.json is
        // documented as hand-editable, and a throw here propagates to AppModel.load,
        // which would cost every server in the file. A value we cannot recognize is
        // a reason to use the default, never a reason to lose the whole config.
        var rawID: UUID?
        do { rawID = try c.decodeIfPresent(UUID.self, forKey: .id) } catch { rawID = nil }
        id             = rawID ?? UUID()
        name           = try c.decodeIfPresent(String.self, forKey: .name) ?? "Server"
        url            = try c.decodeIfPresent(String.self, forKey: .url) ?? "http://localhost:8000/mcp"
        // An unknown era string (a newer build's rawValue) must not poison the file.
        var rawEra: ProtocolEra?
        do { rawEra = try c.decodeIfPresent(ProtocolEra.self, forKey: .era) } catch { rawEra = nil }
        era            = rawEra ?? .auto
        var rawTimeout: Double?
        do { rawTimeout = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) } catch { rawTimeout = nil }
        timeoutSeconds = Self.sanitizeTimeout(rawTimeout ?? 120)
        // The client name on the wire is always the current app name,
        // not whatever an old config file stored.
        clientName = AppInfo.clientName
        var rawHeaders: [HeaderEntry]?
        do { rawHeaders = try c.decodeIfPresent([HeaderEntry].self, forKey: .headers) } catch { rawHeaders = nil }
        headers        = rawHeaders ?? []
    }

    /// 1 s … 3600 s, always finite — a stray value in the config file cannot
    /// hand URLSession a nonsense timeout.
    static func sanitizeTimeout(_ v: Double) -> Double {
        guard v.isFinite else { return 120 }
        return min(max(v, 1), 3600)
    }
}

struct HeaderEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var value: String = ""

    private enum CodingKeys: String, CodingKey { case id, name, value }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var rawID: UUID?
        do { rawID = try c.decodeIfPresent(UUID.self, forKey: .id) } catch { rawID = nil }
        id    = rawID ?? UUID()
        name  = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }
}

/// Which MCP HTTP protocol generation to speak:
/// - 2025-03-26 … 2025-11-25: session-era Streamable HTTP (initialize handshake, Mcp-Session-Id)
/// - 2026-07-28: stateless (no handshake, header routing, per-request metadata)
enum ProtocolEra: String, Codable, CaseIterable, Identifiable {
    case auto
    case v2026_07_28
    case v2025_11_25
    case v2025_06_18
    case v2025_03_26

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:         return "Auto (try 2026-07-28, then 2025 handshake)"
        case .v2026_07_28:  return "2026-07-28 — stateless"
        case .v2025_11_25:  return "2025-11-25 — session"
        case .v2025_06_18:  return "2025-06-18 — session"
        case .v2025_03_26:  return "2025-03-26 — session"
        }
    }

    var versionString: String? {
        switch self {
        case .auto:        return nil
        case .v2026_07_28: return "2026-07-28"
        case .v2025_11_25: return "2025-11-25"
        case .v2025_06_18: return "2025-06-18"
        case .v2025_03_26: return "2025-03-26"
        }
    }

    static let statelessVersion = "2026-07-28"
}

// MARK: - Runtime connection state

enum RuntimeMode {
    case stateless
    case session(version: String, sessionID: String?)

    var sessionID: String? {
        if case .session(_, let sid) = self { return sid }
        return nil
    }
    var protocolVersion: String {
        switch self {
        case .stateless:         return ProtocolEra.statelessVersion
        case .session(let v, _): return v
        }
    }
    var modeLabel: String {
        switch self {
        case .stateless: return "stateless"
        case .session:   return "session"
        }
    }
}

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case ready
    case failed(String)

    var isConnected: Bool {
        if case .ready = self { return true }
        return false
    }
}

struct ReadyInfo {
    var mode: String
    var protocolVersion: String
    var sessionID: String?
}

// MARK: - Tools

struct Tool: Identifiable {
    var name: String
    var title: String?
    var description: String?
    /// Spec Icon[] announced per tool (`tools[].icons`): each entry is
    /// `{src: data: URI or http(s) URL, mimeType?, theme? ("light"/"dark")}`.
    /// Kept as raw JSON — the theme pick and the decode are `withResolvedIcons`
    /// below, and everything stays visible verbatim in the transcript/Raw tab.
    var icons: [JSONValue]?
    /// Spec ToolAnnotations object (`annotations`): `title` plus behavior hints.
    /// Raw so the editor's disclosure shows exactly what the wire said.
    var annotations: JSONValue?
    var inputSchema: JSONValue?
    var raw: JSONValue
    /// The announced icon, resolved for each appearance when tools/list lands:
    /// theme pick and base64 decode done once, off the main actor, instead of
    /// once per row on every view update (see Icons.swift). nil = nothing
    /// announced.
    var iconLight: IconRef?
    var iconDark: IconRef?

    var id: String { name }

    /// Pixels for the current appearance — a lookup, no decoding, no task.
    func icon(dark: Bool) -> IconRef? { dark ? iconDark : iconLight }

    /// Resolves `icons` into pixels for both appearances. Runs off the main
    /// actor while the tools/list reply is still being processed, because a
    /// GitHub-sized list carries two base64 PNGs per tool.
    func withResolvedIcons() -> Tool {
        guard let icons, !icons.isEmpty else { return self }
        var resolved = self
        resolved.iconLight = IconRef.resolve(from: icons, dark: false)
        resolved.iconDark = IconRef.resolve(from: icons, dark: true)
        return resolved
    }

    /// Human label, in spec priority order: top-level `title`, then
    /// `annotations.title` (the GitHub MCP server sets only that one), then
    /// the wire name.
    var displayName: String {
        if let t = title?.trimmed, !t.isEmpty { return t }
        if let a = annotations?["title"]?.string?.trimmed, !a.isEmpty { return a }
        return name
    }

    /// Behavior hints the server **explicitly set to true**. The spec's implied
    /// defaults (destructiveHint is "default true" when absent, etc.) are
    /// deliberately NOT inferred — a debug console shows what was announced,
    /// not what was implied; the tooltip on each chip names the wire key.
    var hints: [BehaviorHint] {
        guard let a = annotations?.object else { return [] }
        var out: [BehaviorHint] = []
        if a["readOnlyHint"]?.bool == true    { out.append(.readOnly) }
        if a["destructiveHint"]?.bool == true { out.append(.destructive) }
        if a["idempotentHint"]?.bool == true  { out.append(.idempotent) }
        if a["openWorldHint"]?.bool == true   { out.append(.openWorld) }
        return out
    }

    static func parse(_ v: JSONValue) -> Tool? {
        guard let name = v["name"]?.string else { return nil }
        // Non-object entries in icons[] are junk we cannot render; dropping them
        // here keeps every consumer from re-checking.
        let icons = v["icons"]?.array?.filter { $0.object != nil }
        return Tool(
            name: name,
            title: v["title"]?.string,
            description: v["description"]?.string,
            icons: icons?.isEmpty == true ? nil : icons,
            annotations: v["annotations"]?.object != nil ? v["annotations"] : nil,
            inputSchema: v["inputSchema"],
            raw: v
        )
    }
}

/// Tool-annotation behavior hints, named after their wire keys (rawValue) with
/// a display label and the spec meaning for the chip tooltip.
enum BehaviorHint: String, CaseIterable, Identifiable {
    case readOnly = "readOnlyHint"
    case destructive = "destructiveHint"
    case idempotent = "idempotentHint"
    case openWorld = "openWorldHint"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .readOnly:    return "read-only"
        case .destructive: return "destructive"
        case .idempotent:  return "idempotent"
        case .openWorld:   return "open-world"
        }
    }

    var explanation: String {
        switch self {
        case .readOnly:
            return "readOnlyHint — the tool does not modify its environment"
        case .destructive:
            return "destructiveHint — the tool may perform destructive updates"
        case .idempotent:
            return "idempotentHint — repeated calls with the same arguments have no additional effect"
        case .openWorld:
            return "openWorldHint — the tool interacts with the outside world (e.g. the web)"
        }
    }
}

// MARK: - Tool call results

struct CallResult: Identifiable {
    let id = UUID()
    let toolName: String
    let date: Date
    let duration: TimeInterval
    let outcome: Outcome
    let rawText: String
    let notifications: [String]
    /// Everything the Result and Raw tabs show about this reply, derived once
    /// when it landed (see ResultPresentation, `withPresentation`). Views read
    /// these values; they derive nothing.
    var presentation = ResultPresentation()

    enum Outcome {
        case success(result: JSONValue)
        case toolError(result: JSONValue)
        case rpcError(code: Int, message: String, data: JSONValue?)
        case transportError(String)
        case cancelled
    }

    /// This result with its presentation derived. Called exactly once per
    /// reply, in ServerModel, at the moment the UI is told about it — that is
    /// the whole caching strategy of this app, in one line.
    func withPresentation() -> CallResult {
        var prepared = self
        prepared.presentation = ResultPresentation(result: self)
        return prepared
    }

    /// The reply as text: the wire body when there is one, the printed result
    /// when there is none. What the Raw tab shows and what Copy takes.
    var displayText: String { presentation.asText }

    /// The JSON-RPC `result` object itself for a completed call or a tool
    /// error — the views read the reply out of it (announced icons in
    /// `_meta`, …); nil for transport failures and cancellations, which have
    /// no reply object at all.
    var replyValue: JSONValue? {
        switch outcome {
        case .success(let value), .toolError(let value): return value
        case .rpcError, .transportError, .cancelled:     return nil
        }
    }
}

// MARK: - Transcript

enum TranscriptDirection {
    case request
    case response
    case note
    case error
}

struct TranscriptEntry: Identifiable {
    let id = UUID()
    let date: Date
    let direction: TranscriptDirection
    let title: String
    /// The body, pretty-printed and whole. No body is ever truncated or
    /// dropped — the Log must be able to surface anything that crossed the
    /// wire, at any length.
    var detail: String?
    /// Hard lines of the body, capped at the point where more would not change
    /// the height of the detail box: enough to size it, never a text layout.
    let detailLines: Int

    init(date: Date, direction: TranscriptDirection, title: String, detail: String?) {
        self.date = date
        self.direction = direction
        self.title = title
        self.detail = detail
        self.detailLines = detail.map { TextMetrics.lines($0, cap: 40) } ?? 0
    }
}

// MARK: - Errors

enum MCPError: Error, CustomStringConvertible {
    case invalidURL(String)
    case http(status: Int, body: String, rpc: RPCError?)
    case rpc(RPCError)
    case streamEnded(String)
    case decoding(String)
    case transport(String)

    var description: String {
        switch self {
        case .invalidURL(let s):
            return "Invalid URL: \(s)"
        case .http(let status, let body, let rpc):
            var text = "HTTP \(status)"
            if let rpc {
                text += " — JSON-RPC \(rpc.code): \(rpc.message)"
            } else {
                let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { text += " — " + String(t.prefix(300)) }
            }
            return text
        case .rpc(let e):
            return e.description
        case .streamEnded(let reason):
            return "Stream closed without response — \(reason)"
        case .decoding(let d):
            return "Unparseable response — \(d)"
        case .transport(let t):
            return "Network error — \(t)"
        }
    }

    /// Errors only a server speaking the modern (2026-07-28) per-request protocol
    /// can produce. Spec § Backward Compatibility: on 400 / 404 / 405 the client
    /// must inspect the body and fall back to `initialize` **only** when the body is
    /// *not* a recognized modern error. Treating these as "the server wants a 2025
    /// handshake" is what silently downgrades a conformant 2026 server.
    struct ModernProtocolSignal {
        /// HeaderMismatch · MissingRequiredClientCapability · UnsupportedProtocolVersion
        static let modernCodes: Set<Int> = [-32020, -32021, -32022]

        var code: Int
        var message: String
        /// `data.supported` of an UnsupportedProtocolVersionError.
        var supportedVersions: [String]
        /// `data.requiredCapabilities` of a MissingRequiredClientCapabilityError.
        var requiredCapabilities: [String]

        /// One of the versions the server advertises that we can speak as a session.
        var legacyVersionToAdopt: String? {
            supportedVersions.filter { $0.hasPrefix("2025") }.sorted(by: >).first
        }
    }

    var modernProtocolSignal: ModernProtocolSignal? {
        let rpc: RPCError?
        switch self {
        case .http(_, _, let r): rpc = r
        case .rpc(let r):        rpc = r
        default:                 return nil
        }
        guard let r = rpc, ModernProtocolSignal.modernCodes.contains(r.code) else { return nil }
        let data = r.data?.object
        let strings: (JSONValue?) -> [String] = { $0?.array?.compactMap { $0.string } ?? [] }
        return ModernProtocolSignal(
            code: r.code,
            message: r.message,
            supportedVersions: strings(data?["supported"]),
            requiredCapabilities: strings(data?["requiredCapabilities"]))
    }

    /// True when the failure suggests "this server wants the 2025 session handshake".
    /// Used only by era == .auto detection. Auth failures are NOT an era hint, and
    /// neither is an error only a modern server could have emitted.
    var looksLikeSessionEra: Bool {
        if modernProtocolSignal != nil { return false }
        switch self {
        case .http(let status, let body, let rpc):
            if status == 401 || status == 403 { return false }
            if status == 400 || status == 404 || status == 405 { return true }
            if rpc != nil { return true }
            let l = body.lowercased()
            return l.contains("initializ") || l.contains("session")
        case .rpc(let e):
            let l = e.message.lowercased()
            return e.code == -32001 || e.code == -32002
                || l.contains("initializ") || l.contains("session")
        default:
            return false
        }
    }
}

func describe(_ error: Error) -> String {
    if let e = error as? MCPError { return e.description }
    if let e = error as? RPCError { return e.description }
    if error is CancellationError { return "cancelled" }
    return error.localizedDescription
}
