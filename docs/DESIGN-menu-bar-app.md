# UTM Watch menu bar app: implementation design

- Status: approved decisions recorded, 2026-11-10
- Scope: first version of the menu bar app, as agreed in the prototype (menu bar item, hover brief, detail window with trend tracks and history, right-click menu, Settings)
- Builds on: `UTMWatchCore`, the collection library already used by the `utmwatch` TUI and accepted in `docs/UAT-2026-11-09.md`

## 1. Recommendation in one paragraph

Build it as a **native Swift app**: an AppKit shell (status item, hover panel, windows) hosting SwiftUI views, with trend tracks drawn by SwiftUI `Canvas`, history in the system's SQLite, and the existing `UTMWatchCore` as the sampling engine. No third-party dependencies. This is the lowest-overhead option available on macOS, it is the only one that reuses the code we already verified, and every system feature the app needs (status item, launch at login, notifications, Automation permission) is a first-party Swift API.

## 2. Tech stack decision

### 2.1 What actually drives resource use and responsiveness

For this app the sampling work is a handful of system calls every 2 seconds. The language those calls are made from barely matters: Swift, Rust, C and Go would all measure within noise of each other. What does matter is **the UI runtime that sits in memory all day**:

| Option | UI runtime kept resident | Idle memory | Fit for this app |
|---|---|---|---|
| **Swift, AppKit + SwiftUI (recommended)** | none beyond system frameworks already loaded on every Mac | Measured: the `utmwatch` TUI on the same core holds 11 MB and 0.58% of a core. Expect roughly 30 to 60 MB with a window open (estimate, to be measured in the soak test) | Direct access to every API needed. Reuses `UTMWatchCore` unchanged |
| Rust + Tauri | a WKWebView process plus the Rust host | Published tests range from about 42 MB to 170 MB idle | Would require rewriting the verified core in Rust, or bridging Swift and Rust. Status item hover, launch at login and notifications go through plugins or custom Objective-C bridging |
| Electron | Chromium plus Node | Published tests range from about 128 MB to 400 MB idle | Exceeds the PRD's 80 MB budget before doing anything |
| Rust or C++ with native AppKit bindings | none | Similar to Swift | No memory advantage over Swift, much more glue code, no code reuse |
| Python (rumps / PyObjC) | CPython interpreter | Typically 40 to 80 MB, slower timers | Fine for a toy, weak for charts and history |

The published Tauri and Electron figures come from blog benchmarks that disagree with each other, and none of them includes a native Swift baseline, so treat them as orders of magnitude. Our own measurement of the Swift core is the only controlled number here.

**Conclusion:** Swift is the ideal language for this app. Not because Swift is faster than Rust at arithmetic, but because it is the only choice that adds no runtime, needs no bridge to the system APIs, and keeps the code that already passed acceptance.

### 2.2 Stack components

| Concern | Choice | Why |
|---|---|---|
| Language / build | Swift 6 toolchain, SwiftPM | Already in use; builds with the Command Line Tools on this Mac |
| App shell | AppKit: `NSApplication` as an agent app (`LSUIElement`), `NSStatusItem`, `NSPanel`, `NSWindow` | SwiftUI's `MenuBarExtra` cannot open on hover and does not expose its status item, so the hover brief needs AppKit |
| Views | SwiftUI hosted with `NSHostingView` | Fast to build the table, tiles and Settings form |
| Trend tracks | SwiftUI `Canvas` drawing our own paths | See 2.3 |
| History store | SQLite through the system `libsqlite3` (C API via the existing shim target) | Zero dependency, single file, fast range queries, trivial "Clear data" |
| Sampling | `UTMWatchCore.MonitorEngine` on a background `DispatchSourceTimer` | Unchanged from the TUI |
| Settings | `UserDefaults` | Six simple values |
| Launch at login | `SMAppService.mainApp` | Current first-party API, no helper bundle |
| AI diagnosis | MCP helper executable over stdio, reading the history database | No model in the app; any MCP-capable agent can diagnose |
| UTM names/states | `NSAppleScript` in-process (replaces the `osascript` subprocess) | No process spawn every 10 s; permission is attributed to the app itself |

All of these frameworks are present in the Command Line Tools SDK on this machine (checked: Charts, SwiftUI, AppKit, ServiceManagement, UserNotifications, libsqlite3).

