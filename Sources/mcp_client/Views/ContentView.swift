import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
        } detail: {
            if let server = app.selected {
                DetailView(server: server)
                    .id(server.id)
            } else {
                ContentUnavailableView(
                    "No server selected",
                    systemImage: "network",
                    description: Text("Add an MCP server with the + button in the sidebar."))
            }
        }
        // No sidebar-hide feature exists. This line is not leftover code — it is
        // what removes the system's Hide-Sidebar toolbar button (and its focus
        // ring / title-reflow oddities). Delete it and that button returns.
        .toolbar(removing: .sidebarToggle)
    }
}

private struct SplitWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Right of the sidebar: tools pane | draggable divider | output pane.
struct DetailView: View {
    @Environment(AppModel.self) private var app
    @Bindable var server: ServerModel

    var body: some View {
        HSplitView {
            ToolsPane(server: server)
                .frame(minWidth: 300,
                       idealWidth: CGFloat(app.splitWidth(for: server.id)),
                       maxWidth: .infinity, maxHeight: .infinity)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: SplitWidthKey.self, value: proxy.size.width)
                })
            OutputPane(server: server)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onPreferenceChange(SplitWidthKey.self) { width in
            app.setSplitWidth(Double(width), for: server.id)
        }
        .navigationTitle(server.config.name)
        .navigationSubtitle(server.displayURL)
    }
}
