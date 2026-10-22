// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Host side of the Scion shared framebuffer (display/SCFB.md): maps the
// ashmem region that crosvm also maps as guest RAM, waits for the guest to
// publish frames, and copies each one into the SurfaceView's buffer queue.
// Also times input -> pixels: the app notes when it sent input report N, and
// the guest stamps each frame with the number of reports it had consumed.

#include <android/log.h>
#include <android/native_window_jni.h>
#include <jni.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <time.h>

#define TAG "AvfDisplay"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

#define SCFB_MAGIC 0x42464353u
#define FOURCC_XB24 0x34324258u /* bytes R,G,B,X = AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM */
#define FOURCC_XR24 0x34325258u /* bytes B,G,R,X (what CoreAnimation/XNU naturally produce) */

struct scfb_hdr {
    uint32_t magic, version;
    uint32_t width, height;
    uint32_t stride, format;
    uint32_t buf_offset[2];
    uint32_t nbufs, flags;
    uint32_t front, pad0;
    uint64_t frame_seq;
    uint64_t input_seq;
    uint64_t guest_ns;
    uint32_t dirty[4];
    uint64_t host_seq;
    uint64_t host_reading;
    uint64_t host_ns;
};

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

// Input reports the app has sent and not yet seen echoed. Ring buffer.
#define PEND 4096
static uint64_t pend_seq[PEND], pend_t0[PEND];
static atomic_uint_fast64_t pend_head, pend_tail;
// Results: per echoed report, ns from send to "frame seen" and to "posted".
#define LAT 8192
static int64_t lat_seen[LAT], lat_posted[LAT];
static atomic_int lat_n;

static atomic_int stop_flag;
static uint64_t st_frames, st_missed, st_copy_ns, st_copy_max, st_first_ns, st_last_ns;
static uint64_t st_guest_seq;

JNIEXPORT jlong JNICALL Java_io_github_dylanneve1_avfdisplay_Scfb_map(JNIEnv *e, jclass c, jint fd, jlong size) {
    (void)e, (void)c;
    void *p = mmap(NULL, (size_t)size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    return p == MAP_FAILED ? 0 : (jlong)(uintptr_t)p;
}

// Fallback when SharedMemory hands out a memfd (crosvm may only map ashmem):
// open the libcutils ashmem device ("/dev/ashmem" + boot id) ourselves.
#define ASHMEM_SET_NAME _IOW(0x77, 1, char[256])
#define ASHMEM_SET_SIZE _IOW(0x77, 3, size_t)
JNIEXPORT jint JNICALL Java_io_github_dylanneve1_avfdisplay_Scfb_ashmemCreate(JNIEnv *e, jclass c, jstring name,
                                                                           jlong size) {
    (void)c;
    char path[64] = "/dev/ashmem", id[40] = {0};
    int b = open("/proc/sys/kernel/random/boot_id", O_RDONLY | O_CLOEXEC);
    if (b >= 0) {
        ssize_t n = read(b, id, 36);
        close(b);
        if (n == 36) snprintf(path, sizeof path, "/dev/ashmem%s", id);
    }
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) fd = open("/dev/ashmem", O_RDWR | O_CLOEXEC);
    if (fd < 0) return -errno;
    char nm[256] = {0};
    const char *s = (*e)->GetStringUTFChars(e, name, NULL);
    snprintf(nm, sizeof nm, "%s", s);
    (*e)->ReleaseStringUTFChars(e, name, s);
    ioctl(fd, ASHMEM_SET_NAME, nm);
    if (ioctl(fd, ASHMEM_SET_SIZE, (size_t)size) < 0) {
        int err = errno;
        close(fd);
        return -err;
    }
    return fd;
}

// Marks the region before boot so the guest can tell the mapping is shared.
JNIEXPORT void JNICALL Java_io_github_dylanneve1_avfdisplay_Scfb_prime(JNIEnv *e, jclass c, jlong base) {
    (void)e, (void)c;
    struct scfb_hdr *h = (struct scfb_hdr *)(uintptr_t)base;
    memset(h, 0, sizeof *h);
    h->host_ns = now_ns();
}

