import Foundation

/// One MCP Streamable HTTP connection. Deliberately protocol-thin: raw bodies,
/// headers, statuses and SSE events are surfaced verbatim for debugging.
///
/// Speaks:
///  - 2026-07-28 stateless: MCP-Protocol-Version + Mcp-Method/Mcp-Name headers, the
///    reserved io.modelcontextprotocol/{protocolVersion,clientInfo,clientCapabilities}
///    keys in params._meta, x-mcp-header values mirrored into Mcp-Param-* headers.
///  - 2025-03-26 … 2025-11-25 session: initialize handshake, Mcp-Session-Id,
///    MCP-Protocol-Version header on subsequent requests.
///
/// Thread-safety: methods run as independent Tasks (a call streaming while a
/// cancel notification or a server-request rejection goes out), so mutable
/// state is serialized behind `stateLock`. Never hold the lock across an await.
final class Connection {
    private let config: ServerConfig
    private let session: URLSession
    private let onEvent: (TranscriptEntry) -> Void
    private let clientVersion = AppInfo.version

    /// Sent as io.modelcontextprotocol/clientCapabilities on every 2026 request —
    /// a REQUIRED field, so it is always present even while the client implements no
    /// client-side features. Add keys here when it does (sampling, elicitation…).
    private let clientCapabilities: [String: JSONValue] = [:]

    /// Methods that carry the required Mcp-Name header (from params.name/params.uri).
    static let nameHeaderMethods: Set<String> = ["tools/call", "prompts/get", "resources/read"]

    // Lock-protected state ---------------------------------------------------
    private let stateLock = NSLock()
    private var _mode: RuntimeMode?
    private var _lastSessionHeader: String?
    private var _nextRequestID = 1
    /// In-flight requests, id → method. A single "current id" slot went wrong as soon
    /// as two requests overlapped (reloading tools during a call), which made
    /// notifications/cancelled name the wrong request.
    private var _inFlight: [Int: String] = [:]
    private var _toolSchemas: [String: JSONValue] = [:]

    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    var mode: RuntimeMode? { withLock { _mode } }
    private func setMode(_ newMode: RuntimeMode?) { withLock { _mode = newMode } }

    /// Session id seen in the most recent response headers (read right after initialize).
    private var lastSessionHeader: String? {
        get { withLock { _lastSessionHeader } }
        set { withLock { _lastSessionHeader = newValue } }
    }

    var toolSchemas: [String: JSONValue] { withLock { _toolSchemas } }
    private func setToolSchemas(_ schemas: [String: JSONValue]) { withLock { _toolSchemas = schemas } }

    /// The request a Cancel should name: the in-flight `tools/call` if there is one
    /// (that is what the button cancels), otherwise the newest in-flight request.
    var inFlightRPCRequestID: Int? {
        withLock {
            if let call = _inFlight.filter({ $0.value == "tools/call" }).keys.max() { return call }
            return _inFlight.keys.max()
        }
    }

    /// Allocates the next request id and marks it in flight, so Cancel can name it
    /// even while other requests are running.
    private func beginRequestID(method: String) -> Int {
        withLock {
            let r = _nextRequestID
            _nextRequestID += 1
            _inFlight[r] = method
            return r
        }
    }

    private func endRequest(_ id: Int) { withLock { _inFlight[id] = nil } }

