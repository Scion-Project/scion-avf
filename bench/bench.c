// SPDX-License-Identifier: AGPL-3.0-or-later
//
// avfbench: a freestanding PID 1 that runs five microbenchmarks and prints
// machine-readable results, so the same guest can be timed under different
// backends (AVF/crosvm on pKVM, QEMU TCG, or natively on the phone).
//
// Workloads follow pyre's docs/SAME-ISA-FASTPATH.md so numbers line up:
//   int    branchy integer switch loop + FNV-style hashing
//   mem    STREAM-like triad a[i] = b[i] + s*c[i] on 3 x 8 MiB of doubles
//   chase  dependent random loads over a 64 MiB cyclic permutation
//   sys    getppid() in a loop (null syscall)
//   pf     mmap 16 MiB, touch every 4 KiB, munmap (page-fault path)
//
// Output (one record per line):
//   AVFKV key=value                     platform facts
//   BENCH name=int rep=0 ops=N ns=T check=0x...
//   === AVFBENCH DONE ===               last line; absent => truncated run
// `ops` is the amount of work (iterations, bytes, loads, syscalls, pages), so
// ns/op is comparable even when --scale differs between backends; `check` is a
// result hash that must match across backends (it proves the same work ran).
//
// Parameters come from the kernel command line (guest) or argv (native):
//   bench.scale=100   work as a percentage of the default (min 1)
//   bench.reps=3      repetitions per workload
//   bench.only=int,sys  comma-separated subset
//   bench.shell=1     drop into /bin/busybox sh afterwards instead of powering off
//   bench.label=foo   echoed back as AVFKV label=foo
// Native run:  bench --scale=20 --reps=2 --only=int,mem   (no mounts, no poweroff)
//
// No libc: raw aarch64 syscalls only, built with any clang that targets
// aarch64-linux and has lld (see bench/build.sh). Not a CoreMark replacement;
// it's a quick, dependency-free relative measure.

typedef unsigned long u64;
typedef long s64;
typedef unsigned int u32;
typedef unsigned char u8;

#define AT_FDCWD (-100)

enum {
    SYS_mkdirat = 34, SYS_mount = 40, SYS_openat = 56, SYS_close = 57, SYS_read = 63,
    SYS_write = 64, SYS_exit = 93, SYS_nanosleep = 101, SYS_sync = 81, SYS_reboot = 142,
    SYS_uname = 160, SYS_getpid = 172, SYS_getppid = 173, SYS_munmap = 215,
    SYS_execve = 221, SYS_mmap = 222, SYS_clock_gettime = 113,
};

static inline s64 sys6(s64 n, s64 a, s64 b, s64 c, s64 d, s64 e, s64 f) {
    register s64 x8 __asm__("x8") = n;
    register s64 x0 __asm__("x0") = a;
    register s64 x1 __asm__("x1") = b;
    register s64 x2 __asm__("x2") = c;
    register s64 x3 __asm__("x3") = d;
    register s64 x4 __asm__("x4") = e;
    register s64 x5 __asm__("x5") = f;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory", "cc");
    return x0;
}
#define sys3(n, a, b, c) sys6((n), (s64)(a), (s64)(b), (s64)(c), 0, 0, 0)

// The compiler may lower loops/struct copies to these.
void *memset(void *d, int c, u64 n) {
    volatile u8 *p = d;
    while (n--) *p++ = (u8)c;
    return d;
}
void *memcpy(void *d, const void *s, u64 n) {
    volatile u8 *p = d;
    const u8 *q = s;
    while (n--) *p++ = *q++;
    return d;
}

// ---- tiny string/number helpers ------------------------------------------

static u64 slen(const char *s) { u64 n = 0; while (s[n]) n++; return n; }

// Does string s start with prefix p?
static int starts(const char *s, const char *p) {
    while (*p) if (*s++ != *p++) return 0;
    return 1;
}

static char obuf[8192];
static u64 olen;
static void flush(void) {
    u64 off = 0;
    while (off < olen) {
        s64 r = sys3(SYS_write, 1, obuf + off, olen - off);
        if (r <= 0) break;
        off += (u64)r;
    }
    olen = 0;
}
static void putc_(char c) { if (olen == sizeof obuf) flush(); obuf[olen++] = c; if (c == '\n') flush(); }
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void putu(u64 v) {
    char t[24]; int n = 0;
    do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) putc_(t[--n]);
}
static void putx(u64 v) {
    puts_("0x");
    for (int i = 60; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15]);
}

