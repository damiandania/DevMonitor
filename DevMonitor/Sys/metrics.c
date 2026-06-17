#include "metrics.h"

#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

// rusage CPU times are in mach absolute-time units; this scales them to ns.
// On Intel the timebase is 1:1 (no-op); on Apple Silicon it is ~125/3.
static double dm_timebase_scale(void) {
    static double scale = 0.0;
    if (scale == 0.0) {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        scale = (double)tb.numer / (double)tb.denom;
    }
    return scale;
}

dm_proc_stat dm_proc_stat_for(pid_t pid) {
    dm_proc_stat s = { 0, 0, 0 };
    struct rusage_info_v6 ri;
    if (proc_pid_rusage((int)pid, RUSAGE_INFO_V6, (rusage_info_t *)&ri) == 0) {
        double scale = dm_timebase_scale();
        s.cpu_time_ns = (int64_t)((double)(ri.ri_user_time + ri.ri_system_time) * scale);
        s.phys_footprint = (int64_t)ri.ri_phys_footprint;
        s.valid = 1;
    }
    return s;
}

int dm_system_cpu_ticks(dm_cpu_ticks *out) {
    natural_t ncpu = 0;
    processor_cpu_load_info_t info = NULL;
    mach_msg_type_number_t count = 0;

    kern_return_t kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                           &ncpu, (processor_info_array_t *)&info, &count);
    if (kr != KERN_SUCCESS) {
        return -1;
    }

    uint64_t user = 0, system = 0, idle = 0, nice = 0;
    for (natural_t i = 0; i < ncpu; i++) {
        user   += info[i].cpu_ticks[CPU_STATE_USER];
        system += info[i].cpu_ticks[CPU_STATE_SYSTEM];
        idle   += info[i].cpu_ticks[CPU_STATE_IDLE];
        nice   += info[i].cpu_ticks[CPU_STATE_NICE];
    }
    vm_deallocate(mach_task_self(), (vm_address_t)info, count * sizeof(integer_t));

    out->user = user;
    out->system = system;
    out->idle = idle;
    out->nice = nice;
    out->total = user + system + idle + nice;
    return 0;
}

int dm_system_mem(dm_mem_info *out) {
    int64_t total = 0;
    size_t len = sizeof(total);
    if (sysctlbyname("hw.memsize", &total, &len, NULL, 0) != 0) {
        return -1;
    }

    vm_size_t page = 0;
    host_page_size(mach_host_self(), &page);

    vm_statistics64_data_t vm;
    mach_msg_type_number_t c = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &c) != KERN_SUCCESS) {
        return -1;
    }

    uint64_t used = ((uint64_t)vm.active_count + (uint64_t)vm.wire_count
                     + (uint64_t)vm.compressor_page_count) * (uint64_t)page;
    out->used = used;
    out->total = (uint64_t)total;
    return 0;
}

int dm_child_pids(pid_t ppid, pid_t *out, int cap) {
    for (int i = 0; i < cap; i++) {
        out[i] = 0;
    }
    int r = proc_listchildpids(ppid, out, cap * (int)sizeof(pid_t));
    if (r <= 0) {
        return 0;
    }
    // The return value's units (bytes vs count) vary across SDKs; derive the
    // count directly from the populated buffer (pids are always > 0).
    int count = 0;
    for (int i = 0; i < cap; i++) {
        if (out[i] > 0) {
            count++;
        } else {
            break;
        }
    }
    return count;
}

int dm_pgrp_pids(pid_t pgid, pid_t *out, int cap) {
    for (int i = 0; i < cap; i++) {
        out[i] = 0;
    }
    int r = proc_listpids(PROC_PGRP_ONLY, (uint32_t)pgid, out, cap * (int)sizeof(pid_t));
    if (r <= 0) {
        return 0;
    }
    int n = r / (int)sizeof(pid_t);
    if (n > cap) {
        n = cap;
    }
    // proc_listpids can leave zero gaps; compact the valid pids.
    int w = 0;
    for (int i = 0; i < n; i++) {
        if (out[i] > 0) {
            out[w++] = out[i];
        }
    }
    return w;
}

int dm_session_pids(pid_t sid, pid_t *out, int cap) {
    static pid_t all[8192];
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, all, (int)sizeof(all));
    if (bytes <= 0) {
        return 0;
    }
    int n = bytes / (int)sizeof(pid_t);
    int w = 0;
    for (int i = 0; i < n && w < cap; i++) {
        pid_t p = all[i];
        if (p <= 0) {
            continue;
        }
        if (getsid(p) == sid) {
            out[w++] = p;
        }
    }
    return w;
}

double dm_load_avg(void) {
    double avg[3];
    if (getloadavg(avg, 3) < 0) {
        return -1.0;
    }
    return avg[0];
}

int dm_all_pids(pid_t *out, int cap) {
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, out, cap * (int)sizeof(pid_t));
    if (bytes <= 0) {
        return 0;
    }
    int n = bytes / (int)sizeof(pid_t);
    if (n > cap) {
        n = cap;
    }
    return n;
}

int dm_proc_name(pid_t pid, char *buf, int size) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    int r = proc_pidpath(pid, path, sizeof(path));
    if (r > 0) {
        char *base = strrchr(path, '/');
        base = base ? base + 1 : path;
        strncpy(buf, base, size - 1);
        buf[size - 1] = '\0';
        return (int)strlen(buf);
    }
    return proc_name(pid, buf, size);
}
