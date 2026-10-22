// SPDX-License-Identifier: AGPL-3.0-or-later
package io.github.dylanneve1.avfdisplay

import android.content.Context
import android.os.ParcelFileDescriptor
import android.os.SharedMemory
import android.os.SystemClock
import android.system.Os
import android.util.Log
import android.view.MotionEvent
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Boots the display test guest in a non-protected custom AVF VM and wires up
 * display and touch, the ways a sideloaded app can:
 *
 *  - display: a "Scion shared framebuffer" (display/SCFB.md). An ashmem region is
 *    added to the VM's raw config as a CustomMemoryBackingFile, so crosvm maps it
 *    as a slice of guest RAM; the app maps the same fd and copies published
 *    frames into a SurfaceView. The Java API never fills that field, so the
 *    IVirtualizationService binder the framework uses is wrapped in a proxy that
 *    adds it to createVm()'s config.
 *  - touch: virtio-input multi-touch. With [Options.stockDisplay] the stock way
 *    (DisplayConfig + useTouch + VirtualMachine.sendMultiTouchEvent, which also
 *    makes crosvm add a virtio-gpu); otherwise the proxy adds the multi-touch
 *    device itself and the app writes evdev events into its socket.
 *
 * It also checks whether the stock display hand-off (crosvm's
 * ICrosvmAndroidDisplayService via virtualizationservice) is reachable at all.
 */
class DisplayVm(private val ctx: Context, private val opts: Options, private val log: (String) -> Unit) {
    data class Options(
        val width: Int,
        val height: Int,
        val dpi: Int,
        val memMib: Long = 512,
        // true: DisplayConfig + useTouch, the stock way. On the Pixel 10 (DP11) crosvm
        // refuses --android-display-service, so the VM does not start; see docs/DISPLAY-INPUT.md.
        val stockDisplay: Boolean = false,
        val gpuBackend: String? = null,
        val benchSec: Int = 5,
        val runSec: Int = 60,
        val taps: Int = 100,
        val shm: String = "auto",     // auto | sharedmemory | ashmem
        val format: String = "xb24",  // guest pixel layout: xb24 (RGBX) | xr24 (BGRX)
        val bufs: Int = 2,            // 2: guest flips a pair; 1: draws in place under the seqlock (like XNU)
        // Any other OS (HackiOS's XNU via avfboot): no Linux test-guest params, just the scfb.* ones
        // plus extraParams, the given disk images (read-only virtio-blk, in order), and cpus.
        val osMode: Boolean = false,
        val extraParams: String = "",
        val disks: List<String> = emptyList(),
        val matchHostCpus: Boolean = false,
        val cpuCount: Int = 0,        // > 0: exactly this many vCPUs (raw config CpuTopology.cpuCount; the Java API has 1 or host)
        val tag: String = "display",
    )

    companion object {
        const val TAG = "AvfDisplay"
        private const val P = "android.system.virtualmachine"
        private const val VS = "android.system.virtualizationservice"
        const val VM_NAME = "avfdisplay"
        const val RAM_BASE = 0x8000_0000L
        const val REGION_MIB = 32L
        // crosvm puts the FDT in the last 2 MiB of RAM; keep clear of it.
        const val TOP_GAP_MIB = 4L
    }

    val regionAddr = RAM_BASE + (opts.memMib - TOP_GAP_MIB - REGION_MIB) * 1024 * 1024
    val regionSize = REGION_MIB * 1024 * 1024
    var base = 0L; private set
    private var shmFd: ParcelFileDescriptor? = null
    private var sharedMemory: SharedMemory? = null
    private var vsInstance: Any? = null   // keeps the patched VirtualizationService alive
    private var vm: Any? = null
    private var vmCls: Class<*>? = null
    private var ownTouchSock: ParcelFileDescriptor? = null
    @Volatile var inputSeq = 0L; private set
    @Volatile var touchScale = 1f
    @Volatile var touchScaleY = 1f
    val result = linkedMapOf<String, Any?>()
    val console = StringBuffer()
    @Volatile var consoleListener: ((String) -> Unit)? = null

