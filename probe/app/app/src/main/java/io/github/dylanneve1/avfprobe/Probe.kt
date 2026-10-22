// SPDX-License-Identifier: AGPL-3.0-or-later
package io.github.dylanneve1.avfprobe

import android.content.Context
import android.content.pm.PackageManager
import android.app.ActivityManager
import android.os.Build
import android.system.Os
import android.system.OsConstants
import org.json.JSONArray
import org.json.JSONObject
import android.util.Log
import java.io.File
import java.io.InputStream
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Walks through every gate between a sideloaded app and a running custom
 * (non-protected) AVF VM, records what it finds, and, if every gate is open,
 * boots the guest from probe/guest and captures its console.
 *
 * All AVF classes live in the com.android.virt APEX (framework-virtualization
 * on the boot classpath) and aren't in the public SDK's android.jar, so
 * everything goes through reflection. That also lets the probe report exactly
 * which members the runtime's hidden-API policy refuses.
 *
 * Gates, in order. The first one that fails is the verdict:
 *   FEATURE_MISSING      android.software.virtualization_framework absent
 *   PERMISSION_MISSING   MANAGE_ / USE_CUSTOM_VIRTUAL_MACHINE not granted
 *   HIDDEN_API_BLOCKED   custom-image builder members not reflectable
 *   GUEST_FILES_MISSING  kernel/initramfs not pushed
 *   CONFIG_REJECTED      VirtualMachineConfig.build() or create() threw
 *   VM_START_FAILED      run() threw, or the VM stopped/errored before output
 *   VM_NO_OUTPUT         VM ran but printed nothing in time
 *   VM_INCOMPLETE_OUTPUT output started but no "AVFPROBE DONE" marker
 *   OK                   guest booted, dumped its platform and powered off
 */
