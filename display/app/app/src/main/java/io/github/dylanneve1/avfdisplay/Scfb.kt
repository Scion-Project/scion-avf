// SPDX-License-Identifier: AGPL-3.0-or-later
package io.github.dylanneve1.avfdisplay

import android.view.Surface

/** JNI side of the shared framebuffer (src/main/cpp/scfb_jni.c). */
object Scfb {
    init {
        System.loadLibrary("scfb")
    }

    /** mmap(fd, size) shared read/write; 0 on failure. */
    @JvmStatic external fun map(fd: Int, size: Long): Long

    /** Opens the libcutils ashmem device directly and sizes a region; fd or -errno. */
    @JvmStatic external fun ashmemCreate(name: String, size: Long): Int

    /** Zeroes the header and stamps host_ns, so the guest can tell the memory is shared. */
    @JvmStatic external fun prime(base: Long)

    /** Blocks, copying every published guest frame into [surface], until [stop]. */
    @JvmStatic external fun presentLoop(surface: Surface, base: Long, size: Long): Int
    @JvmStatic external fun stop()

    /** The app sent input report [seq] (1-based) at CLOCK_MONOTONIC [t0Ns]. */
    @JvmStatic external fun noteInput(seq: Long, t0Ns: Long)

    /** [frames, missed, copy_ns_total, copy_ns_max, first_ns, last_ns, guest_seq, latency_count] */
    @JvmStatic external fun stats(out: LongArray)
    @JvmStatic external fun resetStats()
    @JvmStatic external fun latencies(seen: LongArray, posted: LongArray): Int

    /** [magic, w, h, stride, format, frame_seq, input_seq, host_seq] */
    @JvmStatic external fun header(base: Long, out: LongArray)
}
