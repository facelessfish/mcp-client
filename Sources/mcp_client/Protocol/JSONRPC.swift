import Foundation

/// Lenient JSON-RPC 2.0 incoming-message model: every field optional so that
/// malformed / partial server messages surface in the transcript instead of
/// throwing during decoding.
struct RPCIncoming {
    var idValue: JSONValue?
    var method: String?
    var params: JSONValue?
    var result: JSONValue?
    var error: RPCError?

    var isServerRequest: Bool { method != nil && idValue != nil }
    var isResponse: Bool { method == nil }

    /// Compare against the id we actually sent. Any JSON type — the spec
    /// allows string request ids; servers must echo the sent id verbatim.
    func matches(_ sent: JSONValue) -> Bool {
        guard let idValue else { return false }
        return idValue == sent
    }

    static func parse(_ v: JSONValue) -> RPCIncoming? {
        guard v.object != nil else { return nil }
        return RPCIncoming(
            idValue: v["id"],
            method: v["method"]?.string,
            params: v["params"],
            result: v["result"],
            error: RPCError.from(v["error"])
        )
    }
}

struct RPCError: Error, Codable, CustomStringConvertible {
    var code: Int
    var message: String
    var data: JSONValue?

    static func from(_ v: JSONValue?) -> RPCError? {
        guard let o = v?.object,
              let code = o["code"]?.int,
              let message = o["message"]?.string
        else { return nil }
        return RPCError(code: code, message: message, data: o["data"])
    }

    var description: String {
        var s = "JSON-RPC error \(code): \(message)"
        if let data, !data.isNull { s += " · \(data.compactString)" }
        return s
    }
}

// MARK: - SSE line parser

struct SSEParser {
    struct Event {
        var type: String
        var data: String
        var id: String?
    }

    private var eventType = "message"
    private var dataLines: [String] = []
    private var eventID: String?

    /// Feed one line (without newline). Returns an event when a blank line dispatches it.
    mutating func consume(_ line: String) -> Event? {
        if line.isEmpty { return finish() }
        if line.hasPrefix(":") { return nil } // comment / keep-alive ping
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "event": eventType = value
        case "data":  dataLines.append(value)
        case "id":    eventID = value
        default:      break
        }
        return nil
    }

    /// Flush any pending event (stream ended without trailing blank line).
    mutating func finish() -> Event? {
        defer { eventType = "message"; dataLines = []; eventID = nil }
        guard !dataLines.isEmpty else { return nil }
        return Event(
            type: eventType.isEmpty ? "message" : eventType,
            data: dataLines.joined(separator: "\n"),
            id: eventID
        )
    }
}