### 2.3 Why not Swift Charts for the tracks

Swift Charts is the obvious candidate and it is available, but developer reports describe it struggling with a few thousand points, especially with interaction. The prototype's tracks are simple (two lines per track, two gridlines, a shared crosshair), so drawing them directly in a `Canvas` is about 150 lines, has predictable cost, and gives exact control over the shared time axis and the pin line. Data is always reduced to at most one min/max pair per horizontal pixel before drawing, so a 7-day view costs the same to draw as a 5-minute view.

## 3. Architecture

```
                    ┌──────────────────────────── UTMWatch.app (one process) ────────────────────────────┐
                    │                                                                                      │
 kernel / UTM  ───▶ │  Sampler (background queue)          Store (SQLite, own queue)                        │
 libproc, sysctl,   │   MonitorEngine.tick() every N s ──▶  append batch every 10 s                         │
 ifconfig, UTM      │        │                               1-minute rollups, retention pruning            │
                    │        ▼                                          ▲                                   │
                    │  LiveBuffer (in memory, last 60 min)              │ range queries (async)             │
                    │        │                                          │                                   │
                    │        ▼                                          │                                   │
                    │  AppModel (@MainActor, @Observable) ◀─────────────┘                                   │
                    │        │                                                                              │
                    │        ├─▶ Status item title        ├─▶ Hover brief panel                             │
                    │        ├─▶ Detail window (table, tiles, tracks)   ├─▶ Settings window                 │
                    │        └─▶ AlertEngine ─▶ events table + notifications                                │
                    └──────────────────────────────────────────────────────────────────────────────────────┘
```

Single process, three execution contexts:

- **Sampler queue** (utility QoS): the only place that touches the kernel APIs. Produces one `Snapshot` per tick.
- **Store queue**: owns the SQLite connection. Receives snapshots, answers range queries.
- **Main actor**: UI state only. Never blocks on sampling or disk.

### 3.1 Package layout

```
Sources/CSysShim/          existing; gains thin sqlite3 re-export
Sources/UTMWatchCore/     existing, unchanged API
Sources/UTMWatchStore/    new: schema, writer, range queries, rollups, retention
Sources/UTMWatchApp/      new: AppKit shell, SwiftUI views, AlertEngine, Settings
Sources/utmwatch/             existing TUI, kept as a diagnostic tool
Sources/selftest/          existing; gains store and alert-rule checks
Scripts/make-app.sh        assembles and signs UTMWatch.app from the SwiftPM build
```

## 4. Component design

### 4.1 Sampling and recording

- The timer fires at the configured interval (1, 2 or 5 s) with a small leeway so macOS can coalesce wakeups.
- Sampling runs whether or not any window is open; that is what makes history possible.
- Each snapshot goes to (a) the in-memory `LiveBuffer` and (b) a pending batch for the store.
- Rates always use the monotonic clock and real elapsed time, as in the TUI. Stored timestamps are wall-clock UTC milliseconds.
- Changing the interval in Settings re-arms the timer immediately.

### 4.2 History store

One SQLite file at `~/Library/Application Support/UTM Watch/history.sqlite`, WAL mode.

| Table | Columns | Purpose |
|---|---|---|
| `vm` | id, uuid, name, backend | One row per VM ever seen (unidentified VMs keyed by a synthetic id) |
| `vm_config` | vm_id, ts, cores, mem_bytes | Written when a limit changes, so past moments show the limit that applied then |
| `sample` | ts, vm_id, cpu_cores, mem_bytes, down_rate, up_rate, down_total, up_total | Raw samples, primary key (vm_id, ts) |
| `host_sample` | ts, used, other_used, pressure, swap_used, swap_total | Host context for the tiles and the pressure track |
| `sample_1m` | minute, vm_id, min/avg/max of cpu, mem, down, up | Rollup used for long time frames |
| `event` | ts, kind, vm_id, detail | VM started/stopped, alert raised/cleared |

Behaviour:

- **Writes** are batched: one transaction every 10 seconds, so the disk is touched 6 times a minute, not 30.
- **Rollups**: when a minute completes, its min/avg/max row is written to `sample_1m`.
- **Tier selection**: time frames up to 1 hour read raw samples; longer ones read `sample_1m`. Either way the result is reduced to one min/max pair per pixel before it reaches the view. Zooming into any past moment always gets raw resolution.
- **Retention** (1, 7 or 30 days): a prune runs hourly and deletes rows older than the setting from every table.
- **Clear data**: closes the connection, deletes the file, recreates the schema. Recording continues from that moment.
- **Gaps**: when the Mac sleeps or the app is not running there are no rows. The tracks break the line across any gap longer than three sample intervals and never interpolate.

