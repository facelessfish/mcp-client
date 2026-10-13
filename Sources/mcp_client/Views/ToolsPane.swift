import SwiftUI

struct ToolsPane: View {
    @Bindable var server: ServerModel
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var filter = ""

    private var filteredTools: [Tool] {
        guard !filter.isEmpty else { return server.tools }
        return server.tools.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
                || $0.displayName.localizedCaseInsensitiveContains(filter)
                || ($0.description?.localizedCaseInsensitiveContains(filter) ?? false)
        }
    }

    /// List-row chips are limited to the hints that change what clicking a tool
    /// might do (read-only / destructive); the editor shows every announced one.
    private func rowHints(_ tool: Tool) -> [BehaviorHint] {
        tool.hints.filter { $0 == .readOnly || $0 == .destructive }
    }

    private var selectedTool: Tool? {
        guard let id = server.selectedToolID else { return nil }
        return server.tools.first { $0.name == id }
    }

    /// Does this server announce a showable icon on any of its tools? It
    /// decides the list's left edge: a server where every tool has an icon,
    /// and a server where none ever will, both render no reserved slots —
    /// but a server that mixes the two reserves one for every icon-less row,
    /// so the names still line up. Judged over all tools, not the filtered
    /// view, so typing in the filter never makes the rows' left edge jump.
    private var toolsShowIcons: Bool {
        server.tools.contains { tool in
            guard let icon = tool.icon(dark: scheme == .dark) else { return false }
            return icon.image != nil || icon.needsFetch
        }
    }

    /// The tools list / argument editor sash. While it is being dragged the live
    /// per-server value on the ServerModel drives it; AppModel keeps the
    /// persisted copy and commits it, debounced, once the drag settles — so the
    /// sash is where the user left it, also after a restart. DraggableVSplit only
    /// changes it on user drag — never automatically.
    private var splitFraction: Binding<Double> {
        Binding(
            get: { server.toolsSplitFraction ?? app.toolsSplit(for: server.config.id) ?? 0.5 },
            set: { fraction in
                server.toolsSplitFraction = fraction
                app.setToolsSplit(fraction, for: server.config.id)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if case .failed(let message) = server.status {
                FailureBanner(message: message)
            }
            if server.status.isConnected {
                filterField

                DraggableVSplit(fraction: splitFraction) {
                    // ---- top: tool list (scrolls within its half) ----
                    ScrollViewReader { proxy in
                        List(selection: $server.selectedToolID) {
                            ForEach(filteredTools) { tool in
                                HStack(spacing: 8) {
                                    // The announced icon, when there is one to
                                    // show — pixels were picked and decoded when
                                    // the tool arrived, so a row does no work for
                                    // them. No icon anywhere on this server: no
                                    // slot anywhere, names start at the leading
                                    // edge. Icons mixed with plain tools: an
                                    // empty `IconTile` holds the slot open, so
                                    // the rows still line up (see toolsShowIcons).
                                    if let icon = tool.icon(dark: scheme == .dark),
                                       icon.image != nil || icon.needsFetch {
                                        IconTile(ref: icon)
                                    } else if toolsShowIcons {
                                        IconTile(ref: nil)
                                    }
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 5) {
                                            Text(tool.displayName).lineLimit(1)
                                            ForEach(rowHints(tool)) { hint in
                                                AnnotationChip(hint: hint, compact: true)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        if let d = tool.description, !d.isEmpty {
                                            Text(d)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                                .tag(tool.name)
                                .id(tool.name)
                                .help(tool.name)
                            }
                        }
                        .overlay {
                            if filteredTools.isEmpty {
                                ContentUnavailableView(
                                    server.tools.isEmpty ? "No tools" : "No matches",
                                    systemImage: "hammer",
                                    description: Text(server.lastError ?? "The server returned no tools."))
                            }
                        }
                        .onChange(of: filter) { _, _ in
                            if let first = filteredTools.first {
                                proxy.scrollTo(first.name, anchor: .top)
                            }
                        }
                    }
                } bottom: {
                    // ---- bottom: tool editor ----
                    if let tool = selectedTool {
                        ToolEditor(server: server, tool: tool).id(tool.name)
                    }
                }
            } else {
                // Disconnected: deliberately empty — Connect lives in the
                // header. This Spacer keeps the header pinned to the top
                // instead of letting the VStack center it in the pane.
                Spacer(minLength: 0)
            }
        }
    }

    /// The filter as an ordinary rounded-border input — the same look as the
    /// form fields — with a clear button that appears when there is something
    /// to clear. The full-width hairlines that used to sandwich it are gone:
    /// they sat a few points off from the output pane's divider, and the
    /// misalignment was visible on every launch.
    private var filterField: some View {
        TextField("Filter tools", text: $filter)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .overlay(alignment: .trailing) {
                if !filter.isEmpty {
                    Button { filter = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                    .help("Clear filter")
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                Task { await server.toggleConnect() }
            } label: {
                Text(server.status.isConnected ? "Disconnect" : "Connect")
                    .frame(minWidth: 76)
            }
            .buttonStyle(.borderedProminent)
            .disabled(server.status == .connecting)

            Button {
                Task { await server.refreshTools() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload tools")
            .disabled(!server.status.isConnected)

            Spacer()

            if server.status == .connecting {
                ProgressView().controlSize(.small)
                Text("connecting…").font(.caption).foregroundStyle(.secondary)
            } else if let ready = server.ready, server.status.isConnected {
                StatusChip(ready: ready)
            }
        }
        .padding(8)
    }
}

/// Compact error strip shown under the header when the last connect failed —
/// keeps the raw failure visible without a full-pane placeholder.
private struct FailureBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
    }
}

struct StatusChip: View {
    let ready: ReadyInfo
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let pal = Catppuccin.palette(for: scheme)
        Text(label)
            .font(.caption.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(pal.green.opacity(0.15)))
            .foregroundStyle(pal.green)
            .help("protocol \(ready.protocolVersion) · \(ready.mode)")
    }

    private var label: String {
        var s = "\(ready.protocolVersion) · \(ready.mode)"
        if let sid = ready.sessionID { s += " · " + String(sid.prefix(6)) }
        return s
    }
}

// MARK: - Tool editor (dynamic form ⇄ raw JSON, M2)

struct ToolEditor: View {
    @Bindable var server: ServerModel
    let tool: Tool
    @Environment(\.colorScheme) private var scheme
    /// Raw JSON editor text — the wire truth on Call.
    @State private var text = ""
    /// Parsed top-level object backing the form fields.
    @State private var form: JSONValue = .object([:])
    /// Printed schema and annotations, formatted once when the tool is opened:
    /// this view re-renders on every keystroke in the argument editor, and
    /// re-printing a schema per keystroke is exactly the class of work this
    /// app was rebuilt to stop doing in a view body.
    @State private var schemaText = ""
    @State private var annotationsText = ""
    /// Whether the description is short enough to stay inline — the same rule
    /// `Prose` branches on, decided once when the tool opens, because this
    /// body re-runs on every keystroke and measures nothing. Long descriptions
    /// fold into a disclosure; short ones stay plain prose.
    @State private var descriptionFitsInline = true

    private var fields: [(key: String, prop: JSONValue, required: Bool)] {
        SchemaForm.properties(of: tool.inputSchema)
    }

    private var issue: String? {
        let t = text.trimmed
        if t.isEmpty { return nil }
        guard let data = t.data(using: .utf8),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return "Not valid JSON"
        }
        if v.object != nil || v.isNull { return nil }
        return "Arguments must be a JSON object"
    }

    /// Two-way sync: invalid JSON leaves the form at its last good state;
    /// form edits regenerate the JSON text wholesale.
    private func binding(for key: String) -> Binding<JSONValue?> {
        Binding(
            get: { form.object?[key] },
            set: { newValue in
                var obj = form.object ?? [:]
                if let newValue { obj[key] = newValue } else { obj[key] = nil }
                form = .object(obj)
                text = form.prettyString
            }
        )
    }

    private func syncFormFromText() {
        let t = text.trimmed
        if t.isEmpty { form = .object([:]); return }
        guard let data = t.data(using: .utf8),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data),
              v.object != nil else { return }
        if v != form { form = v }
    }

    /// Call entry point: button, ⌘↵ and Return inside any form field.
    private func submit() {
        guard server.status.isConnected, !server.isCalling, issue == nil else { return }
        server.lastArgsError = nil
        server.callTool(tool, argsText: text)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    // Icon at the head of the editor header, left-justified
                    // before the name — same resolved pixels as the list row,
                    // drawn larger. Rendered only when there is an icon: no
                    // announced icon (or an announced one with nothing
                    // renderable and nothing to fetch) puts no tile here and
                    // reserves no space, so the name starts at the left edge.
                    // Unlike the list, the editor never reserves an empty
                    // slot — it shows one tool at a time and has nothing to
                    // align against.
                    if let icon = tool.icon(dark: scheme == .dark),
                       icon.image != nil || icon.needsFetch {
                        IconTile(ref: icon, side: 28, cornerRadius: 6)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.displayName)
                            .font(.headline)
                            .textSelection(.enabled)
                        if tool.displayName != tool.name {
                            // The human title leads, the wire name stays visible
                            // and copyable underneath.
                            Text(tool.name)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if !tool.hints.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(tool.hints) { hint in
                            AnnotationChip(hint: hint)
                        }
                        Spacer(minLength: 0)
                    }
                }

                // The description reads the same whether it stands inline or is
                // folded away: the dress is asked of `Prose` itself
                // (`TextChrome.secondary` — the callout face in the secondary
                // colour), so the branch that renders through AppKit cannot
                // drift from the one that renders through SwiftUI. It used to:
                // past `Prose.inlineLimit` a description jumped to the label
                // colour at the prose size, because the surface it lands in is
                // dressed as a document.
                if let d = tool.description, !d.isEmpty {
                    if descriptionFitsInline {
                        Prose(d, chrome: .secondary)
                    } else {
                        // A tool that writes an essay used to push the argument
                        // form down behind a standing scroll box. Now it folds
                        // into the same kind of disclosure the JSON editor
                        // uses: one tappable line until asked, the bounded
                        // surface only once opened. Only the disclosure's own
                        // title is styled like a disclosure; the text it opens
                        // is the description, in its usual dress.
                        TappableDisclosure(title: "description") {
                            Prose(d, chrome: .secondary)
                        }
                        .font(.callout)
                    }
                }

                // ---- one rounded card (the Server profile's grouping shape)
                // around the form fields and the call row: everything that acts
                // on these arguments belongs together. With no fields the card
                // still wraps the call row, so no-argument tools keep the same
                // layout. ----
                CardBox {
                    VStack(alignment: .leading, spacing: 8) {
                        if !fields.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(fields, id: \.key) { f in
                                    formRow(f.key, f.prop, required: f.required)
                                }
                            }
                        }

                        // ---- call row: bottom of the card. Reset lives here
                        // too, left-justified opposite the call button;
                        // everything about the call itself stays at the
                        // button's side: progress + spinner + Cancel while a
                        // call is in flight, the last duration when it is not.
                        HStack(spacing: 8) {
                            Button("Reset") {
                                text = SchemaExample.argumentsJSON(from: tool.inputSchema)
                            }
                            .buttonStyle(.link)
                            .help("Regenerate the JSON editor from the input schema")

                            Spacer(minLength: 8)
                            if server.isCalling {
                                if let progress = server.callProgress {
                                    Text(progress)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: 240, alignment: .trailing)
                                }
                                ProgressView().controlSize(.small)
                                Button("Cancel", role: .destructive) { server.cancelCall() }
                            } else if let result = server.lastResult, result.toolName == tool.name {
                                Text("\(Int(result.duration * 1000)) ms")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Button(action: submit) {
                                Text(server.isCalling ? "Calling…" : "Call Tool")
                                    .frame(minWidth: 84)
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!server.status.isConnected || server.isCalling || issue != nil)
                        }
                    }
                }

                // The raw argument editor opens and closes like the two
                // disclosures below it and starts closed: the form and the
                // call row are the point of this pane; the JSON is the
                // escape hatch. The two-way form ⇄ JSON sync keeps working
                // while it is closed — the text it edits is state of this
                // view, not of the TextEditor inside.
                TappableDisclosure(title: "Arguments (JSON)") {
                    TextEditor(text: $text)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 110, maxHeight: 220)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(issue == nil ? Color.secondary.opacity(0.3) : Color.red.opacity(0.7)))
                }
                .font(.callout)

                // Validity complaints stay outside the group, always visible:
                // they explain a disabled Call button even while the editor
                // they refer to is closed.
                if let issue {
                    Text(issue).font(.caption).foregroundStyle(.red)
                }
                if let argsError = server.lastArgsError {
                    Text(argsError).font(.caption).foregroundStyle(.red)
                }

                TappableDisclosure(title: "input schema") {
                    TextSurface(text: schemaText, height: .fixed(150))
                }
                .font(.callout)

                if tool.annotations != nil {
                    // The raw ToolAnnotations object — what the server actually
                    // asserted, including the hints we deliberately do not turn
                    // into chips (false values, unknown keys).
                    TappableDisclosure(title: "annotations") {
                        TextSurface(text: annotationsText, height: .fixed(120))
                    }
                    .font(.callout)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            text = server.argsDrafts[tool.name]
                ?? SchemaExample.argumentsJSON(from: tool.inputSchema)
            syncFormFromText()
            // Printed once per tool, for the two disclosures. A tool is opened
            // rarely; this view's body is not.
            schemaText = (tool.inputSchema ?? .object([:])).prettyString
            annotationsText = (tool.annotations ?? .object([:])).prettyString
            descriptionFitsInline = Prose.fitsInline(tool.description ?? "")
        }
        .onChange(of: text) { _, newValue in
            server.argsDrafts[tool.name] = newValue
            syncFormFromText()
        }
    }

    // MARK: form rows

    private func formRow(_ key: String, _ prop: JSONValue, required: Bool) -> some View {
        HStack(spacing: 8) {
            Text(key + (required ? " *" : ""))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(required ? Color.primary : Color.secondary)
                .frame(width: 110, alignment: .trailing)
                .lineLimit(1)
            control(for: key, prop: prop)
        }
        .help([key, prop["description"]?.string ?? "", SchemaForm.typeLabel(prop)]
            .filter { !$0.isEmpty }
            .joined(separator: " — "))
    }

    @ViewBuilder
    private func control(for key: String, prop: JSONValue) -> some View {
        let value = binding(for: key)
        switch SchemaForm.kind(for: prop) {
        case .text:                      StringField(value: value, onSubmit: submit)
        case .integer:                   NumberField(integer: true, value: value, onSubmit: submit)
        case .number:                    NumberField(integer: false, value: value, onSubmit: submit)
        case .boolean:                   BoolField(value: value)
        case .enumeration(let options):  EnumField(value: value, options: options)
        case .json:                      JSONValueField(value: value, onSubmit: submit)
        }
    }
}

/// Tool-annotation behavior chip — a capsule for one hint the server explicitly
/// announced (`Tool.hints`). Colored by meaning: read-only safe-green,
/// destructive red, the informational ones calm blue/peach; the tooltip carries
/// the wire key and its spec meaning (annotations describe server *claims*,
/// not guarantees — the tooltip says so by naming the hint).
struct AnnotationChip: View {
    let hint: BehaviorHint
    /// Compact variant for list rows.
    var compact = false
    @Environment(\.colorScheme) private var scheme

    private var color: Color {
        let pal = Catppuccin.palette(for: scheme)
        switch hint {
        case .readOnly:    return pal.green
        case .destructive: return pal.red
        case .idempotent:  return pal.blue
        case .openWorld:   return pal.peach
        }
    }

    var body: some View {
        Text(hint.label)
            .font(.system(size: compact ? 9 : 10, design: .monospaced))
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 0.5 : 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
            .help(hint.explanation)
    }
}
