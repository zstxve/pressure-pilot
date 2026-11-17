# pressure-pilot

macOS menu bar app that watches the kernel's memory pressure level and, when memory runs critical, frees RAM by freezing or quitting apps you have marked as expendable. For people whose Mac slows down under memory pressure and who want control over which apps give way first.

![Menu bar popover](docs/screenshot.png)
<!-- TODO: screenshot of the menu bar popover -->

## Features

- Reads the same memory pressure level (`kern.memorystatus_vm_pressure_level`) that drives the graph in Activity Monitor, plus RAM, compressed memory and swap
- Lists running apps by memory footprint, with helper processes (e.g. Safari's WebContent) attributed to their app
- Per-app rule: protected, normal or expendable
- Escalation: yellow pressure triggers a notification suggesting the biggest candidates; red pressure freezes expendable apps one by one (`SIGSTOP`), then quits them like Cmd+Q, optionally force-quits after 60 s
- Never touches protected apps, the frontmost app or apps currently playing audio
- Frozen apps are always resumed on quit, `SIGTERM`, logout and after a crash
- Leak detection: flags apps whose memory floor keeps rising (at least 500 MB and 30 % over the window)
- 7-day statistics: time in yellow/red, interventions, memory freed, and red-phase duration with vs. without intervention; raw data as JSON Lines
- Optional launch at login
- UI in German

## Tech stack

Swift 5.10 · SwiftUI (`MenuBarExtra`) · Swift Package Manager · Darwin / libproc / CoreAudio APIs · XCTest

## Quick start

Requires macOS 13+ and Xcode command line tools.

```bash
git clone https://github.com/zstxve/pressure-pilot.git
cd pressure-pilot
swift test               # 7 tests
./build.sh --install     # builds, ad-hoc signs, copies to ~/Applications and starts the app
```

`./build.sh` without `--install` only builds `build/PressurePilot.app`.

## Usage

Click the memory chip icon in the menu bar. Mark apps you can do without (browsers with many tabs, chat clients) as *expendable*, then enable automatic relief. A frozen app resumes when you click its sun icon or "thaw all". Statistics are stored in `~/Library/Application Support/PressurePilot/stats.jsonl`.

## Project structure

```
Sources/PressurePilot/
├── App.swift           menu bar entry point and status icon
├── Pilot.swift         escalation logic: suggest, freeze, quit, thaw; notifications
├── Memory.swift        pressure level, memory stats, per-app footprint scanner
├── LeakDetector.swift  steady-growth detection on per-minute samples
├── Stats.swift         JSON Lines log and 7-day summary
├── Audio.swift         which processes are playing audio (CoreAudio)
└── PilotView.swift     SwiftUI popover
Tests/PressurePilotTests/   leak detector and statistics tests
```

## Technical decisions

Freezing with `SIGSTOP` comes before quitting because a stopped process keeps its state while macOS can compress or swap out its untouched memory; quitting is the fallback. The hard part was safety: a stopped app left behind would block logout, so frozen PIDs are persisted and resumed on every exit path, including after a crash. Attributing helper processes to their app relies on a private libsystem call (`responsibility_get_pid_responsible_for_pid`, also used by Activity Monitor), loaded via `dlsym` so the app still runs if it disappears.

## Possible extensions

- English localisation
- Signed and notarised release build
- Configurable thresholds for leak detection and escalation timing

## License

MIT, see [LICENSE](LICENSE).