    // ---- reflection helpers ---------------------------------------------------

    private fun cls(n: String) = Class.forName(n)
    private fun find(c: Class<*>, name: String, argc: Int): Method =
        c.methods.firstOrNull { it.name == name && it.parameterCount == argc }
            ?: c.declaredMethods.first { it.name == name && it.parameterCount == argc }.also { it.isAccessible = true }
    private fun call(o: Any, name: String, vararg a: Any?): Any? = try {
        find(o.javaClass, name, a.size).invoke(o, *a)
    } catch (e: InvocationTargetException) {
        throw e.targetException
    }
    private fun describe(t: Throwable): String =
        (if (t is InvocationTargetException) t.targetException ?: t else t).let { "${it.javaClass.name}: ${it.message}" }

    // ---- 1. is the stock display hand-off reachable? --------------------------

    fun checkDisplayService() {
        val r = runCatching {
            val sm = cls("android.os.ServiceManager")
            sm.getMethod("checkService", String::class.java).invoke(null, "android.system.virtualizationservice")
        }
        val v = r.fold({ if (it == null) "null (lookup refused or service absent)" else "binder $it" }, { "error ${describe(it)}" })
        log("stock display hand-off: ServiceManager.checkService(android.system.virtualizationservice) = $v")
        result["virtualizationservice_lookup"] = if (r.getOrNull() != null) "ok" else v
    }

    // ---- 2. shared memory ----------------------------------------------------

    fun createRegion(): Boolean {
        fun kind(fd: Int) = runCatching { Os.readlink("/proc/self/fd/$fd") }.getOrElse { "?" }
        var fd = -1
        if (opts.shm != "ashmem") {
            val sm = SharedMemory.create("scfb", regionSize.toInt())
            sharedMemory = sm
            // SharedMemory has no public fd getter; its parcel form is just the fd.
            val parcel = android.os.Parcel.obtain()
            sm.writeToParcel(parcel, 0)
            parcel.setDataPosition(0)
            val pfd = parcel.readFileDescriptor()
            parcel.recycle()
            val k = kind(pfd.fd)
            log("SharedMemory fd -> $k")
            result["sharedmemory_kind"] = k
            if (opts.shm == "sharedmemory" || k.startsWith("/dev/ashmem")) { shmFd = pfd; fd = pfd.fd } else pfd.close()
        }
        if (fd < 0) {
            val raw = Scfb.ashmemCreate("scfb", regionSize)
            if (raw < 0) {
                log("ashmem device open failed: errno ${-raw}")
                result["region"] = "ashmem open failed errno ${-raw}"
                return false
            }
            shmFd = ParcelFileDescriptor.adoptFd(raw)
            fd = raw
            log("ashmem device fd -> ${kind(fd)}")
        }
        result["region_fd"] = kind(fd)
        base = Scfb.map(fd, regionSize)
        if (base == 0L) {
            log("mmap of the region failed"); result["region"] = "mmap failed"; return false
        }
        Scfb.prime(base)
        log("region: ${regionSize shr 20} MiB at guest IPA 0x${regionAddr.toString(16)}, host ${"0x%x".format(base)}")
        result["region_ipa"] = "0x" + regionAddr.toString(16)
        return true
    }

    // ---- 3. hook createVm to add the backing file (and our own touch device) --

    private fun installHook() {
        val vsCls = cls("$P.VirtualizationService")
        val gi = vsCls.getDeclaredMethod("getInstance").apply { isAccessible = true }
        val inst = gi.invoke(null)!!
        vsInstance = inst
        val f = vsCls.getDeclaredField("mBinder").apply { isAccessible = true }
        val orig = f.get(inst)!!
        val ivs = cls("$VS.IVirtualizationService")
        val proxy = Proxy.newProxyInstance(ivs.classLoader, arrayOf(ivs)) { _, m, args ->
            if (m.name == "createVm" && args != null) patchConfig(args[0])
            try {
                m.invoke(orig, *(args ?: emptyArray()))
            } catch (e: InvocationTargetException) {
                throw e.targetException
            }
        }
        f.set(inst, proxy)
        log("hooked IVirtualizationService.createVm")
    }

