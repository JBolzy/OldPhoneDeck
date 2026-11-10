import Foundation
import IOKit.ps

/// Data for the dashboard widgets: live network throughput, speed tests, batteries, and CPU/RAM/disk.
final class Stats {
    private let queue = DispatchQueue(label: "stats")
    private var lastBytes: (rx: UInt64, tx: UInt64, at: Date)?
    private var history: [[Double]] = []          // [rxMbps, txMbps], one per second, newest last
    private var speed: [String: Any] = [:]
    private var testing = false
    private var batteries: [[String: Any]] = []
    private var sys: [String: Any] = [:]
    private var updates: [String: Any] = [:]
    private var link: [String: Any] = [:]
    private var health: [String: Any] = [:]
    private var lastTicks: [UInt32]?
    private var sysTick = 0

    func start() {
        let net = DispatchSource.makeTimerSource(queue: queue)
        net.schedule(deadline: .now(), repeating: 1)
        net.setEventHandler { [weak self] in self?.sampleNetwork() }
        net.resume()
        let batt = DispatchSource.makeTimerSource(queue: queue)
        batt.schedule(deadline: .now(), repeating: 60)
        // Battery reads shell out (system_profiler takes ~1 s), so keep them off the stats queue.
        batt.setEventHandler { [weak self] in DispatchQueue.global().async { self?.refreshBatteries() } }
        batt.resume()
        // `softwareupdate -l` contacts Apple and can take a while, so it runs rarely and off the stats queue.
        let upd = DispatchSource.makeTimerSource(queue: queue)
        upd.schedule(deadline: .now() + 20, repeating: 6 * 3600)
        upd.setEventHandler { [weak self] in DispatchQueue.global().async { self?.refreshUpdates() } }
        upd.resume()
        // CPU throttling, failed LaunchAgents and the network link: cheap shell-outs, every 30 s.
        let hl = DispatchSource.makeTimerSource(queue: queue)
        hl.schedule(deadline: .now() + 2, repeating: 30)
        hl.setEventHandler { [weak self] in DispatchQueue.global().async { self?.refreshHealth() } }
        hl.resume()
        // Speed test: once shortly after launch so the widget isn't empty, then every 6 hours (it saturates the link for ~20 s).
        let spd = DispatchSource.makeTimerSource(queue: queue)
        spd.schedule(deadline: .now() + 5, repeating: 6 * 3600)
        spd.setEventHandler { [weak self] in self?.runSpeedTest() }
        spd.resume()
        timers = [net, batt, upd, hl, spd]
    }
    private var timers: [DispatchSourceTimer] = []

    func snapshot() -> [String: Any] {
        queue.sync {
            var s = speed
            s["running"] = testing
            return [
                "net": ["rx": history.last?[0] ?? 0, "tx": history.last?[1] ?? 0,
                        "history": history.map { $0[0] }],
                "speed": s,
                "batteries": batteries,
                "sys": sys,
                "updates": updates,
                "link": link,
                "health": health,
                "mac": Host.current().localizedName ?? "Mac",
                "now": Date().timeIntervalSince1970,
                "tz": TimeZone.current.secondsFromGMT(),
            ]
        }
    }

    // MARK: CPU, RAM and disk

