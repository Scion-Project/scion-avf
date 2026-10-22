// SPDX-License-Identifier: AGPL-3.0-or-later
//
// scfb-init: PID 1 for the display/touch test guest. No libc: raw aarch64
// syscalls, so any clang that targets aarch64-linux builds it.
//
// It draws into a "Scion shared framebuffer" (SCFB, see display/SCFB.md): a
// slice of guest RAM that the host app has also mapped, passed on the kernel
// command line as  scfb.addr=0x.. scfb.size=0x.. scfb.w=W scfb.h=H. The guest
// kernel runs with mem= set below scfb.addr so it never uses that memory, and
// init reaches it through /dev/mem.
//
// It also loads virtio_input + evdev from the initramfs, reads every
// /dev/input/event*, prints each touch report to the console ("TOUCH ..."),
// draws a marker under each finger, and echoes the number of input reports it
// has consumed in the frame header, so the host can time input -> pixels.
//
//   scfb.mode=demo   (default) redraw on input and at ~60 Hz
//   scfb.mode=bench  redraw full frames back to back for scfb.bench=N s, then demo
//   scfb.secs=N      power off after N s (0 = run until the host stops the VM)
//   scfb.bufs=0|1|2  1: draw in place with the "drawing" seqlock (as XNU does); 2 (default): flip;
//                    0: in place with no seqlock (ramfb-like, to measure tearing)
//
// Console lines the host parses: "SCFB key=value ...", "TOUCH ...",
// "INPUTDEV ...", "VIRTIO ...", and "=== SCFB DONE ===".

typedef unsigned long u64;
typedef long s64;
typedef unsigned int u32;
typedef int s32;
typedef unsigned short u16;
typedef unsigned char u8;

#define AT_FDCWD (-100)
#define O_RDONLY 0
#define O_RDWR 2
#define O_NONBLOCK 04000
#define O_DIRECTORY 040000
#define O_CLOEXEC 02000000