    private fun patchConfig(cfg: Any) {
        try {
            val raw = call(cfg, "getRawConfig")!!
            val rc = raw.javaClass
            val cmbfCls = cls("$VS.CustomMemoryBackingFile")
            val b = cmbfCls.getConstructor().newInstance()
            cmbfCls.getField("file").set(b, shmFd)
            cmbfCls.getField("rangeStart").setLong(b, regionAddr)
            cmbfCls.getField("size").setLong(b, regionSize)
            val arr = java.lang.reflect.Array.newInstance(cmbfCls, 1)
            java.lang.reflect.Array.set(arr, 0, b)
            rc.getField("customMemoryBackingFiles").set(raw, arr)

            if (opts.cpuCount > 0) {
                val ctCls = cls("$VS.CpuOptions\$CpuTopology")
                val co = rc.getField("cpuOptions").get(raw) ?: cls("$VS.CpuOptions").getConstructor().newInstance().also {
                    rc.getField("cpuOptions").set(raw, it)
                }
                co.javaClass.getField("cpuTopology").set(co, ctCls.getMethod("cpuCount", Int::class.javaPrimitiveType).invoke(null, opts.cpuCount))
                log("createVm: ${opts.cpuCount} vCPUs")
            }
            if (!opts.stockDisplay) {
                val pair = ParcelFileDescriptor.createSocketPair()
                ownTouchSock = pair[0]
                val mtCls = cls("$VS.InputDevice\$MultiTouch")
                val mt = mtCls.getConstructor().newInstance()
                mtCls.getField("width").setInt(mt, opts.width)
                mtCls.getField("height").setInt(mt, opts.height)
                mtCls.getField("pfd").set(mt, pair[1])
                runCatching { mtCls.getField("name").set(mt, "scion-touch") }
                val idCls = cls("$VS.InputDevice")
                val dev = idCls.getMethod("multiTouch", mtCls).invoke(null, mt)
                val old = rc.getField("inputDevices").get(raw) as Array<*>
                val na = java.lang.reflect.Array.newInstance(idCls, old.size + 1)
                old.forEachIndexed { i, d -> java.lang.reflect.Array.set(na, i, d) }
                java.lang.reflect.Array.set(na, old.size, dev)
                rc.getField("inputDevices").set(raw, na)
            }
            val inputs = (rc.getField("inputDevices").get(raw) as Array<*>).joinToString { it.toString().take(60) }
            val disp = rc.getField("displayConfig").get(raw)
            val gpu = runCatching { rc.getField("gpuConfig").get(raw) }.getOrNull()
            log("createVm: +customMemoryBackingFile ipa=0x${regionAddr.toString(16)} size=0x${regionSize.toString(16)}; " +
                "displayConfig=${disp != null} gpuConfig=${gpu != null} inputDevices=[$inputs]")
        } catch (t: Throwable) {
            log("patchConfig FAILED: ${describe(t)}")
            result["hook"] = "patch failed: ${describe(t)}"
        }
    }

    // ---- 4. build + run -------------------------------------------------------

    fun params(): String {
        if (opts.osMode) {
            // A leading "-" (e.g. "-v") must not come first: crosvm takes it for an option.
            return "scfb.addr=0x${regionAddr.toString(16)} scfb.size=0x${regionSize.toString(16)} " +
                "scfb.w=${opts.width} scfb.h=${opts.height} ${opts.extraParams}".trim()
        }
        val memParam = opts.memMib - TOP_GAP_MIB - REGION_MIB
        return "console=hvc0 earlycon=uart8250,mmio,0x3f8 panic=-1 rdinit=/init mem=${memParam}M " +
            "scfb.addr=0x${regionAddr.toString(16)} scfb.size=0x${regionSize.toString(16)} " +
            "scfb.w=${opts.width} scfb.h=${opts.height} scfb.bench=${opts.benchSec} scfb.secs=0 scfb.fmt=${opts.format} scfb.bufs=${opts.bufs}"
    }