static char cmdline[4096];

// Returns a pointer to the value of "bench.<key>=" in cmdline, or 0.
static const char *opt(const char *key) {
    for (const char *p = cmdline; *p; ) {
        while (*p == ' ') p++;
        if (starts(p, "bench.") && starts(p + 6, key) && p[6 + slen(key)] == '=') return p + 7 + slen(key);
        while (*p && *p != ' ') p++;
    }
    return 0;
}
static u64 opt_u64(const char *key, u64 dflt) {
    const char *v = opt(key);
    if (!v || *v < '0' || *v > '9') return dflt;
    u64 r = 0;
    while (*v >= '0' && *v <= '9') r = r * 10 + (u64)(*v++ - '0');
    return r;
}
static int opt_has_name(const char *key, const char *name) {  // name in comma list?
    const char *v = opt(key);
    if (!v) return 1;
    u64 nl = slen(name);
    while (*v && *v != ' ') {
        if (starts(v, name) && (v[nl] == ',' || v[nl] == ' ' || v[nl] == 0)) return 1;
        while (*v && *v != ' ' && *v != ',') v++;
        if (*v == ',') v++;
    }
    return 0;
}

static u64 now_ns(void) {
    s64 ts[2];
    sys3(SYS_clock_gettime, 1 /* CLOCK_MONOTONIC */, ts, 0);
    return (u64)ts[0] * 1000000000ull + (u64)ts[1];
}

static s64 slurp_to(const char *path, char *buf, u64 cap) {
    s64 fd = sys6(SYS_openat, AT_FDCWD, (s64)path, 0, 0, 0, 0);
    if (fd < 0) return fd;
    u64 n = 0;
    for (;;) {
        s64 r = sys3(SYS_read, fd, buf + n, cap - 1 - n);
        if (r <= 0) break;
        n += (u64)r;
        if (n == cap - 1) break;
    }
    sys3(SYS_close, fd, 0, 0);
    buf[n] = 0;
    return (s64)n;
}

static void kv_file(const char *key, const char *path) {
    static char b[512];
    puts_("AVFKV "); puts_(key); putc_('=');
    if (slurp_to(path, b, sizeof b) < 0) putc_('?');
    else for (u64 i = 0; b[i] && b[i] != '\n'; i++) putc_(b[i]);
    putc_('\n');
}

// ---- workloads -------------------------------------------------------------
// Each returns a checksum and sets *ops. `n` is the work scaled by bench.scale.

static u64 wl_int(u64 n, u64 *ops) {
    u64 x = 0x9e3779b97f4a7c15ull, h = 1469598103934665603ull;
    for (u64 i = 0; i < n; i++) {
        x = x * 6364136223846793005ull + 1442695040888963407ull;
        switch ((x >> 33) & 7) {
            case 0: h ^= x; h *= 1099511628211ull; break;
            case 1: h += x >> 7; break;
            case 2: h = (h << 13) | (h >> 51); break;
            case 3: h ^= x >> 29; h *= 0x100000001b3ull; break;
            case 4: h -= x & 0xffff; break;
            case 5: h += (h >> 11) ^ x; break;
            case 6: h = h * 31 + (x & 0xff); break;
            default: h ^= h >> 17; break;
        }
    }
    *ops = n;
    return h;
}

#define MEM_N (1u << 20)   /* 1 Mi doubles = 8 MiB per array */
static double A[MEM_N], B[MEM_N], C[MEM_N];

static void prep_mem(void) {   // untimed, idempotent
    for (u64 i = 0; i < MEM_N; i++) { B[i] = (double)i * 0.5; C[i] = (double)(i & 1023) + 1.0; A[i] = 0.0; }
}
static u64 wl_mem(u64 passes, u64 *ops) {
    double *restrict a = A, *restrict b = B, *restrict c = C;
    double s = 3.0;
    for (u64 p = 0; p < passes; p++) {
        for (u64 i = 0; i < MEM_N; i++) a[i] = b[i] + s * c[i];
        s += 1.0;  // keeps the passes from being collapsed
    }
    double sum = 0;
    for (u64 i = 0; i < MEM_N; i += 64) sum += a[i];
    *ops = passes * 3ull * MEM_N * 8ull;   // bytes moved
    union { double d; u64 u; } r = { sum };
    return r.u;
}

