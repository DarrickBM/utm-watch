#include "shim.h"

#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_mib.h>
#include <net/if_var.h>
#include <net/route.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/ip_icmp.h>
#include <poll.h>
#include <time.h>
#include <unistd.h>

int shim_list_pids(pid_t *buf, int capacity) {
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, buf, capacity * (int)sizeof(pid_t));
    if (bytes <= 0) return -1;
    return bytes / (int)sizeof(pid_t);
}

int shim_proc_path(pid_t pid, char *buf, uint32_t size) {
    return proc_pidpath(pid, buf, size);
}

int shim_proc_start_time(pid_t pid, uint64_t *sec) {
    struct proc_bsdinfo info;
    int n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (n != (int)sizeof(info)) return -1;
    *sec = info.pbi_start_tvsec;
    return 0;
}

int shim_proc_ppid(pid_t pid, pid_t *ppid) {
    struct proc_bsdinfo info;
    int n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (n != (int)sizeof(info)) return -1;
    *ppid = (pid_t)info.pbi_ppid;
    return 0;
}

int shim_proc_args(pid_t pid, char *buf, uint32_t size) {
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t len = 0;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || len < sizeof(int)) return -1;
    char *raw = malloc(len);
    if (!raw) return -1;
    if (sysctl(mib, 3, raw, &len, NULL, 0) != 0 || len < sizeof(int)) { free(raw); return -1; }
    // Layout: argc, the executable path, NUL padding, then argc NUL-terminated arguments, then the environment.
    int argc; memcpy(&argc, raw, sizeof(int));
    char *p = raw + sizeof(int), *end = raw + len;
    while (p < end && *p) p++;          // executable path
    while (p < end && !*p) p++;         // padding
    uint32_t out = 0;
    for (int i = 0; i < argc && p < end; i++) {
        size_t n = strnlen(p, (size_t)(end - p));
        if (out + n + 1 > size) break;
        memcpy(buf + out, p, n); buf[out + n] = 0;
        out += (uint32_t)n + 1;
        p += n + 1;
    }
    free(raw);
    return (int)out;
}

static double timebase_ratio(void) {
    static double ratio = 0.0;
    if (ratio == 0.0) {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        ratio = (double)tb.numer / (double)tb.denom;
    }
    return ratio;
}

int shim_proc_rusage(pid_t pid, uint64_t *user_ns, uint64_t *system_ns, uint64_t *footprint) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return -1;
    double r = timebase_ratio();
    *user_ns = (uint64_t)((double)ri.ri_user_time * r);
    *system_ns = (uint64_t)((double)ri.ri_system_time * r);
    *footprint = ri.ri_phys_footprint;
    return 0;
}

int shim_proc_resident(pid_t pid, uint64_t *resident) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return -1;
    *resident = ri.ri_resident_size;
    return 0;
}

int shim_proc_open_paths(pid_t pid, shim_path_cb cb, void *ctx) {
    int size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (size <= 0) return -1;
    size *= 2; /* headroom in case fds are opened between the two calls */
    struct proc_fdinfo *fds = malloc((size_t)size);
    if (!fds) return -1;
    int got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, size);
    if (got <= 0) { free(fds); return -1; }
    int n = got / PROC_PIDLISTFD_SIZE;
    int count = 0;
    for (int i = 0; i < n; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_VNODE) continue;
        struct vnode_fdinfowithpath vi;
        int r = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, sizeof(vi));
        if (r != (int)sizeof(vi)) continue;
        cb(vi.pvip.vip_path, ctx);
        count++;
    }
    free(fds);
    return count;
}

/* NET_RT_IFLIST2 only yields interface names and indexes here: on current macOS its
 * if_data64 byte counters are wrapped at 32 bits, while the per-interface MIB
 * (what netstat -ib uses) carries the real 64-bit values. */
static int read_ifmib(unsigned int index, struct ifmibdata *out) {
    int mib[6] = {CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, (int)index, IFDATA_GENERAL};
    size_t len = sizeof(*out);
    return sysctl(mib, 6, out, &len, NULL, 0);
}

int shim_iflist2(shim_if_cb cb, void *ctx) {
    int mib[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    size_t len = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0) return -1;
    char *buf = malloc(len);
    if (!buf) return -1;
    if (sysctl(mib, 6, buf, &len, NULL, 0) < 0) { free(buf); return -1; }
    char *end = buf + len;
    int count = 0;
    for (char *p = buf; p < end;) {
        struct if_msghdr *ifm = (struct if_msghdr *)p;
        if (ifm->ifm_msglen == 0) break;
        if (ifm->ifm_type == RTM_IFINFO2) {
            struct if_msghdr2 *ifm2 = (struct if_msghdr2 *)p;
            struct sockaddr_dl *sdl = (struct sockaddr_dl *)(ifm2 + 1);
            char name[IFNAMSIZ + 1];
            memset(name, 0, sizeof(name));
            size_t nlen = sdl->sdl_nlen < IFNAMSIZ ? sdl->sdl_nlen : IFNAMSIZ;
            memcpy(name, sdl->sdl_data, nlen);
            uint64_t ibytes = ifm2->ifm_data.ifi_ibytes, obytes = ifm2->ifm_data.ifi_obytes;
            struct ifmibdata md;
            if (read_ifmib(ifm2->ifm_index, &md) == 0) {
                ibytes = md.ifmd_data.ifi_ibytes;
                obytes = md.ifmd_data.ifi_obytes;
            }
            cb(name, ifm2->ifm_index, ibytes, obytes, ctx);
            count++;
        }
        p += ifm->ifm_msglen;
    }
    free(buf);
    return count;
}

