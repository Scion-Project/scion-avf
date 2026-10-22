package io.github.dylanneve1.gpu3dprobe

import android.app.Activity
import android.os.Bundle
import android.widget.ScrollView
import android.widget.TextView
import java.io.File
import java.io.InputStream
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Proxy
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Boots one non-protected custom AVF VM with a virtio-gpu (crosvm `--gpu`, via the @hide
 * VirtualMachineCustomImageConfig.GpuConfig) and records its console. The guest is
 * hackios-xnu-kernel's avf/gpu3d/probe Image, which draws through gfxstream and prints
 * "GPU3D ..." lines; gpu3d/run-on-device.sh drives this.
 *
 *   am start -n io.github.dylanneve1.gpu3dprobe/.MainActivity \
 *     [--es kernel Image] [--es initrd payload.bin] [--ei cpus 8] [--es params "gpu3d.size=828x1792"] [--es backend gfxstream]
 *     [--es contexts gfxstream-gles] [--ez egl true] [--ez gles true] [--ez surfaceless true]
 *     [--ez vulkan false] [--es features ""] [--ei mem 512] [--ei timeout 90] [--es tag run]
 *
 * The kernel is read from the app's external files dir (adb push to
 * /sdcard/Android/data/io.github.dylanneve1.gpu3dprobe/files/) and copied to internal storage,
 * because virtmgr must be able to open it. Results: files/<tag>-console.txt and
 * files/<tag>-report.txt in the same external directory.
 */