#define CH_N (8u << 20)    /* 8 Mi entries * 8 B = 64 MiB */
static u64 chain[CH_N];

static int chase_ready;
static u64 g_rng = 88172645463325252ull;
static u64 xorshift(void) { g_rng ^= g_rng << 13; g_rng ^= g_rng >> 7; g_rng ^= g_rng << 17; return g_rng; }

static void prep_chase(void) {   // Sattolo shuffle: one cycle through every entry. Untimed, idempotent.
    if (chase_ready) return;
    for (u64 i = 0; i < CH_N; i++) chain[i] = i;
    for (u64 i = CH_N - 1; i > 0; i--) {
        u64 j = xorshift() % i;
        u64 t = chain[i]; chain[i] = chain[j]; chain[j] = t;
    }
    chase_ready = 1;
}
static u64 wl_chase(u64 steps, u64 *ops) {
    u64 p = 0;
    for (u64 i = 0; i < steps; i++) p = chain[p];
    *ops = steps;
    return p;
}

static u64 wl_sys(u64 n, u64 *ops) {
    u64 acc = 0;
    for (u64 i = 0; i < n; i++) acc += (u64)sys3(SYS_getppid, 0, 0, 0);
    *ops = n;
    return acc + n;
}

static u64 wl_pf(u64 reps, u64 *ops) {
    const u64 len = 16ull << 20;
    u64 pages = 0, acc = 0;
    for (u64 r = 0; r < reps; r++) {
        // PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS
        s64 m = sys6(SYS_mmap, 0, (s64)len, 3, 0x22, -1, 0);
        if (m < 0 && m > -4096) { *ops = pages; return 0xdead; }
        volatile u8 *p = (volatile u8 *)m;
        for (u64 off = 0; off < len; off += 4096) { p[off] = (u8)(off >> 12); pages++; }
        acc += p[4096] + p[len - 4096];
        sys3(SYS_munmap, m, len, 0);
    }
    *ops = pages;
    return acc;
}

struct wl { const char *name; u64 (*fn)(u64, u64 *); u64 base; const char *unit; void (*prep)(void); };
static const struct wl WLS[] = {
    {"int",   wl_int,   100000000ull, "iter",    0},
    {"mem",   wl_mem,   60ull,        "byte",    prep_mem},
    {"chase", wl_chase, 2000000ull,   "load",    prep_chase},
    {"sys",   wl_sys,   1000000ull,   "syscall", 0},
    {"pf",    wl_pf,    40ull,        "page",    0},
};

static void do_mount(const char *src, const char *dst, const char *type) {
    sys6(SYS_mkdirat, AT_FDCWD, (s64)dst, 0755, 0, 0, 0);
    sys6(SYS_mount, (s64)src, (s64)dst, (s64)type, 0, 0, 0);
}

struct utsname { char f[6][65]; };
static u64 g_pagesz;