    fun buildAndRun(kernel: File, initrd: File): Boolean {
        installHook()
        val img = cls("$P.VirtualMachineCustomImageConfig\$Builder").getConstructor().newInstance()
        call(img, "setName", VM_NAME)
        call(img, "setKernelPath", kernel.path)
        call(img, "setInitrdPath", initrd.path)
        params().split(' ').filter { it.isNotBlank() }.forEach { call(img, "addParam", it) }
        if (opts.disks.isNotEmpty()) {
            val diskCls = cls("$P.VirtualMachineCustomImageConfig\$Disk")
            for (d in opts.disks) {
                val f = File(kernel.parentFile, d)
                call(img, "addDisk", diskCls.getMethod("RODisk", String::class.java).invoke(null, f.path))
                log("disk: ${f.path} (${f.length() shr 20} MiB, read-only)")
            }
        }
        if (opts.stockDisplay) {
            val db = cls("$P.VirtualMachineCustomImageConfig\$DisplayConfig\$Builder").getConstructor().newInstance()
            call(db, "setWidth", opts.width); call(db, "setHeight", opts.height)
            call(db, "setHorizontalDpi", opts.dpi); call(db, "setVerticalDpi", opts.dpi)
            call(db, "setRefreshRate", 60)
            call(img, "setDisplayConfig", call(db, "build"))
            if (opts.gpuBackend != null) {
                val gb = cls("$P.VirtualMachineCustomImageConfig\$GpuConfig\$Builder").getConstructor().newInstance()
                call(gb, "setBackend", opts.gpuBackend)
                call(img, "setGpuConfig", call(gb, "build"))
            }
            call(img, "useTouch", true)
            call(img, "useKeyboard", true)
        }
        val imgCfg = call(img, "build")!!
        val cb = cls("$P.VirtualMachineConfig\$Builder").getConstructor(Context::class.java).newInstance(ctx)
        call(cb, "setCustomImageConfig", imgCfg)
        call(cb, "setProtectedVm", false)
        call(cb, "setMemoryBytes", opts.memMib * 1024 * 1024)
        call(cb, "setCpuTopology", if (opts.matchHostCpus) 1 else 0)
        call(cb, "setDebugLevel", 1)
        call(cb, "setVmOutputCaptured", true)
        val config = call(cb, "build")!!

        val vmmCls = cls("$P.VirtualMachineManager")
        @Suppress("UNCHECKED_CAST")
        val vmm = ctx.getSystemService(vmmCls as Class<Any>) ?: run { log("no VirtualMachineManager"); return false }
        runCatching { if (call(vmm, "get", VM_NAME) != null) call(vmm, "delete", VM_NAME) }
        val v = call(vmm, "create", VM_NAME, config)!!
        vm = v
        vmCls = cls("$P.VirtualMachine")
        val cbCls = cls("$P.VirtualMachineCallback")
        val stopped = CountDownLatch(1)
        val cbObj = Proxy.newProxyInstance(cbCls.classLoader, arrayOf(cbCls)) { p, m, a ->
            when (m.name) {
                "onStopped" -> { log("VM stopped: reason ${a[1]}"); result["stop_reason"] = a[1]; stopped.countDown(); null }
                "onError" -> { log("VM error ${a[1]}: ${a[2]}"); result["vm_error"] = "${a[1]}: ${a[2]}"; null }
                "hashCode" -> System.identityHashCode(p)
                "equals" -> p === a[0]
                "toString" -> "cb"
                else -> null
            }
        }
        call(v, "setCallback", Executors.newSingleThreadExecutor(), cbObj)
        val t0 = SystemClock.elapsedRealtime()
        try {
            call(v, "run")
        } catch (t: Throwable) {
            log("run() failed: ${describe(t)}"); result["run"] = describe(t); return false
        }
        log("run() ok after ${SystemClock.elapsedRealtime() - t0} ms")
        stoppedLatch = stopped
        pump(call(v, "getConsoleOutput") as InputStream)
        return true
    }

