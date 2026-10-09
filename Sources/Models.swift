import AppKit
import Foundation

enum LaunchMode: String, Codable, CaseIterable, Identifiable {
    /// A private, re-signed clone of Claude.app: own Dock icon, own Cmd-Tab entry.
    case standalone
    /// Launches the official Claude.app with a separate data folder: shares Claude's Dock icon.
    case lightweight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standalone: return "Standalone"
        case .lightweight: return "Lightweight"
        }
    }

    var detail: String {
        switch self {
        case .standalone:
            return "Own coloured Dock icon and Cmd-Tab entry. Uses a space-saving clone of Claude.app that needs a quick rebuild after Claude updates."
        case .lightweight:
            return "Runs the official, Anthropic-signed Claude.app. Always up to date and every feature works, but each window shows the standard Claude Dock icon."
        }
    }
}

struct Profile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var colorHex: String
    var mode: LaunchMode
    var createdAt: Date
    /// Claude version / path the launcher was last built from.
    var builtVersion: String?
    var builtFromPath: String?

    init(name: String, colorHex: String, mode: LaunchMode) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.mode = mode
        self.createdAt = Date()
    }

    var shortID: String { String(id.uuidString.prefix(8)).lowercased() }
    var bundleIdentifier: String { "com.local.switchclaude.profile.\(shortID)" }
    var dataURL: URL { Paths.profilesData.appendingPathComponent(id.uuidString, isDirectory: true) }
    var launcherURL: URL {
        Paths.launchers.appendingPathComponent("\(Paths.safeFileName(name)).app", isDirectory: true)
    }
    var nsColor: NSColor { NSColor(hex: colorHex) ?? .systemOrange }
    var initial: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }
}

struct ClaudeInstall: Equatable {
    static let bundleID = "com.anthropic.claudefordesktop"

    let url: URL
    let version: String
    let executableName: String

    init?(url: URL) {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let info = try? Plist.read(plistURL),
              let exec = info["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/\(exec)").path)
        else { return nil }
        // Never treat one of our own profile launchers as "the" Claude.
        if url.standardizedFileURL.path.hasPrefix(Paths.launchers.standardizedFileURL.path) { return nil }
        if info["SwitchClaudeProfileID"] != nil || info["SwitchboardProfileID"] != nil { return nil }
        self.url = url
        self.executableName = exec
        self.version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String) ?? "unknown"
    }

    static func locate(override: String?) -> ClaudeInstall? {
        var candidates: [URL] = []
        if let o = override, !o.isEmpty { candidates.append(URL(fileURLWithPath: o)) }
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { candidates.append(u) }
        candidates.append(URL(fileURLWithPath: "/Applications/Claude.app"))
        candidates.append(Paths.home.appendingPathComponent("Applications/Claude.app"))
        for c in candidates {
            if let install = ClaudeInstall(url: c) { return install }
        }
        return nil
    }
}
