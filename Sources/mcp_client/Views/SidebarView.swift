import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    /// Initial focus lives here so first responder lands on the list itself —
    /// arrow-key navigation works immediately and no control in another pane
    /// grabs the focus ring at launch.
    @FocusState private var listFocused: Bool

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            List(selection: $app.selection) {
                ForEach(app.servers) { server in
                    ServerRow(server: server)
                        .tag(server.id)
                        .contextMenu {
                            Button("Edit…") { app.beginEdit(server.id) }
                            Button("Duplicate") { app.duplicate(server.id) }
                            Divider()
                            Button("Delete", role: .destructive) { app.remove(server.id) }
                        }
                }
                // Drag a row onto another to reorder the list. The on-screen
                // order is the saved order: servers.json stores its `servers`
                // array exactly as the sidebar shows it, so the arrangement
                // survives restarts.
                .onMove { indices, destination in
                    app.moveServers(from: indices, to: destination)
                }
            }
            .focused($listFocused)
            .onAppear { listFocused = true }
            .overlay {
                if app.servers.isEmpty {
                    if let failure = app.loadFailure {
                        ContentUnavailableView {
                            Label("servers.json unreadable", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(failure)
                        }
                    } else {
                        ContentUnavailableView("No servers", systemImage: "plus.rectangle",
                                               description: Text("Click + below to add one."))
                    }
                }
            }

            Divider()

            // ---- bottom action bar: add / remove on the left, edit on the right ----
            HStack(spacing: 10) {
                Button {
                    app.beginAdd()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add server (⌘N)")

                Button {
                    app.removeSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(app.selection == nil)
                .help("Remove selected server")

                Spacer()

                Button {
                    if let id = app.selection { app.beginEdit(id) }
                } label: {
                    Image(systemName: "pencil")
                }
                .disabled(app.selection == nil)
                .help("Edit selected server")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        .sheet(item: $app.editorDraft) { draft in
            ServerEditorSheet(draft: draft)
        }
    }
}

struct ServerRow: View {
    let server: ServerModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.config.name).lineLimit(1)
                Text(server.displayURL)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var dotColor: Color {
        switch server.status {
        case .ready:        return .green
        case .connecting:   return .yellow
        case .failed:       return .red
        case .disconnected: return Color.secondary.opacity(0.6)
        }
    }
}
