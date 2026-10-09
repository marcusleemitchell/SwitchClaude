import AppKit
import Foundation

// MARK: - Icons

enum IconMaker {
    /// Claude's icon with a coloured badge carrying the profile's initial.
    static func render(base: NSImage?, color: NSColor, initial: String, pixels: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        let s = CGFloat(pixels)
        let full = NSRect(x: 0, y: 0, width: s, height: s)

        if let base {
            base.draw(in: full, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            let inset = full.insetBy(dx: s * 0.1, dy: s * 0.1)
            NSColor(white: 0.95, alpha: 1).setFill()
            NSBezierPath(roundedRect: inset, xRadius: s * 0.18, yRadius: s * 0.18).fill()
        }

        let d = s * 0.46
        let badge = NSRect(x: s - d - s * 0.04, y: s * 0.04, width: d, height: d)
        let circle = NSBezierPath(ovalIn: badge)
        color.setFill()
        circle.fill()
        NSColor.white.setStroke()
        circle.lineWidth = max(1, s * 0.03)
        circle.stroke()

        if !initial.isEmpty {
            let font = NSFont.systemFont(ofSize: d * 0.56, weight: .bold)
            let str = NSAttributedString(string: initial, attributes: [
                .font: font, .foregroundColor: color.contrastingText,
            ])
            let size = str.size()
            str.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func writeICNS(base: NSImage?, color: NSColor, initial: String, to out: URL) throws {
        let fm = FileManager.default
        let iconset = fm.temporaryDirectory.appendingPathComponent("switchclaude-\(UUID().uuidString).iconset")
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iconset) }

        let specs: [(String, Int)] = [
            ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
            ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
            ("512x512", 512), ("512x512@2x", 1024),
        ]
        for (name, px) in specs {
            guard let rep = render(base: base, color: color, initial: initial, pixels: px),
                  let png = rep.representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: iconset.appendingPathComponent("icon_\(name).png"))
        }
        try Shell.run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", out.path])
    }
}

// MARK: - Launcher bundles

enum BundleBuilder {
    static let codesign = "/usr/bin/codesign"
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static let launcherExecutable = "SwitchClaudeLauncher"
    static let iconName = "SwitchClaudeProfile"

    /// (Re)creates the launcher app for a profile. Runs off the main thread.
    static func build(profile: Profile, claude: ClaudeInstall, baseIcon: NSImage?,
                      progress: (String) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.launchers, withIntermediateDirectories: true)
        try fm.createDirectory(at: profile.dataURL, withIntermediateDirectories: true)

        let dest = profile.launcherURL
        if fm.fileExists(atPath: dest.path) {
            _ = try? Shell.run(lsregister, ["-u", dest.path])
            try fm.removeItem(at: dest)
        }

        do {
            switch profile.mode {
            case .standalone: try buildStandalone(profile, claude, baseIcon, dest, progress)
            case .lightweight: try buildLightweight(profile, claude, baseIcon, dest, progress)
            }
        } catch {
            try? fm.removeItem(at: dest) // never leave a half-built launcher behind
            throw error
        }

