// SPDX-License-Identifier: AGPL-3.0-or-later
package io.github.dylanneve1.avfdisplay

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.random.Random

/**
 * Full-screen SurfaceView showing the guest's shared framebuffer, touches
 * forwarded to the guest's virtio-input multi-touch device, and a scripted run:
 *
 *   am start -n io.github.dylanneve1.avfdisplay/.MainActivity --ez autorun true
 *     [--ez stock_display false|true] [--es gpu_backend 2d] [--el mem_mib 512]
 *     [--ei bench_s 5] [--ei run_s 60] [--ei taps 100] [--es shm auto|sharedmemory|ashmem]
 *     [--es fmt xb24|xr24] [--ei bufs 2|1] [--ei scale_div 1] [--es tag display]
 *
 * Guest files: files/guest/{Image,initrd.img} in internal storage (the runner
 * streams them in with run-as). Results: <external files>/<tag>-{report.txt,
 * result.json,console.txt}.
 */
class MainActivity : Activity() {
    private lateinit var surface: SurfaceView
    private lateinit var status: TextView
    private val surfaceReady = CountDownLatch(1)
    @Volatile private var dvm: DisplayVm? = null
    @Volatile private var realTouchReports = 0
    private val report = StringBuilder()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }
        surface = SurfaceView(this)
        status = TextView(this).apply {
            setTextColor(Color.WHITE)
            setBackgroundColor(0x80000000.toInt())
            textSize = 11f
            gravity = Gravity.BOTTOM
            setPadding(16, 16, 16, 16)
        }
        val root = FrameLayout(this)
        root.addView(surface, FrameLayout.LayoutParams(-1, -1))
        root.addView(status, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM))
        setContentView(root)
        window.insetsController?.let {
            it.hide(WindowInsets.Type.systemBars())
            it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        surface.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(h: SurfaceHolder) = surfaceReady.countDown()
            override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, hh: Int) {}
            override fun surfaceDestroyed(h: SurfaceHolder) { Scfb.stop() }
        })
        surface.setOnTouchListener { v, ev ->
            val d = dvm
            if (d != null && d.sendTouch(ev)) realTouchReports++
            if (ev.actionMasked == MotionEvent.ACTION_UP) v.performClick()
            true
        }
        if (savedInstanceState == null && intent.getBooleanExtra("autorun", false)) {
            surface.post { Thread({ runCatching { run() }.onFailure { out("crashed: $it"); Log.e(TAG, "crash", it) } }, "run").start() }
        }
    }

    private fun out(s: String) {
        Log.i(TAG, s)
        synchronized(report) { report.append(s).append('\n') }
        runOnUiThread {
            status.text = (status.text.toString() + s + "\n").lines().takeLast(14).joinToString("\n")
        }
    }

    private fun pct(v: List<Long>, p: Double) = if (v.isEmpty()) 0.0 else v.sorted()[((v.size - 1) * p).toInt()] / 1e6

    private fun run() {
        val i = intent
        val viewW = surface.width
        val viewH = surface.height
        val div = i.getIntExtra("scale_div", 1).coerceAtLeast(1)
        // Guest framebuffer = the view's pixel size (optionally divided), even dimensions.
        val gw = (viewW / div) and 1.inv()
        val gh = (viewH / div) and 1.inv()
        val opts = DisplayVm.Options(
            width = gw, height = gh, dpi = resources.displayMetrics.densityDpi / div,
            memMib = i.getLongExtra("mem_mib", 512),
            stockDisplay = i.getBooleanExtra("stock_display", false),
            gpuBackend = i.getStringExtra("gpu_backend"),
            benchSec = i.getIntExtra("bench_s", 5),
            runSec = i.getIntExtra("run_s", 60),
            taps = i.getIntExtra("taps", 100),
            shm = i.getStringExtra("shm") ?: "auto",
            format = i.getStringExtra("fmt") ?: "xb24",
            bufs = i.getIntExtra("bufs", 2),
            tag = i.getStringExtra("tag") ?: "display",
        )
        val res = linkedMapOf<String, Any?>()
        out("# AVF display/touch test  view=${viewW}x$viewH guest=${gw}x$gh dpi=${opts.dpi} mem=${opts.memMib}MiB " +
            "stock_display=${opts.stockDisplay} gpu_backend=${opts.gpuBackend} fmt=${opts.format}")
        res["view"] = "${viewW}x$viewH"; res["guest_fb"] = "${gw}x$gh"; res["stock_display"] = opts.stockDisplay; res["bufs"] = opts.bufs
        surfaceReady.await(10, TimeUnit.SECONDS)
        val sized = CountDownLatch(1)
        runOnUiThread { surface.holder.setFixedSize(gw, gh); sized.countDown() }
        sized.await(2, TimeUnit.SECONDS)
        SystemClock.sleep(300)

        val d = DisplayVm(this, opts, ::out)
        val verdict = try {
            execute(d, opts, viewW, res)
        } catch (t: Throwable) {
            out("FAILED: $t"); Log.e(TAG, "run", t); "CRASH ${t.javaClass.simpleName}: ${t.message}"
        }
        Scfb.stop()
        d.stopVm()
        d.close()
        res.putAll(d.result)
        res["verdict"] = verdict
        out("VERDICT: $verdict")
        val dir = getExternalFilesDir(null) ?: filesDir
        File(dir, "${opts.tag}-console.txt").writeText(d.console.toString())
        File(dir, "${opts.tag}-report.txt").writeText(synchronized(report) { report.toString() })
        File(dir, "${opts.tag}-result.json").writeText(toJson(res))
    }

    private fun waitLine(d: DisplayVm, prefix: String, timeoutMs: Long, stopped: () -> Boolean = { false }): String? {
        val end = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < end && !stopped()) {
            d.console.lines().firstOrNull { it.contains(prefix) }?.let { return it }
            SystemClock.sleep(50)
        }
        return null
    }

    private fun execute(d: DisplayVm, opts: DisplayVm.Options, viewW: Int, res: MutableMap<String, Any?>): String {
        d.checkDisplayService()
        if (!d.createRegion()) return "REGION_FAILED"
        d.consoleListener = { line ->
            if (line.startsWith("SCFB") || line.startsWith("INPUTDEV") || line.startsWith("VIRTIO")) out("guest: $line")
        }
        val presenter = Thread({
            // The surface can be mid-resize right after setFixedSize: retry until it takes.
            var rc = -1
            for (attempt in 0 until 100) {
                val sf = surface.holder.surface
                if (sf != null && sf.isValid) {
                    rc = Scfb.presentLoop(sf, d.base, d.regionSize)
                    if (rc != -1) break
                }
                SystemClock.sleep(100)
            }
            out("present loop ended rc=$rc")
        }, "present").apply { start() }

        val gdir = File(filesDir, "guest")
        val kernel = File(gdir, "Image"); val initrd = File(gdir, "initrd.img")
        if (!kernel.isFile || !initrd.isFile) return "GUEST_FILES_MISSING"
        out("params: ${d.params()}")
        val tRun = SystemClock.elapsedRealtime()
        if (!d.buildAndRun(kernel, initrd)) return "VM_START_FAILED"
        dvm = d
        d.setScale(opts.width.toFloat() / viewW)

        val mapped = waitLine(d, "SCFB mapped", 20000, stopped = { d.stoppedLatch?.count == 0L }) ?: return "GUEST_NO_REGION (${d.console.lines().lastOrNull { it.startsWith("SCFB") }})"
        res["guest_mapped"] = mapped
        res["host_pre_seen_by_guest"] = mapped.contains("host_pre=1")
        val st = LongArray(12)
        // First frame on the screen.
        val tFirst = SystemClock.elapsedRealtime() + 15000
        while (SystemClock.elapsedRealtime() < tFirst) { Scfb.stats(st); if (st[0] > 0) break; SystemClock.sleep(10) }
        res["first_frame_ms_after_run"] = if (st[0] > 0) SystemClock.elapsedRealtime() - tRun else null
        if (st[0] == 0L) return "NO_FRAMES (guest mapped the region but nothing reached the host: memory not shared?)"
        out("first frame presented ${res["first_frame_ms_after_run"]} ms after run()")

        // Throughput: the guest redraws every pixel back to back for bench_s.
        if (opts.benchSec > 0) {
            Scfb.resetStats()
            val done = waitLine(d, "SCFB bench=done", opts.benchSec * 1000L + 20000)
            Scfb.stats(st)
            val spanMs = (st[5] - st[4]) / 1e6
            res["bench_guest"] = done
            res["bench_host_frames"] = st[0]; res["bench_host_missed"] = st[1]
            res["bench_host_fps"] = if (spanMs > 0) "%.1f".format(st[0] * 1000 / spanMs) else null
            res["bench_copy_ms_avg"] = if (st[0] > 0) "%.2f".format(st[2] / 1e6 / st[0]) else null
            res["bench_copy_ms_max"] = "%.2f".format(st[3] / 1e6)
            res["bench_seqlock_waits_retries_torn"] = listOf(st[8], st[9], st[10])
            res["bench_frames_with_mixed_rows"] = st[11]
            out("bench: guest [$done]; host presented ${st[0]} frames (${res["bench_host_fps"]} fps), " +
                "skipped ${st[1]}, copy avg ${res["bench_copy_ms_avg"]} ms max ${res["bench_copy_ms_max"]} ms; " +
                "seqlock waits/retries/torn ${res["bench_seqlock_waits_retries_torn"]}, frames with rows of two frames ${st[11]}")
        }

        // Touch: scripted reports through the same path as real touches.
        val inputs = waitLine(d, "SCFB inputs=", 5000)
        res["guest_inputs"] = inputs
        d.console.lines().filter { it.startsWith("INPUTDEV") }.let { res["guest_input_devices"] = it }
        if (inputs == null || inputs.endsWith("=0")) return "NO_TOUCH_DEVICE (${inputs ?: "guest silent"})"
        Scfb.resetStats()
        val scale = opts.width.toFloat() / viewW
        val rnd = Random(1)
        val seq0 = d.inputSeq
        var lastX = 0; var lastY = 0
        for (t in 0 until opts.taps) {
            val gx = rnd.nextInt(100, opts.width - 100); val gy = rnd.nextInt(200, opts.height - 100)
            val down = SystemClock.uptimeMillis()
            val acts = listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE, MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP)
            acts.forEachIndexed { k, a ->
                val x = gx + k * 20; val y = gy + k * 10
                val ev = MotionEvent.obtain(down, SystemClock.uptimeMillis(), a, x / scale, y / scale, 0)
                d.sendTouch(ev); ev.recycle()
                if (a != MotionEvent.ACTION_UP) { lastX = x; lastY = y }
                SystemClock.sleep(16)
            }
        }
        val sent = d.inputSeq - seq0
        SystemClock.sleep(1000)
        val seen = LongArray(8192); val posted = LongArray(8192)
        val n = Scfb.latencies(seen, posted)
        val sl = seen.take(n); val pl = posted.take(n)
        val touchLines = d.console.lines().filter { it.startsWith("TOUCH") }
        res["touch_sent"] = sent
        res["touch_guest_reports"] = touchLines.size
        res["touch_last_guest_line"] = touchLines.lastOrNull { it.contains(" s0=") }
        res["touch_last_sent_xy"] = "$lastX,$lastY"
        res["latency_samples"] = n
        res["latency_seen_ms_p50_p90_p99"] = listOf(pct(sl, .5), pct(sl, .9), pct(sl, .99))
        res["latency_posted_ms_p50_p90_p99"] = listOf(pct(pl, .5), pct(pl, .9), pct(pl, .99))
        out("touch: sent $sent reports, guest logged ${touchLines.size}; last sent (guest px) $lastX,$lastY; " +
            "guest: ${res["touch_last_guest_line"]}")
        out("input->frame seen ms p50/p90/p99: ${res["latency_seen_ms_p50_p90_p99"]}; " +
            "->posted: ${res["latency_posted_ms_p50_p90_p99"]}")

        // Interactive window: real touches (or `adb shell input swipe`) are forwarded.
        Scfb.resetStats()
        realTouchReports = 0
        val tEnd = SystemClock.elapsedRealtime() + opts.runSec * 1000L
        out("interactive for ${opts.runSec} s: touch the screen")
        while (SystemClock.elapsedRealtime() < tEnd) SystemClock.sleep(200)
        Scfb.stats(st)
        val n2 = Scfb.latencies(seen, posted)
        res["real_touch_reports"] = realTouchReports
        res["real_touch_latency_samples"] = n2
        res["real_touch_latency_posted_ms_p50_p90"] = listOf(pct(posted.take(n2), .5), pct(posted.take(n2), .9))
        val spanMs = (st[5] - st[4]) / 1e6
        res["idle_host_fps"] = if (spanMs > 0) "%.1f".format(st[0] * 1000 / spanMs) else null
        res["idle_seqlock_waits_retries_torn"] = listOf(st[8], st[9], st[10])
        out("interactive: ${realTouchReports} real touch reports, latency posted p50/p90 ${res["real_touch_latency_posted_ms_p50_p90"]}; " +
            "steady host fps ${res["idle_host_fps"]}, seqlock waits/retries/torn ${res["idle_seqlock_waits_retries_torn"]}")
        presenter.isDaemon
        return when {
            touchLines.isEmpty() -> "TOUCH_NOT_REACHING_GUEST"
            else -> "OK"
        }
    }

    private fun toJson(m: Map<String, Any?>): String {
        fun v(x: Any?): String = when (x) {
            null -> "null"
            is Number, is Boolean -> x.toString()
            is List<*> -> x.joinToString(",", "[", "]") { v(it) }
            else -> "\"" + x.toString().replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\""
        }
        return m.entries.joinToString(",\n  ", "{\n  ", "\n}\n") { "\"${it.key}\": ${v(it.value)}" }
    }

    override fun onDestroy() {
        Scfb.stop()
        super.onDestroy()
    }

    companion object { const val TAG = "AvfDisplay" }
}
