import SwiftUI

// MARK: - Dynamic argument form (M2)
//
// Form fields are generated from the tool's inputSchema (top-level object
// properties) and kept in two-way sync with the raw JSON editor:
//  - a form edit rewrites the JSON text (all keys, including non-schema ones,
//    survive because the form state is the parsed object itself);
//  - a *valid* JSON edit re-parses into the form state (fields refresh);
//  - on Call, the JSON text wins (arguments are parsed from the editor).
//
// Widgets keep their own transient editing text so half-typed numbers ("1.",
// "-") and broken nested JSON aren't reverted mid-keystroke; they only push
// parseable values into the shared model. Pressing Return in a field calls
// the tool via the onSubmit callback.

enum FormKind {
    case text, integer, number, boolean, enumeration([JSONValue]), json
}

enum SchemaForm {
    static func kind(for prop: JSONValue) -> FormKind {
        if let values = prop["enum"]?.array, !values.isEmpty { return .enumeration(values) }
        switch prop["type"]?.string {
        case "string":  return .text
        case "integer": return .integer
        case "number":  return .number
        case "boolean": return .boolean
        default:        return .json   // object / array / anyOf / $ref / unknown
        }
    }

    /// Top-level properties in display order: required first, then optional,
    /// each group alphabetical.
    static func properties(of schema: JSONValue?) -> [(key: String, prop: JSONValue, required: Bool)] {
        guard let props = schema?["properties"]?.object else { return [] }
        let required = schema?["required"]?.array?.compactMap(\.string) ?? []
        func sortKey(_ k: String) -> (Int, String) { (required.contains(k) ? 0 : 1, k) }
        return props.keys.sorted { sortKey($0) < sortKey($1) }.map { k in
            (k, props[k] ?? .null, required.contains(k))
        }
    }

    static func typeLabel(_ prop: JSONValue) -> String {
        if prop["enum"]?.array != nil { return "enum" }
        return prop["type"]?.string ?? "any"
    }
}

// MARK: - Field widgets

struct StringField: View {
    @Binding var value: JSONValue?
    var onSubmit: (() -> Void)?

    var body: some View {
        TextField("", text: Binding(
            get: {
                guard let value, !value.isNull else { return "" }
                return value.string ?? value.compactString
            },
            set: { value = .string($0) }
        ))
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12, design: .monospaced))
        .onSubmit { onSubmit?() }
    }
}

/// Int/Double field. Local editing text so invalid intermediates stay on screen
/// un-parsed; the model only sees complete numbers, and an empty field removes
/// the key. External model changes re-canonicalize the text unless the current
/// text already represents that value.
struct NumberField: View {
    let integer: Bool
    @Binding var value: JSONValue?
    var onSubmit: (() -> Void)?
    @State private var text = ""

    private static func display(_ v: JSONValue?) -> String {
        guard let v, !v.isNull else { return "" }
        switch v {
        case .int(let i):      return String(i)
        case .double(let d):   return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .string(let s):   return s
        default:               return v.compactString
        }
    }

    private static func parse(_ s: String, integer: Bool) -> JSONValue? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        if integer, let i = Int(t) { return .int(i) }
        if let d = Double(t) {
            if integer {
                if d == d.rounded(), d.magnitude < 9.2e18 { return .int(Int(d)) }
                return nil // half-typed float into an integer field: not yet valid
            }
            return .double(d)
        }
        return nil
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .onAppear { text = Self.display(value) }
            .onChange(of: text) { _, new in
                if new.trimmingCharacters(in: .whitespaces).isEmpty { value = nil; return }
                if let v = Self.parse(new, integer: integer) { value = v }
            }
            .onChange(of: value) { _, v in
                if Self.parse(text, integer: integer) != v { text = Self.display(v) }
            }
            .onSubmit { onSubmit?() }
    }
}

struct BoolField: View {
    @Binding var value: JSONValue?
    var body: some View {
        Toggle("", isOn: Binding(
            get: { value?.bool ?? false },
            set: { value = .bool($0) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

struct EnumField: View {
    @Binding var value: JSONValue?
    let options: [JSONValue]

    var body: some View {
        Picker("", selection: $value) {
            Text("(unset)").tag(Optional<JSONValue>.none)
            ForEach(options, id: \.self) { opt in
                Text(opt.string ?? opt.compactString).tag(Optional(opt))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 220, alignment: .leading)
    }
}

/// Nested object / array (and anything exotic): a compact-JSON single-line editor.
struct JSONValueField: View {
    @Binding var value: JSONValue?
    var onSubmit: (() -> Void)?
    @State private var text = ""
    @State private var invalid = false

    private static func decode(_ s: String) -> JSONValue? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let d = t.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: d)
    }

    var body: some View {
        TextField("[…] / {…}", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(invalid ? Color.red.opacity(0.7) : Color.clear, lineWidth: 1))
            .onAppear { text = value?.compactString ?? "" }
            .onChange(of: text) { _, new in
                let t = new.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { invalid = false; value = nil; return }
                if let v = Self.decode(t) { invalid = false; value = v }
                else { invalid = true }
            }
            .onChange(of: value) { _, v in
                // don't overwrite while the field text already matches the model
                if Self.decode(text) != v { text = v?.compactString ?? "" }
            }
            .onSubmit { onSubmit?() }
    }
}