    private func sampleSystem() {
        var cpuInfo = host_cpu_load_info()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cpuStatus = withUnsafeMutablePointer(to: &cpuInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        if cpuStatus == KERN_SUCCESS {
            let t = [cpuInfo.cpu_ticks.0, cpuInfo.cpu_ticks.1, cpuInfo.cpu_ticks.2, cpuInfo.cpu_ticks.3]   // user, system, idle, nice
            if let l = lastTicks {
                let d = zip(t, l).map { Double($0 &- $1) }
                let total = d.reduce(0, +)
                if total > 0 { sys["cpu"] = (total - d[2]) / total * 100 }
            }
            lastTicks = t
        }

        // "Used" as Activity Monitor counts it: app memory + wired + compressed.
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmStatus = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if vmStatus == KERN_SUCCESS {
            let pages = Double(vm.internal_page_count) - Double(vm.purgeable_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)
            sys["ramUsed"] = pages * Double(sysconf(_SC_PAGESIZE))
            sys["ramTotal"] = Double(ProcessInfo.processInfo.physicalMemory)
        }
        if let up = Health.uptime() { sys["uptime"] = up }
        sys["pressure"] = MemoryStats.pressure()
        sys["swapMB"] = MemoryStats.swapUsedMB()

        if sysTick % 30 == 0,
           let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
           let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage {
            sys["diskTotal"] = Double(total)
            sys["diskFree"] = Double(free)
        }
        sysTick += 1
    }

    // MARK: Health: throttling, failed agents, network link

    private func refreshHealth() {
        var h: [String: Any] = ["agents": Health.failedAgents()]
        if let limit = Health.cpuSpeedLimit() { h["throttle"] = limit }
        let l = Health.link() ?? [:]
        queue.async { self.health = h; self.link = l }
    }

    // MARK: Pending macOS updates

    private func refreshUpdates() {
        // The "No new software" message goes to stderr, so success with no "* Label:" lines means up to date.
        guard let data = Stats.run("/usr/sbin/softwareupdate", ["-l"], timeout: 120) else { return }
        let text = String(data: data, encoding: .utf8) ?? ""
        let titles = text.split(separator: "\n").compactMap { line -> String? in
            let s = line.trimmingCharacters(in: .whitespaces)
            return s.hasPrefix("* Label:") ? String(s.dropFirst("* Label:".count)).trimmingCharacters(in: .whitespaces) : nil
        }
        queue.async { self.updates = ["count": titles.count, "titles": titles] }
    }

    // MARK: Network throughput (all en* interfaces)

    private func sampleNetwork() {
        sampleSystem()
        var rx: UInt64 = 0, tx: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard i.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), String(cString: i.ifa_name).hasPrefix("en"),
                  let data = i.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            rx += UInt64(data.pointee.ifi_ibytes)
            tx += UInt64(data.pointee.ifi_obytes)
        }
        let now = Date()
        if let last = lastBytes {
            let dt = now.timeIntervalSince(last.at)
            // Counters are 32-bit per interface and can wrap; skip negative deltas.
            let drx = rx >= last.rx ? Double(rx - last.rx) : 0
            let dtx = tx >= last.tx ? Double(tx - last.tx) : 0
            history.append([drx * 8 / dt / 1e6, dtx * 8 / dt / 1e6])
            if history.count > 60 { history.removeFirst(history.count - 60) }
        }
        lastBytes = (rx, tx, now)
    }

    // MARK: Speed test (macOS's built-in networkQuality)

    func runSpeedTest() {
        queue.async {
            guard !self.testing else { return }
            self.testing = true
            DispatchQueue.global().async {
                let json = Stats.run("/usr/bin/networkQuality", ["-c"])
                var result: [String: Any] = [:]
                if let data = json, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let dl = obj["dl_throughput"] as? Double { result["down"] = dl / 1e6 }
                    if let ul = obj["ul_throughput"] as? Double { result["up"] = ul / 1e6 }
                    if let rtt = obj["base_rtt"] as? Double { result["ping"] = rtt }
                    result["at"] = Date().timeIntervalSince1970 * 1000
                }
                self.queue.async {
                    self.testing = false
                    if !result.isEmpty { self.speed = result }
                }
            }
        }
    }

    // MARK: Batteries

    private func refreshBatteries() {
        var list: [[String: Any]] = []

        // This Mac's own battery, if it has one.
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for src in sources {
                guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                list.append(["name": "MacBook", "kind": "laptop", "level": cur * 100 / max,
                             "charging": (d[kIOPSIsChargingKey] as? Bool) ?? false])
            }
        }

        // Bluetooth HID accessories (Magic Keyboard/Mouse/Trackpad) report BatteryPercent in the IORegistry.
        if let data = Stats.run("/usr/sbin/ioreg", ["-r", "-k", "BatteryPercent", "-a"]),
           let items = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] {
            var seen = Set<String>()
            for item in items {
                guard let name = item["Product"] as? String, let pct = item["BatteryPercent"] as? Int,
                      seen.insert(name).inserted else { continue }
                let lower = name.lowercased()
                let kind = lower.contains("mouse") ? "mouse" : lower.contains("trackpad") ? "trackpad" : "keyboard"
                list.append(["name": Stats.shortName(name), "kind": kind, "level": pct, "charging": false])
            }
        }

        // AirPods and other audio devices: system_profiler reports per-bud levels.
        if let data = Stats.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let bt = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
           let connected = bt["device_connected"] as? [[String: Any]] {
            for entry in connected {
                for (name, value) in entry {
                    guard let d = value as? [String: Any] else { continue }
                    func pct(_ k: String) -> Int? {
                        (d[k] as? String).flatMap { Int($0.replacingOccurrences(of: " %", with: "").replacingOccurrences(of: "%", with: "")) }
                    }
                    let buds = [pct("device_batteryLevelLeft"), pct("device_batteryLevelRight")].compactMap { $0 }
                    if let level = buds.min() ?? pct("device_batteryLevelMain") {
                        var item: [String: Any] = ["name": Stats.shortName(name), "kind": "headphones", "level": level, "charging": false]
                        if let c = pct("device_batteryLevelCase") { item["case"] = c }
                        list.append(item)
                    }
                }
            }
        }
        queue.async { self.batteries = list }
    }

    /// "Alex's Magic Mouse" → "Magic Mouse", "Sam' Keyboard" → "Keyboard"; keeps labels short on a 3.5" screen.
    static func shortName(_ name: String) -> String {
        if let r = name.range(of: "^\\S+['’]s?\\s+", options: .regularExpression) { return String(name[r.upperBound...]) }
        return name
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval? = nil) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}
