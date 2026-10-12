import Foundation
import Observation

/// App-wide state: the list of servers, selection, persistence, sash positions.
@MainActor
@Observable
final class AppModel {
    var servers: [ServerModel] = []
    var selection: UUID?
    /// The output tab is app-wide, not per-server-view state: switching servers
    /// must keep Log/Server/Raw selected, never snap back to Result. The app
    /// opens on Server — until something has been called, that is the only tab
    /// with anything to show.
    var outputTab: OutputTab = .server
    var editorDraft: EditorDraft?
    /// Set when servers.json existed but could not be decoded. The unreadable file
    /// is quarantined on the spot: carrying on with an empty list would let the next
    /// save() overwrite a config we never managed to read.
    var loadFailure: String?
    /// Set only when an unreadable servers.json could not even be moved aside —
    /// writing then would be the data loss, so persistence stays off this session.
    private var refusesToSave = false

    struct EditorDraft: Identifiable {
        let configID: UUID
        var isNew: Bool
        var config: ServerConfig
        var id: UUID { configID }
    }

    /// Sash positions per server, both persisted in servers.json: the width of
    /// the tools pane (left of the output pane) and the tools pane's own vertical
    /// split (tool list above, argument editor below).
    private var splitWidths: [UUID: Double] = [:]
    private var toolsSplits: [UUID: Double] = [:]
    private var saveTask: Task<Void, Never>?

    init() {
        load()
        selection = servers.first?.id
    }

    var selected: ServerModel? {
        guard let selection else { return nil }
        return servers.first { $0.id == selection }
    }
    func model(for id: UUID) -> ServerModel? {
        servers.first { $0.id == id }
    }

    // MARK: - CRUD

    func beginAdd() {
        editorDraft = EditorDraft(configID: UUID(), isNew: true, config: ServerConfig())
    }

    func beginEdit(_ id: UUID) {
        guard let m = model(for: id) else { return }
        editorDraft = EditorDraft(configID: m.config.id, isNew: false, config: m.config)
    }

    /// New servers materialize only on Save; Cancel adds nothing.
    func applyEditor(_ config: ServerConfig) {
        if let m = model(for: config.id) {
            m.updateConfig(config)
        } else {
            servers.append(ServerModel(config: config))
            selection = config.id
        }
        editorDraft = nil
        save()
    }

    func duplicate(_ id: UUID) {
        guard let m = model(for: id) else { return }
        var c = m.config
        c.id = UUID()
        c.name += " (copy)"
        servers.append(ServerModel(config: c))
        selection = c.id
        save()
    }

    func remove(_ id: UUID) {
        if let m = model(for: id) {
            Task { await m.disconnect() }
        }
        servers.removeAll { $0.id == id }
        splitWidths[id] = nil
        toolsSplits[id] = nil
        // a pending measurement must not resurrect a deleted server's sashes
        pending[.toolsWidth(id)] = nil
        pending[.toolsSplit(id)] = nil
        if selection == id { selection = servers.first?.id }
        save()
    }

    func removeSelected() {
        if let id = selection { remove(id) }
    }

