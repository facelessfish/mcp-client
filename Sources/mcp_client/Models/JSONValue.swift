import Foundation

/// Minimal, lossless JSON model used for every MCP payload (schemas, arguments,
/// results) so that nothing a server sends can be silently dropped.
indirect enum JSONValue: Codable, Equatable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:            try c.encodeNil()
        case .bool(let v):     try c.encode(v)
        case .int(let v):      try c.encode(v)
        case .double(let v):   try c.encode(v)
        case .string(let v):   try c.encode(v)
        case .array(let v):    try c.encode(v)
        case .object(let v):   try c.encode(v)
        }
    }
}

// MARK: - Accessors

extension JSONValue {
    var object: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
    var array: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }
    var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    var bool: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
    var int: Int? {
        switch self {
        case .int(let v):    return v
        case .double(let v): return v.rounded() == v ? Int(v) : nil
        default:             return nil
        }
    }
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    subscript(key: String) -> JSONValue? {
        get {
            if case .object(let o) = self { return o[key] }
            return nil
        }
        set {
            if case .object(var o) = self {
                o[key] = newValue
                self = .object(o)
            }
        }
    }
}

// MARK: - Printing (deterministic: sorted keys, stable diffs)

extension JSONValue {
    var compactString: String {
        var out = ""
        write(into: &out, indent: nil)
        return out
    }

    var prettyString: String {
        var out = ""
        write(into: &out, indent: 0)
        return out
    }

    private func write(into out: inout String, indent: Int?) {
        func newline(_ level: Int?) -> String {
            guard let level else { return "" }
            return "\n" + String(repeating: "  ", count: level)
        }
        switch self {
        case .null:
            out += "null"
        case .bool(let v):
            out += v ? "true" : "false"
        case .int(let v):
            out += String(v)
        case .double(let v):
            if v == v.rounded(), abs(v) < 1e15 {
                out += String(format: "%.1f", v)
            } else {
                out += String(v)
            }
        case .string(let v):
            out += Self.quote(v)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                out += newline(indent.map { $0 + 1 })
                item.write(into: &out, indent: indent.map { $0 + 1 })
                if i < items.count - 1 { out += "," }
            }
            out += newline(indent) + "]"
        case .object(let dict):
            if dict.isEmpty { out += "{}"; return }
            out += "{"
            let keys = dict.keys.sorted()
            for (i, key) in keys.enumerated() {
                // The value of a key is one level deeper than the key itself —
                // which is what the array case below already does. Passing the
                // parent's level here printed every nested object flush with
                // its parent: the structure was there, the indentation wasn't.
                let inner = indent.map { $0 + 1 }
                out += newline(inner)
                out += Self.quote(key)
                out += ":"
                if indent != nil { out += " " }
                dict[key]!.write(into: &out, indent: inner)
                if i < keys.count - 1 { out += "," }
            }
            out += newline(indent) + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var r = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            default:
                if ch.value < 0x20 {
                    r += String(format: "\\u%04x", ch.value)
                } else {
                    r.unicodeScalars.append(ch)
                }
            }
        }
        return r + "\""
    }

    /// Pretty-print raw response bytes for the transcript; falls back to the
    /// raw text if it is not JSON. Whole, always: the Log is where a tool name
    /// from the middle of a megabyte tools/list has to be findable, so no
    /// body is ever truncated. (The old 200 KB cut here was what made
    /// late-listed tools invisible to a Log search.)
    static func prettyText(from data: Data) -> String {
        if let v = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return v.prettyString
        }
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? "(empty body)" : text
    }
}