int cmain(int argc, char **argv) {
    int is_init = sys3(SYS_getpid, 0, 0, 0) == 1;
    {   // auxv follows argv[] and envp[]; AT_PAGESZ = 6
        char **e = argv + argc + 1;
        while (*e) e++;
        for (u64 *av = (u64 *)(e + 1); av[0]; av += 2)
            if (av[0] == 6) g_pagesz = av[1];
    }
    if (is_init) {
        do_mount("proc", "/proc", "proc");
        do_mount("sysfs", "/sys", "sysfs");
        do_mount("devtmpfs", "/dev", "devtmpfs");
        if (sys3(SYS_write, 1, "", 0) < 0) {   // no console on fds 0-2: reopen /dev/console as fd 1
            s64 fd = sys6(SYS_openat, AT_FDCWD, (s64)"/dev/console", 1 /* O_WRONLY */, 0, 0, 0);
            if (fd >= 0) sys3(24 /* dup3 */, fd, 1, 0);
        }
        slurp_to("/proc/cmdline", cmdline, sizeof cmdline);
        for (u64 i = 0; cmdline[i]; i++) if (cmdline[i] == '\n') cmdline[i] = 0;   // drop the trailing newline
    } else {   // native: turn "--scale=20 --reps=2" into "bench.scale=20 bench.reps=2"
        u64 n = 0;
        for (int i = 1; i < argc; i++) {
            const char *a = argv[i];
            while (*a == '-') a++;
            const char *pre = "bench.";
            for (u64 k = 0; pre[k] && n < sizeof cmdline - 2; k++) cmdline[n++] = pre[k];
            for (; *a && n < sizeof cmdline - 2; a++) cmdline[n++] = *a;
            cmdline[n++] = ' ';
        }
        cmdline[n] = 0;
    }

    u64 scale = opt_u64("scale", 100);
    if (scale < 1) scale = 1;
    u64 reps = opt_u64("reps", 3);
    if (reps < 1) reps = 1;

    puts_("avfbench: hello from the guest (pid "); putu((u64)sys3(SYS_getpid, 0, 0, 0)); puts_(")\n");
    puts_("=== AVFBENCH BEGIN ===\n");
    puts_("AVFKV schema=1\nAVFKV kind=bench\n");
    {
        const char *l = opt("label");
        puts_("AVFKV label=");
        if (l) while (*l && *l != ' ') putc_(*l++);
        putc_('\n');
    }
    puts_("AVFKV mode="); puts_(is_init ? "guest" : "native"); putc_('\n');
    puts_("AVFKV page_size="); putu(g_pagesz); putc_('\n');
    puts_("AVFKV scale="); putu(scale); putc_('\n');
    puts_("AVFKV reps="); putu(reps); putc_('\n');
    struct utsname u;
    if (sys3(SYS_uname, &u, 0, 0) == 0) {
        puts_("AVFKV kernel_release="); puts_(u.f[2]); putc_('\n');
        puts_("AVFKV machine="); puts_(u.f[4]); putc_('\n');
    }
    {
        u64 frq;
        __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(frq));
        puts_("AVFKV cntfrq_hz="); putu(frq); putc_('\n');
    }
    kv_file("cpus_online", "/sys/devices/system/cpu/online");
    kv_file("midr_el1", "/sys/devices/system/cpu/cpu0/regs/identification/midr_el1");
    kv_file("cmdline", "/proc/cmdline");
    kv_file("uptime_s", "/proc/uptime");

    for (u64 w = 0; w < sizeof WLS / sizeof WLS[0]; w++) {
        const struct wl *wl = &WLS[w];
        if (!opt_has_name("only", wl->name)) continue;
        u64 n = wl->base * scale / 100;
        if (n < 1) n = 1;
        for (u64 r = 0; r < reps; r++) {
            u64 ops = 0;
            if (wl->prep) wl->prep();
            u64 t0 = now_ns();
            u64 chk = wl->fn(n, &ops);
            u64 t1 = now_ns();
            puts_("BENCH name="); puts_(wl->name);
            puts_(" unit="); puts_(wl->unit);
            puts_(" rep="); putu(r);
            puts_(" ops="); putu(ops);
            puts_(" ns="); putu(t1 - t0);
            puts_(" check="); putx(chk);
            putc_('\n');
        }
    }
    kv_file("uptime_end_s", "/proc/uptime");
    puts_("=== AVFBENCH DONE ===\n");
    flush();

    if (is_init) {
        sys3(SYS_sync, 0, 0, 0);
        if (opt_u64("shell", 0)) {
            char *sh_argv[] = {"busybox", "sh", 0};
            char *sh_env[] = {"PATH=/bin", 0};
            sys3(SYS_execve, "/bin/busybox", sh_argv, sh_env);
        }
        sys6(SYS_reboot, 0xfee1dead, 672274793, 0x4321fedc, 0, 0, 0);   // POWER_OFF -> PSCI SYSTEM_OFF
        for (;;) { u64 ts[2] = {3600, 0}; sys3(SYS_nanosleep, ts, 0, 0); }   // PID 1 must not return
    }
    return 0;
}

__asm__(
    ".text\n"
    ".global _start\n"
    "_start:\n"
    "  mov x29, #0\n"
    "  mov x30, #0\n"
    "  ldr x0, [sp]\n"        // argc
    "  add x1, sp, #8\n"      // argv
    "  mov x2, sp\n"
    "  and sp, x2, #~15\n"
    "  bl cmain\n"
    "  mov x8, #93\n"         // exit(cmain())
    "  svc #0\n"
    "1: b 1b\n");
