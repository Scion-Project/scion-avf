// SPDX-License-Identifier: AGPL-3.0-or-later
//
// avfprobe init: a freestanding PID 1 for a throwaway Linux guest.
//
// It mounts proc/sysfs/devtmpfs, prints what the virtual platform looks like
// (CPUs, memory map, interrupts, device tree, PCI/virtio devices, consoles) to
// the console, then powers the VM off. No libc: raw aarch64 syscalls only, so
// it builds with any clang that can target aarch64-linux and needs no sysroot.
//
// Output lines are plain text. Section headers look like "=== name ===" and
// the last line is "=== AVFPROBE DONE ===" so a host can tell a complete run
// from a truncated one. Just before it, a "=== summary ===" section holds
// machine-readable "AVFKV key=value" lines (page size, RAM, CPUs, MIDR, virtio
// and PCI ids, uptime at init) that the host tools lift into result.json.
//
// Run with "--dry-run" as an ordinary process (e.g. under adb shell) to test
// the dumping code without mounting anything or powering off.

typedef unsigned long u64;
typedef long s64;
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;

#define AT_FDCWD (-100)
#define O_RDONLY 0
#define O_WRONLY 1
#define O_DIRECTORY 040000
#define O_CLOEXEC 02000000

enum {
    SYS_getdents64 = 61, SYS_mkdirat = 34, SYS_mount = 40, SYS_openat = 56,
    SYS_close = 57, SYS_read = 63, SYS_write = 64, SYS_exit = 93,
    SYS_nanosleep = 101, SYS_sync = 81, SYS_reboot = 142, SYS_uname = 160,
    SYS_getpid = 172,
};

static s64 sys6(s64 n, s64 a, s64 b, s64 c, s64 d, s64 e, s64 f) {
    register s64 x8 __asm__("x8") = n;
    register s64 x0 __asm__("x0") = a;
    register s64 x1 __asm__("x1") = b;
    register s64 x2 __asm__("x2") = c;
    register s64 x3 __asm__("x3") = d;
    register s64 x4 __asm__("x4") = e;
    register s64 x5 __asm__("x5") = f;
    __asm__ volatile("svc #0"
                     : "+r"(x0)
                     : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
                     : "memory", "cc");
    return x0;
}
#define sys3(n, a, b, c) sys6(n, (s64)(a), (s64)(b), (s64)(c), 0, 0, 0)

// The compiler may emit calls to these even with -ffreestanding.
void *memset(void *d, int c, u64 n) {
    u8 *p = d;
    while (n--) *p++ = (u8)c;
    return d;
}
void *memcpy(void *d, const void *s, u64 n) {
    u8 *p = d;
    const u8 *q = s;
    while (n--) *p++ = *q++;
    return d;
}

static u64 slen(const char *s) {
    u64 n = 0;
    while (s[n]) n++;
    return n;
}
static int seq(const char *a, const char *b) {
    while (*a && *a == *b) a++, b++;
    return *a == *b;
}

// ---- output -------------------------------------------------------------

static int out_fd = 1;
static char obuf[4096];
static u64 olen;

static void flush(void) {
    u64 off = 0;
    while (off < olen) {
        s64 r = sys3(SYS_write, out_fd, obuf + off, olen - off);
        if (r <= 0) break;
        off += (u64)r;
    }
    olen = 0;
}
static void putc_(char c) {
    if (olen == sizeof obuf) flush();
    obuf[olen++] = c;
    if (c == '\n') flush();
}
static void puts_(const char *s) {
    while (*s) putc_(*s++);
}
static void putu(u64 v) {
    char t[24];
    int i = 0;
    do t[i++] = (char)('0' + v % 10); while (v /= 10);
    while (i) putc_(t[--i]);
}
static void putx(u64 v, int digits) {
    static const char h[] = "0123456789abcdef";
    for (int i = digits - 1; i >= 0; i--) putc_(h[(v >> (i * 4)) & 0xf]);
}
static void section(const char *name) {
    puts_("=== ");
    puts_(name);
    puts_(" ===\n");
}

// ---- files --------------------------------------------------------------

static char fbuf[65536];

// Reads a whole (small) file into fbuf. Returns its length, or -errno.
static s64 slurp(const char *path) {
    s64 fd = sys6(SYS_openat, AT_FDCWD, (s64)path, O_RDONLY | O_CLOEXEC, 0, 0, 0);
    if (fd < 0) return fd;
    u64 n = 0;
    for (;;) {
        s64 r = sys3(SYS_read, fd, fbuf + n, sizeof fbuf - 1 - n);
        if (r <= 0) break;
        n += (u64)r;
        if (n == sizeof fbuf - 1) break;
    }
    sys3(SYS_close, fd, 0, 0);
    fbuf[n] = 0;
    return (s64)n;
}

