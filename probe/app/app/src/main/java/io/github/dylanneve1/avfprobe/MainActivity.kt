// SPDX-License-Identifier: AGPL-3.0-or-later
package io.github.dylanneve1.avfprobe

import android.app.Activity
import android.graphics.Typeface
import android.os.Bundle
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * One screen: a "Run probe" button and the report as it's written.
 *
 * Also scriptable from adb (see probe/run-on-device.sh):
 *   am start -n io.github.dylanneve1.avfprobe/.MainActivity --ez autorun true \
 *     [--ez boot false] [--ez protected true] [--el mem_mib 256] \
 *     [--ez match_host_cpus true] [--el timeout_s 60] [--es params "..."]
 * The report goes to logcat (tag AvfProbe) and to
 * /sdcard/Android/data/io.github.dylanneve1.avfprobe/files/report.txt.
 */
class MainActivity : Activity() {
    private lateinit var text: TextView
    private lateinit var scroll: ScrollView
    private lateinit var button: Button
    @Volatile private var running = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (12 * resources.displayMetrics.density).toInt()
        button = Button(this).apply {
            text = "Run probe"
            setOnClickListener { start(optionsFromIntent()) }
        }
        text = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            textSize = 11f
            setTextIsSelectable(true)
            setPadding(pad, pad, pad, pad)
        }
        scroll = ScrollView(this).apply { addView(text) }
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            fitsSystemWindows = true
            addView(button, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
            addView(scroll, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
        })
        if (savedInstanceState == null && intent.getBooleanExtra("autorun", false)) {
            start(optionsFromIntent())
        }
    }

    private fun optionsFromIntent(): Probe.Options {
        val i = intent
        val d = Probe.Options()
        return Probe.Options(
            boot = i.getBooleanExtra("boot", d.boot),
            protectedVm = i.getBooleanExtra("protected", d.protectedVm),
            memMib = i.getLongExtra("mem_mib", d.memMib),
            matchHostCpus = i.getBooleanExtra("match_host_cpus", d.matchHostCpus),
            timeoutSec = i.getLongExtra("timeout_s", d.timeoutSec),
            params = i.getStringExtra("params") ?: d.params,
        )
    }

    private fun start(opts: Probe.Options) {
        if (running) return
        running = true
        button.isEnabled = false
        text.text = ""
        Thread({
            try {
                Probe(this, opts) { line ->
                    runOnUiThread {
                        text.append(line + "\n")
                        scroll.post { scroll.fullScroll(ScrollView.FOCUS_DOWN) }
                    }
                }.run()
            } catch (t: Throwable) {
                android.util.Log.e(Probe.TAG, "probe crashed", t)
                runOnUiThread { text.append("probe crashed: $t\n") }
            } finally {
                running = false
                runOnUiThread { button.isEnabled = true }
            }
        }, "avf-probe").start()
    }
}
