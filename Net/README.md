# utmwatch-net (phase F3d spike)

A small helper that embeds a userspace Tailscale node (`tailscale.com/tsnet`) so UTM Watch
can reach a fleet hub on another LAN without the user installing or seeing Tailscale.
It is a plain Go program run as a child process; `libtailscale` was not needed.

**Verdict: go.** See [Spike result](#spike-result-2026-11-11) for measurements and gotchas.

## Build

Needs Go 1.27 or newer (`brew install go`). No cgo, so both targets build on a Mac.

```bash
./build.sh
```

This writes `bin/utmwatch-net-darwin-arm64` and `bin/utmwatch-net-linux-amd64`.

## Run

Client mode (agents and the fleet-view Mac): a loopback proxy that dials through the tailnet.
The one port accepts HTTP proxy requests (plain and `CONNECT`) and SOCKS5.

```bash
TS_AUTHKEY=tskey-auth-... ./bin/utmwatch-net-darwin-arm64 -dir /path/to/state -proxy 127.0.0.1:18802
```

Hub mode: the same, plus a tailnet port forwarded to a local port.

```bash
TS_AUTHKEY=tskey-auth-... ./bin/utmwatch-net-darwin-arm64 -dir /path/to/state -forward 8787=127.0.0.1:8787
```

Then, from a client Mac:

```bash
curl -x http://127.0.0.1:18802 http://<hub-hostname>:8787/
```

| Flag | Meaning |
|---|---|
| `-dir` | State directory (required). The only place the helper writes. |
| `-hostname` | Node name on the tailnet. Default `utmwatch-<machine name>`. |
| `-proxy` | Loopback address for the proxy. Default `127.0.0.1:0` (a free port, reported in the `ready` line). |
| `-forward` | `TAILNET_PORT=HOST:PORT`, repeatable. Turns on hub mode. |
| `-authkey-file` | File holding the auth key, or `-` to read one line from stdin. `TS_AUTHKEY` also works. |
| `-tags` | Tags to advertise, for example `tag:utmwatch`. |
| `-ephemeral` | Register as an ephemeral node. |
| `-join-timeout` | How long to wait for the join. Default 60 s. |
| `-verbose` | Tailscale backend logs on stderr. |
| `-upload-logs` | Allow log upload to log.tailscale.com (off by default here). |

The auth key is needed only for the first join; afterwards the node key in `-dir` is enough.
Never pass the key as a command-line argument: it would show in `ps`.

Status is one JSON object per line on stdout, human-readable logs go to stderr:

```json
{"event":"ready","hostname":"utmwatch-spike-hub","dnsName":"utmwatch-spike-hub.<tailnet>.ts.net","ips":["100.x.y.z","fd7a:..."],"proxy":"127.0.0.1:18801","forwards":["8787->127.0.0.1:18787"],"tailnet":"...","keyExpiry":"2027-05-10T11:55:15Z"}
```

Other events: `needs-login` (no usable key; the URL must not be opened by the app), `error`, `stopping`.

## Spike result (2026-11-11)

Tested on a Mac mini (Apple silicon, macOS 26.6.2) with Tailscale.app running and connected,
tsnet v1.104.6, Go 1.27.4. Two helper processes with separate state directories ran on this one Mac.

| Question | Result |
|---|---|
| Joins with an auth key, no login UI | Yes. First join took 1.9 s and 2.1 s; a restart with no key took 0.2 s. Without a key it prints a login URL and never joins, which the helper reports as `needs-login`. |
| Menu bar, System Settings VPN list, Tailscale app | Nothing appears. `scutil --nc list`, the `utun` interface list and the route count were identical before and during the run, and the helper never registered as a GUI app. It uses no TUN device, no system extension, and needs no root. |
| System Tailscale unaffected | Its state, addresses and prefs were unchanged and it kept working. **Not fully tested:** the key supplied was for the same tailnet the Tailscale app is signed in to, so the only visible effect was the two new nodes in its peer list. A different-account run is still owed; nothing observed suggests it would differ, because the helper shares no state, interface or socket with the app. |
| HTTP from one embedded node to a local server behind another | Yes, over HTTP proxy, `CONNECT` and SOCKS5, by tailnet IP, MagicDNS name and short name. First request 35 ms, then about 2 ms. A closed port returns 502 at once. |
| How long a node stays authorised | An untagged node gets Tailscale's default node-key expiry: 180 days (the test nodes expire 2027-05-10). A node joined with a **tagged** key has key expiry disabled by default. The auth key's own expiry (at most 90 days) does not affect nodes already joined. |
| Size added | 20.0 MB on disk for macOS arm64 (21.7 MB for linux amd64); 7.7 MB and 8.4 MB gzipped. Unstripped it is 30.3 MB. |
| Builds for macOS arm64 and linux amd64 | Yes, both from this Mac with `CGO_ENABLED=0`. The Linux binary is statically linked. It was built but not run. |
| Runtime cost | About 38 MB resident memory and 0.07 s CPU per 20 s when idle. State directory is 48 KB. |

### Auth key the fleet owner should create

Reusable, tagged (for example `tag:utmwatch`), pre-approved if the tailnet has device approval on,
not ephemeral, expiry at the 90-day maximum.

- Reusable, because one key is embedded in the pairing code and joins every Mac.
- Tagged, so nodes never expire and are owned by the tag rather than a person. The tag must first be
  declared under `tagOwners` in the tailnet policy file, which is one extra step for the owner.
  It also allows an access rule that limits `tag:utmwatch` nodes to the hub port.
- Not ephemeral, because an agent Mac that sleeps for a while would be removed and could not rejoin
  once the key has expired.
- After 90 days adding a new Mac needs a fresh key; Macs already joined are unaffected.

### Gotchas

- **Untagged nodes can reach the owner's whole tailnet.** With a plain key and the default policy,
  every Mac holding the pairing code becomes a full member of the owner's tailnet. The tagged key plus
  an access rule is what contains this.
- **First request after a quick restart can stall.** In 1 of 4 restarts the first connection hung and
  the retry 2 s later succeeded. `HubClient` should use a short connect timeout and retry, or the
  helper should probe the hub before reporting `ready`.
- **The helper listens on all interfaces** (one UDP port for WireGuard, one TCP port for Tailscale's
  peer API). The macOS firewall was off on the test Mac; with it on, an ad-hoc-signed binary may raise
  the "accept incoming connections" prompt. Untested. Outbound-only still works through relays.
- **Log upload.** tsnet uploads node logs to log.tailscale.com by default. The helper turns this off
  unless `-upload-logs` is given; small local log files still appear in the state directory.
- **Hostname.** tsnet defaults to the binary name; the helper sets `utmwatch-<machine name>` so the
  owner can tell nodes apart in the admin console.
- **Build tags save little.** The `ts_omit_*` tags in `build.sh` cut only 0.6 MB; stripping symbols
  (`-s -w`) is what takes 30 MB down to 20 MB.
- **Free-plan limits apply.** Each Mac counts as a device on the owner's tailnet.
- Not covered by this spike: two Macs on genuinely different networks (NAT traversal or relay
  fallback), sleep and wake, and the macOS firewall prompt. These belong to the F3d verify step.
