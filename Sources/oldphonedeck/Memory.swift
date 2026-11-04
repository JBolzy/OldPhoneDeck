import Foundation

/// Per-app memory breakdown for the deck's RAM overlay, plus the Ollama unload control.
/// Sizes come from `top -o mem` (physical footprint, the same figure Activity Monitor shows), not ps RSS.
enum MemoryStats {
    private static let lock = NSLock()
    private static var cache: (at: Date, json: [String: Any])?

    private static let ollamaBinary = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
                                       "/Applications/Ollama.app/Contents/Resources/ollama"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Blocking (~0.5 s); call off the server queue. Results are shared for 2 s so several viewers cost one `top`.
    static func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache, Date().timeIntervalSince(c.at) < 2 { return c.json }
        let json: [String: Any] = [
            "apps": topApps(15),
            "pressure": pressure(),
            "swapMB": swapUsedMB(),
            "ollama": ollamaLoaded().map { ["name": $0.name, "mb": $0.mb] },
        ]
        cache = (Date(), json)
        return json
    }

    // MARK: Apps

    private static func topApps(_ limit: Int) -> [[String: Any]] {
        guard let topData = Stats.run("/usr/bin/top", ["-l", "1", "-o", "mem", "-stats", "pid,mem"], timeout: 10),
              let psData = Stats.run("/bin/ps", ["-Ao", "pid=,comm="], timeout: 5) else { return [] }

        var paths: [Int: String] = [:]
        for line in String(decoding: psData, as: UTF8.self).split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let pid = Int(t[..<sp]) else { continue }
            paths[pid] = t[sp...].trimmingCharacters(in: .whitespaces)
        }

        var totals: [String: Double] = [:]
        var inTable = false
        for line in String(decoding: topData, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ")
            if f.first == "PID" { inTable = true; continue }
            guard inTable, f.count >= 2, let pid = Int(f[0]), let mb = megabytes(String(f[1])) else { continue }
            totals[groupName(paths[pid] ?? ""), default: 0] += mb
        }
        return totals.sorted { $0.value > $1.value }.prefix(limit)
            .map { ["name": $0.key, "mb": Int($0.value.rounded())] }
    }

    /// `top` prints sizes like "938M", "788K", "1G", sometimes with a trailing +/-.
    private static func megabytes(_ s: String) -> Double? {
        var t = Substring(s)
        while let c = t.last, c == "+" || c == "-" { t = t.dropLast() }
        guard let unit = t.last, let n = Double(t.dropLast()) else { return nil }
        switch unit {
        case "B": return n / 1_048_576
        case "K": return n / 1024
        case "M": return n
        case "G": return n * 1024
        default: return nil
        }
    }

    /// Helpers roll up under the outermost .app in their path (Claude Helper (Renderer) → Claude).
    private static func groupName(_ path: String) -> String {
        for part in path.split(separator: "/") where part.hasSuffix(".app") { return String(part.dropLast(4)) }
        let base = (path as NSString).lastPathComponent
        if base.hasPrefix("com.apple.WebKit.") { return "Safari / WebKit" }
        return base.isEmpty ? "Unknown" : base
    }

    // MARK: Pressure and swap

    private static func pressure() -> String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return "normal" }
        return level >= 4 ? "critical" : level >= 2 ? "warn" : "normal"
    }

    private static func swapUsedMB() -> Int {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return 0 }
        return Int(swap.xsu_used / 1_048_576)
    }

    // MARK: Ollama

    /// Models currently loaded, from `ollama ps` (empty when Ollama isn't installed or running).
    static func ollamaLoaded() -> [(name: String, mb: Int)] {
        guard let bin = ollamaBinary, let data = Stats.run(bin, ["ps"], timeout: 4) else { return [] }
        let size = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*(GB|MB|KB)"#)
        var out: [(String, Int)] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst() {
            guard let name = line.split(separator: " ").first.map(String.init) else { continue }
            var mb = 0
            let s = String(line)
            if let m = size?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let nr = Range(m.range(at: 1), in: s), let ur = Range(m.range(at: 2), in: s), let n = Double(s[nr]) {
                mb = Int(s[ur] == "GB" ? n * 1024 : s[ur] == "MB" ? n : n / 1024)
            }
            out.append((name, mb))
        }
        return out
    }

    /// Runs `ollama stop <model>` only for a model `ollama ps` currently lists.
    static func ollamaStop(_ model: String) -> Bool {
        guard let bin = ollamaBinary, ollamaLoaded().contains(where: { $0.name == model }),
              Stats.run(bin, ["stop", model], timeout: 15) != nil else { return false }
        lock.lock(); cache = nil; lock.unlock()
        return true
    }
}
