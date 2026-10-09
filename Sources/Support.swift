import AppKit
import Foundation

// MARK: - Paths

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/SwitchClaude", isDirectory: true)
    static let profilesData = support.appendingPathComponent("Profiles", isDirectory: true)
    static let store = support.appendingPathComponent("profiles.json")
    /// Where the per-profile launcher apps live (shows up in Launchpad and Spotlight).
    static let launchers = home.appendingPathComponent("Applications/Claude Profiles", isDirectory: true)
    /// The data folder used by a normal Claude Desktop install.
    static let defaultClaudeData = home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)

    static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\u{0}")
        return s.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Shell

struct ShellError: LocalizedError {
    let command: String
    let status: Int32
    let output: String
    var errorDescription: String? {
        "`\(command)` failed (exit \(status)).\n\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

private final class DataBox: @unchecked Sendable { var data = Data() }

enum Shell {
    struct Result { let stdout: Data; let stderr: Data; let status: Int32 }

    static func exec(_ path: String, _ args: [String]) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        // Read both pipes concurrently so neither can fill up and block the child.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return Result(stdout: outData, stderr: errBox.data, status: p.terminationStatus)
    }

    /// Runs a command and throws if it exits non-zero. Returns stdout as text.
    @discardableResult
    static func run(_ path: String, _ args: [String]) throws -> String {
        let r = try exec(path, args)
        let stdout = String(decoding: r.stdout, as: UTF8.self)
        guard r.status == 0 else {
            let stderr = String(decoding: r.stderr, as: UTF8.self)
            let name = (path as NSString).lastPathComponent
            throw ShellError(command: ([name] + args).joined(separator: " "), status: r.status, output: stderr + stdout)
        }
        return stdout
    }

    /// Single-quotes a string for /bin/sh.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Colours

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        func b(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.redComponent), b(c.greenComponent), b(c.blueComponent))
    }

    /// Black or white, whichever reads better on top of this colour.
    var contrastingText: NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return lum > 0.62 ? .black : .white
    }
}

enum Palette {
    static let hexes = ["#D97757", "#E5484D", "#F5A524", "#30A46C", "#12A594",
                        "#0090FF", "#6E56CF", "#D6409F", "#8D8D86", "#1F1F1F"]
}

// MARK: - Plists

enum Plist {
    static func read(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return dict
    }

    static func write(_ dict: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }
}