        progress("Registering…")
        _ = try? Shell.run(lsregister, ["-f", dest.path])
    }

    static func remove(profile: Profile) {
        let dest = profile.launcherURL
        _ = try? Shell.run(lsregister, ["-u", dest.path])
        try? FileManager.default.removeItem(at: dest)
    }

    // MARK: Standalone: clone Claude.app, swap identity + icon, wrap the executable, ad-hoc sign.

    private static func buildStandalone(_ profile: Profile, _ claude: ClaudeInstall, _ baseIcon: NSImage?,
                                        _ dest: URL, _ progress: (String) -> Void) throws {
        let fm = FileManager.default

        // 1. Capture the entitlements of the original binaries before we touch anything.
        progress("Reading Claude's entitlements…")
        let mainRel = "Contents/MacOS/\(claude.executableName)"
        var entitlements: [(rel: String, plist: Data?)] = []
        let frameworks = claude.url.appendingPathComponent("Contents/Frameworks")
        let helpers = ((try? fm.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
        for helper in helpers {
            entitlements.append(("Contents/Frameworks/\(helper.lastPathComponent)", safeEntitlements(of: helper)))
        }
        entitlements.append((mainRel, safeEntitlements(of: claude.url.appendingPathComponent(mainRel))))

        // 2. Clone. `cp -c` uses APFS clonefile, so this takes almost no extra disk space.
        progress("Cloning Claude.app…")
        do {
            try Shell.run("/bin/cp", ["-Rc", claude.url.path, dest.path])
        } catch {
            try? fm.removeItem(at: dest)
            try Shell.run("/bin/cp", ["-R", claude.url.path, dest.path])
        }
        _ = try? Shell.run("/usr/bin/xattr", ["-cr", dest.path])

        // 3. New identity. CFBundleName is deliberately left alone: Electron uses it to find its helper apps.
        progress("Customising…")
        let plistURL = dest.appendingPathComponent("Contents/Info.plist")
        var info = try Plist.read(plistURL)
        info["CFBundleIdentifier"] = profile.bundleIdentifier
        info["CFBundleExecutable"] = launcherExecutable
        info["CFBundleIconFile"] = iconName
        info.removeValue(forKey: "CFBundleIconName") // otherwise macOS keeps using the asset-catalogue icon
        info["SwitchClaudeProfileID"] = profile.id.uuidString
        try Plist.write(info, to: plistURL)

        try IconMaker.writeICNS(base: baseIcon, color: profile.nsColor, initial: profile.initial,
                                to: dest.appendingPathComponent("Contents/Resources/\(iconName).icns"))

        // 4. Wrapper: exec (same PID, so the Dock keeps our bundle's icon) the real binary with its own data dir.
        let script = """
        #!/bin/sh
        exec "$(dirname "$0")/\(claude.executableName)" --user-data-dir=\(Shell.quote(profile.dataURL.path)) "$@"

        """
        let wrapper = dest.appendingPathComponent("Contents/MacOS/\(launcherExecutable)")
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        // 5. Ad-hoc sign: everything first, then helpers + main binary with their (filtered) entitlements,
        //    then seal the outer bundle last.
        progress("Signing (this can take a minute)…")
        try Shell.run(codesign, ["--force", "--deep", "--sign", "-", dest.path])
        for item in entitlements {
            let target = dest.appendingPathComponent(item.rel)
            guard fm.fileExists(atPath: target.path) else { continue }
            var args = ["--force", "--sign", "-"]
            var tmp: URL?
            if let plist = item.plist {
                let t = fm.temporaryDirectory.appendingPathComponent("switchclaude-ents-\(UUID().uuidString).plist")
                try plist.write(to: t)
                tmp = t
                args += ["--entitlements", t.path]
            }
            args.append(target.path)
            defer { if let tmp { try? fm.removeItem(at: tmp) } }
            try Shell.run(codesign, args)
        }
        try Shell.run(codesign, ["--force", "--sign", "-", dest.path])
    }

    /// The original entitlements minus anything that needs Anthropic's Team ID (those would get an
    /// ad-hoc signed binary killed at launch).
    private static func safeEntitlements(of url: URL) -> Data? {
        var raw: Data?
        if let r = try? Shell.exec(codesign, ["-d", "--entitlements", "-", "--xml", url.path]), r.status == 0, !r.stdout.isEmpty {
            raw = r.stdout
        } else if let r = try? Shell.exec(codesign, ["-d", "--entitlements", ":-", url.path]), r.status == 0, !r.stdout.isEmpty {
            raw = r.stdout
        }
        guard let raw,
              let dict = try? PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any]
        else { return nil }
        let blocked: Set<String> = ["com.apple.security.application-groups"]
        let kept = dict.filter { $0.key.hasPrefix("com.apple.security.") && !blocked.contains($0.key) }
        guard !kept.isEmpty else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: kept, format: .xml, options: 0)
    }

    // MARK: Lightweight: a tiny app that opens the official Claude.app with a separate data folder.

    private static func buildLightweight(_ profile: Profile, _ claude: ClaudeInstall, _ baseIcon: NSImage?,
                                         _ dest: URL, _ progress: (String) -> Void) throws {
        let fm = FileManager.default
        progress("Creating launcher…")
        let contents = dest.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": profile.bundleIdentifier,
            "CFBundleName": profile.name,
            "CFBundleDisplayName": profile.name,
            "CFBundleExecutable": launcherExecutable,
            "CFBundleIconFile": iconName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleInfoDictionaryVersion": "6.0",
            "LSMinimumSystemVersion": "12.0",
            "LSUIElement": true, // the shim itself never shows in the Dock
            "SwitchClaudeProfileID": profile.id.uuidString,
        ]
        try Plist.write(info, to: contents.appendingPathComponent("Info.plist"))

        try IconMaker.writeICNS(base: baseIcon, color: profile.nsColor, initial: profile.initial,
                                to: resources.appendingPathComponent("\(iconName).icns"))

        let script = """
        #!/bin/sh
        exec /usr/bin/open -n -a \(Shell.quote(claude.url.path)) --args --user-data-dir=\(Shell.quote(profile.dataURL.path))

        """
        let wrapper = macOS.appendingPathComponent(launcherExecutable)
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        progress("Signing…")
        try Shell.run(codesign, ["--force", "--sign", "-", dest.path])
    }
}
