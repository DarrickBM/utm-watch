# How UTM Watch works

How UTM Watch measures each VM, finds which process belongs to which VM, and what it needs from macOS. For installing and using the app, see the [README](../README.md).

## What the numbers mean

| Column | Definition | Source |
|---|---|---|
| CPU | Process CPU time (user + system) delta ÷ real elapsed time, in cores. 1.0 = one core fully busy. | `proc_pid_rusage` |
| Memory | Physical footprint of the VM process, **including compressed pages**; matches Activity Monitor's Memory column. It is shown against the VM's configured RAM, but it covers the whole VM process, including memory the Mac uses on the VM's behalf, so it can read higher than the configured RAM. Once a guest has touched all its memory the footprint barely moves, so the detail window's Memory track also plots how much of the footprint is **in RAM right now** (solid) against the footprint (dashed). | `proc_pid_rusage`, `config.plist` |
| Disk | Space in use inside the VM against how much its main volume holds, read every 10 seconds from the disk image file, read-only and without asking the guest. The figure is the guest filesystem's own count: APFS (macOS), ext2/3/4, Btrfs and XFS (Linux, also inside LVM) and NTFS (Windows), in raw and qcow2 images. For a disk that cannot be read this way (encrypted, compressed qcow2, another filesystem) it is the room the image takes on the Mac against the disk's nominal size. An event is recorded when a disk passes 90%. | the VM's disk image in `Data/`: partition table, then the filesystem's superblock, space manager or allocation bitmap |
| ↓ Down / ↑ Up | Bytes per second on the VM's `vmenetN` interface, from the guest's point of view. | per-interface MIB (64-bit counters) |
| Total ↓/↑ | Bytes since the interface was created (i.e. since the VM booted). | same |
| Allocatable | total RAM − memory used by macOS and your apps (measured, not a fixed reserve) − configured RAM of all running VMs. VMs can grow to their limit, so limits are counted, not current footprints. | `host_statistics64`, `config.plist` |
| free now | total RAM − Activity Monitor "Memory Used". Includes file cache that macOS can reclaim. | `host_statistics64` |
| Cores allocated | Sum of configured CPU counts of running VMs vs physical cores. Over the physical count means VMs compete under full load. | `config.plist`, `hw.ncpu` |
| macOS VMs | Running Apple-backend macOS guests; macOS allows at most two at once. | `config.plist` |

Memory uses binary units (8192 MiB shows as 8 GB, like UTM and Activity Monitor). Network uses decimal units (1 MB/s = 1,000,000 bytes/s), like other network tools.

VM memory tends to climb towards its limit and stay there even when the guest frees memory; that is how the hypervisor works, not a leak.

## How VMs are identified

1. **Process → VM**: every VM process (`com.apple.Virtualization.VirtualMachine` for the Apple backend, UTM's `QEMULauncher` or a standalone `qemu-system-*` for QEMU) holds its disk image inside `<Name>.utm/Data/` open. The open-file list of the process gives the bundle. Processes that hold no `.utm` file (Lume, Tart, Parallels...) are listed as `Unidentified VM (PID n)` with CPU and memory but no network.
2. **VM → interface**: the VM's MAC address (`Network.0.MacAddress` in `config.plist`) is looked up in the bridge's learned-address table (`ifconfig bridge100`, "Address cache"), which names the `vmenetN` member. The entry appears once the VM has sent traffic; until then the row shows `—` and a note.
3. **Name and status**: UTM's AppleScript interface (`virtual machines`: name, status, backend), refreshed every 10 s and whenever a VM process appears or disappears. If UTM is not running, automation is denied, or UTM does not answer, the tool keeps working: names come from the `.utm` bundle, status is inferred from whether a process exists, and a note says so. Failed queries are retried after a minute (or on `r`) so a pending permission prompt is not re-triggered every 10 seconds.

Only NAT ("Shared") networking is supported in this version; bridged VMs show no network.

## Permissions

No root is needed, but macOS may show two prompts the first time `utmwatch` runs from a given terminal app:

- **"… would like to access data from other apps"**: the VM configs live in UTM's container (`~/Library/Containers/com.utmapp.UTM`). Deny it and names still come from the bundle path, but CPU/memory limits, MAC addresses (so network columns) and the macOS-VM count are unavailable.
- **"… wants access to control UTM"** (Automation): used only for VM names and states. Deny it and status is inferred from the process list.

The display never waits on these dialogs: the first frame appears within about two seconds with whatever is available, and a note explains what is still pending.

## Traffic direction

On the host, bytes the `vmenetN` interface **sends** are bytes going **into** the VM (the guest's download), and bytes it **receives** are the guest's upload. The totals on this machine support that reading (a freshly installed VM shows gigabytes "sent" by its vmenet). It still needs the PRD's acceptance check: download a file of known size inside a VM and compare the Total ↓ column. If it turns out reversed, run with `--swap-directions` and flip the default in `MonitorEngine.Options`.

## Implementation notes

- `Sources/CSysShim`: C wrappers for `libproc` (`proc_listpids`, `proc_pidpath`, `proc_pid_rusage`, `PROC_PIDFDVNODEPATHINFO`), interface counters and `host_statistics64`.
- Interface byte counters come from the per-interface MIB (`net.link.generic.ifdata.<index>.general`), because on current macOS the `NET_RT_IFLIST2` `if_data64` byte fields wrap at 32 bits. `NET_RT_IFLIST2` is only used to enumerate names and indexes.
- All rates use the monotonic clock and the real elapsed time between samples. A sample is dropped (shown as `—`) when a counter goes backwards or an interface was rebuilt (new index), e.g. after a VM restart.
- Slow sources (UTM query, `ifconfig`, bundle configs) run on a background queue so a hung AppleEvent never blocks the display.
- Everything in `UTMWatchCore` is UI-independent; `utmwatch` only parses flags, draws with ANSI escapes and handles keys.