enum {
    SYS_getdents64 = 61, SYS_ioctl = 29, SYS_mount = 40, SYS_openat = 56,
    SYS_close = 57, SYS_read = 63, SYS_write = 64, SYS_ppoll = 73,
    SYS_exit = 93, SYS_nanosleep = 101, SYS_clock_gettime = 113,
    SYS_sync = 81, SYS_reboot = 142, SYS_getpid = 172, SYS_mmap = 222,
    SYS_finit_module = 273,
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
static int starts(const char *s, const char *p) {
    while (*p)
        if (*s++ != *p++) return 0;
    return 1;
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
static void puts_d(s64 v) {
    if (v < 0) putc_('-'), v = -v;
    putu((u64)v);
}
static void putx(u64 v) {
    static const char h[] = "0123456789abcdef";
    int i = 15;
    while (i > 0 && !((v >> (i * 4)) & 0xf)) i--;
    puts_("0x");
    for (; i >= 0; i--) putc_(h[(v >> (i * 4)) & 0xf]);
}
static void kv(const char *k, u64 v) {
    putc_(' ');
    puts_(k);
    putc_('=');
    putu(v);
}

static u64 parse_num(const char *s) {
    u64 v = 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        for (s += 2;; s++) {
            char c = *s;
            if (c >= '0' && c <= '9') v = v * 16 + (u64)(c - '0');
            else if (c >= 'a' && c <= 'f') v = v * 16 + (u64)(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') v = v * 16 + (u64)(c - 'A' + 10);
            else break;
        }
    } else {
        for (; *s >= '0' && *s <= '9'; s++) v = v * 10 + (u64)(*s - '0');
    }
    return v;
}

static char fbuf[16384];
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

static u64 now_ns(void) {
    s64 ts[2];
    sys3(SYS_clock_gettime, 1 /* CLOCK_MONOTONIC */, ts, 0);
    return (u64)ts[0] * 1000000000ul + (u64)ts[1];
}
static void sleep_ns(u64 ns) {
    s64 ts[2] = {(s64)(ns / 1000000000ul), (s64)(ns % 1000000000ul)};
    sys3(SYS_nanosleep, ts, 0, 0);
}

// ---- SCFB header (layout shared with the host, see display/SCFB.md) -----

#define SCFB_MAGIC 0x42464353u /* "SCFB" */
#define FOURCC_XB24 0x34324258u /* DRM_FORMAT_XBGR8888: bytes R,G,B,X */

struct scfb_hdr {
    u32 magic, version;          // 0x00
    u32 width, height;           // 0x08
    u32 stride, format;          // 0x10  bytes per row, DRM fourcc
    u32 buf_offset[2];           // 0x18  from region start
    u32 nbufs, flags;            // 0x20  flags bit0: guest ready
    u32 front;                   // 0x28  index of the newest complete buffer
    volatile u32 drawing;        // 0x2c  single buffer: 1 while the guest draws (seqlock with host_reading)
    volatile u64 frame_seq;      // 0x30  guest: frames published (front holds frame_seq)
    volatile u64 input_seq;      // 0x38  guest: input reports consumed when the frame was drawn
    volatile u64 guest_ns;       // 0x40  guest CLOCK_MONOTONIC at publish
    u32 dirty[4];                // 0x48  x, y, w, h of the change vs the previous frame
    volatile u64 host_seq;       // 0x58  host: last frame_seq it finished copying
    volatile u64 host_reading;   // 0x60  host: frame_seq it is copying now, 0 if idle
    volatile u64 host_ns;        // 0x68  host: its clock when host_seq was set
};

static volatile struct scfb_hdr *H;
static u8 *region;
static u32 W, HT, STRIDE;

static inline void dmb(void) { __asm__ volatile("dmb ish" ::: "memory"); }

#define FOURCC_XR24 0x34325258u /* DRM_FORMAT_XRGB8888: bytes B,G,R,X */
static int bgrx;
static u32 rgb(u32 r, u32 g, u32 b) {
    return bgrx ? 0xff000000u | (r << 16) | (g << 8) | b : 0xff000000u | (b << 16) | (g << 8) | r;
}

static u32 *buf_px(u32 idx) { return (u32 *)(region + H->buf_offset[idx]); }

static void fill(u32 *fb, s64 x0, s64 y0, s64 w, s64 h, u32 c) {
    if (x0 < 0) w += x0, x0 = 0;
    if (y0 < 0) h += y0, y0 = 0;
    if (x0 + w > W) w = W - x0;
    if (y0 + h > HT) h = HT - y0;
    if (w <= 0 || h <= 0) return;
    for (s64 y = y0; y < y0 + h; y++) {
        u32 *row = (u32 *)((u8 *)fb + (u64)y * STRIDE) + x0;
        for (s64 x = 0; x < w; x++) row[x] = c;
    }
}

// 3x5 digits, bit 14 = top-left.
static const u16 digits[10] = {
    0x7b6f, 0x2c97, 0x73e7, 0x73cf, 0x5bc9, 0x79cf, 0x79ef, 0x7249, 0x7bef, 0x7bcf,
};
static void draw_num(u32 *fb, s64 x, s64 y, u64 v, s64 scale, u32 c) {
    char t[24];
    int n = 0;
    do t[n++] = (char)(v % 10); while (v /= 10);
    for (int i = n - 1; i >= 0; i--) {
        u16 bits = digits[(int)t[i]];
        for (int r = 0; r < 5; r++)
            for (int col = 0; col < 3; col++)
                if (bits & (1u << (14 - (r * 3 + col))))
                    fill(fb, x + col * scale, y + r * scale, scale, scale, c);
        x += 4 * scale;
    }
}

// ---- input --------------------------------------------------------------

struct input_event { s64 sec, usec; u16 type, code; s32 value; };
#define EV_SYN 0
#define EV_KEY 1
#define EV_ABS 3
#define ABS_MT_SLOT 0x2f
#define ABS_MT_POSITION_X 0x35
#define ABS_MT_POSITION_Y 0x36
#define ABS_MT_TRACKING_ID 0x39
#define BTN_TOUCH 0x14a
#define NSLOTS 10

struct pollfd { s32 fd; short events, revents; };
static struct pollfd pfds[8];
static int npfd;
static struct { s32 id, x, y; } slots[NSLOTS];
static int cur_slot;
static u64 input_seq, touch_down;

#define IOC(dir, type, nr, size) (((u64)(dir) << 30) | ((u64)(size) << 16) | ((u64)(type) << 8) | (u64)(nr))

static void open_inputs(void) {
    char dbuf[2048], path[64];
    s64 fd = sys6(SYS_openat, AT_FDCWD, (s64)"/dev/input", O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0, 0, 0);
    if (fd < 0) return;
    for (;;) {
        s64 n = sys3(SYS_getdents64, fd, dbuf, sizeof dbuf);
        if (n <= 0) break;
        for (s64 off = 0; off < n;) {
            u16 reclen = *(u16 *)(dbuf + off + 16);
            const char *name = dbuf + off + 19;
            off += reclen;
            if (!starts(name, "event") || npfd == 8) continue;
            const char *pre = "/dev/input/";
            int i = 0;
            for (; pre[i]; i++) path[i] = pre[i];
            for (int j = 0; name[j] && i < 63; j++) path[i++] = name[j];
            path[i] = 0;
            s64 efd = sys6(SYS_openat, AT_FDCWD, (s64)path, O_RDONLY | O_NONBLOCK | O_CLOEXEC, 0, 0, 0);
            if (efd < 0) continue;
            char dev[128];
            memset(dev, 0, sizeof dev);
            sys3(SYS_ioctl, efd, IOC(2, 'E', 0x06, sizeof dev - 1), dev);  // EVIOCGNAME
            s32 ax[6], ay[6];                                             // struct input_absinfo
            memset(ax, 0, sizeof ax);
            memset(ay, 0, sizeof ay);
            sys3(SYS_ioctl, efd, IOC(2, 'E', 0x40 + ABS_MT_POSITION_X, sizeof ax), ax);  // EVIOCGABS
            sys3(SYS_ioctl, efd, IOC(2, 'E', 0x40 + ABS_MT_POSITION_Y, sizeof ay), ay);
            puts_("INPUTDEV path=");
            puts_(path);
            puts_(" name=\"");
            puts_(dev);
            puts_("\" mt_x=");
            puts_d(ax[1]);
            putc_(':');
            puts_d(ax[2]);
            puts_(" mt_y=");
            puts_d(ay[1]);
            putc_(':');
            puts_d(ay[2]);
            putc_('\n');
            pfds[npfd].fd = (s32)efd;
            pfds[npfd].events = 1;  // POLLIN
            npfd++;
        }
    }
    sys3(SYS_close, fd, 0, 0);
}

// Returns 1 if at least one complete report (SYN_REPORT) arrived.
static int read_inputs(void) {
    int got = 0;
    struct input_event ev[64];
    for (int i = 0; i < npfd; i++) {
        for (;;) {
            s64 n = sys3(SYS_read, pfds[i].fd, ev, sizeof ev);
            if (n <= 0) break;
            for (u64 k = 0; k < (u64)n / sizeof ev[0]; k++) {
                struct input_event *e = &ev[k];
                if (e->type == EV_ABS) {
                    if (e->code == ABS_MT_SLOT) cur_slot = e->value >= 0 && e->value < NSLOTS ? e->value : 0;
                    else if (e->code == ABS_MT_TRACKING_ID) slots[cur_slot].id = e->value;
                    else if (e->code == ABS_MT_POSITION_X) slots[cur_slot].x = e->value;
                    else if (e->code == ABS_MT_POSITION_Y) slots[cur_slot].y = e->value;
                } else if (e->type == EV_KEY && e->code == BTN_TOUCH) {
                    touch_down = (u64)e->value;
                } else if (e->type == EV_SYN && e->code == 0) {
                    input_seq++;
                    got = 1;
                    puts_("TOUCH");
                    kv("seq", input_seq);
                    kv("down", touch_down);
                    for (int s = 0; s < NSLOTS; s++) {
                        if (slots[s].id < 0) continue;
                        puts_(" s");
                        putu((u64)s);
                        putc_('=');
                        puts_d(slots[s].x);
                        putc_(',');
                        puts_d(slots[s].y);
                    }
                    puts_(" t_us=");
                    putu((u64)e->sec * 1000000ul + (u64)e->usec);
                    putc_('\n');
                }
            }
        }
    }
    return got;
}

// ---- rendering ----------------------------------------------------------

static u64 frames, bench_bytes;

static void render(u32 *fb, u64 n, int full_bench) {
    if (full_bench) {
        // Every pixel changes every frame: a moving diagonal gradient.
        for (u32 y = 0; y < HT; y++) {
            u32 *row = (u32 *)((u8 *)fb + (u64)y * STRIDE);
            u32 g = (y + (u32)n * 8) & 0xff;
            for (u32 x = 0; x < W; x++) row[x] = rgb((x + (u32)n * 4) & 0xff, g, 0x80);
        }
        bench_bytes += (u64)HT * W * 4;
    } else {
        // Static colour bars with a grid, then a sweeping bar so a stalled
        // display is obvious.
        static const u32 bars[8][3] = {{255, 255, 255}, {255, 255, 0}, {0, 255, 255}, {0, 255, 0},
                                       {255, 0, 255}, {255, 0, 0}, {0, 0, 255}, {16, 16, 16}};
        for (u32 y = 0; y < HT; y++) {
            u32 *row = (u32 *)((u8 *)fb + (u64)y * STRIDE);
            for (u32 x = 0; x < W; x++) {
                const u32 *b = bars[(x * 8) / W];
                u32 c = rgb(b[0] * 3 / 4, b[1] * 3 / 4, b[2] * 3 / 4);
                if (x % 120 == 0 || y % 120 == 0) c = rgb(40, 40, 40);
                row[x] = c;
            }
        }
        fill(fb, 0, (s64)((n * 6) % HT), W, 12, rgb(255, 255, 255));
    }
    // Header strip: frame number and input count.
    fill(fb, 0, 0, W, 90, rgb(0, 0, 0));
    draw_num(fb, 20, 15, n, 12, rgb(0, 255, 0));
    draw_num(fb, (s64)W / 2, 15, input_seq, 12, rgb(255, 200, 0));
    // Finger markers.
    for (int s = 0; s < NSLOTS; s++) {
        if (slots[s].id < 0) continue;
        fill(fb, slots[s].x - 40, slots[s].y - 40, 80, 80, rgb(255, 40, 40));
        fill(fb, slots[s].x - 3, 0, 6, HT, rgb(255, 255, 255));
        fill(fb, 0, slots[s].y - 3, W, 6, rgb(255, 255, 255));
    }
}

static int nbufs = 2;
static inline void dsb(void) { __asm__ volatile("dsb ish" ::: "memory"); }

// One buffer, drawn in place (what XNU does): don't start while the host is
// copying, and say so while drawing, so the host never shows a half-drawn frame.
static int no_seqlock;  // scfb.bufs=0: in place without the seqlock, like ramfb (to see tearing)
static void publish_inplace(int full_bench) {
    u64 t0 = now_ns();
    for (; !no_seqlock;) {
        while (H->host_reading && now_ns() - t0 < 4000000ul) {
        }
        H->drawing = 1;
        dsb();
        if (!H->host_reading || now_ns() - t0 >= 4000000ul) break;
        H->drawing = 0;  // both looked at once: let the host finish
        dsb();
    }
    frames++;
    render(buf_px(0), frames, full_bench);
    H->dirty[0] = 0;
    H->dirty[1] = 0;
    H->dirty[2] = W;
    H->dirty[3] = HT;
    H->input_seq = input_seq;
    H->guest_ns = now_ns();
    dsb();
    if (!no_seqlock) H->drawing = 0;
    H->frame_seq = frames;
    dsb();
}

static void publish(int full_bench) {
    if (nbufs == 1) {
        publish_inplace(full_bench);
        return;
    }
    u32 back = H->front ^ 1;
    // Don't overwrite the buffer the host is still copying (it holds frame
    // frame_seq - 1). Give up after 50 ms so a host that never reads can't
    // stall the guest.
    u64 t0 = now_ns();
    while (H->host_reading && H->host_reading == H->frame_seq - 1 && now_ns() - t0 < 50000000ul) {
    }
    frames++;
    render(buf_px(back), frames, full_bench);
    H->dirty[0] = 0;
    H->dirty[1] = 0;
    H->dirty[2] = W;
    H->dirty[3] = HT;
    H->input_seq = input_seq;
    H->guest_ns = now_ns();
    dmb();
    H->front = back;
    dmb();
    H->frame_seq = frames;
    dmb();
}

// ---- setup --------------------------------------------------------------

static void do_mount(const char *src, const char *dst, const char *type) {
    s64 r = sys6(SYS_mount, (s64)src, (s64)dst, (s64)type, 0, 0, 0);
    if (r < 0) {
        puts_("mount ");
        puts_(dst);
        puts_(" failed ");
        puts_d(r);
        putc_('\n');
    }
}

static void load_module(const char *path) {
    s64 fd = sys6(SYS_openat, AT_FDCWD, (s64)path, O_RDONLY | O_CLOEXEC, 0, 0, 0);
    s64 r = fd < 0 ? fd : sys3(SYS_finit_module, fd, "", 4 /* MODULE_INIT_COMPRESSED_FILE */);
    if (fd >= 0) sys3(SYS_close, fd, 0, 0);
    puts_("SCFB module=");
    puts_(path);
    puts_(" rc=");
    puts_d(r);
    putc_('\n');
}

static void list_virtio(void) {
    char dbuf[2048], p[160];
    s64 fd = sys6(SYS_openat, AT_FDCWD, (s64)"/sys/bus/virtio/devices", O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0, 0, 0);
    if (fd < 0) return;
    for (;;) {
        s64 n = sys3(SYS_getdents64, fd, dbuf, sizeof dbuf);
        if (n <= 0) break;
        for (s64 off = 0; off < n;) {
            u16 reclen = *(u16 *)(dbuf + off + 16);
            const char *name = dbuf + off + 19;
            off += reclen;
            if (name[0] == '.') continue;
            const char *pre = "/sys/bus/virtio/devices/";
            int i = 0;
            for (; pre[i]; i++) p[i] = pre[i];
            for (int j = 0; name[j]; j++) p[i++] = name[j];
            const char *suf = "/device";
            for (int j = 0; suf[j]; j++) p[i++] = suf[j];
            p[i] = 0;
            puts_("VIRTIO dev=");
            puts_(name);
            puts_(" id=");
            if (slurp(p) > 0) {
                for (char *c = fbuf; *c && *c != '\n'; c++) putc_(*c);
            }
            putc_('\n');
        }
    }
    sys3(SYS_close, fd, 0, 0);
}

static u64 arg(const char *cmdline, const char *key, u64 dflt) {
    for (const char *c = cmdline; *c; c++) {
        if ((c == cmdline || c[-1] == ' ') && starts(c, key)) return parse_num(c + slen(key));
    }
    return dflt;
}

static void poweroff(void) {
    sys3(SYS_sync, 0, 0, 0);
    sys6(SYS_reboot, 0xfee1dead, 672274793, 0x4321fedc, 0, 0, 0);
    for (;;) sleep_ns(3600ul * 1000000000ul);
}

int cmain(void) {
    do_mount("proc", "/proc", "proc");
    do_mount("sysfs", "/sys", "sysfs");
    do_mount("devtmpfs", "/dev", "devtmpfs");
    if (sys3(SYS_write, 1, "", 0) < 0) {
        s64 fd = sys6(SYS_openat, AT_FDCWD, (s64)"/dev/console", 1 | O_CLOEXEC, 0, 0, 0);
        if (fd >= 0) out_fd = (int)fd;
    }
    puts_("SCFB hello\n");
    for (int s = 0; s < NSLOTS; s++) slots[s].id = -1;

    static char cmdline[4096];
    s64 cl = slurp("/proc/cmdline");
    for (s64 i = 0; i < cl && i < (s64)sizeof cmdline - 1; i++) cmdline[i] = fbuf[i];
    u64 addr = arg(cmdline, "scfb.addr=", 0);
    u64 size = arg(cmdline, "scfb.size=", 0);
    W = (u32)arg(cmdline, "scfb.w=", 1080);
    HT = (u32)arg(cmdline, "scfb.h=", 2400);
    u64 secs = arg(cmdline, "scfb.secs=", 0);
    u64 bench = arg(cmdline, "scfb.bench=", 0);
    u64 bufs_arg = arg(cmdline, "scfb.bufs=", 2);
    nbufs = bufs_arg <= 1 ? 1 : 2;
    no_seqlock = bufs_arg == 0;
    for (const char *c = cmdline; *c; c++)
        if (starts(c, "scfb.fmt=xr24")) bgrx = 1;

    list_virtio();
    load_module("/lib/modules/evdev.ko.xz");
    load_module("/lib/modules/virtio_input.ko.xz");
    for (int tries = 0; tries < 100; tries++) {
        open_inputs();
        if (npfd) break;
        sleep_ns(20000000ul);
    }
    puts_("SCFB inputs=");
    putu((u64)npfd);
    putc_('\n');

    STRIDE = W * 4;
    u64 bufsz = ((u64)STRIDE * HT + 0xffff) & ~0xfffful;
    if (!addr || 0x10000 + 2 * bufsz > size) {
        puts_("SCFB error=no-region addr=");
        putx(addr);
        puts_(" size=");
        putx(size);
        putc_('\n');
    } else {
        s64 fd = sys6(SYS_openat, AT_FDCWD, (s64)"/dev/mem", O_RDWR | O_CLOEXEC, 0, 0, 0);
        s64 m = fd < 0 ? fd : sys6(SYS_mmap, 0, (s64)size, 3 /* RW */, 1 /* MAP_SHARED */, fd, (s64)addr);
        if (m < 0 && m > -4096) {
            puts_("SCFB error=mmap rc=");
            puts_d(m);
            putc_('\n');
        } else {
            region = (u8 *)m;
            H = (volatile struct scfb_hdr *)region;
            // Did the host's view of this memory reach us? The host writes
            // host_ns before boot; non-zero means the mapping really is shared.
            puts_("SCFB mapped addr=");
            putx(addr);
            puts_(" size=");
            putx(size);
            kv("host_pre", H->host_ns != 0);
            putc_('\n');
            H->magic = SCFB_MAGIC;
            H->version = 1;
            H->width = W;
            H->height = HT;
            H->stride = STRIDE;
            H->format = bgrx ? FOURCC_XR24 : FOURCC_XB24;
            H->buf_offset[0] = 0x10000;
            H->buf_offset[1] = nbufs == 2 ? (u32)(0x10000 + bufsz) : 0x10000;
            H->nbufs = (u32)nbufs;
            H->drawing = 0;
            H->front = 0;
            H->frame_seq = 0;
            dmb();
            H->flags = 1;
            dmb();
        }
    }
    flush();

    u64 t_start = now_ns(), t_report = t_start, f_report = 0, h_report = 0;
    if (H && bench) {
        puts_("SCFB bench=start\n");
        u64 tb = now_ns(), b0 = bench_bytes, f0 = frames, h0 = H->host_seq;
        while (now_ns() - tb < bench * 1000000000ul) {
            read_inputs();
            publish(1);
        }
        u64 dt = now_ns() - tb;
        puts_("SCFB bench=done");
        kv("frames", frames - f0);
        kv("ms", dt / 1000000);
        kv("guest_fps_x10", (frames - f0) * 10000000000ul / dt);
        kv("mbps", (bench_bytes - b0) * 1000 / dt);
        kv("host_frames", H->host_seq - h0);
        kv("host_fps_x10", (H->host_seq - h0) * 10000000000ul / dt);
        putc_('\n');
        f_report = frames;
        h_report = H->host_seq;
        t_report = now_ns();
    }

    u64 next = now_ns();
    for (;;) {
        u64 t = now_ns();
        if (secs && t - t_start > secs * 1000000000ul) break;
        s64 wait = (s64)(next - t);
        if (wait < 0) wait = 0;
        s64 ts[2] = {0, wait};
        if (npfd) sys6(SYS_ppoll, (s64)pfds, npfd, (s64)ts, 0, 8, 0);
        else sleep_ns((u64)wait);
        int got = read_inputs();
        t = now_ns();
        if (H && (got || t >= next)) {
            publish(0);
            next = t + 16666666ul;
        }
        if (H && t - t_report >= 2000000000ul) {
            puts_("SCFB stats");
            kv("frames", frames);
            kv("fps_x10", (frames - f_report) * 10000000000ul / (t - t_report));
            kv("host_seq", H->host_seq);
            kv("host_fps_x10", (H->host_seq - h_report) * 10000000000ul / (t - t_report));
            kv("input_seq", input_seq);
            putc_('\n');
            f_report = frames;
            h_report = H->host_seq;
            t_report = t;
        }
    }
    puts_("=== SCFB DONE ===\n");
    flush();
    poweroff();
    return 0;
}

__asm__(
    ".text\n"
    ".global _start\n"
    "_start:\n"
    "  mov x29, #0\n"
    "  mov x30, #0\n"
    "  mov x2, sp\n"
    "  and sp, x2, #~15\n"
    "  bl cmain\n"
    "  mov x8, #93\n"
    "  svc #0\n"
    "1: b 1b\n");
