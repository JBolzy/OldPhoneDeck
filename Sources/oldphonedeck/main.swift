import AppKit

// MARK: Options

struct Options {
    var port: UInt16 = 8045

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--port": port = UInt16(it.next() ?? "") ?? port
            case "-h", "--help":
                print("""
                oldphonedeck: turn an old iPhone into a Stream Deck-style control panel for your Mac
                  --port N          HTTP port (default 8045)
                """)
                exit(0)
            default: print("Unknown option \(a) (try --help)"); exit(2)
            }
        }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let opts = Options(CommandLine.arguments)
let configDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".oldphonedeck")

// MARK: Access token (anyone on the Wi-Fi could otherwise open apps on your Mac)

func loadToken() -> String {
    let file = configDir.appendingPathComponent("token")
    if let t = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
        return t
    }
    let t = (0..<12).map { _ in String("abcdefghjkmnpqrstuvwxyz23456789".randomElement()!) }.joined()
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    try? t.write(to: file, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return t
}

func lanAddress() -> String {
    var addr = "localhost"
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return addr }
    defer { freeifaddrs(ifaddr) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let i = p.pointee
        guard i.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: i.ifa_name)
        guard name.hasPrefix("en") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(i.ifa_addr, socklen_t(i.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        addr = String(cString: host)
        if name == "en0" { break }
    }
    return addr
}

let token = loadToken()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// MARK: Services

let server: HTTPServer
do { server = try HTTPServer(port: opts.port) } catch { print("Cannot listen on \(opts.port): \(error)"); exit(1) }

let stats = Stats()
stats.start()

// MARK: Routes

let webRoot = Bundle.module.url(forResource: "web", withExtension: nil)!

let routes: (HTTPRequest, HTTPConnection) -> Void = { req, conn in
    // Public: the page shell, so a home-screen bookmark loads.
    if req.path == "/" || req.path == "/index.html" {
        let html = (try? Data(contentsOf: webRoot.appendingPathComponent("index.html"))) ?? Data()
        return conn.respond(200, "text/html; charset=utf-8", html)
    }
    guard req.query["k"] == token else { return conn.respond(403, text: "bad token") }
    let p = req.params

    switch (req.method, req.path) {
    case ("GET", "/info"):
        conn.respondJSON(["ok": true])   // lets the page check its access token
    case ("GET", "/stats"):
        conn.respondJSON(stats.snapshot())
    case ("GET", "/memory"):
        DispatchQueue.global().async {
            let snap = MemoryStats.snapshot()
            server.queue.async { conn.respondJSON(snap) }
        }
    case ("POST", "/ollama/stop"):
        let model = p["model"] ?? ""
        DispatchQueue.global().async {
            let ok = MemoryStats.ollamaStop(model)
            server.queue.async { ok ? conn.respond(text: "ok") : conn.respond(404, text: "model not loaded") }
        }
    case ("POST", "/speedtest"):
        stats.runSpeedTest()
        conn.respond(text: "ok")
    case ("GET", "/launcher"):
        let selected: Any = Launcher.selected() ?? NSNull()
        conn.respondJSON(["selected": selected, "all": Apps.list()])
    case ("POST", "/launcher"):
        // Body: paths=<path>\n<path>\n… in display order.
        let paths = (p["paths"] ?? "").split(separator: "\n").map(String.init)
        do { conn.respondJSON(["saved": try Launcher.save(paths)]) }
        catch { conn.respond(500, text: error.localizedDescription) }
    case ("GET", "/icon"):
        let path = p["path"] ?? ""
        guard Apps.isKnown(path) else { return conn.respond(404, text: "unknown app") }
        DispatchQueue.main.async {
            let png = Apps.icon(path) ?? Data()
            server.queue.async { conn.respond(200, "image/png", png) }
        }
    case ("POST", "/launch"):
        let path = p["path"] ?? ""
        guard Apps.isKnown(path) else { return conn.respond(404, text: "unknown app") }
        DispatchQueue.main.async { Apps.launch(path) }
        conn.respond(text: "ok")
    default:
        conn.respond(404, text: "not found")
    }
}
server.start(routes)

let lanIP = lanAddress()

// MARK: Start

print("""

OldPhoneDeck is running. On the phone (same Wi-Fi), open Safari and go to:

    http://\(lanIP):\(opts.port)/#k=\(token)

Then tap Share → Add to Home Screen. Hold any key to choose your 4 apps.

Ctrl-C to quit.

""")

signal(SIGINT) { _ in exit(0) }
app.run()
