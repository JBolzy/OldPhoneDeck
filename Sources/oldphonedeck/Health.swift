import Foundation
import CoreWLAN

/// Small read-only probes for the deck: uptime, CPU throttling, failed user agents and the network link.
enum Health {
    static func uptime() -> Double? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date().timeIntervalSince1970 - Double(tv.tv_sec)
    }

    /// `pmset -g therm` only prints CPU_Speed_Limit (percent) once macOS has throttled the CPU.
    static func cpuSpeedLimit() -> Int? {
        guard let data = Stats.run("/usr/bin/pmset", ["-g", "therm"], timeout: 5) else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.contains("CPU_Speed_Limit") {
            if let v = line.split(separator: "=").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), v < 100 { return v }
        }
        return nil
    }

    /// Agents in ~/Library/LaunchAgents that are loaded, not running, and last exited with an error.
    static func failedAgents() -> [String] {
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        let mine = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".plist") }.map { String($0.dropLast(6)) })
        guard !mine.isEmpty, let data = Stats.run("/bin/launchctl", ["list"], timeout: 5) else { return [] }
        var out: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: "\t")
            // PID, last exit status, label. "-" means not running; -15 is a plain SIGTERM stop.
            guard f.count == 3, f[0] == "-", mine.contains(String(f[2])), let status = Int(f[1]), status != 0, status != -15 else { continue }
            out.append(String(f[2]))
        }
        return out
    }

    /// The interface carrying the default route: Wi-Fi (link rate and signal) or Ethernet (negotiated speed).
    static func link() -> [String: Any]? {
        guard let route = Stats.run("/sbin/route", ["-n", "get", "default"], timeout: 5),
              let line = String(decoding: route, as: UTF8.self).split(separator: "\n").first(where: { $0.contains("interface:") }),
              let name = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        if let wifi = CWWiFiClient.shared().interfaces()?.first(where: { $0.interfaceName == name }) {
            return ["type": "wifi", "rate": wifi.transmitRate(), "rssi": wifi.rssiValue()]
        }
        // "media: autoselect (1000baseT <full-duplex>)", "(2500Base-T …)" or "(10Gbase-T …)"
        var out: [String: Any] = ["type": "ethernet"]
        if let data = Stats.run("/sbin/ifconfig", [name], timeout: 5) {
            let text = String(decoding: data, as: UTF8.self)
            if let re = try? NSRegularExpression(pattern: #"(\d+)(G?)base"#, options: .caseInsensitive),
               let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let nr = Range(m.range(at: 1), in: text), let n = Double(text[nr]) {
                out["rate"] = m.range(at: 2).length > 0 ? n * 1000 : n
            }
        }
        return out
    }
}