static void dump_file(const char *path) {
    section(path);
    s64 n = slurp(path);
    if (n < 0) {
        puts_("(unavailable, errno ");
        putu((u64)-n);
        puts_(")\n");
        return;
    }
    for (s64 i = 0; i < n; i++) putc_(fbuf[i]);
    if (n == 0 || fbuf[n - 1] != '\n') putc_('\n');
}

// Prints the first line of a file after a label, e.g. "vendor=0x1af4".
static void print_line_of(const char *label, const char *path) {
    s64 n = slurp(path);
    puts_(label);
    if (n < 0) {
        puts_("?");
    } else {
        for (s64 i = 0; i < n && fbuf[i] != '\n'; i++) putc_(fbuf[i]);
    }
}

struct linux_dirent64 {
    u64 d_ino;
    s64 d_off;
    u16 d_reclen;
    u8 d_type;
    char d_name[];
};
#define DT_DIR 4
#define DT_LNK 10

typedef void (*dirent_fn)(const char *dir, const char *name, int type, void *ctx);

static int for_each_entry(const char *dir, dirent_fn fn, void *ctx) {
    char dbuf[4096];
    s64 fd = sys6(SYS_openat, AT_FDCWD, (s64)dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0, 0, 0);
    if (fd < 0) return (int)fd;
    for (;;) {
        s64 n = sys3(SYS_getdents64, fd, dbuf, sizeof dbuf);
        if (n <= 0) break;
        for (s64 off = 0; off < n;) {
            struct linux_dirent64 *d = (struct linux_dirent64 *)(dbuf + off);
            off += d->d_reclen;
            if (seq(d->d_name, ".") || seq(d->d_name, "..")) continue;
            fn(dir, d->d_name, d->d_type, ctx);
        }
    }
    sys3(SYS_close, fd, 0, 0);
    return 0;
}

static void join(char *dst, u64 cap, const char *a, const char *b) {
    u64 i = 0;
    for (; *a && i + 1 < cap; a++) dst[i++] = *a;
    if (i + 1 < cap) dst[i++] = '/';
    for (; *b && i + 1 < cap; b++) dst[i++] = *b;
    dst[i] = 0;
}

// ---- device tree --------------------------------------------------------

static const char *const dt_props[] = {
    "compatible", "reg", "device_type", "status", "method", "enable-method",
    "interrupts", "ranges", "bootargs", "stdout-path", "linux,initrd-start",
    "linux,initrd-end", "clock-frequency", "model", 0,
};

static int printable_strings(const char *p, s64 n) {
    if (n <= 0 || p[n - 1] != 0) return 0;
    for (s64 i = 0; i < n; i++) {
        unsigned char c = (unsigned char)p[i];
        if (c == 0) {
            if (i == 0 || p[i - 1] == 0) return 0;  // empty string
        } else if (c < 0x20 || c > 0x7e) {
            return 0;
        }
    }
    return 1;
}

static void print_prop(const char *path, const char *name, int depth) {
    s64 n = slurp(path);
    if (n < 0) return;
    for (int i = 0; i < depth + 1; i++) puts_("  ");
    puts_(name);
    puts_(" = ");
    if (printable_strings(fbuf, n)) {
        for (s64 i = 0; i < n - 1; i++) {
            if (fbuf[i]) putc_(fbuf[i]);
            else puts_("\", \"");
        }
    } else {
        // Big-endian 32-bit cells, as in a .dts.
        puts_("<");
        for (s64 i = 0; i + 4 <= n && i < 256; i += 4) {
            u32 v = ((u32)(u8)fbuf[i] << 24) | ((u32)(u8)fbuf[i + 1] << 16) |
                    ((u32)(u8)fbuf[i + 2] << 8) | (u32)(u8)fbuf[i + 3];
            if (i) putc_(' ');
            puts_("0x");
            putx(v, 8);
        }
        if (n > 256) puts_(" ...");
        puts_(">");
    }
    putc_('\n');
}

struct dt_ctx {
    int depth;
};

static void dt_walk(const char *dir, int depth);

static void dt_child(const char *dir, const char *name, int type, void *ctx) {
    struct dt_ctx *c = ctx;
    if (type != DT_DIR) return;
    char p[512];
    join(p, sizeof p, dir, name);
    dt_walk(p, c->depth + 1);
}

static const char *dt_root = "/sys/firmware/devicetree/base";

