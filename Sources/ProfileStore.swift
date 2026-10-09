import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var claude: ClaudeInstall?
    @Published private(set) var running: [UUID: pid_t] = [:]
    @Published private(set) var busy: [UUID: String] = [:]
    @Published var errorMessage: String?
    @Published var importDismissed: Bool {
        didSet { UserDefaults.standard.set(importDismissed, forKey: "importDismissed") }
    }

    private var claudePathOverride: String? {
        get { UserDefaults.standard.string(forKey: "claudePathOverride") }
        set { UserDefaults.standard.set(newValue, forKey: "claudePathOverride") }
    }
    private var timer: Timer?

    init() {
        importDismissed = UserDefaults.standard.bool(forKey: "importDismissed")
        let migrated = Self.migrateFromSwitchboard()
        load()
        if migrated {
            // Old launchers point at the old data path; flag them all for a rebuild.
            for i in profiles.indices { profiles[i].builtFromPath = nil }
            save()
        }
        refreshClaude()
        refreshRunning()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRunning()
                self?.refreshClaude()
            }
        }
    }

    // MARK: Derived state

    var canImport: Bool {
        !importDismissed && FileManager.default.fileExists(atPath: Paths.defaultClaudeData.path)
    }

    func needsRebuild(_ p: Profile) -> Bool {
        guard let claude, busy[p.id] == nil else { return false }
        if !FileManager.default.fileExists(atPath: p.launcherURL.path) { return true }
        if p.builtFromPath != claude.url.path { return true }
        return p.mode == .standalone && p.builtVersion != claude.version
    }

    var anyNeedsRebuild: Bool { profiles.contains { needsRebuild($0) } }

    func isNameTaken(_ name: String) -> Bool {
        let key = Paths.safeFileName(name).lowercased()
        return profiles.contains { Paths.safeFileName($0.name).lowercased() == key }
    }

    // MARK: Persistence

    /// Moves data from the app's earlier name ("Switchboard") if present.
    private static func migrateFromSwitchboard() -> Bool {
        let fm = FileManager.default
        let old = Paths.home.appendingPathComponent("Library/Application Support/Switchboard", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: Paths.support.path) else { return false }
        do {
            try fm.moveItem(at: old, to: Paths.support)
        } catch {
            return false
        }
        // Profile data paths changed, so the old launchers are now broken; remove them (a rebuild recreates them).
        if let items = try? fm.contentsOfDirectory(at: Paths.launchers, includingPropertiesForKeys: nil) {
            for app in items where app.pathExtension == "app" {
                let info = try? Plist.read(app.appendingPathComponent("Contents/Info.plist"))
                if info?["SwitchboardProfileID"] != nil { try? fm.removeItem(at: app) }
            }
        }
        return true
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.store) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        profiles = (try? dec.decode([Profile].self, from: data)) ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(profiles).write(to: Paths.store, options: .atomic)
        } catch {
            errorMessage = "Couldn't save profiles: \(error.localizedDescription)"
        }
    }

    private func update(_ id: UUID, _ change: (inout Profile) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&profiles[i])
        save()
    }

    // MARK: Claude install

    func refreshClaude() {
        let found = ClaudeInstall.locate(override: claudePathOverride)
        if found != claude { claude = found }
    }

    func chooseClaude() {
        let panel = NSOpenPanel()
        panel.title = "Choose Claude.app"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ClaudeInstall(url: url) != nil else {
            errorMessage = "That doesn't look like a usable Claude Desktop app."
            return
        }
        claudePathOverride = url.path
        refreshClaude()
    }

    // MARK: Running instances

    func refreshRunning() {
        guard let r = try? Shell.exec("/bin/ps", ["-axww", "-o", "pid=,command="]), r.status == 0 else { return }
        let lines = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n")
        var found: [UUID: pid_t] = [:]
        for line in lines {
            let trimmed = line.drop(while: { $0 == " " })
            guard let space = trimmed.firstIndex(of: " "), let pid = pid_t(trimmed[..<space]) else { continue }
            let command = trimmed[space...]
            // Skip Chromium child processes (renderer, GPU, utility…); we want the main process.
            if command.contains("--type=") { continue }
            for p in profiles where found[p.id] == nil {
                if command.contains("--user-data-dir=\(p.dataURL.path)") && !command.contains("/usr/bin/open") {
                    found[p.id] = pid
                }
            }
        }
        if found != running { running = found }
    }

    // MARK: Actions

    func create(name: String, colorHex: String, mode: LaunchMode, importDefault: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Paths.safeFileName(trimmed).isEmpty else { return }
        guard !isNameTaken(trimmed) else {
            errorMessage = "You already have a profile called “\(trimmed)”."
            return
        }
        if importDefault && isOfficialClaudeRunning() {
            errorMessage = "Quit Claude Desktop first so its data can be copied safely, then try the import again."
            return
        }
        let profile = Profile(name: trimmed, colorHex: colorHex, mode: mode)
        profiles.append(profile)
        save()
        if importDefault { importDismissed = true }
        Task { await build(profile, importDefault: importDefault) }
    }

    func rebuild(_ p: Profile) {
        guard running[p.id] == nil else {
            errorMessage = "Quit “\(p.name)” before rebuilding it."
            return
        }
        Task { await build(p, importDefault: false) }
    }

    /// Flip between Standalone and Lightweight. Data is kept; only the launcher is rebuilt.
    func switchMode(_ p: Profile) {
        guard running[p.id] == nil else {
            errorMessage = "Quit “\(p.name)” before changing its type."
            return
        }
        guard busy[p.id] == nil else { return }
        let old = p.mode
        update(p.id) { $0.mode = (old == .standalone) ? .lightweight : .standalone }
        if let updated = profiles.first(where: { $0.id == p.id }) {
            Task { await build(updated, importDefault: false, revertModeOnFailure: old) }
        }
    }

    func rebuildAll() {
        for p in profiles where needsRebuild(p) && running[p.id] == nil && busy[p.id] == nil {
            Task { await build(p, importDefault: false) }
        }
    }

    @discardableResult
    private func build(_ p: Profile, importDefault: Bool, revertModeOnFailure: LaunchMode? = nil) async -> Bool {
        guard let claude else {
            errorMessage = "Claude Desktop wasn't found. Install it, or choose its location at the bottom of the window."
            return false
        }
        guard busy[p.id] == nil else { return false }
        let id = p.id
        busy[id] = "Preparing…"
        let icon = NSWorkspace.shared.icon(forFile: claude.url.path)
        let report: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor in if self?.busy[id] != nil { self?.busy[id] = msg } }
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                if importDefault {
                    report("Importing existing Claude data…")
                    try ProfileStore.copyDefaultData(to: p.dataURL)
                }
                try BundleBuilder.build(profile: p, claude: claude, baseIcon: icon, progress: report)
            }.value
            update(id) {
                $0.builtVersion = claude.version
                $0.builtFromPath = claude.url.path
            }
            busy[id] = nil
            return true
        } catch {
            if let old = revertModeOnFailure { update(id) { $0.mode = old } }
            errorMessage = "Couldn't build “\(p.name)”.\n\n\(error.localizedDescription)"
            busy[id] = nil
            return false
        }
    }

    nonisolated private static func copyDefaultData(to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.profilesData, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        do {
            try Shell.run("/bin/cp", ["-Rc", Paths.defaultClaudeData.path, dest.path])
        } catch {
            try? fm.removeItem(at: dest)
            try Shell.run("/bin/cp", ["-R", Paths.defaultClaudeData.path, dest.path])
        }
        // Chromium's single-instance lock files point at the old location; drop them.
        for name in ["SingletonLock", "SingletonCookie", "SingletonSocket"] {
            try? fm.removeItem(at: dest.appendingPathComponent(name))
        }
    }

    func launch(_ p: Profile) {
        if let pid = running[p.id], let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            return
        }
        guard FileManager.default.fileExists(atPath: p.launcherURL.path) else {
            Task {
                if await build(p, importDefault: false),
                   let fresh = profiles.first(where: { $0.id == p.id }) { launch(fresh) }
            }
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: p.launcherURL, configuration: config) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.errorMessage = "Couldn't open “\(p.name)”: \(error.localizedDescription)" }
        }
    }

    func quit(_ p: Profile) {
        guard let pid = running[p.id] else { return }
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    func delete(_ p: Profile, deleteData: Bool) {
        guard running[p.id] == nil else {
            errorMessage = "Quit “\(p.name)” before deleting it."
            return
        }
        BundleBuilder.remove(profile: p)
        if deleteData, FileManager.default.fileExists(atPath: p.dataURL.path) {
            NSWorkspace.shared.recycle([p.dataURL]) { _, _ in }
        }
        profiles.removeAll { $0.id == p.id }
        save()
    }

    func revealLauncher(_ p: Profile) {
        NSWorkspace.shared.activateFileViewerSelecting([p.launcherURL])
    }

    func openDataFolder(_ p: Profile) {
        try? FileManager.default.createDirectory(at: p.dataURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(p.dataURL)
    }

    /// Each profile has its own claude_desktop_config.json (MCP servers etc.).
    func openConfig(_ p: Profile) {
        let fm = FileManager.default
        let file = p.dataURL.appendingPathComponent("claude_desktop_config.json")
        if !fm.fileExists(atPath: file.path) {
            try? fm.createDirectory(at: p.dataURL, withIntermediateDirectories: true)
            try? "{\n  \"mcpServers\": {}\n}\n".write(to: file, atomically: true, encoding: .utf8)
        }
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([file], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }

    func openLaunchersFolder() {
        try? FileManager.default.createDirectory(at: Paths.launchers, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Paths.launchers)
    }

    private func isOfficialClaudeRunning() -> Bool {
        // Lightweight profiles also run the official app; only the default instance matters here.
        NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeInstall.bundleID)
            .contains { !running.values.contains($0.processIdentifier) }
    }
}