JNIEXPORT void JNICALL Java_io_github_dylanneve1_avfdisplay_Scfb_noteInput(JNIEnv *e, jclass c, jlong seq, jlong t0) {
    (void)e, (void)c;
    uint64_t h = atomic_load(&pend_head);
    if (h - atomic_load(&pend_tail) >= PEND) return;  // full: drop
    pend_seq[h % PEND] = (uint64_t)seq;
    pend_t0[h % PEND] = (uint64_t)t0;
    atomic_store(&pend_head, h + 1);
}

JNIEXPORT void JNICALL Java_io_github_dylanneve1_avfdisplay_Scfb_stop(JNIEnv *e, jclass c) {
    (void)e, (void)c;
    atomic_store(&stop_flag, 1);
}

static void copy_rows(uint8_t *dst, int32_t dstride_px, const uint8_t *src, uint32_t sstride, uint32_t w,
                      uint32_t h, int swap_rb) {
    for (uint32_t y = 0; y < h; y++) {
        uint32_t *d = (uint32_t *)(dst + (size_t)y * (size_t)dstride_px * 4);
        const uint32_t *s = (const uint32_t *)(src + (size_t)y * sstride);
        if (!swap_rb) {
            memcpy(d, s, (size_t)w * 4);
        } else {
            for (uint32_t x = 0; x < w; x++) {
                uint32_t v = s[x];
                d[x] = (v & 0xff00ff00u) | ((v & 0xffu) << 16) | ((v >> 16) & 0xffu);
            }
        }
    }
}

// Runs until stop(). Returns 0, or a negative step number on failure.
JNIEXPORT jint JNICALL Java_io_github_dylanneve1_avfdisplay_Scfb_presentLoop(JNIEnv *env, jclass c, jobject surface,
                                                                          jlong base, jlong size) {
    (void)c;
    volatile struct scfb_hdr *h = (volatile struct scfb_hdr *)(uintptr_t)base;
    ANativeWindow *win = ANativeWindow_fromSurface(env, surface);
    if (!win) return -1;
    atomic_store(&stop_flag, 0);
    uint64_t last = 0;
    uint32_t gw = 0, gh = 0, gfmt = 0;
    uint64_t last_copy_ns = 0;
    int swap = 0;
    while (!atomic_load(&stop_flag)) {
        if (h->magic != SCFB_MAGIC || !(h->flags & 1)) {
            struct timespec ts = {0, 2000000};
            nanosleep(&ts, NULL);
            continue;
        }
        uint64_t seq = __atomic_load_n(&h->frame_seq, __ATOMIC_ACQUIRE);
        // POLL: the guest draws without publishing (a text console): copy at ~60 Hz anyway.
        int poll_due = (h->flags & 2) && now_ns() - last_copy_ns >= 16666666ull;
        if (seq == last && !poll_due) {
            struct timespec ts = {0, 250000};
            nanosleep(&ts, NULL);
            continue;
        }
        uint64_t t_seen = now_ns();
        __atomic_store_n(&h->host_reading, seq, __ATOMIC_RELEASE);
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
        // The guest publishes front before frame_seq, so front matches seq
        // unless it already moved on (then we show the newer frame).
        uint32_t front = h->front & 1;
        uint64_t in_seq = h->input_seq;
        if (h->width != gw || h->height != gh || h->format != gfmt) {
            gw = h->width;
            gh = h->height;
            gfmt = h->format;
            // BGRX guests: ask for a BGRA buffer queue (HAL_PIXEL_FORMAT_BGRA_8888 = 5)
            // so the copy stays a memcpy; swizzle only if gralloc refuses it.
            swap = 0;
            int fmt = AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM;
            if (gfmt == FOURCC_XR24) fmt = 5;
            if (ANativeWindow_setBuffersGeometry(win, (int32_t)gw, (int32_t)gh, fmt) != 0 && fmt == 5) {
                ANativeWindow_setBuffersGeometry(win, (int32_t)gw, (int32_t)gh, AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM);
                swap = 1;
            }
            LOGI("guest framebuffer %ux%u stride %u format 0x%x swizzle %d", gw, gh, h->stride, h->format, swap);
        }
        uint64_t off = h->buf_offset[front];
        if (off + (uint64_t)h->stride * gh > (uint64_t)size) return -2;
        ANativeWindow_Buffer buf;
        if (ANativeWindow_lock(win, &buf, NULL) != 0) return -3;
        uint64_t t_c0 = now_ns();
        uint32_t w = gw < (uint32_t)buf.width ? gw : (uint32_t)buf.width;
        uint32_t hh = gh < (uint32_t)buf.height ? gh : (uint32_t)buf.height;
        copy_rows(buf.bits, buf.stride, (const uint8_t *)(uintptr_t)(base + off), h->stride, w, hh, swap);
        uint64_t t_c1 = now_ns();
        __atomic_store_n(&h->host_seq, seq, __ATOMIC_RELEASE);
        __atomic_store_n(&h->host_reading, 0, __ATOMIC_RELEASE);
        ANativeWindow_unlockAndPost(win);
        uint64_t t_post = now_ns();
        h->host_ns = t_post;

        last_copy_ns = t_post;
        if (seq == last) continue;  // a POLL refresh, not a new frame
        if (st_frames == 0) st_first_ns = t_seen;
        st_last_ns = t_post;
        st_frames++;
        if (last && seq > last + 1) st_missed += seq - last - 1;
        st_copy_ns += t_c1 - t_c0;
        if (t_c1 - t_c0 > st_copy_max) st_copy_max = t_c1 - t_c0;
        st_guest_seq = seq;
        last = seq;

        // Every pending input the guest had consumed when it drew this frame.
        uint64_t tail = atomic_load(&pend_tail), head = atomic_load(&pend_head);
        while (tail != head && pend_seq[tail % PEND] <= in_seq) {
            int n = atomic_load(&lat_n);
            if (n < LAT) {
                lat_seen[n] = (int64_t)(t_seen - pend_t0[tail % PEND]);
                lat_posted[n] = (int64_t)(t_post - pend_t0[tail % PEND]);
                atomic_store(&lat_n, n + 1);
            }
            tail++;
        }
        atomic_store(&pend_tail, tail);
    }
    ANativeWindow_release(win);
    return 0;
}