    /// Sidebar drag-and-drop reordering. Nothing is re-created: the same
    /// `ServerModel` instances move in place, so live connections, argument
    /// drafts and the selection all ride along untouched. The array order is
    /// what gets saved, so the arrangement is the same at the next launch.
    func moveServers(from source: IndexSet, to destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - Sash positions (persisted per server)

    /// Tools pane width; 400 until it has been measured once.
    func splitWidth(for id: UUID) -> Double { splitWidths[id] ?? 400 }

    /// Tools list / argument editor split as a fraction of the pane's height;
    /// nil means the user never moved it, and the view picks its own default.
    func toolsSplit(for id: UUID) -> Double? { toolsSplits[id] }

    func setSplitWidth(_ width: Double, for id: UUID) {
        let baseline = pending[.toolsWidth(id)] ?? splitWidth(for: id)
        guard width > 100, abs(width - baseline) >= 1 else { return }
        measure(.toolsWidth(id), width)
    }

    func setToolsSplit(_ fraction: Double, for id: UUID) {
        let value = min(max(fraction, 0.15), 0.85)   // the handle's own limits
        let baseline = pending[.toolsSplit(id)] ?? toolsSplits[id] ?? 0.5
        guard abs(value - baseline) >= 0.002 else { return }
        measure(.toolsSplit(id), value)
    }

    private enum Sash: Hashable {
        case toolsWidth(UUID)
        case toolsSplit(UUID)
    }

    /// A sash reports its position on every frame of a drag, and a write to
    /// observed state re-renders exactly the panes that are being dragged — the
    /// feedback loop that made window scaling stutter, and that can nudge a
    /// divider on its own, since `idealWidth` feeds back into the split. So the
    /// measurements are parked here, unobserved, while the dragging is going on
    /// and committed once it settles; the file write is debounced on top.
    @ObservationIgnored private var pending: [Sash: Double] = [:]
    @ObservationIgnored private var pendingTask: Task<Void, Never>?

    private func measure(_ sash: Sash, _ value: Double) {
        pending[sash] = value
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.commitPending()
        }
    }

    private func commitPending() {
        guard !pending.isEmpty else { return }
        for (sash, value) in pending {
            switch sash {
            case .toolsWidth(let id):  splitWidths[id] = value
            case .toolsSplit(let id):  toolsSplits[id] = value
            }
        }
        pending.removeAll()
        scheduleSave()
    }

    // MARK: - Persistence

    /// Every field optional on purpose: the synthesized decoder only uses
    /// `decodeIfPresent` for optionals, so a hand-edited file that omits `version`
    /// (or `servers`) decodes instead of throwing away the whole store.
    private struct Store: Codable {
        var version: Int? = nil
        var servers: [ServerConfig]? = nil
        var splitWidths: [String: Double]? = nil
        var toolsSplits: [String: Double]? = nil
    }

    /// The two sash maps travel as server-UUID keys; unparseable keys (a file
    /// edited by hand) are dropped, the rest of the file is kept.
    private static func uuidKeyed(_ map: [String: Double]?) -> [UUID: Double] {
        var out: [UUID: Double] = [:]
        for (key, value) in map ?? [:] {
            guard let id = UUID(uuidString: key) else { continue }
            out[id] = value
        }
        return out
    }

    private static func stringKeyed(_ map: [UUID: Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: map.map { ($0.uuidString, $1) })
    }

    private var storeURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let dir = base.appendingPathComponent("Faceless MCP Client", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("servers.json")
    }

    private func load() {
        let fm = FileManager.default
        guard let url = storeURL, fm.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let store = try JSONDecoder().decode(Store.self, from: data)
            servers = (store.servers ?? []).map { ServerModel(config: $0) }
            splitWidths = Self.uuidKeyed(store.splitWidths)
            toolsSplits = Self.uuidKeyed(store.toolsSplits)
            selection = servers.first?.id
        } catch {
            // Quarantine instead of ignoring. Previously a decode error left the app
            // with an empty list and no hint, and the first save() — e.g. after
            // adding one server — overwrote a config that had only been unreadable.
            // servers.json → servers.json.bad (string concat: appendingPathExtension
            // has its own ideas about components that already carry an extension).
            let bad = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + ".bad")
            try? fm.removeItem(at: bad)
            if (try? fm.moveItem(at: url, to: bad)) != nil {
                loadFailure = "servers.json unreadable - moved to \(bad.lastPathComponent)\n\n\(error)"
            } else {
                loadFailure = "servers.json unreadable and could not be moved aside - saving disabled\n\n\(error)"
                // Nothing was loaded and the file is still live: refuse to save over it.
                refusesToSave = true
            }
            selection = nil
        }
    }

    func save() {
        // A file we could not read and could not move aside must never be replaced
        // by whatever the UI happens to hold right now.
        guard !refusesToSave else { return }
        loadFailure = nil
        let store = Store(
            servers: servers.map { $0.config },
            splitWidths: Self.stringKeyed(splitWidths),
            toolsSplits: Self.stringKeyed(toolsSplits))
        guard let url = storeURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(store) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }
}
