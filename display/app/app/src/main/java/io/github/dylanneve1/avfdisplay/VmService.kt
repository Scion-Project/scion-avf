// SPDX-License-Identifier: AGPL-3.0-or-later
package io.github.dylanneve1.avfdisplay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import java.io.File

/**
 * Runs an os-mode VM (HackiOS's XNU via avfboot) as a foreground service, so the VM outlives the
 * activity. Leaving the app keeps iOS running, and coming back reattaches the display (the
 * activity's presenter copies from the same shared framebuffer) instead of starting it again.
 *
 * Started once by MainActivity's autorun with the activity's intent extras plus view_w/view_h.
 * After run_s seconds, or when the VM stops, it writes <tag>-result.json and <tag>-console.txt to
 * the external files dir and stops itself.
 */
class VmService : Service() {
    /** The running VM, for the activity to attach to. */
    class Session(val vm: DisplayVm, val opts: DisplayVm.Options) {
        @Volatile var done = false
        @Volatile var realTouchReports = 0
    }

    companion object {
        const val TAG = "AvfDisplay"
        private const val CHANNEL = "vm"
        @Volatile var session: Session? = null
        val log = StringBuffer()
        fun out(s: String) {
            Log.i(TAG, s)
            log.append(s).append('\n')
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Virtual machine", NotificationManager.IMPORTANCE_LOW))
        val n = Notification.Builder(this, CHANNEL)
            .setContentTitle("VM running")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .build()
        startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        if (session != null || intent == null) return START_NOT_STICKY
        val opts = MainActivity.options(intent, intent.getIntExtra("view_w", 1080), intent.getIntExtra("view_h", 2424),
            resources.displayMetrics.densityDpi)
        Thread({ run(intent, opts) }, "vm").start()
        return START_NOT_STICKY
    }

    private fun run(intent: Intent, opts: DisplayVm.Options) {
        val res = linkedMapOf<String, Any?>()
        val dir = getExternalFilesDir(null) ?: filesDir
        val d = DisplayVm(this, opts, ::out)
        val s = Session(d, opts)
        val verdict = try {
            if (!d.createRegion()) "REGION_FAILED" else {
                session = s
                d.consoleListener = { line ->
                    if (line.contains("MiniIOMobileFramebuffer: shared") || line.contains("virtio-input") || line.contains("panic"))
                        out("guest: ${line.take(200)}")
                }
                val gdir = File(filesDir, "guest")
                val kernel = File(gdir, intent.getStringExtra("kernel") ?: "Image")
                val initrd = File(gdir, intent.getStringExtra("initrd") ?: "initrd.img")
                if (!kernel.isFile || !initrd.isFile) "GUEST_FILES_MISSING (${kernel.name}, ${initrd.name})"
                else {
                    out("params: ${d.params()}")
                    val tRun = SystemClock.elapsedRealtime()
                    if (!d.buildAndRun(kernel, initrd)) "VM_START_FAILED" else {
                        val st = LongArray(12)
                        var firstFrame: Long? = null
                        var lastSave = 0L
                        val end = tRun + opts.runSec * 1000L
                        out("running for ${opts.runSec} s")
                        while (SystemClock.elapsedRealtime() < end && d.stoppedLatch?.count != 0L) {
                            Scfb.stats(st)
                            val now = SystemClock.elapsedRealtime()
                            if (firstFrame == null && st[0] > 0) {
                                firstFrame = now - tRun
                                out("first published frame $firstFrame ms after run()")
                            }
                            if (now - lastSave > 5000) {
                                lastSave = now
                                runCatching { File(dir, "${opts.tag}-console.txt").writeText(d.console.toString()) }
                                out("t=${(now - tRun) / 1000}s frames=${st[0]} guest_seq=${st[6]} touches=${s.realTouchReports}")
                            }
                            SystemClock.sleep(200)
                        }
                        Scfb.stats(st)
                        res["first_frame_ms_after_run"] = firstFrame
                        res["frames_presented"] = st[0]
                        res["guest_frame_seq"] = st[6]
                        res["real_touch_reports"] = s.realTouchReports
                        res["console_bytes"] = d.console.length
                        if (firstFrame != null) "OK" else "NO_FRAMES"
                    }
                }
            }
        } catch (t: Throwable) {
            out("FAILED: $t"); Log.e(TAG, "vm", t); "CRASH ${t.javaClass.simpleName}: ${t.message}"
        }
        s.done = true
        Scfb.stop()
        d.stopVm()
        res.putAll(d.result)
        res["verdict"] = verdict
        out("VERDICT: $verdict")
        runCatching { File(dir, "${opts.tag}-console.txt").writeText(d.console.toString()) }
        runCatching { File(dir, "${opts.tag}-report.txt").writeText(log.toString()) }
        runCatching {
            File(dir, "${opts.tag}-result.json").writeText(res.entries.joinToString(",\n  ", "{\n  ", "\n}\n") {
                "\"${it.key}\": " + when (val v = it.value) {
                    null -> "null"
                    is Number, is Boolean -> v.toString()
                    else -> "\"" + v.toString().replace("\\", "\\\\").replace("\"", "\\\"") + "\""
                }
            })
        }
        session = null
        d.close()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }
}