// [frames, missed, copy_ns_total, copy_ns_max, first_ns, last_ns, guest_seq, latency_count]
JNIEXPORT void JNICALL Java_io_github_dylanneve1_avfdisplay_Scfb_stats(JNIEnv *env, jclass c, jlongArray out) {
    (void)c;
    jlong v[8] = {(jlong)st_frames, (jlong)st_missed, (jlong)st_copy_ns, (jlong)st_copy_max,
                  (jlong)st_first_ns, (jlong)st_last_ns, (jlong)st_guest_seq, (jlong)atomic_load(&lat_n)};
    (*env)->SetLongArrayRegion(env, out, 0, 8, v);
}

JNIEXPORT void JNICALL Java_io_github_dylanneve1_avfdisplay_Scfb_resetStats(JNIEnv *env, jclass c) {
    (void)env, (void)c;
    st_frames = st_missed = st_copy_ns = st_copy_max = st_first_ns = st_last_ns = 0;
    atomic_store(&lat_n, 0);
}

JNIEXPORT jint JNICALL Java_io_github_dylanneve1_avfdisplay_Scfb_latencies(JNIEnv *env, jclass c, jlongArray seen,
                                                                        jlongArray posted) {
    (void)c;
    int n = atomic_load(&lat_n);
    int cap = (*env)->GetArrayLength(env, seen);
    if (n > cap) n = cap;
    (*env)->SetLongArrayRegion(env, seen, 0, n, (const jlong *)lat_seen);
    (*env)->SetLongArrayRegion(env, posted, 0, n, (const jlong *)lat_posted);
    return n;
}

// Header snapshot for the report: [magic, w, h, stride, format, frame_seq, input_seq, host_seq].
JNIEXPORT void JNICALL Java_io_github_dylanneve1_avfdisplay_Scfb_header(JNIEnv *env, jclass c, jlong base,
                                                                     jlongArray out) {
    (void)c;
    volatile struct scfb_hdr *h = (volatile struct scfb_hdr *)(uintptr_t)base;
    jlong v[8] = {h->magic, h->width, h->height, h->stride, h->format,
                  (jlong)h->frame_seq, (jlong)h->input_seq, (jlong)h->host_seq};
    (*env)->SetLongArrayRegion(env, out, 0, 8, v);
}
