# OldPhoneDeck

**Turn an old iPhone into a Stream Deck–style control panel for your Mac.**
No jailbreak, no App Store, nothing to install on the phone: it runs in Safari, even on an iPhone 4S stuck on iOS 9.

![An iPhone 4S on a desk stand running OldPhoneDeck](docs/desk.jpg)

| The deck | Pick your apps |
|---|---|
| ![Deck](docs/deck.jpg) | ![Pick apps](docs/pick-apps.jpg) |

## Features

- **4 big keys:** a 2x2 grid of Mac apps of your choice. Tap a key and the app opens on your Mac. Hold any key to pick apps.
- **Top CPU:** the three busiest processes on the Mac, refreshed every few seconds. The four status cards (Internet, System, Batteries, Top CPU) form a 2x2 grid beside the keys.
- **Internet widget:** download, upload and ping (macOS's built-in `networkQuality`), plus a live traffic graph. Tap it to re-test.
- **Batteries widget:** MacBook, Magic Keyboard / Mouse / Trackpad and AirPods (with case), each as an icon + percentage.
- **System widget:** CPU, RAM, free disk space and pending macOS updates. Tap RAM for the top apps by memory, memory pressure and swap (plus an Unload button for a loaded Ollama model).
- **Fits any iPhone:** a compact 480×320 layout on old phones; full-width landscape and a portrait layout on modern ones.
- **Modern iPhones also get:** a **Phone** tab that streams the camera (into OBS) and the mic (into BlackHole) to your Mac.

## Requirements

- A Mac with macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`)
- An iPhone or iPad with Safari: anything from iOS 8/9 (iPhone 4S, 5, iPad 2…) to the latest
- Both on the same Wi-Fi network

## Quick start

```bash
git clone https://github.com/<you>/OldPhoneDeck.git
cd OldPhoneDeck
swift build -c release
.build/release/oldphonedeck
```

It prints a link like `http://192.168.x.x:8045/#k=<token>`. On the phone:

1. Open that link in **Safari**.
2. Tap **Share → Add to Home Screen** and launch it from there to run it full screen.
3. **Hold any key** to choose your 4 apps.

Tips for a dedicated desk display: set **Auto-Lock → Never**, and use **Guided Access** (Settings → Accessibility) to lock the phone to the deck.

### Modern iPhone: voice, camera and mic (optional)

Safari only allows the microphone, camera and speech recognition on **HTTPS** pages, so OldPhoneDeck creates a private certificate authority on your Mac (stored in `~/.oldphonedeck/tls`).

1. On the iPhone, open `http://<mac-ip>:8045/oldphonedeck.mobileconfig` and tap **Allow**.
2. **Settings → Profile Downloaded → Install.**
3. **Settings → General → About → Certificate Trust Settings** → turn on **OldPhoneDeck CA**. *(Easy to miss: without it Safari keeps saying "This Connection Is Not Private".)*
4. Open `https://<mac-ip>:8047/#k=<token>` and add it to the Home Screen.

**Camera → video calls:** in [OBS](https://obsproject.com), add a *Media Source* with `http://localhost:8045/camera.mjpg?k=<token>`, then click **Start Virtual Camera**.
**Mic → video calls:** install [BlackHole 2ch](https://existential.audio/blackhole/) and restart OldPhoneDeck; pick "BlackHole 2ch" as the microphone in your call app.
*(For plain FaceTime or Zoom calls, macOS's built-in Continuity Camera is simpler.)*

## How it works

```
iPhone (Safari)                     Mac: oldphonedeck (Swift, no dependencies)
┌──────────────────────┐  Wi-Fi    ┌───────────────────────────────────────────────────┐
│ deck page            │ ────────▶ │ :8045 HTTP   page, apps, stats                  │
│ (ES5 JavaScript so   │           │ :8047 HTTPS  same, for modern iPhones             │
│  iOS 8/9 can run it) │ ────────▶ │ :8048 WSS    camera frames + mic audio            │
└──────────────────────┘           └───────────────────────────────────────────────────┘
```

| Feature | Mac side |
|---|---|
| App keys | `NSWorkspace` lists `/Applications`, renders icons, opens apps |
| Top CPU | `ps -Aceo pcpu=,comm= -r` every 3 s |
| System | `host_statistics` (CPU), `host_statistics64` (RAM), volume capacity of `/`, and `softwareupdate -l` every 6 h for pending updates |
| Memory (tap RAM) | `top -l 1 -o mem` (footprint, grouped by parent app), `sysctl` for pressure and swap, `ollama ps` / `ollama stop` |
| Internet | `/usr/bin/networkQuality -c` + `en*` interface byte counters |
| Batteries | IOKit power sources, `ioreg -r -k BatteryPercent`, `system_profiler SPBluetoothDataType` |
| HTTPS | Local CA and server certificate generated with the built-in `openssl`, served as an iOS profile |

The whole phone UI is one file, [`Sources/oldphonedeck/web/index.html`](Sources/oldphonedeck/web/index.html). It's deliberately written in ES5 (no arrow functions, `let`, `fetch`…) so iOS 8/9 Safari can run it.

## Options

```
oldphonedeck --port 8045           # HTTP port (HTTPS = port+2, WebSocket = port+3)
oldphonedeck --mic-device NAME     # audio output that receives the phone's mic (default: BlackHole)
```

Settings live in `~/.oldphonedeck/`: `token` (the access code), `launcher.json` (your keys) and `tls/` (certificates).

## Security

- It listens on your **local network only**, and every request needs the random token from `~/.oldphonedeck/token`.
- Anyone with the link on your Wi-Fi can open apps on your Mac, so **treat the URL like a password** and **never port-forward it to the internet**.
- Delete `~/.oldphonedeck/token` to issue a new one.

## Troubleshooting

| Problem | Fix |
|---|---|
| Phone shows a blank page | Is the Mac on the same Wi-Fi? Check the printed IP. Old iOS can't run modern JavaScript, so if you edited `index.html`, keep it ES5. |
| "This Connection Is Not Private" | Finish step 3 of the HTTPS setup (Certificate Trust Settings). |
| Mic says "No audio device matching BlackHole" | Install BlackHole 2ch, or ignore it if you don't use the mic. |

## Built with Claude Code

This project was built in an evening with [Claude Code](https://claude.com/claude-code). Want your own variant? Point Claude Code at this repo and ask for changes like *"add a weather widget"*, *"make the keys run Shortcuts"* or *"add a Pomodoro timer"*. Ask it to keep `index.html` ES5 if you want old iPhones to keep working.

## License

[MIT](LICENSE)