class MainActivity : Activity() {
    private lateinit var text: TextView
    private val report = StringBuffer()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        text = TextView(this).apply { textSize = 10f; setTextIsSelectable(true) }
        setContentView(ScrollView(this).apply { addView(text) })
        val x = intent
        val opts = Opts(
            kernel = x.getStringExtra("kernel") ?: "Image",
            initrd = x.getStringExtra("initrd"),
            cpus = x.getIntExtra("cpus", 1),
            params = x.getStringExtra("params") ?: "",
            backend = x.getStringExtra("backend") ?: "gfxstream",
            contexts = (x.getStringExtra("contexts") ?: "gfxstream-gles").split(',', ':').filter { it.isNotBlank() },
            egl = x.getBooleanExtra("egl", true),
            gles = x.getBooleanExtra("gles", true),
            surfaceless = x.getBooleanExtra("surfaceless", true),
            vulkan = x.getBooleanExtra("vulkan", false),
            features = x.getStringExtra("features"),
            gpu = x.getBooleanExtra("gpu", true),
            memMib = x.getIntExtra("mem", 512).toLong(),
            timeoutSec = x.getIntExtra("timeout", 90).toLong(),
            tag = x.getStringExtra("tag") ?: "run",
        )
        Thread({
            val ok = runCatching { run(opts) }.onFailure { out("FAILED: ${describe(it)}") }.getOrDefault(false)
            out("HARNESS-DONE ${if (ok) "ok" else "error"}")
            runCatching { File(getExternalFilesDir(null), "${opts.tag}-report.txt").writeText(report.toString()) }
        }, "gpu3d").start()
    }

    data class Opts(
        val kernel: String, val initrd: String?, val cpus: Int, val params: String, val backend: String, val contexts: List<String>,
        val egl: Boolean, val gles: Boolean, val surfaceless: Boolean, val vulkan: Boolean,
        val features: String?, val gpu: Boolean, val memMib: Long, val timeoutSec: Long, val tag: String,
    )

    private fun out(line: String) {
        report.append(line).append('\n')
        runOnUiThread { text.append(line + "\n") }
    }

    private fun unwrap(t: Throwable): Throwable =
        if (t is InvocationTargetException) t.targetException?.let(::unwrap) ?: t else t

    private fun describe(t: Throwable) = unwrap(t).let { "${it.javaClass.name}: ${it.message}" }

    private fun cls(n: String) = Class.forName("android.system.virtualmachine.$n")

    /** Calls the public method [name] of [target] whose parameter count matches. */
    private fun call(target: Any, name: String, vararg args: Any?): Any? {
        val m = target.javaClass.methods.first { it.name == name && it.parameterTypes.size == args.size }
        return m.invoke(target, *args)
    }

    private fun run(o: Opts): Boolean {
        out("gpu3d harness: $o")
        val src = File(getExternalFilesDir(null), o.kernel)
        val kernel = File(filesDir, "gpu3d-Image")
        src.inputStream().use { i -> kernel.outputStream().use { i.copyTo(it) } }
        out("kernel ${src.path} -> ${kernel.path} (${kernel.length()} bytes)")
        val initrd = o.initrd?.let { name ->
            File(filesDir, "gpu3d-initrd").also { dst ->
                File(getExternalFilesDir(null), name).inputStream().use { i -> dst.outputStream().use { i.copyTo(it) } }
                out("initrd $name -> ${dst.path} (${dst.length()} bytes)")
            }
        }

        var img: Any = cls("VirtualMachineCustomImageConfig\$Builder").getConstructor().newInstance()
        img = call(img, "setName", "gpu3d")!!
        img = call(img, "setKernelPath", kernel.path)!!
        initrd?.let { img = call(img, "setInitrdPath", it.path)!! }
        for (p in o.params.split(' ').filter { it.isNotBlank() }) img = call(img, "addParam", p)!!
        if (o.gpu) {
            var gb: Any = cls("VirtualMachineCustomImageConfig\$GpuConfig\$Builder").getConstructor().newInstance()
            gb = call(gb, "setBackend", o.backend)!!
            gb = call(gb, "setContextTypes", o.contexts.toTypedArray() as Any)!!
            gb = call(gb, "setRendererUseEgl", o.egl)!!
            gb = call(gb, "setRendererUseGles", o.gles)!!
            gb = call(gb, "setRendererUseSurfaceless", o.surfaceless)!!
            gb = call(gb, "setRendererUseVulkan", o.vulkan)!!
            o.features?.let { gb = call(gb, "setRendererFeatures", it)!! }
            val gpu = call(gb, "build")!!
            img = call(img, "setGpuConfig", gpu)!!
            out("GpuConfig: $gpu")
        }
        val image = call(img, "build")!!

        var cb: Any = cls("VirtualMachineConfig\$Builder").getConstructor(android.content.Context::class.java).newInstance(this)
        cb = call(cb, "setCustomImageConfig", image)!!
        cb = call(cb, "setProtectedVm", false)!!
        cb = call(cb, "setMemoryBytes", o.memMib * 1024 * 1024)!!
        // CPU_TOPOLOGY_ONE_CPU = 0, CPU_TOPOLOGY_MATCH_HOST = 1
        cb = call(cb, "setCpuTopology", if (o.cpus > 1) 1 else 0)!!
        cb = call(cb, "setDebugLevel", 1)!!
        cb = call(cb, "setVmOutputCaptured", true)!!
        val config = call(cb, "build")!!

        val vmm = getSystemService(cls("VirtualMachineManager"))!!
        runCatching { if (call(vmm, "get", "gpu3d") != null) call(vmm, "delete", "gpu3d") }
        val vm = call(vmm, "create", "gpu3d", config)!!
        val cbCls = cls("VirtualMachineCallback")
        val stopNames = cbCls.fields.filter { it.name.startsWith("STOP_REASON_") }
            .associate { it.getInt(null) to it.name.removePrefix("STOP_REASON_") }
        val stopped = CountDownLatch(1)
        val t0 = System.nanoTime()
        fun ms() = (System.nanoTime() - t0) / 1_000_000
        val proxy = Proxy.newProxyInstance(cbCls.classLoader, arrayOf(cbCls)) { self, m, args ->
            when (m.name) {
                "onStopped" -> { out("+${ms()}ms onStopped(${stopNames[args[1] as Int] ?: args[1]})"); stopped.countDown(); null }
                "onError" -> { out("+${ms()}ms onError(${args[1]}: ${args[2]})"); null }
                "hashCode" -> System.identityHashCode(self)
                "equals" -> self === args?.get(0)
                "toString" -> "Gpu3dCallback"
                else -> null
            }
        }
        call(vm, "setCallback", Executors.newSingleThreadExecutor(), proxy)
        call(vm, "run")
        out("+${ms()}ms run() returned")

        val console = StringBuffer()
        var done = false
        val pump = Thread({
            runCatching {
                val s = call(vm, "getConsoleOutput") as InputStream
                val b = ByteArray(4096)
                while (true) {
                    val n = s.read(b)
                    if (n < 0) break
                    val chunk = String(b, 0, n, Charsets.UTF_8)
                    console.append(chunk)
                    if (console.contains("GPU3D-DONE")) done = true
                }
            }
        }, "console").apply { isDaemon = true; start() }

        val finished = stopped.await(o.timeoutSec, TimeUnit.SECONDS)
        if (!finished) {
            out("timeout after ${o.timeoutSec}s; stopping the VM")
            runCatching { call(vm, "stop") }
            stopped.await(10, TimeUnit.SECONDS)
        }
        pump.join(2000)
        runCatching { call(vm, "close") }
        val c = console.toString().replace("\r", "")
        File(getExternalFilesDir(null), "${o.tag}-console.txt").writeText(c)
        out("console: ${c.length} chars; done marker: $done")
        c.lineSequence().filter { it.startsWith("GPU3D") || it.startsWith("vgpu3d") }.forEach { out(it) }
        return true
    }
}
