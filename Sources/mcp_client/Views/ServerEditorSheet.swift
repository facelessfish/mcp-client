import SwiftUI
import AppKit

struct ServerEditorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var config: ServerConfig
    @State private var timeoutText: String
    @FocusState private var nameFocused: Bool
    private let isNew: Bool

    init(draft: AppModel.EditorDraft) {
        _config = State(initialValue: draft.config)
        _timeoutText = State(initialValue: Self.trimmed(draft.config.timeoutSeconds))
        isNew = draft.isNew
    }

    /// Authorization is a separate option in this sheet, not a header row:
    /// this field is the only place the credential is read or written (it
    /// creates/removes the underlying `Authorization` entry as the text
    /// empties, and `visibleHeaders` keeps that entry out of the generic list
    /// below, so it never shows twice). The separation is UI only — it stays
    /// a stored header, so persistence, the wire path, and configs that
    /// gained the header by hand or by an older build all keep working: such
    /// an entry simply lands in this field.
    private var authorization: Binding<String> {
        Binding(
            get: {
                config.headers.first { $0.name.lowercased() == "authorization" }?.value ?? ""
            },
            set: { newValue in
                guard let idx = config.headers
                    .firstIndex(where: { $0.name.lowercased() == "authorization" })
                else {
                    if !newValue.isEmpty {
                        var h = HeaderEntry()
                        h.name = "Authorization"
                        h.value = newValue
                        config.headers.append(h)
                    }
                    return
                }
                if newValue.isEmpty {
                    config.headers.remove(at: idx)
                } else {
                    config.headers[idx].value = newValue
                }
            }
        )
    }

    /// The generic header rows: every header except the Authorization entry,
    /// which lives exclusively in the field above (name matched the same way
    /// the `authorization` binding matches it). Bindings address entries by
    /// id rather than by position, so editing or removing a row never races
    /// the filtering.
    private var visibleHeaders: [Binding<HeaderEntry>] {
        config.headers.compactMap { entry in
            guard entry.name.lowercased() != "authorization" else { return nil }
            let id = entry.id
            return Binding(
                get: { config.headers.first { $0.id == id } ?? entry },
                set: { newValue in
                    if let idx = config.headers.firstIndex(where: { $0.id == id }) {
                        config.headers[idx] = newValue
                    }
                })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "Add MCP Server" : "Edit MCP Server")
                .font(.headline)
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 6)

            Form {
                TextField("Name", text: $config.name)
                    .focused($nameFocused)
                TextField("URL", text: $config.url, prompt: Text("http://localhost:8000/mcp"))
                    .font(.system(.body, design: .monospaced))

                Picker("Protocol", selection: $config.era) {
                    ForEach(ProtocolEra.allCases) { era in
                        Text(era == .auto ? "Auto" : era.label).tag(era)
                    }
                }

                LabeledContent("Request timeout") {
                    HStack(spacing: 4) {
                        TextField("", text: $timeoutText)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("seconds")
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("Authorization", text: authorization,
                          prompt: Text("Bearer token"))
                    .font(.system(.body, design: .monospaced))

                Section("HTTP headers — sent on every request") {
                    // `visibleHeaders`, not `$config.headers`: the
                    // Authorization entry belongs to the field above and is
                    // never shown among the generic rows.
                    ForEach(visibleHeaders, id: \.wrappedValue.id) { $header in
                        HStack(spacing: 6) {
                            TextField("Name", text: $header.name)
                                .font(.system(.body, design: .monospaced))
                            TextField("Value", text: $header.value)
                                .font(.system(.body, design: .monospaced))
                            Button {
                                config.headers.removeAll { $0.id == header.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                    Button("Add header") {
                        config.headers.append(HeaderEntry())
                    }
                }

            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(config.name.trimmed.isEmpty || config.url.trimmed.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 580, height: 540)
        .onAppear {
            // Opening the editor used to focus the Name field with its whole
            // value selected — one stray keystroke replaced the server's name.
            // Nothing is focused on open: the user clicks (or tabs) into what
            // they want to edit, and a click places the caret without
            // selecting. Async because the sheet is not yet key inside
            // onAppear — the initial focus lands after this pass; both lines
            // are needed because the focus can be owned either by SwiftUI's
            // focus state or by AppKit's first responder.
            DispatchQueue.main.async {
                nameFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    private func save() {
        config.timeoutSeconds = Double(timeoutText) ?? 120
        app.applyEditor(config)
        dismiss()
    }

    private static func trimmed(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}
