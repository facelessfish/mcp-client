import SwiftUI
import AppKit

@main
struct MCPClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup("Faceless MCP Client") {
            ContentView()
                .environment(app)
                .frame(minWidth: 1100, minHeight: 640)
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            // Our About panel, fed from AppInfo — the one place the version and
            // the repository URL exist. The stock item can only show what the
            // bundle's Info.plist says, which under `swift run` is nothing.
            CommandGroup(replacing: .appInfo) {
                Button("About Faceless MCP Client") { AboutPanel.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Server…") { app.beginAdd() }
                    .keyboardShortcut("n")
            }
            // Find, for whichever text surface should answer — the Raw tab
            // and the Result document, which mark themselves primary; plus
            // any surface the user focused (a disclosure's payload, say).
            // The routing is deliberate, not responder-chain luck: see
            // `TextFindRouter` (TextSurface.swift). Where nothing searchable
            // is on screen — the Server and Log tabs — the menu item simply
            // does nothing.
            CommandGroup(after: .textEditing) {
                Button("Find in Text…") { TextSurface.showFind() }
                    .keyboardShortcut("f")
            }
            // (⌘, / "Edit Server…" intentionally not overridden — the default
            // SwiftUI Settings item is only shown when a Settings scene exists,
            // which this app does not use.)
        }
    }
}

/// The standard About panel, fed from AppInfo so the version and the repo URL
/// live in exactly one place. The credits block is rendered by AppKit and its
/// links are clickable, so the repository is one click from the panel.
enum AboutPanel {
    static func show() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationVersion: AppInfo.version,
        ]
        if let credits { options[.credits] = credits }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static let credits: NSAttributedString? = {
        let html = """
        <body>
          <p style="text-align:center">A debugger for MCP servers over HTTP:<br>
          servers, tools, calls — and the raw wire.</p>
          <p style="text-align:center">
            <a href="\(AppInfo.repoURL)">\(AppInfo.repoURL)</a>
          </p>
          <p style="text-align:center;font-size:small">BSD-2-Clause licensed</p>
        </body>
        """
        return try? NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // A one-window debug tool: macOS window tabbing is meaningless here,
        // and it fills the View menu with "Show Tab Bar" / "Show All Tabs"
        // items that can only confuse. Turning it off before any window
        // exists removes the menu items and the tab picker entirely.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Makes the unbundled `swift run` binary behave like a real app
        // (dock icon + foreground focus).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
