# UTM Watch Fleet: design

Approved 2026-11-11 from the "UTM Watch Fleet" prototype (7 artboards, light and dark). This records what was approved
and how it is built. The single-Mac app is described in `DESIGN-menu-bar-app.md` and is unchanged when no fleet is set up.

## 1. What a fleet is

Several Macs running UTM Watch report to one **hub**. Any Mac in the fleet can open the **fleet window** and see every
Mac's VMs. It is the same app everywhere: a Mac is in a fleet only once it has joined one or hosts the hub.

- Monitoring only. The hub has a reserved command channel; nothing uses it yet.
- One hub serves one owner's fleet. There are no accounts.
- Free and open source, like the rest of the app.

## 2. Parts

```
Mac (member)                      Hub                               Any Mac (fleet window)
sampler -> local SQLite           utmwatch-hub + hub.sqlite         FleetController polls /v1/hosts
Uploader -> POST /v1/ingest ----> ingest, rollups, offline events   drill-in: DetailView fed by the hub
```

| Part | Where | Notes |
|---|---|---|
| Wire types, pairing code, SHA-256 | `Sources/UTMWatchModel/Wire.swift` | Foundation only |
| Hub database | `Sources/UTMWatchStore/HubStore.swift` | Same tables as the local store plus a host dimension; reads go through `HistoryReader`, shared with `HistoryStore`, so a Mac's history from the hub equals what that Mac reads locally (asserted in `selftest`) |
| Hub API, client, uploader, identity | `Sources/UTMWatchFleet/` | `HubService` has no transport, so tests call it in process |
| Hub server and command line | `Hub/` (nested package) | Hummingbird stays out of the app's build |
| Private network helper | `Net/` (Go, `tsnet`) | An embedded Tailscale node; see section 6 |
| App side | `Sources/UTMWatchApp/FleetController.swift`, `FleetView.swift` | Runs the hub and helper as child processes |

The app bundle carries `utmwatch-hub` and `utmwatch-net` beside `utmwatch-mcp` (`Scripts/make-app.sh`).

## 3. Joining

The hub Mac makes a **pairing code**: one string, `utmw1.` followed by the hub's address, a single-use enrolment token
(15 minutes) and, when the fleet spans networks, the network key. The other Mac pastes it into Settings › Fleet.

- The hub answers with the Mac's own upload token and its own reader token, saved in `fleet.json` (mode 0600) in the
  app's data folder. The hub keeps only hashes.
- Joining again keeps the Mac's UUID, so its history stays; the old tokens stop working.
- Revoking a Mac on the hub ends both its uploads and its view of the fleet.
- The hub Mac enrols itself the first time hosting is switched on, so it appears in its own fleet.

## 4. Reporting

The local database is the queue. The uploader keeps three cursors in the local `meta` table (samples, pings, event row
id) and every ten seconds sends what lies after them, in slices of five minutes while catching up. The first upload
carries the last 24 hours. If the hub cannot be reached the Mac keeps recording and continues from its cursors later,
waiting longer between attempts (up to five minutes).

The hub stores a Mac's timestamps as sent and judges online or offline by its own clock. A Mac silent for 60 seconds
is **offline**, or **asleep** if the last thing it said was that it was going to sleep; the hub writes
`host_offline` / `host_asleep` / `host_online` on the fleet timeline, once per change.

Retention on the hub: raw samples 48 hours, 1-minute rollups and events 90 days.

## 5. The fleet window

**Overview.** One table. Each Mac is a grey row: name, pills ("This Mac", "Hub", "Clock 14 s ahead", "Older version"),
state, CPU busy, memory free for VMs with a warning mark under pressure or high swap, network link, app version.
Its VMs follow: state, CPU meter, memory in RAM over memory held, network down and up. Macs are in alphabetical order
with an "All / Needs attention" filter. A Mac that is not reporting collapses to one line ("3 VMs · 3 were running
when this Mac stopped reporting"). With no fleet, the window explains what a fleet is and points to Settings.

**Drill-in.** Clicking a Mac shows it in the same detail view this Mac has for itself, inside the fleet window, with a
"‹ Fleet" button. Differences for another Mac: history comes from the hub and is asked again every five seconds while
live; "now" is that Mac's newest sample; there is no rename pencil (names are changed on that Mac) and no
"Ask AI about this moment"; the swap row carries the Mac's name; the footer says where the data comes from.

**Settings › Fleet** has three states: not in a fleet (name, pairing code, "Host the hub on this Mac"); reporting
(status, hub, name, "Report this Mac's VMs", notifications, a new code, "Leave fleet…"); hosting (switch, hub address,
"New pairing code", enrolled Macs with "Revoke…", "Connect Macs on other networks").

**Menu.** "Open Fleet" sits under "Open UTM Watch" and is always there.

**Alerts.** A Mac that can read the fleet polls its events and posts a notification when another Mac has memory
pressure, high swap, a VM at its CPU limit, a weak or lost link, or stops reporting. This Mac's own trouble stays in
its menu bar item, as before.

## 6. Macs on other networks

On one network the hub is reached at `http://<name>.local:<port>`. For Macs elsewhere, the owner pastes one auth key
from their own Tailscale account on the hub Mac. `utmwatch-net` then joins that network as a userspace node: no
Tailscale app, menu bar item, VPN entry or root, and a Tailscale already on the Mac is left alone. Pairing codes made
afterwards carry the key and the hub's private address, so other Macs join without seeing Tailscale. The app talks to
the hub through the helper's loopback proxy.

Beside a Tailscale of the user's own: the helper keeps its state in the app's data folder, picks its own UDP and
loopback ports, creates no network interface and changes no routes or DNS. A hub on the private network is only ever
reached through the helper's proxy, never directly, because the same address can belong to another machine on the
user's own tailnet; when the helper is not running the hub reads as unreachable.

Recommended key: reusable, tagged, pre-approved, not ephemeral. Tagged nodes do not expire.

## 7. Known limits

- A hub hosted by the app runs while that Mac is on and logged in.
- The hub listens on all of the hub Mac's interfaces, in plain HTTP; only enrolled Macs get anything from it. It is
  meant for a trusted LAN or the private network, never the open internet.
- The app allows plain HTTP generally (`NSAllowsArbitraryLoads`), because a hub's address is whatever the user's
  network gives it. The update check still requires https itself.
- Every enrolled Mac can read the whole fleet.
- Ad-hoc signed builds make macOS ask for permissions again after each update, on every Mac.
- Testing aids: `UTMWATCH_DATA_DIR` moves the app's files; `UTMWATCH_NO_UTM=1` keeps a trial copy away from UTM;
  `utmwatch fleet sim` imitates Macs; `--snapshot-fleet <png>` pictures the fleet window.