class Probe(
    private val ctx: Context,
    private val opts: Options,
    private val sink: (String) -> Unit,
) {
    data class Options(
        val boot: Boolean = true,
        val protectedVm: Boolean = false,
        val memMib: Long = 256,
        val matchHostCpus: Boolean = false,
        val timeoutSec: Long = 60,
        val params: String = DEFAULT_PARAMS,
        /** Subdirectory of the app's external files dir holding kernel + initrd. */
        val guestDir: String = "guest",
        val kernelFile: String = "Image",
        val initrdFile: String = "initrd.img",
        /** Prefix for the output files (report/console/vmlog/result.json); "" = none. */
        val tag: String = "",
    )

    companion object {
        const val TAG = "AvfProbe"
        const val FEATURE = "android.software.virtualization_framework"
        const val VM_NAME = "avfprobe"   // the VM instance name; always deleted before create()
        // The probe guest ends with AVFPROBE DONE, the benchmark guest with AVFBENCH DONE.
        val DONE_RE = Regex("=== AVF(PROBE|BENCH) DONE ===")

        // hvc0 is a virtio-console wired to the same console fd as ttyS0 (see
        // virtmgr's crosvm.rs); earlycon catches anything before virtio is up.
        const val DEFAULT_PARAMS =
            "console=hvc0 earlycon=uart8250,mmio,0x3f8 printk.devkmsg=on panic=-1 rdinit=/init"

        private const val PKG = "android.system.virtualmachine"
        const val PERM_MANAGE = "android.permission.MANAGE_VIRTUAL_MACHINE"
        const val PERM_CUSTOM = "android.permission.USE_CUSTOM_VIRTUAL_MACHINE"
        const val PERM_DEBUG = "android.permission.DEBUG_VIRTUAL_MACHINE"
    }

    private fun outFile(name: String) = File(outDir, if (opts.tag.isEmpty()) name else "${opts.tag}-$name")

    // Facts collected for result.json (the machine-readable twin of the report).
    private val timings = JSONObject()
    private val facts = JSONObject()
    private var guestKv = JSONObject()
    private var stopReasonOut: String? = null
    private var errorOut: String? = null
    private var capsOut = -1

    private val report = StringBuilder()
    private var verdict: String? = null
    private var verdictDetail = ""

    private fun out(line: String = "") {
        report.append(line).append('\n')
        Log.i(TAG, line)
        sink(line)
    }

    private fun fail(gate: String, detail: String) {
        out("  -> FAIL [$gate] $detail")
        if (verdict == null) {
            verdict = gate
            verdictDetail = detail
        }
    }

    private fun section(name: String) {
        out()
        out("## $name")
    }

    val outDir: File get() = ctx.getExternalFilesDir(null) ?: ctx.filesDir

    fun run(): String {
        out("# AVF probe report")
        out("time: ${java.time.OffsetDateTime.now()}")
        deviceInfo()
        val featureOk = checkFeature()
        val permsOk = checkPermissions()
        val api = checkHiddenApi()
        val guest = locateGuest()
        val config = buildConfig(api, guest)
        if (opts.boot && featureOk && permsOk && config != null) {
            bootVm(config)
        } else if (verdict == null && !opts.boot) {
            out()
            out("(boot skipped: started with boot=false)")
        }
        out()
        out("VERDICT: ${verdict ?: if (opts.boot) "OK" else "CHECKS_OK_BOOT_SKIPPED"}" +
            if (verdictDetail.isNotEmpty()) " ($verdictDetail)" else "")
        val text = report.toString()
        runCatching { outFile("report.txt").writeText(text) }
        // result.json is written last (atomically): host scripts wait for it.
        runCatching {
            val tmp = outFile("result.json.tmp")
            tmp.writeText(resultJson().toString(2))
            tmp.renameTo(outFile("result.json"))
        }.onFailure { Log.e(TAG, "result.json", it) }
        return text
    }

    private fun resultJson(): JSONObject = JSONObject().apply {
        put("schema", 1)
        put("tool", "avfprobe")
        put("tag", opts.tag)
        put("time", java.time.OffsetDateTime.now().toString())
        put("verdict", verdict ?: if (opts.boot) "OK" else "CHECKS_OK_BOOT_SKIPPED")
        put("detail", verdictDetail)
        put("options", JSONObject().apply {
            put("boot", opts.boot); put("protected", opts.protectedVm); put("mem_mib", opts.memMib)
            put("match_host_cpus", opts.matchHostCpus); put("timeout_s", opts.timeoutSec)
            put("params", opts.params); put("guest_dir", opts.guestDir)
            put("kernel", opts.kernelFile); put("initrd", opts.initrdFile)
        })
        put("host", facts)
        put("capabilities", capsOut)
        put("timings_ms", timings)
        put("stop_reason", stopReasonOut ?: JSONObject.NULL)
        put("vm_error", errorOut ?: JSONObject.NULL)
        put("guest", guestKv)
    }

    /** Lifts "AVFKV key=value" lines (one pair per line) from the guest console. */
    private fun parseGuestKv(console: String): JSONObject {
        val o = JSONObject()
        for (line in console.lineSequence()) {
            val l = line.trim()
            if (!l.startsWith("AVFKV ")) continue
            val body = l.removePrefix("AVFKV ")
            val k = body.substringBefore('=', "")
            if (k.isNotEmpty()) o.put(k, body.substringAfter('=').trim())
        }
        return o
    }

    // ---- gate 0: what are we running on ------------------------------------

    private fun deviceInfo() {
        section("device")
        out("model: ${Build.MANUFACTURER} ${Build.MODEL} (${Build.DEVICE})")
        out("soc: ${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}")
        out("android: ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT}), " +
            "security patch ${Build.VERSION.SECURITY_PATCH}")
        out("build: ${Build.FINGERPRINT} type=${Build.TYPE}")
        out("abis: ${Build.SUPPORTED_ABIS.joinToString()}")
        out("/dev/kvm visible to app: ${File("/dev/kvm").exists()}")
        val hostPage = runCatching { Os.sysconf(OsConstants._SC_PAGESIZE) }.getOrDefault(-1L)
        val memInfo = ActivityManager.MemoryInfo().also {
            (ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(it)
        }
        out("host page size: $hostPage; host CPUs: ${Runtime.getRuntime().availableProcessors()}; " +
            "host RAM: ${memInfo.totalMem / (1024 * 1024)} MiB; kernel: ${System.getProperty("os.version")}")
        facts.put("model", "${Build.MANUFACTURER} ${Build.MODEL}")
        facts.put("device", Build.DEVICE)
        facts.put("soc", "${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}")
        facts.put("android", Build.VERSION.RELEASE)
        facts.put("sdk", Build.VERSION.SDK_INT)
        facts.put("security_patch", Build.VERSION.SECURITY_PATCH)
        facts.put("fingerprint", Build.FINGERPRINT)
        facts.put("page_size", hostPage)
        facts.put("cpus", Runtime.getRuntime().availableProcessors())
        facts.put("ram_mib", memInfo.totalMem / (1024 * 1024))
        facts.put("kernel", System.getProperty("os.version") ?: "")
        facts.put("dev_kvm_visible", File("/dev/kvm").exists())
        val props = getprop()
        for (k in listOf(
            "hypervisor.vm.supported", "hypervisor.protected_vm.supported",
            "hypervisor.version", "hypervisor.memory_reclaim.supported",
            "ro.boot.hypervisor.vm.supported", "ro.boot.hypervisor.protected_vm.supported",
            "ro.boot.hypervisor.version", "ro.boot.hypervisor.pvmfw.path",
        )) {
            out("prop $k = ${props[k] ?: "(unset or unreadable)"}")
            facts.put("prop.$k", props[k] ?: JSONObject.NULL)
        }
    }

    private fun getprop(): Map<String, String> = runCatching {
        val p = ProcessBuilder("getprop").redirectErrorStream(true).start()
        val re = Regex("""^\[(.*)]: \[(.*)]$""")
        p.inputStream.bufferedReader().readLines()
            .mapNotNull { re.find(it)?.destructured?.let { (k, v) -> k to v } }.toMap()
            .also { p.waitFor() }
    }.getOrDefault(emptyMap())

    // ---- gate 1: feature ---------------------------------------------------

    private fun checkFeature(): Boolean {
        section("gate 1: system feature")
        val has = ctx.packageManager.hasSystemFeature(FEATURE)
        out("$FEATURE: $has")
        facts.put("virtualization_framework", has)
        if (!has) {
            fail("FEATURE_MISSING", "$FEATURE not declared; getSystemService(VirtualMachineManager) returns null")
        }
        return has
    }

    // ---- gate 2: permissions -----------------------------------------------

    private fun checkPermissions(): Boolean {
        section("gate 2: permissions")
        var ok = true
        for (p in listOf(PERM_MANAGE, PERM_CUSTOM, PERM_DEBUG)) {
            val granted = ctx.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
            val prot = runCatching {
                val info = ctx.packageManager.getPermissionInfo(p, 0)
                protectionString(info.protection, info.protectionFlags)
            }.getOrElse { "unknown (${it.javaClass.simpleName})" }
            out("$p: ${if (granted) "GRANTED" else "not granted"} [protection: $prot]")
            if (!granted && p != PERM_DEBUG) {
                ok = false
                fail("PERMISSION_MISSING", "$p not granted (adb shell pm grant ${ctx.packageName} $p)")
            }
        }
        out("(DEBUG_VIRTUAL_MACHINE isn't needed for a custom VM; listed for reference)")
        return ok
    }

    private fun protectionString(base: Int, flags: Int): String {
        val b = when (base) { 0 -> "normal"; 1 -> "dangerous"; 2 -> "signature"; 4 -> "internal"; else -> "base=$base" }
        val f = mutableListOf<String>()
        if (flags and 0x10 != 0) f += "privileged"
        if (flags and 0x20 != 0) f += "development"
        if (flags and 0x40 != 0) f += "appop"
        if (flags and 0x400 != 0) f += "preinstalled"
        return (listOf(b) + f).joinToString("|")
    }

    // ---- gate 3: hidden API ------------------------------------------------

    /** Resolved reflective handles; null fields mean "blocked or missing". */
    class Api(
        val vmm: Class<*>?, val cfg: Class<*>?, val cfgBuilder: Class<*>?,
        val imgCfg: Class<*>?, val imgBuilder: Class<*>?, val vm: Class<*>?,
        val callback: Class<*>?, val methods: Map<String, Method?>,
        val imgBuilderCtor: java.lang.reflect.Constructor<*>?,
        val cfgBuilderCtor: java.lang.reflect.Constructor<*>?,
    ) {
        fun m(key: String): Method = methods[key] ?: error("$key unavailable")
    }

    private fun checkHiddenApi(): Api {
        section("gate 3: API access (hidden-API policy)")
        fun cls(n: String) = runCatching { Class.forName("$PKG.$n") }.getOrNull()
        val vmm = cls("VirtualMachineManager")
        val cfg = cls("VirtualMachineConfig")
        val cfgB = cls("VirtualMachineConfig\$Builder")
        val img = cls("VirtualMachineCustomImageConfig")
        val imgB = cls("VirtualMachineCustomImageConfig\$Builder")
        val vm = cls("VirtualMachine")
        val cb = cls("VirtualMachineCallback")
        out("classes: " + listOf(
            "VirtualMachineManager" to vmm, "VirtualMachineConfig" to cfg,
            "VirtualMachineCustomImageConfig" to img, "VirtualMachine" to vm,
            "VirtualMachineCallback" to cb,
        ).joinToString { (n, c) -> "$n=${if (c != null) "found" else "MISSING"}" })

        val methods = linkedMapOf<String, Method?>()
        // key -> (class, name, params, hidden?)  "hidden" = blocked in the
        // Android 16 hiddenapi flags; the rest are @SystemApi ("sdk" list).
        data class M(val c: Class<*>?, val n: String, val p: Array<Class<*>?>, val hidden: Boolean)
        val wanted = linkedMapOf(
            "vmm.getCapabilities" to M(vmm, "getCapabilities", arrayOf(), false),
            "vmm.get" to M(vmm, "get", arrayOf(String::class.java), false),
            "vmm.delete" to M(vmm, "delete", arrayOf(String::class.java), false),
            "vmm.create" to M(vmm, "create", arrayOf(String::class.java, cfg), false),
            "cfgB.setProtectedVm" to M(cfgB, "setProtectedVm", arrayOf(Boolean::class.javaPrimitiveType), false),
            "cfgB.setMemoryBytes" to M(cfgB, "setMemoryBytes", arrayOf(Long::class.javaPrimitiveType), false),
            "cfgB.setCpuTopology" to M(cfgB, "setCpuTopology", arrayOf(Int::class.javaPrimitiveType), false),
            "cfgB.setDebugLevel" to M(cfgB, "setDebugLevel", arrayOf(Int::class.javaPrimitiveType), false),
            "cfgB.setVmOutputCaptured" to M(cfgB, "setVmOutputCaptured", arrayOf(Boolean::class.javaPrimitiveType), false),
            "cfgB.build" to M(cfgB, "build", arrayOf(), false),
            "cfgB.setCustomImageConfig" to M(cfgB, "setCustomImageConfig", arrayOf(img), true),
            "imgB.setName" to M(imgB, "setName", arrayOf(String::class.java), true),
            "imgB.setKernelPath" to M(imgB, "setKernelPath", arrayOf(String::class.java), true),
            "imgB.setInitrdPath" to M(imgB, "setInitrdPath", arrayOf(String::class.java), true),
            "imgB.addParam" to M(imgB, "addParam", arrayOf(String::class.java), true),
            "imgB.build" to M(imgB, "build", arrayOf(), true),
            "vm.setCallback" to M(vm, "setCallback", arrayOf(java.util.concurrent.Executor::class.java, cb), false),
            "vm.run" to M(vm, "run", arrayOf(), false),
            "vm.stop" to M(vm, "stop", arrayOf(), false),
            "vm.getStatus" to M(vm, "getStatus", arrayOf(), false),
            "vm.getConsoleOutput" to M(vm, "getConsoleOutput", arrayOf(), false),
            "vm.getLogOutput" to M(vm, "getLogOutput", arrayOf(), false),
            "vm.close" to M(vm, "close", arrayOf(), false),
        )
        val blocked = mutableListOf<String>()
        for ((key, w) in wanted) {
            val m = if (w.c == null || w.p.any { it == null }) null
            else runCatching { w.c.getMethod(w.n, *w.p.map { it!! }.toTypedArray()) }.getOrNull()
            methods[key] = m
            if (m == null) blocked += key
            out("  ${if (m != null) "ok     " else "BLOCKED"} $key${if (w.hidden) "  (@hide)" else ""}")
        }
        val imgCtor = imgB?.let { runCatching { it.getConstructor() }.getOrNull() }
        out("  ${if (imgCtor != null) "ok     " else "BLOCKED"} imgB.<init>()  (@hide)")
        if (imgCtor == null) blocked += "imgB.<init>"
        val cfgCtor = cfgB?.let { runCatching { it.getConstructor(Context::class.java) }.getOrNull() }
        out("  ${if (cfgCtor != null) "ok     " else "BLOCKED"} cfgB.<init>(Context)")
        if (cfgCtor == null) blocked += "cfgB.<init>"

        if (vmm == null || cfg == null || vm == null) {
            fail("FEATURE_MISSING", "AVF framework classes not on the boot classpath")
        } else if (blocked.isNotEmpty()) {
            fail("HIDDEN_API_BLOCKED", "unreachable: ${blocked.joinToString()} " +
                "(see docs/SPIKE-1-AVF-LAUNCH.md for the hidden_api_blacklist_exemptions setting)")
        }
        return Api(vmm, cfg, cfgB, img, imgB, vm, cb, methods, imgCtor, cfgCtor)
    }

    // ---- gate 4: guest files -----------------------------------------------

    private fun locateGuest(): Pair<File, File>? {
        section("gate 4: guest files")
        // crosvm gets fds the app opens, from files the app owns (app_data_file):
        // internal storage. tools/avf-lib.sh (avf_push) streams guest files
        // straight there with run-as. The external files dir is only a fallback,
        // copied in if the app can read it: files adb pushes into a folder adb
        // created belong to shell, and the app can't (#6).
        val src = File(outDir, opts.guestDir)
        val dst = File(ctx.filesDir, opts.guestDir).apply { mkdirs() }
        val pairs = listOf(opts.kernelFile, opts.initrdFile).map { File(src, it) to File(dst, it) }
        for ((s, d) in pairs) {
            if (!s.exists()) continue
            if (!s.canRead()) {
                out("note: ${s.path} exists but the app can't read it (owned by shell?); ignored")
                continue
            }
            if (!d.isFile || d.length() != s.length() || d.lastModified() < s.lastModified()) {
                runCatching { s.copyTo(d, overwrite = true) }
                    .onSuccess { out("copied ${s.path} -> ${d.path}") }
                    .onFailure { out("note: copying ${s.path} failed: ${describe(it)}") }
            }
        }
        val (k, i) = pairs.map { it.second }
        out("kernel: ${k.path} ${if (k.isFile) "${k.length()} bytes" else "MISSING"}")
        out("initrd: ${i.path} ${if (i.isFile) "${i.length()} bytes" else "MISSING"}")
        if (!k.isFile || !i.isFile) {
            fail("GUEST_FILES_MISSING", "copy ${opts.kernelFile} and ${opts.initrdFile} to ${dst.path}/ " +
                "with run-as (tools/avf-lib.sh avf_push does this)")
            return null
        }
        return k to i
    }

    // ---- gate 5: config ----------------------------------------------------

    private fun unwrap(t: Throwable): Throwable =
        if (t is InvocationTargetException && t.targetException != null) t.targetException else t

    private fun describe(t: Throwable): String = unwrap(t).let { "${it.javaClass.name}: ${it.message}" }

    private fun buildConfig(api: Api, guest: Pair<File, File>?): Any? {
        section("gate 5: VM config")
        if (guest == null || api.imgBuilderCtor == null || api.cfgBuilderCtor == null ||
            api.methods.values.any { it == null }) {
            out("(skipped: an earlier gate failed)")
            return null
        }
        out("protected=${opts.protectedVm} mem=${opts.memMib}MiB " +
            "cpus=${if (opts.matchHostCpus) "match-host" else "1"} debug=FULL outputCaptured=true")
        out("params: ${opts.params}")
        return try {
            var b = api.imgBuilderCtor.newInstance()
            b = api.m("imgB.setName").invoke(b, VM_NAME)
            b = api.m("imgB.setKernelPath").invoke(b, guest.first.path)
            b = api.m("imgB.setInitrdPath").invoke(b, guest.second.path)
            for (p in opts.params.split(' ').filter { it.isNotBlank() }) {
                b = api.m("imgB.addParam").invoke(b, p)
            }
            val img = api.m("imgB.build").invoke(b)
            var c = api.cfgBuilderCtor.newInstance(ctx)
            c = api.m("cfgB.setCustomImageConfig").invoke(c, img)
            c = api.m("cfgB.setProtectedVm").invoke(c, opts.protectedVm)
            c = api.m("cfgB.setMemoryBytes").invoke(c, opts.memMib * 1024 * 1024)
            // CPU_TOPOLOGY_ONE_CPU = 0, CPU_TOPOLOGY_MATCH_HOST = 1
            c = api.m("cfgB.setCpuTopology").invoke(c, if (opts.matchHostCpus) 1 else 0)
            // DEBUG_LEVEL_FULL = 1; required by setVmOutputCaptured(true)
            c = api.m("cfgB.setDebugLevel").invoke(c, 1)
            c = api.m("cfgB.setVmOutputCaptured").invoke(c, true)
            val config = api.m("cfgB.build").invoke(c)
            out("VirtualMachineConfig built: $config")
            config
        } catch (t: Throwable) {
            fail("CONFIG_REJECTED", "client-side build failed: ${describe(t)}")
            null
        }
    }

    // ---- gate 6: create + run ----------------------------------------------

    private fun bootVm(config: Any) {
        section("gate 6: create and run")
        val apiCls = { n: String -> Class.forName("$PKG.$n") }
        val vmmCls = apiCls("VirtualMachineManager")
        @Suppress("UNCHECKED_CAST")
        val vmm: Any? = ctx.getSystemService(vmmCls as Class<Any>)
        if (vmm == null) {
            fail("FEATURE_MISSING", "getSystemService(VirtualMachineManager) returned null")
            return
        }
        val caps = vmmCls.getMethod("getCapabilities").invoke(vmm) as Int
        capsOut = caps
        out("capabilities: 0x${caps.toString(16)} " +
            "(protected=${caps and 1 != 0}, non-protected=${caps and 2 != 0})")
        val needed = if (opts.protectedVm) 1 else 2
        if (caps and needed == 0) {
            fail("FEATURE_MISSING", "hypervisor reports no ${if (opts.protectedVm) "protected" else "non-protected"} VM support")
            return
        }

        val vmCls = apiCls("VirtualMachine")
        val cbCls = apiCls("VirtualMachineCallback")
        val stopNames = cbCls.fields.filter { it.name.startsWith("STOP_REASON_") }
            .associate { it.getInt(null) to it.name.removePrefix("STOP_REASON_") }
        val errNames = cbCls.fields.filter { it.name.startsWith("ERROR_") }
            .associate { it.getInt(null) to it.name }

        // A stale instance with the same name would make create() throw.
        runCatching {
            if (vmmCls.getMethod("get", String::class.java).invoke(vmm, VM_NAME) != null) {
                vmmCls.getMethod("delete", String::class.java).invoke(vmm, VM_NAME)
                out("deleted stale VM instance '$VM_NAME'")
            }
        }.onFailure { out("note: cleanup of old instance failed: ${describe(it)}") }

        val tCreate = System.nanoTime()
        val vm = try {
            vmmCls.getMethod("create", String::class.java, apiCls("VirtualMachineConfig"))
                .invoke(vmm, VM_NAME, config)
        } catch (t: Throwable) {
            fail("CONFIG_REJECTED", "VirtualMachineManager.create: ${describe(t)}")
            return
        }
        timings.put("create", (System.nanoTime() - tCreate) / 1_000_000)
        out("created: $vm")

        val stopped = CountDownLatch(1)
        var stopReason: String? = null
        var errorMsg: String? = null
        val events = mutableListOf<String>()
        val t0 = System.nanoTime()
        fun ms() = (System.nanoTime() - t0) / 1_000_000
        val cb = Proxy.newProxyInstance(cbCls.classLoader, arrayOf(cbCls)) { proxy, m, args ->
            when (m.name) {
                "onStopped" -> {
                    val r = args[1] as Int
                    stopReason = stopNames[r] ?: "code $r"
                    timings.put("stopped", ms())
                    synchronized(events) { events += "+${ms()}ms onStopped(${stopReason})" }
                    stopped.countDown(); null
                }
                "onError" -> {
                    val code = args[1] as Int
                    errorMsg = "${errNames[code] ?: code}: ${args[2]}"
                    synchronized(events) { events += "+${ms()}ms onError($errorMsg)" }
                    null
                }
                "onPayloadStarted", "onPayloadReady", "onPayloadFinished" -> {
                    synchronized(events) { events += "+${ms()}ms ${m.name}" }; null
                }
                "hashCode" -> System.identityHashCode(proxy)
                "equals" -> proxy === args[0]
                "toString" -> "AvfProbeCallback"
                else -> null
            }
        }
        val exec = Executors.newSingleThreadExecutor()
        vmCls.getMethod("setCallback", java.util.concurrent.Executor::class.java, cbCls)
            .invoke(vm, exec, cb)

        try {
            vmCls.getMethod("run").invoke(vm)
        } catch (t: Throwable) {
            // virtmgr checks MANAGE_/USE_CUSTOM_VIRTUAL_MACHINE server-side,
            // so a missing grant surfaces here as a SecurityException.
            val d = describe(t)
            fail(if (d.contains("permission", ignoreCase = true)) "PERMISSION_MISSING" else "VM_START_FAILED",
                "VirtualMachine.run: $d")
            runCatching { vmCls.getMethod("close").invoke(vm) }
            exec.shutdownNow()
            return
        }
        timings.put("run_returned", ms())
        out("run() returned after ${ms()} ms; status=${vmCls.getMethod("getStatus").invoke(vm)}")

        val console = StringBuffer()
        var firstByteMs = -1L
        var doneMs = -1L
        fun pump(name: String, s: InputStream?, buf: StringBuffer, first: Boolean): Thread =
            Thread({
                if (s == null) return@Thread
                val b = ByteArray(4096)
                runCatching {
                    while (true) {
                        val n = s.read(b)
                        if (n < 0) break
                        if (first && firstByteMs < 0) firstByteMs = ms()
                        buf.append(String(b, 0, n, Charsets.UTF_8))
                        if (first && doneMs < 0 && DONE_RE.containsMatchIn(buf)) doneMs = ms()
                    }
                }
            }, "pump-$name").apply { isDaemon = true; start() }
        val log = StringBuffer()
        val consoleIn = runCatching { vmCls.getMethod("getConsoleOutput").invoke(vm) as InputStream }
            .onFailure { out("getConsoleOutput: ${describe(it)}") }.getOrNull()
        val logIn = runCatching { vmCls.getMethod("getLogOutput").invoke(vm) as InputStream }
            .onFailure { out("getLogOutput: ${describe(it)}") }.getOrNull()
        val p1 = pump("console", consoleIn, console, true)
        val p2 = pump("log", logIn, log, false)

        val finished = stopped.await(opts.timeoutSec, TimeUnit.SECONDS)
        if (!finished) {
            out("timeout after ${opts.timeoutSec}s; stopping VM")
            runCatching { vmCls.getMethod("stop").invoke(vm) }
                .onFailure { out("stop: ${describe(it)}") }
            stopped.await(10, TimeUnit.SECONDS)
        }
        p1.join(2000); p2.join(500)
        runCatching { vmCls.getMethod("close").invoke(vm) }
        exec.shutdown()

        synchronized(events) { events.forEach { out("event: $it") } }
        out("first console byte: ${if (firstByteMs >= 0) "+${firstByteMs}ms" else "never"}; " +
            "done marker: ${if (doneMs >= 0) "+${doneMs}ms" else "never"}")
        val consoleText = console.toString()
        runCatching { outFile("console.txt").writeText(consoleText) }
        runCatching { outFile("vmlog.txt").writeText(log.toString()) }
        out("console: ${consoleText.length} chars -> ${outFile("console.txt").path}")
        if (firstByteMs >= 0) timings.put("first_console_byte", firstByteMs)
        if (doneMs >= 0) timings.put("done_marker", doneMs)
        stopReasonOut = stopReason
        errorOut = errorMsg
        guestKv = parseGuestKv(consoleText)

        when {
            consoleText.isEmpty() && (stopReason != null || errorMsg != null) ->
                fail("VM_START_FAILED", "stopped before any output: reason=$stopReason error=$errorMsg")
            consoleText.isEmpty() -> fail("VM_NO_OUTPUT", "no console output in ${opts.timeoutSec}s")
            doneMs < 0 -> fail("VM_INCOMPLETE_OUTPUT", "console never reached the done marker; stop=$stopReason")
        }

        section("guest console")
        consoleText.lineSequence().forEach { out(it) }
    }
}
