# OldPhoneDeck

**Turn an old iPhone into a Stream Deck–style control panel for your Mac.**
No jailbreak, no App Store, nothing to install on the phone: it runs in Safari, even on an iPhone 4S stuck on iOS 9.

![An iPhone 4S on a desk stand running OldPhoneDeck](docs/desk.jpg)

| The deck | Pick your apps |
|---|---|
| ![Deck](docs/deck.jpg) | ![Pick apps](docs/pick-apps.jpg) |

## Features

- **4 big keys:** a 2x2 grid of Mac apps of your choice. Tap a key and the app opens on your Mac. Hold any key to pick apps.
- **Top memory:** the three biggest apps by memory (helper processes rolled up under their app), plus the loaded Ollama model when there is one. Tap it, or tap RAM, for the full list. The four status cards (Internet, System, Batteries, Top memory) form a 2x2 grid beside the keys.
- **Attention strip:** stays hidden until something needs you (memory pressure or heavy swap, low disk, pending macOS updates, CPU throttling, a failed LaunchAgent, weak Wi-Fi), and turns red with "Offline · last seen …" if the Mac stops answering.
- **Internet widget:** download, upload and ping (macOS's built-in `networkQuality`, re-run every 6 hours), a live traffic graph, and the link in use (Wi-Fi rate or Ethernet speed). Tap it to re-test.
- **Batteries widget:** MacBook, Magic Keyboard / Mouse / Trackpad and AirPods (with case), each as an icon + percentage.
- **System widget:** RAM (coloured by memory pressure, with swap), CPU, free disk space and the Mac's uptime. Tap RAM for the top apps by memory, memory pressure and swap (plus an Unload button for a loaded Ollama model).
- **Fits any iPhone:** a compact 480×320 layout on old phones; full-width landscape and a portrait layout on modern ones.

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

## How it works

```
iPhone (Safari)                     Mac: oldphonedeck (Swift, no dependencies)
┌──────────────────────┐  Wi-Fi    ┌───────────────────────────────────────────────────┐
│ deck page            │ ────────▶ │ :8045 HTTP   page, apps, stats                    │
│ (ES5 JavaScript so   │           │                                                   │
│  iOS 8/9 can run it) │           │                                                   │
└──────────────────────┘           └───────────────────────────────────────────────────┘
```

| Feature | Mac side |
|---|---|
| App keys | `NSWorkspace` lists `/Applications`, renders icons, opens apps |
| System | `host_statistics` (CPU), `host_statistics64` (RAM), volume capacity of `/`, and `softwareupdate -l` every 6 h for pending updates |
| Memory (tap RAM) | `top -l 1 -o mem` (footprint, grouped by parent app), `sysctl` for pressure and swap, `ollama ps` / `ollama stop` |
| Internet | `/usr/bin/networkQuality -c` + `en*` interface byte counters |
| Batteries | IOKit power sources, `ioreg -r -k BatteryPercent`, `system_profiler SPBluetoothDataType` |
| Health | `kern.boottime` (uptime), `pmset -g therm` (throttling), `launchctl list` (failed agents in `~/Library/LaunchAgents`), `route`/CoreWLAN/`ifconfig` (network link) |

The whole phone UI is one file, [`Sources/oldphonedeck/web/index.html`](Sources/oldphonedeck/web/index.html). It's deliberately written in ES5 (no arrow functions, `let`, `fetch`…) so iOS 8/9 Safari can run it.

## Options

```
oldphonedeck --port 8045           # HTTP port
```

Settings live in `~/.oldphonedeck/`: `token` (the access code), and `launcher.json` (your keys).

## Security

- It listens on your **local network only**, and every request needs the random token from `~/.oldphonedeck/token`.
- Anyone with the link on your Wi-Fi can open apps on your Mac, so **treat the URL like a password** and **never port-forward it to the internet**.
- Delete `~/.oldphonedeck/token` to issue a new one.

## Troubleshooting

| Problem | Fix |
|---|---|
| Phone shows a blank page | Is the Mac on the same Wi-Fi? Check the printed IP. Old iOS can't run modern JavaScript, so if you edited `index.html`, keep it ES5. |

## Built with Claude Code

This project was built in an evening with [Claude Code](https://claude.com/claude-code). Want your own variant? Point Claude Code at this repo and ask for changes like *"add a weather widget"*, *"make the keys run Shortcuts"* or *"add a Pomodoro timer"*. Ask it to keep `index.html` ES5 if you want old iPhones to keep working.

## License

[MIT](LICENSE)