static void dt_walk(const char *dir, int depth) {
    if (depth > 8) return;
    for (int i = 0; i < depth; i++) puts_("  ");
    const char *rel = dir + slen(dt_root);
    puts_(*rel ? rel : "/");
    putc_('\n');
    char p[512];
    for (int i = 0; dt_props[i]; i++) {
        join(p, sizeof p, dir, dt_props[i]);
        print_prop(p, dt_props[i], depth);
    }
    struct dt_ctx c = {depth};
    for_each_entry(dir, dt_child, &c);
}

// ---- buses --------------------------------------------------------------

static void pci_dev(const char *dir, const char *name, int type, void *ctx) {
    (void)type;
    (void)ctx;
    char p[512], f[512];
    join(p, sizeof p, dir, name);
    puts_(name);
    join(f, sizeof f, p, "vendor");
    print_line_of(" vendor=", f);
    join(f, sizeof f, p, "device");
    print_line_of(" device=", f);
    join(f, sizeof f, p, "class");
    print_line_of(" class=", f);
    putc_('\n');
}

static void virtio_dev(const char *dir, const char *name, int type, void *ctx) {
    (void)type;
    (void)ctx;
    char p[512], f[512];
    join(p, sizeof p, dir, name);
    puts_(name);
    join(f, sizeof f, p, "device");
    print_line_of(" virtio-id=", f);
    join(f, sizeof f, p, "vendor");
    print_line_of(" vendor=", f);
    putc_('\n');
}

static void list_name(const char *dir, const char *name, int type, void *ctx) {
    (void)dir;
    (void)type;
    (void)ctx;
    puts_(name);
    putc_('\n');
}

static void dump_dir(const char *title, const char *dir, dirent_fn fn) {
    section(title);
    int r = for_each_entry(dir, fn, 0);
    if (r < 0) {
        puts_("(unavailable, errno ");
        putu((u64)-r);
        puts_(")\n");
    }
}

// ---- main ---------------------------------------------------------------

struct utsname {
    char sysname[65], nodename[65], release[65], version[65], machine[65], domainname[65];
};

static void do_mount(const char *src, const char *dst, const char *type) {
    sys3(SYS_mkdirat, AT_FDCWD, dst, 0755);
    s64 r = sys6(SYS_mount, (s64)src, (s64)dst, (s64)type, 0, 0, 0);
    puts_("mount ");
    puts_(type);
    puts_(" on ");
    puts_(dst);
    if (r == 0) {
        puts_(": ok\n");
    } else {
        puts_(": errno ");
        putu((u64)-r);
        putc_('\n');
    }
}

// ---- machine-readable summary --------------------------------------------

static u64 g_pagesz;   // AT_PAGESZ from the auxiliary vector: the guest kernel's page size

static void kv_file(const char *key, const char *path) {
    puts_("AVFKV ");
    puts_(key);
    putc_('=');
    print_line_of("", path);
    putc_('\n');
}

static void kv_virtio(const char *dir, const char *name, int type, void *ctx) {
    (void)type; (void)ctx;
    char p[512], f[512];
    join(p, sizeof p, dir, name);
    join(f, sizeof f, p, "device");
    print_line_of(" ", f);
}

static void kv_pci(const char *dir, const char *name, int type, void *ctx) {
    (void)type; (void)ctx;
    char p[512], f[512];
    join(p, sizeof p, dir, name);
    join(f, sizeof f, p, "vendor");
    print_line_of(" ", f);
    join(f, sizeof f, p, "device");
    print_line_of(":", f);
}