    init(config: ServerConfig, onEvent: @escaping (TranscriptEntry) -> Void) {
        self.config = config
        self.onEvent = onEvent
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpAdditionalHeaders = nil
        // URLSession's request timeout is an inactivity timeout — SSE keep-alive
        // comments therefore keep long calls alive naturally.
        cfg.timeoutIntervalForRequest = max(1, config.timeoutSeconds)
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Public API

    var normalizedURLString: String {
        var s = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        return s
    }

    /// Connect. For .auto: probe the 2026 stateless contract, fall back to a
    /// 2025 initialize handshake when the probe fails with an era hint.
    func connect(preferredEra: ProtocolEra) async throws -> ReadyInfo {
        lastInitResultJSON = nil
        switch preferredEra {
        case .auto:
            do {
                setMode(.stateless)
                connectedTools = try await refreshToolsThrowing()
                let info = ReadyInfo(mode: "stateless", protocolVersion: ProtocolEra.statelessVersion, sessionID: nil)
                record(.note, "mode: stateless (2026-07-28) — no handshake", nil)
                return info
            } catch let e as MCPError {
                // Spec § Backward Compatibility: probe first, but on 400/404/405 read
                // the *body*. A recognized modern JSON-RPC error means the server
                // speaks the per-request protocol — an initialize handshake is not the
                // fix, and silently downgrading hides the real problem (that was: the
                // client sent unnamespaced _meta keys and Auto called every modern
                // server a 2025 one).
                if let signal = e.modernProtocolSignal {
                    var note = "auto: JSON-RPC \(signal.code) \(signal.message)"
                    if !signal.supportedVersions.isEmpty {
                        note += " - supported: "
                            + signal.supportedVersions.joined(separator: ", ")
                    }
                    if !signal.requiredCapabilities.isEmpty {
                        note += " - needs clientCapabilities: "
                            + signal.requiredCapabilities.joined(separator: ", ")
                    }
                    record(.note, note, nil)
                    if let legacy = signal.legacyVersionToAdopt {
                        record(.note, "auto: handshake at \(legacy)", nil)
                        setMode(nil)
                        return try await handshake(preferredVersion: legacy)
                    }
                    setMode(nil)
                    throw e
                }
                guard e.looksLikeSessionEra else {
                    setMode(nil)
                    throw e
                }
                record(.note, "auto: not stateless (\(e.description)) — trying 2025 handshake", nil)
                setMode(nil)
                return try await handshake(preferredVersion: "2025-11-25")
            }
        case .v2026_07_28:
            setMode(.stateless)
            return ReadyInfo(mode: "stateless", protocolVersion: ProtocolEra.statelessVersion, sessionID: nil)
        default:
            setMode(nil)
            return try await handshake(preferredVersion: preferredEra.versionString ?? "2025-11-25")
        }
    }

    var lastInitResultJSON: JSONValue?
    /// `server/discover` result captured at connect time (stateless era):
    /// supportedVersions, capabilities, instructions, _meta.serverInfo.
    private(set) var discoverResult: JSONValue?
    /// serverInfo a stateless (2026) server publishes in a result's
    /// `_meta["io.modelcontextprotocol/serverInfo"]` (tools/list or
    /// server/discover) — the handshake-free counterpart of initialize's
    /// serverInfo. Read by the Server profile.
    private(set) var metaServerInfo: JSONValue?
    /// Tools fetched as a side effect of connect() (auto-mode probe); read once by the UI.
    private(set) var connectedTools: [Tool]?

    func listTools() async throws -> [Tool] {
        try await refreshToolsThrowing()
    }

    /// 2026 stateless: `server/discover` — the MANDATORY discovery RPC that
    /// returns supportedVersions, capabilities, instructions and
    /// _meta[io.modelcontextprotocol/serverInfo] in one request. The
    /// handshake-free counterpart of what `initialize` gave the session eras.
    /// Calling it is optional for clients, so callers must treat failure as
    /// "nothing announced", never as a connection error.
    @discardableResult
    func discover() async throws -> JSONValue {
        let outcome = try await perform(method: "server/discover", params: .object([:]))
        discoverResult = outcome.result
        if let si = outcome.result["_meta"]?["io.modelcontextprotocol/serverInfo"],
           si.object != nil {
            metaServerInfo = si
        }
        return outcome.result
    }

    func callTool(name: String, arguments: JSONValue,
                  onNotification: @escaping (String) -> Void) async throws -> CallResult {
        let started = Date()
        var finalArgs = arguments
        var extraHeaders: [String: String] = [:]

        // 2026 stateless: designated (x-mcp-header) parameters are mirrored into
        // Mcp-Param-* headers. Mirrored, not moved — the body keeps every argument.
        if let m = mode, case .stateless = m, let schema = toolSchemas[name] {
            let mirrored = Self.applyDesignatedHeaders(schema: schema, arguments: arguments)
            finalArgs = mirrored.arguments
            extraHeaders = mirrored.headers
            if !extraHeaders.isEmpty {
                record(.note, "x-mcp-header: "
                       + extraHeaders.sorted { $0.key < $1.key }
                            .map { "\($0.key)=\($0.value)" }
                            .joined(separator: " · "), nil)
            }
        }

        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": finalArgs,
        ])