    var stoppedLatch: CountDownLatch? = null

    private fun pump(s: InputStream) {
        Thread({
            val r = s.bufferedReader()
            runCatching {
                while (true) {
                    val line = r.readLine() ?: break
                    console.append(line).append('\n')
                    consoleListener?.invoke(line)
                }
            }
        }, "console").apply { isDaemon = true; start() }
    }

    fun stopVm() {
        val v = vm ?: return
        runCatching { call(v, "stop") }
        stoppedLatch?.await(10, TimeUnit.SECONDS)
        runCatching { call(v, "close") }
    }

    // ---- 5. touch -------------------------------------------------------------

    fun setScale(scale: Float, scaleY: Float = scale) {
        touchScale = scale
        touchScaleY = scaleY
        vm?.let { v -> runCatching { call(v, "setTouchScale", scale) } }
    }

    private fun countsAsReport(a: Int) = a == MotionEvent.ACTION_DOWN || a == MotionEvent.ACTION_UP ||
        a == MotionEvent.ACTION_MOVE || a == MotionEvent.ACTION_POINTER_DOWN || a == MotionEvent.ACTION_POINTER_UP

    /** Forwards a touch (view coordinates). Returns true if it became one input report. */
    fun sendTouch(ev: MotionEvent): Boolean {
        val v = vm ?: return false
        if (!countsAsReport(ev.actionMasked)) return false
        val t0 = System.nanoTime()
        val ok = if (opts.stockDisplay) {
            call(v, "sendMultiTouchEvent", ev) as Boolean
        } else writeOwnTouch(ev)
        if (ok) {
            inputSeq++
            Scfb.noteInput(inputSeq, t0)
        }
        return ok
    }

    // Same evdev stream the framework writes (VirtualMachine.sendMultiTouchEventInternal).
    private fun writeOwnTouch(ev: MotionEvent): Boolean {
        val s = ownTouchSock ?: return false
        val evs = ArrayList<IntArray>()
        fun e(t: Int, c: Int, v: Int) = evs.add(intArrayOf(t, c, v))
        when (ev.actionMasked) {
            MotionEvent.ACTION_MOVE -> for (i in 0 until ev.pointerCount) {
                val id = ev.getPointerId(i)
                val x = (ev.getX(i) * touchScale).toInt(); val y = (ev.getY(i) * touchScaleY).toInt()
                e(3, 0x2f, id); e(3, 0x39, id); e(3, 0x35, x); e(3, 0x36, y); e(3, 0, x); e(3, 1, y)
            }
            else -> {
                val down = ev.actionMasked == MotionEvent.ACTION_DOWN || ev.actionMasked == MotionEvent.ACTION_POINTER_DOWN
                val i = ev.actionIndex
                val id = ev.getPointerId(i)
                val x = (ev.getX(i) * touchScale).toInt(); val y = (ev.getY(i) * touchScaleY).toInt()
                e(1, 0x14a, if (down) 1 else 0); e(3, 0x2f, id); e(3, 0x39, if (down) id else -1)
                e(3, 0x35, x); e(3, 0x36, y); e(3, 0, x); e(3, 1, y)
            }
        }
        e(0, 0, 0)
        val bb = ByteBuffer.allocate(8 * evs.size).order(ByteOrder.LITTLE_ENDIAN)
        evs.forEach { bb.putShort(it[0].toShort()); bb.putShort(it[1].toShort()); bb.putInt(it[2]) }
        return runCatching { FileOutputStream(s.fileDescriptor).write(bb.array()); true }.getOrDefault(false)
    }

    fun close() {
        runCatching { shmFd?.close() }
        runCatching { sharedMemory?.close() }
        Log.i(TAG, "closed")
    }
}