static void kv_summary(void) {
    section("summary");
    puts_("AVFKV schema=1\nAVFKV kind=probe\n");
    puts_("AVFKV page_size="); putu(g_pagesz); putc_('\n');
    struct utsname u;
    if (sys3(SYS_uname, &u, 0, 0) == 0) {
        puts_("AVFKV kernel_release="); puts_(u.release); putc_('\n');
        puts_("AVFKV machine="); puts_(u.machine); putc_('\n');
    }
    kv_file("cmdline", "/proc/cmdline");
    kv_file("cpus_online", "/sys/devices/system/cpu/online");
    kv_file("midr_el1", "/sys/devices/system/cpu/cpu0/regs/identification/midr_el1");
    kv_file("uptime_s", "/proc/uptime");
    kv_file("hypervisor_type", "/sys/hypervisor/type");
    // MemTotal / MemAvailable, in kB
    if (slurp("/proc/meminfo") > 0) {
        static const char *const keys[] = {"MemTotal:", "MemAvailable:"};
        static const char *const names[] = {"mem_total_kb", "mem_available_kb"};
        for (int k = 0; k < 2; k++) {
            for (char *l = fbuf; *l; ) {
                char *e = l;
                while (*e && *e != '\n') e++;
                u64 kl = slen(keys[k]);
                int m = 1;
                for (u64 i = 0; i < kl; i++) if (l[i] != keys[k][i]) { m = 0; break; }
                if (m) {
                    char *v = l + kl;
                    while (*v == ' ') v++;
                    puts_("AVFKV "); puts_(names[k]); putc_('=');
                    while (v < e && *v >= '0' && *v <= '9') putc_(*v++);
                    putc_('\n');
                    break;
                }
                l = *e ? e + 1 : e;
            }
        }
    }
    puts_("AVFKV virtio_ids=");
    for_each_entry("/sys/bus/virtio/devices", kv_virtio, 0);
    putc_('\n');
    puts_("AVFKV pci_ids=");
    for_each_entry("/sys/bus/pci/devices", kv_pci, 0);
    putc_('\n');
}

static void probe(void) {
    section("uname");
    struct utsname u;
    if (sys3(SYS_uname, &u, 0, 0) == 0) {
        puts_(u.sysname); putc_(' ');
        puts_(u.release); putc_(' ');
        puts_(u.version); putc_(' ');
        puts_(u.machine); putc_('\n');
    }

    dump_file("/proc/cmdline");
    dump_file("/sys/devices/system/cpu/online");
    dump_file("/sys/devices/system/cpu/possible");
    dump_file("/sys/devices/system/cpu/cpu0/regs/identification/midr_el1");
    dump_file("/sys/devices/system/cpu/cpu0/regs/identification/revidr_el1");
    dump_file("/proc/cpuinfo");
    dump_file("/proc/meminfo");
    dump_file("/proc/iomem");
    dump_file("/proc/interrupts");
    dump_file("/proc/consoles");
    dump_file("/sys/hypervisor/type");
    dump_file("/sys/kernel/mm/transparent_hugepage/enabled");

    dump_dir("pci devices", "/sys/bus/pci/devices", pci_dev);
    dump_dir("virtio devices", "/sys/bus/virtio/devices", virtio_dev);
    dump_dir("platform devices", "/sys/bus/platform/devices", list_name);
    dump_dir("tty devices", "/sys/class/tty", list_name);

    section("device tree");
    dt_walk(dt_root, 0);

    kv_summary();
    section("AVFPROBE DONE");
}

int cmain(int argc, char **argv) {
    int dry = argc > 1 && seq(argv[1], "--dry-run");
    {   // auxv follows argv[] and envp[]; AT_PAGESZ = 6
        char **e = argv + argc + 1;
        while (*e) e++;
        for (u64 *av = (u64 *)(e + 1); av[0]; av += 2)
            if (av[0] == 6) g_pagesz = av[1];
    }
    int is_init = sys3(SYS_getpid, 0, 0, 0) == 1;

    if (!dry) {
        do_mount("proc", "/proc", "proc");
        do_mount("sysfs", "/sys", "sysfs");
        do_mount("devtmpfs", "/dev", "devtmpfs");
        // The kernel opens /dev/console as fds 0-2 for init when the initramfs
        // has that node. If it didn't, fall back to the kernel log, which
        // reaches every registered console.
        if (sys3(SYS_write, 1, "", 0) < 0) {
            s64 fd = sys6(SYS_openat, AT_FDCWD, (s64)"/dev/console", O_WRONLY | O_CLOEXEC, 0, 0, 0);
            if (fd < 0) fd = sys6(SYS_openat, AT_FDCWD, (s64)"/dev/kmsg", O_WRONLY | O_CLOEXEC, 0, 0, 0);
            if (fd >= 0) out_fd = (int)fd;
        }
    }
    puts_("avfprobe: hello from the guest (pid ");
    putu((u64)sys3(SYS_getpid, 0, 0, 0));
    puts_(dry ? ", dry run)\n" : ")\n");

    probe();
    flush();

    if (!dry && is_init) {
        sys3(SYS_sync, 0, 0, 0);
        // LINUX_REBOOT_MAGIC1/2, LINUX_REBOOT_CMD_POWER_OFF -> PSCI SYSTEM_OFF.
        sys6(SYS_reboot, 0xfee1dead, 672274793, 0x4321fedc, 0, 0, 0);
        // Never return from PID 1: that panics the kernel.
        for (;;) {
            u64 ts[2] = {3600, 0};
            sys3(SYS_nanosleep, ts, 0, 0);
        }
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