        do {
            let outcome = try await perform(method: "tools/call", params: params, extraHeaders: extraHeaders,
                                            onNotification: { v in onNotification(Self.summarizeNotification(v)) })
            let isToolError = outcome.result["isError"]?.bool == true
            var notifications = outcome.notifications
            // An MRTR / unknown-result discriminator is not a normal answer — say so
            // right next to the call instead of letting it look like a plain success.
            // (The transcript entry comes from perform(), which flags resultType on
            // EVERY method's result, not just this one.)
            if let note = Self.resultTypeNote(outcome.result) {
                notifications.insert(note, at: 0)
            }
            return CallResult(
                toolName: name, date: started, duration: Date().timeIntervalSince(started),
                outcome: isToolError ? .toolError(result: outcome.result) : .success(result: outcome.result),
                rawText: outcome.rawText, notifications: notifications)
        } catch let e as MCPError {
            if case .rpc(let rpc) = e {
                return CallResult(toolName: name, date: started, duration: Date().timeIntervalSince(started),
                                  outcome: .rpcError(code: rpc.code, message: rpc.message, data: rpc.data),
                                  rawText: e.description, notifications: [])
            }
            return CallResult(toolName: name, date: started, duration: Date().timeIntervalSince(started),
                              outcome: .transportError(e.description), rawText: "", notifications: [])
        }
    }

    func terminateSession() async {
        guard let m = mode, case .session(let version, let sid?) = m,
              let url = URL(string: normalizedURLString) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = min(max(config.timeoutSeconds, 5), 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        for h in config.headers where !h.name.isEmpty { req.setValue(h.value, forHTTPHeaderField: h.name) }
        record(.note, "DELETE session → ending", nil)
        if let (_, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse {
            record(.note, "DELETE → HTTP \(http.statusCode)", nil)
        } else {
            record(.note, "DELETE failed (ignored)", nil)
        }
    }

    /// Legacy (2025-era) best-effort cancellation notice; the real cancel is task cancellation.
    func sendCancelNotification(rpcRequestID: Int) async {
        guard let m = mode, case .session = m else { return }
        _ = try? await perform(
            method: "notifications/cancelled",
            params: .object(["requestId": .int(rpcRequestID), "reason": .string("cancelled by Faceless MCP Client")]),
            isNotification: true)
    }

    // MARK: - Handshake (session era)

    private func handshake(preferredVersion: String) async throws -> ReadyInfo {
        // Clear any previous session id: if this initialize response omits the
        // header we must not keep sending a stale/expired one.
        lastSessionHeader = nil
        let params: JSONValue = .object([
            "protocolVersion": .string(preferredVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(config.clientName),
                "version": .string(clientVersion),
            ]),
        ])
        // The initialize request must NOT carry an MCP-Protocol-Version header.
        let outcome = try await perform(method: "initialize", params: params,
                                        sendProtocolVersionHeader: false, allowSessionRetry: false)
        let negotiated = outcome.result["protocolVersion"]?.string ?? preferredVersion
        lastInitResultJSON = outcome.result
        if negotiated == ProtocolEra.statelessVersion {
            setMode(.stateless)
            return ReadyInfo(mode: "stateless", protocolVersion: negotiated, sessionID: nil)
        }
        setMode(.session(version: negotiated, sessionID: lastSessionHeader))
        _ = try? await perform(method: "notifications/initialized", params: nil, isNotification: true)
        record(.note, "handshake ok — \(negotiated)" + (lastSessionHeader != nil ? " · session id received" : " · no session id"), nil)
        return ReadyInfo(mode: "session", protocolVersion: negotiated, sessionID: lastSessionHeader)
    }

    // MARK: - tools/list

    private func refreshToolsThrowing() async throws -> [Tool] {
        var parsed: [Tool] = []
        var cursor: String?
        var page = 0
        repeat {
            var params: JSONValue = .object([:])
            if let cursor { params["cursor"] = .string(cursor) }
            let outcome = try await perform(method: "tools/list", params: params)
            if case .array(let items)? = outcome.result["tools"] {
                parsed += items.compactMap { Tool.parse($0) }
            }
            if let si = outcome.result["_meta"]?["io.modelcontextprotocol/serverInfo"],
               si.object != nil {
                metaServerInfo = si
            }
            cursor = outcome.result["nextCursor"]?.string
            page += 1
        } while (cursor?.isEmpty == false) && page < 50

        // Announced icons are picked and decoded here — off the main actor, once
        // per tool, while this reply is still being processed — so that building
        // 46 rows costs a lookup each, not 92 base64 decodes per keystroke in the
        // filter field (see Tool.withResolvedIcons / Icons.swift).
        parsed = parsed.map { $0.withResolvedIcons() }

        // NOT uniqueKeysWithValues: that traps on duplicate keys, so a server listing
        // the same tool twice crashed the app. Last schema wins.
        setToolSchemas(Dictionary(parsed.compactMap { t in
            t.inputSchema.map { (t.name, $0) }
        }, uniquingKeysWith: { _, latest in latest }))

        for tool in parsed {
            for warning in Self.designatedHeaderWarnings(tool: tool) {
                record(.note, "x-mcp-header \(tool.name): \(warning)", nil)
            }
        }
        record(.note, "tools/list → \(parsed.count) tool(s)", nil)
        return parsed
    }

    // MARK: - Core request machinery

    private struct RPCOutcome {
        var result: JSONValue
        var rawText: String
        var notifications: [String]
    }

    @discardableResult
    private func perform(method: String,
                         params: JSONValue?,
                         isNotification: Bool = false,
                         extraHeaders: [String: String] = [:],
                         sendProtocolVersionHeader: Bool = true,
                         allowSessionRetry: Bool = true,
                         onNotification: ((JSONValue) -> Void)? = nil) async throws -> RPCOutcome {
        var params = params
        // A notification must never trigger the session re-handshake: it has no id to
        // retry, and doing so resurrected sessions the user had just cancelled.
        let allowSessionRetry = allowSessionRetry && !isNotification

        // ---- progress token ---------------------------------------------
        // Spec-conformant servers only emit notifications/progress when the
        // call advertises params._meta.progressToken — always advertise one
        // so the SSE progress path actually gets exercised.
        var progressToken: String?
        if method == "tools/call", !isNotification {
            let token = "dbg-" + UUID().uuidString
            progressToken = token
            var obj = params?.object ?? [:]
            var meta = obj["_meta"]?.object ?? [:]
            if meta["progressToken"] == nil {
                meta["progressToken"] = .string(token)
                obj["_meta"] = .object(meta)
                params = .object(obj)
            }
        }

        // ---- headers ----------------------------------------------------
        var headers: [String: String] = [
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
        ]
        for h in config.headers where !h.name.trimmingCharacters(in: .whitespaces).isEmpty {
            headers[h.name] = h.value
        }
        switch mode {
        case nil:
            break // initialize: no protocol/session headers yet
        case .stateless:
            headers["MCP-Protocol-Version"] = ProtocolEra.statelessVersion
            headers["Mcp-Method"] = method
            // Mcp-Name comes from params.name, or params.uri for resources/read.
            if Self.nameHeaderMethods.contains(method) {
                if let name = params?["name"]?.string {
                    headers["Mcp-Name"] = Self.encodeHeaderValue(name)
                } else if let uri = params?["uri"]?.string {
                    headers["Mcp-Name"] = Self.encodeHeaderValue(uri)
                }
            }
            // 2026: per-request metadata (requests only, not notifications). The keys
            // are spec-reserved and namespaced — bare `protocolVersion`/`clientInfo`
            // are not recognized, and a request missing protocolVersion or
            // clientCapabilities is rejected 400/-32602 (which Auto used to read as
            // "this server wants the 2025 handshake"). MCP-Protocol-Version must also
            // match io.modelcontextprotocol/protocolVersion or the server answers
            // 400/-32020 HeaderMismatch.
            if !isNotification {
                var obj = params?.object ?? [:]
                var meta = obj["_meta"]?.object ?? [:]
                meta["io.modelcontextprotocol/protocolVersion"] = .string(ProtocolEra.statelessVersion)
                meta["io.modelcontextprotocol/clientCapabilities"] = .object(clientCapabilities)
                if meta["io.modelcontextprotocol/clientInfo"] == nil {
                    meta["io.modelcontextprotocol/clientInfo"] = .object([
                        "name": .string(config.clientName),
                        "version": .string(clientVersion),
                    ])
                }
                obj["_meta"] = .object(meta)
                params = .object(obj)
            }
        case .session(let version, let sessionID):
            if sendProtocolVersionHeader { headers["MCP-Protocol-Version"] = version }
            if let sessionID { headers["Mcp-Session-Id"] = sessionID }
        }
        headers.merge(extraHeaders) { _, new in new }

        // ---- envelope ---------------------------------------------------
        var envelope: JSONValue = .object([:])
        envelope["jsonrpc"] = .string("2.0")
        let requestID: Int
        if isNotification {
            requestID = -1
        } else {
            requestID = beginRequestID(method: method)
            envelope["id"] = .int(requestID)
        }
        // Registered here rather than after the POST so every exit path — invalid URL,
        // connect failure, error status — releases the in-flight slot.
        defer { if requestID >= 0 { endRequest(requestID) } }
        envelope["method"] = .string(method)
        if let params { envelope["params"] = params }

        guard let url = URL(string: normalizedURLString) else {
            record(.error, "invalid URL: \(config.url)", nil)
            throw MCPError.invalidURL(config.url)
        }
        record(.request, "POST \(method)", requestDetail(url: url, headers: headers, body: envelope))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(5, config.timeoutSeconds)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = Data(envelope.compactString.utf8)

        // ---- execute ----------------------------------------------------
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error where Self.isCancellation(error) {
            // Cancelled before the response head arrived: URLSession reports -999,
            // not CancellationError. Without this the Cancel button produced a red
            // "Request failed" banner and a bogus "connection failed" log entry —
            // which is exactly the path the plain-JSON (non-SSE) tools take.
            throw CancellationError()
        } catch {
            record(.error, "POST \(method) — connection failed", describe(error))
            throw MCPError.transport(describe(error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transport("non-HTTP response")
        }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            lastSessionHeader = sid
        }

        // 202/204: accepted, no body (normal for notifications).
        if http.statusCode == 202 || http.statusCode == 204 {
            record(.response, "\(method) · HTTP \(http.statusCode) accepted", nil)
            if isNotification { return RPCOutcome(result: .null, rawText: "", notifications: []) }
            throw MCPError.streamEnded("HTTP \(http.statusCode) with no response body")
        }

        guard (200...299).contains(http.statusCode) else {
            let (bodyData, _) = await Self.drain(bytes)
            let bodyText = String(decoding: bodyData, as: UTF8.self)
            let rpc = (try? JSONDecoder().decode(JSONValue.self, from: bodyData))
                .flatMap { RPCIncoming.parse($0)?.error }
            record(.error, "\(method) · HTTP \(http.statusCode)", JSONValue.prettyText(from: bodyData))
            // Expired session → re-handshake once, then retry the original request.
            if http.statusCode == 404, allowSessionRetry, let m = mode, case .session(let version, let sid?) = m {
                _ = sid
                record(.note, "session expired (HTTP 404) — re-initializing", nil)
                setMode(nil)
                _ = try await handshake(preferredVersion: version)
                return try await perform(method: method, params: params, isNotification: isNotification,
                                         extraHeaders: extraHeaders,
                                         sendProtocolVersionHeader: sendProtocolVersionHeader,
                                         allowSessionRetry: false, onNotification: onNotification)
            }
            throw MCPError.http(status: http.statusCode, body: bodyText, rpc: rpc)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()

        // ---- SSE response stream ----------------------------------------
        if contentType.contains("text/event-stream") {
            do {
                let outcome = try await consumeSSE(bytes: bytes,
                                                   expectedIDValue: .int(requestID),
                                                   expectedProgressToken: progressToken,
                                                   onNotification: onNotification)
                let n = outcome.notifications.count
                record(.response,
                       "\(method) · HTTP 200 (event-stream)" + (n > 0 ? " · \(n) notification(s)" : ""),
                       JSONValue.prettyText(from: Data(outcome.rawText.utf8)))
                flagResultType(method: method, result: outcome.result, rawText: outcome.rawText)
                return outcome
            } catch {
                if !(error is CancellationError) {
                    record(.error, "\(method) · stream failed", describe(error))
                }
                throw error
            }
        }

        // ---- plain JSON response ----------------------------------------
        let (data, drainError) = await Self.drain(bytes)
        if let error = drainError, Self.isCancellation(error) { throw CancellationError() }
        let text = String(decoding: data, as: UTF8.self)
        record(.response,
               "\(method) · HTTP \(http.statusCode)"
                   + (drainError == nil ? "" : " · connection broke mid-body"),
               JSONValue.prettyText(from: data))
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let incoming = RPCIncoming.parse(value) else {
            // Name the real cause when the body was cut short — "unparseable response"
            // sent you hunting for a server bug that was really a dead connection.
            if let error = drainError {
                throw MCPError.transport("\(describe(error)) — body truncated at \(data.count) byte(s)")
            }
            throw MCPError.decoding(String(text.prefix(600)))
        }
        if !isNotification, let got = incoming.idValue, got != .int(requestID) {
            record(.note, "response id mismatch — sent \(requestID), received \(got.compactString) (accepting anyway)", nil)
        }
        if incoming.isServerRequest {
            record(.note, "server→client request “\(incoming.method ?? "?")” in plain response — rejecting", text)
            await rejectServerRequest(id: incoming.idValue)
            throw MCPError.streamEnded("expected a response, server sent a request instead")
        }
        if isNotification {
            return RPCOutcome(result: incoming.result ?? .null, rawText: text, notifications: [])
        }
        if let e = incoming.error { throw MCPError.rpc(e) }
        let outcome = RPCOutcome(result: incoming.result ?? .null, rawText: text, notifications: [])
        flagResultType(method: method, result: outcome.result, rawText: text)
        return outcome
    }

    // MARK: - SSE consumption

    private func consumeSSE(bytes: URLSession.AsyncBytes,
                            expectedIDValue: JSONValue,
                            expectedProgressToken: String?,
                            onNotification: ((JSONValue) -> Void)?) async throws -> RPCOutcome {
        var parser = SSEParser()
        var notes: [String] = []
        var finalResult: JSONValue?
        var finalRaw: String?
        var rpcError: RPCError?
        var streamError: String?

        func process(_ ev: SSEParser.Event) {
            if ev.type == "endpoint" {
                record(.note, "deprecated HTTP+SSE “endpoint” event: \(ev.data)", nil)
                return
            }
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(ev.data.utf8)),
                  let msg = RPCIncoming.parse(value) else {
                record(.note, "unparsed SSE data", String(ev.data.prefix(800)))
                return
            }
            if msg.isServerRequest {
                record(.note, "server→client request “\(msg.method ?? "?")” — replying method-not-found", ev.data)
                Task { [weak self] in await self?.rejectServerRequest(id: msg.idValue) }
                return
            }
            if msg.method != nil {
                // Ignore progress belonging to another request's token.
                if msg.method == "notifications/progress",
                   let expected = expectedProgressToken,
                   let token = msg.params?["progressToken"],
                   token.string != expected {
                    return
                }
                let s = Self.summarizeNotification(value)
                notes.append(s)
                onNotification?(value)
                return
            }
            let exact = msg.matches(expectedIDValue)
            // This is a debugger: the plain-JSON path already accepts a mismatched id
            // with a note, so do the same here. A server echoing our id 7 as "7" used
            // to end up as the misleading "stream ended before response".
            let lenient = !exact && msg.isResponse && msg.idValue != nil
                && (msg.result != nil || msg.error != nil)
            if exact || lenient {
                if lenient {
                    notes.append("response id \(msg.idValue?.compactString ?? "nil") ≠ sent "
                                 + "\(expectedIDValue.compactString) — accepted anyway")
                }
                if let e = msg.error { rpcError = e }
                else { finalResult = msg.result ?? .null; finalRaw = ev.data }
            } else {
                notes.append("unmatched response id \(msg.idValue?.compactString ?? "nil") — ignored")
            }
        }

        // Frame lines ourselves: URLSession's `bytes.lines` collapses the empty
        // lines that separate SSE events, merging multi-event streams into one
        // unparseable blob. Raw-byte framing keeps the blank-line boundaries.
        var lineBytes: [UInt8] = []
        lineBytes.reserveCapacity(16 * 1024)

        func feed(_ line: [UInt8]) -> Bool {
            var s = String(decoding: line, as: UTF8.self)
            if s.hasSuffix("\r") { s = String(s.dropLast()) }
            if let ev = parser.consume(s) { process(ev) }
            return finalResult == nil && rpcError == nil
        }

        var stop = false
        do {
            for try await b in bytes {
                if b == 0x0A { // \n — empty line below = SSE event boundary
                    stop = !feed(lineBytes)
                    lineBytes.removeAll(keepingCapacity: true)
                    if stop { break }
                } else if b != 0x0D {
                    lineBytes.append(b)
                }
            }
            if !stop, !lineBytes.isEmpty { _ = feed(lineBytes) }
            if finalResult == nil && rpcError == nil, let ev = parser.finish() {
                process(ev)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            streamError = describe(error)
        }

        if let e = rpcError { throw MCPError.rpc(e) }
        if let r = finalResult, let raw = finalRaw {
            return RPCOutcome(result: r, rawText: raw, notifications: notes)
        }
        var reason = streamError ?? "stream ended before response"
        if !notes.isEmpty { reason += " (\(notes.count) notification(s) received first)" }
        throw MCPError.streamEnded(reason)
    }

    private func rejectServerRequest(id: JSONValue?) async {
        var env: JSONValue = .object([:])
        env["jsonrpc"] = .string("2.0")
        env["id"] = id ?? .null
        env["error"] = .object([
            "code": .int(-32601),
            "message": .string("Faceless MCP Client does not handle server-initiated requests"),
        ])
        guard let url = URL(string: normalizedURLString) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for h in config.headers where !h.name.isEmpty { req.setValue(h.value, forHTTPHeaderField: h.name) }
        if let m = mode {
            req.setValue(m.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            if let sid = m.sessionID { req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id") }
        }
        req.httpBody = Data(env.compactString.utf8)
        _ = try? await session.data(for: req)
    }

    // MARK: - x-mcp-header mirroring (2026 stateless)

    /// Mirrors `x-mcp-header` designated parameters into `Mcp-Param-{Name}` headers.
    ///
    /// Mirroring only — the values **stay** in `arguments`. Servers MUST compare the
    /// header against the body and answer 400 / -32020 HeaderMismatch when they
    /// disagree, so deleting the argument (what this used to do) breaks every
    /// conformant server. An absent or `null` parameter gets **no** header; the
    /// invented `~` / `~~` / `~base64~` sentinels are not in the spec.
    static func applyDesignatedHeaders(schema: JSONValue, arguments: JSONValue)
        -> (arguments: JSONValue, headers: [String: String]) {
        guard let args = arguments.object,
              let props = schema["properties"]?.object else { return (arguments, [:]) }
        var headers: [String: String] = [:]
        for (key, prop) in props {
            guard let custom = prop["x-mcp-header"]?.string, !custom.isEmpty else { continue }
            // Only values actually present are mirrored; null means "no header".
            guard case .some(let value) = args[key], !value.isNull else { continue }
            guard let text = mirrorableText(for: value) else { continue }
            headers["Mcp-Param-" + custom] = encodeHeaderValue(text)
        }
        return (arguments, headers)
    }

    /// String form of a designated value: string as-is, integer decimal, boolean
    /// lowercase. Anything else (object, array, real, …) is outside the spec's
    /// mirroring rules — `designatedHeaderWarnings` has already flagged it.
    static func mirrorableText(for value: JSONValue) -> String? {
        switch value {
        case .string(let s): return s
        case .bool(let b):   return b ? "true" : "false"
        case .int(let i):    return String(i)
        case .double(let d) where d == d.rounded() && abs(d) < 9.2e18:
            return String(Int(d))          // servers that type an int as "number"
        default:             return nil
        }
    }

    /// RFC 9110-safe values travel plain; everything else uses the spec's Base64
    /// sentinel `=?base64?{Base64}?=` (standard alphabet, padding kept), including
    /// values that already look like the sentinel. An empty string is sentinel-encoded
    /// as well: URLSession would drop a header with an empty value, and `=?base64??=`
    /// decodes back to "" without ambiguity.
    static func encodeHeaderValue(_ value: String) -> String {
        let sentinel = value.hasPrefix("=?base64?") && value.hasSuffix("?=")
        if !sentinel, Self.isHeaderSafe(value) { return value }
        return "=?base64?" + Data(value.utf8).base64EncodedString() + "?="
    }

    /// Visible ASCII (0x21–0x7E) plus SP/HTAB, no leading or trailing whitespace.
    static func isHeaderSafe(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        guard let first = s.unicodeScalars.first, let last = s.unicodeScalars.last else { return false }
        if first.value == 0x20 || first.value == 0x09 || last.value == 0x20 || last.value == 0x09 {
            return false
        }
        return s.unicodeScalars.allSatisfy {
            ($0.value >= 0x21 && $0.value <= 0x7E) || $0.value == 0x20 || $0.value == 0x09
        }
    }

    /// tchar per RFC 9110 §5.6.2 — the syntax every `x-mcp-header` name must obey.
    static let httpTokenCharacters: Set<Character> =
        Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// Violations of the spec's `x-mcp-header` constraints. A conformant client must
    /// drop the whole tool from tools/list when these are non-empty; this is a
    /// debugger, so we keep the tool visible and log the reasons instead.
    static func designatedHeaderWarnings(tool: Tool) -> [String] {
        guard let props = tool.inputSchema?["properties"]?.object else { return [] }
        var warnings: [String] = []
        var seen: [String: String] = [:]          // lowercased annotation → property
        for (key, prop) in props.sorted(by: { $0.key < $1.key }) {
            guard let raw = prop["x-mcp-header"] else { continue }
            guard let value = raw.string else {
                warnings.append("“\(key)”: annotation is not a string"); continue
            }
            if value.isEmpty {
                warnings.append("“\(key)”: annotation is empty")
            }
            if value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                warnings.append("“\(key)”: annotation contains control characters")
            }
            if !value.allSatisfy(Self.httpTokenCharacters.contains) {
                warnings.append("“\(key)”: “\(value)” is not an HTTP field-name token")
            }
            if let other = seen[value.lowercased()] {
                warnings.append("“\(other)” and “\(key)” share “\(value)”")
            } else {
                seen[value.lowercased()] = key
            }
            if let type = prop["type"]?.string, !["string", "integer", "boolean"].contains(type) {
                warnings.append("“\(key)”: type “\(type)” cannot be designated (string/integer/boolean only)")
            }
        }
        return warnings
    }

    // MARK: - Misc helpers

    private func record(_ direction: TranscriptDirection, _ title: String, _ detail: String?) {
        onEvent(TranscriptEntry(date: Date(), direction: direction, title: title, detail: detail))
    }

    /// 2026's `resultType` discriminator applies to **any** request result, and
    /// anything but `complete` (MRTR's `input_required`, an extension type) means
    /// what came back is not the answer: a `tools/list` or `server/discover`
    /// carrying it must not masquerade as an empty list / bare profile. Flag it
    /// for every method; `callTool` additionally shows the note beside the call.
    private func flagResultType(method: String, result: JSONValue, rawText: String) {
        guard let note = Self.resultTypeNote(result) else { return }
        record(.note, "\(method) · " + note, rawText)
    }

    private func requestDetail(url: URL, headers: [String: String], body: JSONValue) -> String {
        var s = "POST \(url.absoluteString)\n\n"
        for k in headers.keys.sorted() {
            s += "\(k): \(Self.masked(name: k, value: headers[k] ?? ""))\n"
        }
        s += "\n" + body.prettyString
        return s
    }

    static func masked(name: String, value: String) -> String {
        let n = name.lowercased()
        if n.contains("authorization") || n.contains("token") || n.contains("key") || n.contains("secret") {
            return value.count > 8 ? String(value.prefix(8)) + "…" : "••••"
        }
        return value
    }

    static func summarizeNotification(_ v: JSONValue) -> String {
        let m = v["method"]?.string ?? "notification"
        if m == "notifications/progress", let p = v["params"] {
            var s = "progress"
            if let prog = p["progress"] { s += " " + prog.compactString }
            if let total = p["total"] { s += "/" + total.compactString }
            if let msg = p["message"]?.string { s += " — " + msg }
            return s
        }
        return m
    }

    /// Returns the body plus the error that ended the stream (nil when it ended
    /// cleanly). Swallowing that error made every broken stream look like bad JSON.
    private static func drain(_ bytes: URLSession.AsyncBytes) async -> (Data, Error?) {
        var data = Data()
        do {
            for try await b in bytes { data.append(b) }
            return (data, nil)
        } catch {
            return (data, error)
        }
    }

    /// URLSession reports task cancellation as URLError(.cancelled) / NSURLError -999
    /// rather than CancellationError. Normalize it so Cancel always reads as
    /// "Cancelled" and never as a transport failure.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let e = error as? URLError, e.code == .cancelled { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        return Task.isCancelled
    }

    /// 2026 results carry a `resultType` discriminator; anything but `complete`
    /// (MRTR's `input_required`, an extension type) is not a plain answer, so make it
    /// impossible to mistake one for a normal successful call.
    static func resultTypeNote(_ result: JSONValue) -> String? {
        guard let type = result["resultType"]?.string, !type.isEmpty, type != "complete" else { return nil }
        if type == "input_required" {
            return "resultType=input_required — server requests client input (MRTR, unhandled)"
        }
        return "resultType=\(type) — unrecognized"
    }
}