Size estimate at a 2 s interval with two VMs: about 130,000 rows a day, roughly 6 MB a day including indexes, so about 45 MB for 7 days and under 200 MB for 30 days. To be confirmed by measurement.

### 4.3 Menu bar item and hover brief

- `NSStatusItem` with variable length; title such as `2 VM · 4.2 cores`, updated only when the text changes.
- Three states as in the prototype: normal, alert active (warning glyph), no VM running.
- **Left click** opens or focuses the detail window. **Right click** shows an `NSMenu`: Open UTM Watch, Settings, Quit.
- **Hover**: macOS 26 draws status items inside Control Center's process, so the button receives no tracking-area events, and global mouse-moved monitors are not delivered either (both confirmed in the A0 spike). The app instead reads the pointer position on a 0.15 s timer with tolerance and tests it against the item's frame. After about 200 ms inside, a borderless non-activating `NSPanel` appears under the item with the brief. It closes when the pointer leaves both the item and the panel. The panel does not take focus, so it never interrupts typing.

### 4.4 Detail window

Matches artboards 2 and 3 of the prototype.

- **Time frame model**: `(length, end)` where `end == nil` means live. Presets, the arrows and Jump to only change these two values. A pinned moment is an absolute timestamp, independent of the visible frame.
- **Live mode** reads from `LiveBuffer` for frames up to 60 minutes: no disk access, so the window updates the instant a sample arrives.
- **History mode** issues one async range query per change of time frame. Queries are cancellable, so dragging through history never queues up stale work.
- **Readout**: the table, tiles and track values show the pinned moment, else the hovered moment, else now (or the end of the range). Hover lookups are a binary search in arrays already in memory; no query per mouse move.
- **Tracks**: Events, Host pressure, CPU, Memory, Network down, Network up, all on one shared time axis with one crosshair.
- When the window is closed, none of this runs; only the status item title updates.

### 4.5 Events and AI diagnosis through MCP

Decided 2026-11-10: no configurable alert rules and no model inside the app. The app records what happened; an AI agent the user already has (for example Claude) reads that record through MCP and works out the cause.

**In the app**

- `EventDetector` (built) logs VM starts and stops, memory pressure changes, swap crossing 80%, and a VM held above 90% of its cores for 60 s. Events show on the Events track and turn the menu bar item to its warning state while one is active.
- **Process capture**: when a warning event fires, the app records the top five host processes by memory footprint and by CPU (name, pid, footprint, CPU share) into the event row. This is what lets an agent say *why* memory ran short. It reads only process names and totals through `libproc`, needs no extra permission, and can be switched off in Settings.
- The detail window gets an "Ask AI about this moment" button on a pinned moment. It copies a ready-made prompt naming the time, so the hand-off to an agent is one paste.

**The helper: `utmwatch-mcp`**

