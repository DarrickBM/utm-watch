// Thin C wrappers around libproc, sysctl and Mach host APIs that are awkward
// or impossible to call directly from Swift.
#ifndef VMMON_SHIM_H
#define VMMON_SHIM_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Fills `buf` with up to `capacity` PIDs. Returns the number written, or -1.
int shim_list_pids(pid_t *buf, int capacity);

/// Writes the executable path of `pid` into `buf`. Returns length, or <= 0 on failure.
int shim_proc_path(pid_t pid, char *buf, uint32_t size);

/// Parent process ID. Returns 0 on success.
int shim_proc_ppid(pid_t pid, pid_t *ppid);

/// Copies the process's arguments (argv[0] first) into `buf`, each ending in a NUL.
/// Returns the number of bytes written, or -1. Only works for the current user's processes.
int shim_proc_args(pid_t pid, char *buf, uint32_t size);

/// Process start time (seconds since epoch). Returns 0 on success.
int shim_proc_start_time(pid_t pid, uint64_t *sec);

/// Cumulative user/system CPU time in nanoseconds and physical footprint in bytes.
/// Returns 0 on success.
int shim_proc_rusage(pid_t pid, uint64_t *user_ns, uint64_t *system_ns, uint64_t *footprint);
/* Bytes of the process that are in physical RAM right now (excludes compressed and swapped pages). */
int shim_proc_resident(pid_t pid, uint64_t *resident);

typedef void (*shim_path_cb)(const char *path, void *ctx);
/// Calls `cb` once per vnode (file) the process has open. Returns count, or -1.
int shim_proc_open_paths(pid_t pid, shim_path_cb cb, void *ctx);

typedef void (*shim_if_cb)(const char *name, uint32_t index, uint64_t ibytes, uint64_t obytes, void *ctx);
/// Walks NET_RT_IFLIST2 and calls `cb` with 64-bit byte counters per interface. Returns count, or -1.
int shim_iflist2(shim_if_cb cb, void *ctx);

typedef struct {
    uint64_t page_size;
    uint64_t free_pages;
    uint64_t active_pages;
    uint64_t inactive_pages;
    uint64_t wired_pages;
    uint64_t compressor_pages;
    uint64_t internal_pages;
    uint64_t purgeable_pages;
    uint64_t external_pages;
    uint64_t speculative_pages;
} shim_vm_stats;
/// host_statistics64(HOST_VM_INFO64). Returns 0 on success.
int shim_host_memory(shim_vm_stats *out);

/// vm.swapusage in bytes. Returns 0 on success.
int shim_swap_usage(uint64_t *total, uint64_t *used);

/// Cumulative busy and total CPU ticks across all cores. Returns 0 on success.
int shim_host_cpu_ticks(uint64_t *busy, uint64_t *total);

/// Cumulative bytes a process has read from and written to disk. Returns 0 on success.
int shim_proc_diskio(pid_t pid, uint64_t *read_bytes, uint64_t *written_bytes);

/// Short process name. Returns length, or <= 0 on failure.
int shim_proc_name(pid_t pid, char *buf, uint32_t size);

/// Link speed in bits per second and error counters for an interface. Returns 0 on success.
int shim_if_link(const char *name, uint64_t *baudrate, uint64_t *ierrors, uint64_t *oerrors);

/// Sends one ICMP echo to an IPv4 address and waits for the reply (no root needed).
/// Returns 0 with the round-trip time, 1 on timeout, -1 on error.
int shim_ping(const char *ip, int timeout_ms, double *rtt_ms);

#ifdef __cplusplus
}
#endif
#endif