int shim_host_memory(shim_vm_stats *out) {
    vm_size_t page = 0;
    host_page_size(mach_host_self(), &page);
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS) return -1;
    out->page_size = page;
    out->free_pages = vm.free_count;
    out->active_pages = vm.active_count;
    out->inactive_pages = vm.inactive_count;
    out->wired_pages = vm.wire_count;
    out->compressor_pages = vm.compressor_page_count;
    out->internal_pages = vm.internal_page_count;
    out->purgeable_pages = vm.purgeable_count;
    out->external_pages = vm.external_page_count;
    out->speculative_pages = vm.speculative_count;
    return 0;
}

int shim_swap_usage(uint64_t *total, uint64_t *used) {
    struct xsw_usage xsu;
    size_t len = sizeof(xsu);
    if (sysctlbyname("vm.swapusage", &xsu, &len, NULL, 0) != 0) return -1;
    *total = xsu.xsu_total;
    *used = xsu.xsu_used;
    return 0;
}

int shim_host_cpu_ticks(uint64_t *busy, uint64_t *total) {
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &count) != KERN_SUCCESS) return -1;
    uint64_t user = info.cpu_ticks[CPU_STATE_USER], sys = info.cpu_ticks[CPU_STATE_SYSTEM];
    uint64_t idle = info.cpu_ticks[CPU_STATE_IDLE], nice = info.cpu_ticks[CPU_STATE_NICE];
    *busy = user + sys + nice;
    *total = user + sys + nice + idle;
    return 0;
}

int shim_proc_diskio(pid_t pid, uint64_t *read_bytes, uint64_t *written_bytes) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return -1;
    *read_bytes = ri.ri_diskio_bytesread;
    *written_bytes = ri.ri_diskio_byteswritten;
    return 0;
}

int shim_proc_name(pid_t pid, char *buf, uint32_t size) {
    return proc_name(pid, buf, size);
}

int shim_if_link(const char *name, uint64_t *baudrate, uint64_t *ierrors, uint64_t *oerrors) {
    unsigned int index = if_nametoindex(name);
    if (index == 0) return -1;
    struct ifmibdata md;
    if (read_ifmib(index, &md) != 0) return -1;
    *baudrate = md.ifmd_data.ifi_baudrate;
    *ierrors = md.ifmd_data.ifi_ierrors;
    *oerrors = md.ifmd_data.ifi_oerrors;
    return 0;
}

static uint16_t icmp_checksum(const void *data, size_t len) {
    const uint16_t *p = data;
    uint32_t sum = 0;
    for (; len > 1; len -= 2) sum += *p++;
    if (len == 1) sum += *(const uint8_t *)p;
    sum = (sum >> 16) + (sum & 0xffff);
    sum += (sum >> 16);
    return (uint16_t)~sum;
}

int shim_ping(const char *ip, int timeout_ms, double *rtt_ms) {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    if (inet_pton(AF_INET, ip, &addr.sin_addr) != 1) return -1;

    /* Datagram ICMP sockets need no privileges on macOS. */
    int s = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
    if (s < 0) return -1;

    static uint16_t counter = 0;
    uint16_t seq = ++counter;
    uint8_t packet[64];
    memset(packet, 0x5a, sizeof(packet));
    struct icmp *icmp = (struct icmp *)packet;
    icmp->icmp_type = ICMP_ECHO;
    icmp->icmp_code = 0;
    icmp->icmp_id = htons((uint16_t)(getpid() & 0xffff));
    icmp->icmp_seq = htons(seq);
    icmp->icmp_cksum = 0;
    icmp->icmp_cksum = icmp_checksum(packet, sizeof(packet));

    uint64_t start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    if (sendto(s, packet, sizeof(packet), 0, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(s); return -1; }

    int result = 1;
    for (;;) {
        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        int remaining = timeout_ms - (int)((now - start) / 1000000ull);
        if (remaining <= 0) break;
        struct pollfd pfd = {.fd = s, .events = POLLIN, .revents = 0};
        if (poll(&pfd, 1, remaining) <= 0) break;
        uint8_t buf[1500];
        struct sockaddr_in from;
        socklen_t fromlen = sizeof(from);
        ssize_t n = recvfrom(s, buf, sizeof(buf), 0, (struct sockaddr *)&from, &fromlen);
        if (n < (ssize_t)ICMP_MINLEN) continue;
        /* The kernel hands back the IP header in front of the ICMP message. */
        size_t off = 0;
        if ((buf[0] >> 4) == 4) off = (size_t)(buf[0] & 0x0f) * 4;
        if ((size_t)n < off + ICMP_MINLEN) continue;
        struct icmp *reply = (struct icmp *)(buf + off);
        if (reply->icmp_type != ICMP_ECHOREPLY || ntohs(reply->icmp_seq) != seq) continue;
        if (from.sin_addr.s_addr != addr.sin_addr.s_addr) continue;
        uint64_t end = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        *rtt_ms = (double)(end - start) / 1e6;
        result = 0;
        break;
    }
    close(s);
    return result;
}