- A separate small executable inside the app bundle. It speaks MCP over standard input/output (JSON-RPC 2.0, one message per line): `initialize`, `tools/list`, `tools/call`. No SDK dependency; the protocol surface needed is small.
- The agent starts it on demand and it exits when the agent disconnects. No network port, no background process, no cost while unused.
- It opens the history database read-only (WAL mode allows a reader alongside the app's writer). For "now" it reads the newest recorded sample, which is at most about 10 s old, so it needs no permissions of its own.
- It refuses to serve if "Let AI agents read history" is off in Settings.

| Tool | Input | Returns |
|---|---|---|
| `get_status` | none | Latest sample: each VM's CPU, memory, network, limits; host allocatable memory, swap, pressure; age of the sample |
| `list_events` | `from`, `to` | Events in the range, each with its captured top processes |
| `summarize` | `from`, `to` | Per VM and host: average, peak and peak time per metric, time under pressure, largest changes, data gaps |
| `get_moment` | `time` | Every value at that time, as in the pinned view, plus the nearest event |
| `get_metrics` | `vm`, `metric`, `from`, `to`, `points` (max 500) | One metric's trend for one VM, reduced to the requested number of points with averages and peaks |

Times are ISO 8601 with offset; relative forms such as `-2h` are accepted for `from`. Results are compact JSON with units in the field names. Every tool is read-only and bounded in size.

**Limits**

- MCP is pull: nothing is diagnosed until the user asks an agent. The menu bar warning state is what tells the user something happened.
- Causes inside a VM (which guest process used the CPU) are not visible without a guest agent; the tools report that the VM was the one under load, not what inside it.
- With a cloud agent, VM names, process names and usage figures leave the Mac when the agent reads them.

### 4.5.1 Connection-quality signals (for "the VM is sometimes slow to connect to")

Target use case (Darrick, 2026-11-10): a client reaches a VM through UU Remote and reports that connecting is slow at unpredictable times. Darrick is away from the Mac and wants an agent to find the cause without relying on the client for times. The Mac mini may be on Wi-Fi or Ethernet; both must be supported.

UU Remote runs inside the guest and connects outward (peer-to-peer where possible, relayed otherwise), so there is no fixed inbound port on the VM to test. The app therefore measures each segment it can see and lets the agent rule segments in or out:

| Signal | How | Cadence | What it answers |
|---|---|---|---|
| VM responsiveness | ICMP echo from the host to each VM's address on the NAT bridge (address found from the ARP table by MAC; unprivileged datagram ICMP socket) | 10 s | Was the guest itself slow or frozen? |
| Local network | ICMP echo to the default gateway, 3 packets | 30 s | Was the Wi-Fi or LAN hop bad? |
| Internet path | ICMP echo to two public anchors (configurable), 3 packets each | 30 s | Was the uplink slow or dropping packets? |
| Link state | Active interface and type; on Wi-Fi: signal, noise, transmit rate, channel (CoreWLAN, no location permission needed since the network name is not read); on Ethernet: link speed and interface error counters | 30 s, plus an event on change | Did the link weaken, roam, or switch? |
| Sleep and wake | `NSWorkspace` sleep/wake notifications as events | on change | Was the Mac asleep, so the first connection had to wake it? |
| Host CPU | Busy cores across the whole Mac | every sample | Was the Mac's processor saturated by something else? |
| VM disk activity | Read and write bytes per second per VM process (`proc_pid_rusage`) | every sample | Was the VM stalled on disk? |
| Likely remote sessions | Derived: sustained upload from a VM (screen streaming) marks a period when someone was probably connected | derived at query time | When was the client actually using it? (heuristic, labelled as such) |

Storage: latency and loss go in a `probe` table (target, rtt_ms, loss) with the same rollup and retention rules; link state and host CPU extend `host_sample`; disk rates extend `sample`.

UI: two more tracks, "Responsiveness" (VM ping time, per VM) and "Network path" (gateway and internet latency, with loss marked), and a Link tile showing Wi-Fi signal or Ethernet speed.

Additional MCP tool, because the client usually cannot say when it was slow:

| Tool | Input | Returns |
|---|---|---|
| `find_incidents` | `from`, `to` | Ranked periods where any signal was abnormal (latency spike, packet loss, weak or changed link, sleep, memory pressure, swap, CPU limit, host CPU saturated), each with which segment was affected and whether a remote session was likely active |

`get_moment`, `summarize` and `get_metrics` gain the new fields.

What stays invisible: the client's own network, UU Remote's relay servers, and slowness inside the guest after the connection is up. The agent can state that the Mac, its link and its uplink were healthy at a given time, which localizes the fault to the other side.

Cost: about 10 small packets a minute per VM plus 18 a minute for the path; negligible CPU. The anchors receive only pings.

### 4.6 Settings, launch at login, quit

- Settings window as in artboard 5: launch at login, sample interval, network units, retention, Clear data, AI diagnosis (allow agents to read history, the command to connect an agent, process capture at events), permission status, Quit.
- Launch at login registers the app with `SMAppService`; the switch reflects the system's actual state, since the user can also change it in System Settings.
- Permission status is checked, not assumed: Automation by attempting the UTM query, container access by attempting to read a `config.plist`. Denied states degrade exactly as the TUI does.
- Quit flushes the pending batch, closes the store, and exits.

## 5. Performance design

Budgets come from the PRD: under 1% of one core on average, under 80 MB, first data within 3 seconds, no growth over time.

| Risk to the budget | Design answer |
|---|---|
| UI work on every sample | Views observe only what they show. With no window open, a tick ends after updating one string |
| Disk I/O on every sample | 10-second batched transactions in WAL mode |
| Drawing long time frames | Rollup tier plus per-pixel min/max reduction; draw cost is bounded by window width |
| Hover and scrubbing lag | Readout from in-memory arrays; history queries async and cancellable |
| Memory growth | `LiveBuffer` is a fixed-size ring; history arrays are replaced, never appended; autorelease pool per tick (the leak found in the TUI soak) |
| Slow or hung UTM / permission prompts | Already isolated in `MonitorEngine`: slow sources run off the sampling path with back-off |
| Subprocess cost | UTM query moves in-process. `ifconfig` for the bridge table stays, but only runs on VM start/stop and every 10 s |

Verification: the same soak used for the TUI (one hour, sampled every 5 minutes) on the finished app, once with the window closed and once with it open in live mode.

## 6. Build, signing and distribution

- `swift build -c release`, then `Scripts/make-app.sh` assembles `UTMWatch.app`: the binary, an `Info.plist` (bundle identifier, `LSUIElement`, `NSAppleEventsUsageDescription`), and an icon, then signs it.
- **Signing matters for permissions.** macOS ties the Automation and app-data permissions to the app's code signature. An ad-hoc signature changes on every build, so the permission prompts would return after each rebuild. The script will sign with a stable local identity instead.
- Xcode is installed for its Apple Development signing certificate. The build itself stays on SwiftPM plus the packaging script.
- Install by copying the app to `/Applications`.

## 7. Risks and open points

| # | Item | Impact | Plan |
|---|---|---|---|
| T1 | Hover on a status item | Resolved in the A0 spike: tracking areas do not work on macOS 26, pointer polling does | Keep the polling approach; re-test after macOS updates |
| T2 | Stable signing identity | Repeated permission prompts | Apple Development certificate from Xcode (decided). Needs Xcode installed and an Apple ID added in Xcode's Accounts settings |
| T3 | Notifications | Dropped from the first version in favour of the menu bar warning state and MCP diagnosis | Revisit if the warning state proves too easy to miss |
| T4 | Store size and query speed at 30 days are estimates | Disk use, slow 7-day view | Measure with generated data before enabling the 30-day option |
| T5 | Bridged-network VMs and non-UTM VM names | Missing network columns | Unchanged from the PRD: out of scope for this version |

Decisions made (Darrick, 2026-11-10):

1. **Signing**: install Xcode and sign with an Apple Development certificate. `make-app.sh` signs with that identity; building can stay on SwiftPM.
2. **Raw history**: keep full-resolution samples for the whole retention period, with 1-minute rollups alongside for long time frames.

## 8. Milestones

| Step | Content | Estimate |
|---|---|---|
| A0 | Spike: status item, hover panel, signing identity, one test notification (retires T1 to T3) | 0.5 day |
| A1 | App shell: status item title and states, right-click menu, hover brief on live data | 1 day |
| A2 | Store: schema, batched writer, rollups, retention, Clear data, self-checks | 1 day |
| A3 | Detail window, live: table, tiles, tracks, crosshair readout | 1.5 days |
| A4 | History: time frames, arrows, Jump to, pin, Events and pressure tracks | 1 day |
| A5 | Settings, launch at login, permission status (done); process capture at events; MCP helper and its Settings section | 1 day |
| A6 | Packaging script, one-hour soaks, acceptance run against the PRD | 0.5 day |

## Sources consulted

- Tauri vs Electron memory and CPU comparisons: https://dev.to/gethopp/tauri-vs-electron-performance-bundle-size-and-the-real-trade-offs-1el4 , https://betterstack.com/community/guides/scaling-nodejs/tauri-vs-electron-vs-deno-vs-electrobun/ , https://www.levminer.com/blog/tauri-vs-electron
- `MenuBarExtra` limits and status item access: https://www.github.com/orchetect/MenuBarExtraAccess
- Status item hover regressions on recent macOS: https://developer.apple.com/forums/thread/836113
- Swift Charts with many points: https://developer.apple.com/forums/thread/740314 , https://developer.apple.com/forums/thread/763757
- Stats, an existing Swift menu bar monitor: https://github.com/exelban/stats
