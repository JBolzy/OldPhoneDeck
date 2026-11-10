import AppKit

/// The app launcher: lists installed apps, renders their icons, and opens them.
enum Apps {
    private static let lock = NSLock()
    private static var iconCache: [String: Data] = [:]

    static func list() -> [[String: String]] {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var out: [[String: String]] = []
        for dir in dirs {
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                guard seen.insert(name).inserted else { continue }
                out.append(["name": name, "path": dir + "/" + item])
            }
        }
        return out.sorted { $0["name"]!.localizedCaseInsensitiveCompare($1["name"]!) == .orderedAscending }
    }

    /// Only paths that appear in our own listing may be launched or rendered.
    static func isKnown(_ path: String) -> Bool { list().contains { $0["path"] == path } }

    static func icon(_ path: String, size: Int = 114) -> Data? {
        lock.lock(); if let d = iconCache[path] { lock.unlock(); return d }; lock.unlock()
        // Resolve symlinks (e.g. /Applications/Safari.app) so the icon has no alias-arrow badge.
        let img = NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        lock.lock(); iconCache[path] = png; lock.unlock()
        return png
    }

    static func launch(_ path: String) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg) { _, err in
            if let err { print("Launch failed for \(path): \(err.localizedDescription)") }
        }
    }
}

/// Which apps the phone launcher shows, in order. Stored on the Mac so Safari and the
/// home-screen app (which have separate storage on iOS) see the same list.
enum Launcher {
    static let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".oldphonedeck/launcher.json")

    /// nil = never configured (phone shows everything and suggests editing).
    static func selected() -> [String]? {
        guard let data = try? Data(contentsOf: file),
              let paths = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return paths
    }

    @discardableResult
    static func save(_ paths: [String]) throws -> Int {
        let known = Set(Apps.list().compactMap { $0["path"] })
        let clean = paths.filter { known.contains($0) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: clean, options: .prettyPrinted).write(to: file)
        return clean.count
    }
}
