# Spike #1: can our app launch an AVF custom VM on a Pixel 10?

Status: **tooling done and verified as far as possible without the phone. The
Pixel 10 run is still pending** (steps in [section 4](#4-pixel-10-run-untested)).
This spike involves no Apple software: the guest is a stock Debian arm64 kernel
plus a small init of our own. The hardened runner, the RAM/vCPU/16 KiB sweeps and
the pKVM-vs-TCG benchmark built on this probe are described in
[AVF-BENCH.md](AVF-BENCH.md); `tools/run-all.sh` runs both.

Sources are marked like this throughout:

* **[emu]** measured on the Android 16 arm64 emulator (`BE2A.250530.026.D1`,
  user build) on this Mac;
* **[dex]** read from the hidden-API flags compiled into that emulator's
  `/apex/com.android.virt/javalib/framework-virtualization.jar`;
* **[aosp]** read from AOSP `packages/modules/Virtualization` and crosvm at
  `main` (October 2026). The Pixel 10's build may differ, and the probe reports
  what's actually there;
* **[qemu]** our guest booted under QEMU 11.1 with HVF on the Mac;
* **[untested]** expected, not yet observed on a Pixel.

## 1. Short answer

An ordinary sideloaded app *can* in principle start a custom, non-protected VM
with its own kernel, with three adb-side steps and nothing on the device
modified:

1. `pm grant` **MANAGE_VIRTUAL_MACHINE** (protection
   `signature|development|preinstalled`) [emu];
2. `pm grant` **USE_CUSTOM_VIRTUAL_MACHINE** (`signature|development`) [emu];
3. a **hidden-API exemption** for the custom-image builder, because the Java
   API for "boot this kernel + initrd" is `@hide` and blocked for apps [dex, emu].
   The minimum exemption is two signature prefixes (section 4). Without it, the
   only VM an app can start is Microdroid.

`DEBUG_VIRTUAL_MACHINE` is `signature` only, so it can't be granted, and isn't
needed [emu, aosp].

What remains unverified is whether the Pixel 10's virtmgr/crosvm/SELinux let it
all the way through. The emulator stops at the first gate, because it has no
`android.software.virtualization_framework` (an M1 has no nested
virtualization, so the emulator can't expose a hypervisor). One run of
`probe/run-on-device.sh` on the phone answers that, and prints which gate
failed if one did.

## 2. The gates, and what the probe reports

The probe app (`probe/app`) checks these in order. The first gate that fails
becomes the last line of its report: `VERDICT: <GATE> (<detail>)`.

| # | Gate / verdict | What's checked | Emulator result |
|---|---|---|---|
| 1 | `FEATURE_MISSING` | `PackageManager.hasSystemFeature("android.software.virtualization_framework")`; later also `getSystemService(VirtualMachineManager)` and `getCapabilities()` | **fails**: feature absent, so the service is `null` [emu] |
| 2 | `PERMISSION_MISSING` | `checkSelfPermission` for both permissions. A missing grant that only virtmgr notices shows up as a `SecurityException` from `run()` and is classified here too | passes after `pm grant`; fails without [emu] |
| 3 | `HIDDEN_API_BLOCKED` | reflective lookup of every AVF member used. Each one is listed `ok`/`BLOCKED` | 7 members blocked by default; all reachable with the exemption [emu] |
| 4 | `GUEST_FILES_MISSING` | `Image` + `initrd.img` pushed to the app's external files dir, then copied to internal storage | passes [emu] |
| 5 | `CONFIG_REJECTED` | `VirtualMachineConfig.Builder.build()` client-side, then `VirtualMachineManager.create()` | build throws `UnsupportedOperationException: Non-protected VMs are not supported on this device.` because the client checks the hypervisor capability [emu] |
| 6 | `VM_START_FAILED` | `VirtualMachine.run()` throws, or `onStopped`/`onError` arrive before any console output | not reached [emu]; [untested] |
| 7 | `VM_NO_OUTPUT` / `VM_INCOMPLETE_OUTPUT` | console never produced bytes / never reached `=== AVFPROBE DONE ===` | not reached; [untested] |
| - | `OK` | guest booted, dumped its platform and powered itself off | [untested] |

Full emulator reports: [`spike-1/emulator-report.txt`](spike-1/emulator-report.txt)
(grants and exemption applied) and
[`spike-1/emulator-report-no-grants.txt`](spike-1/emulator-report-no-grants.txt).

## 3. API surface: what's public, what needed reflection or adb

All AVF classes live in the `com.android.virt` APEX (`framework-virtualization`
is on `BOOTCLASSPATH`) and aren't in the SDK's `android.jar`, so the probe
calls everything through reflection. That's purely a compile-time matter. What
matters at runtime is each member's hidden-API flag [dex], confirmed by the
runtime's `hiddenapi: ... denied` / `allowed` log lines [emu]:

| Member(s) | Flag | Needs |
|---|---|---|
| `VirtualMachineManager.getCapabilities/get/getOrCreate/create/delete` | `SDK` (`@SystemApi`) | MANAGE_VIRTUAL_MACHINE (enforced by virtmgr) |
| `VirtualMachineConfig.Builder(Context)`, `setProtectedVm`, `setMemoryBytes`, `setCpuTopology`, `setDebugLevel`, `setVmOutputCaptured`, `setShouldUseHugepages`, `setPayloadBinaryName`, `build` | `SDK` | — |
| `VirtualMachine.run/stop/getStatus/setCallback/getConsoleOutput/getLogOutput/connectVsock/close` | `SDK` | — |
| `VirtualMachineCallback` (implemented with `java.lang.reflect.Proxy`) | `SDK` | — |
| **`VirtualMachineConfig.Builder.setCustomImageConfig`** | **`BLOCKED`** | hidden-API exemption |
| **`VirtualMachineCustomImageConfig.Builder` (all: `<init>`, `setName`, `setKernelPath`, `setInitrdPath`, `addParam`, `build`, …)** | **`BLOCKED`** | hidden-API exemption |
| `setOs`, `setVmConsoleInputSupported`, `setPayloadConfigPath`, `isFeatureEnabled`, `getConsoleInput`, `suspend`/`resume`, balloon, input-event senders | `BLOCKED` | not used by the probe |
| `android.system.virtualizationservice.*` (the raw AIDL: `IVirtualizationService`, `VirtualMachineRawConfig`, …) | `BLOCKED` | not used; see section 6 |

Server-side, virtmgr treats **any raw config as "custom"** and requires
USE_CUSTOM_VIRTUAL_MACHINE on top of MANAGE_VIRTUAL_MACHINE
(`is_custom_config` / `check_use_custom_virtual_machine` in
`android/virtmgr/src/aidl.rs`) [aosp]. Both are checked against the *calling
app's* uid via the permission service, so the grants are real gates. The
hidden-API exemption is not a security boundary: it only lets the app reach the
Java builder the platform's own Terminal app uses. Permission checks and SELinux
stay in force.

Hidden-API exemption details, all [emu]:

* `settings put global hidden_api_blacklist_exemptions <list>` takes
  **comma-separated** signature prefixes. A `:`-separated list is silently
  ignored. It applies to processes started *after* the change, so the app must
  be force-stopped first. `system_server` logs `Can't set API denylist
  exemptions: no zygote connection` even when the setting does take effect.
* The two prefixes in section 4 are enough. With them, every member is `ok`
  and the config builds up to the device-capability check.
* `settings put global hidden_api_policy 1` also works, but it opens *all*
  hidden APIs to *all* apps. Prefer the exemption list.

## 4. Pixel 10 run [untested]

Everything below is **untested on a real device**. Run it with the phone in
developer mode with USB debugging on. It needs no root, no bootloader unlock,
and no change to the build.

**Build (on the host, once):**

```sh
probe/guest/build.sh                       # downloads a SHA-256-pinned Debian kernel, builds init + initramfs
(cd probe/app && ./gradlew assembleDebug)  # JAVA_HOME = a JDK 17+, e.g. Android Studio's jbr
```

**One command** does the whole run below, pulls the results into
`probe/results/<timestamp>/` (with `summary.md`/`summary.json` and a
`<tag>-result.json` per run), and on exit restores the exemption and
stay-awake settings and revokes the grants, also on Ctrl-C. It never prompts and
fails fast if no device, or several, are attached:

```sh
probe/run-on-device.sh               # add -s <serial> if more than one device is attached
probe/run-on-device.sh --full        # + all-host-CPUs, 16 KiB-page kernel, guest-RAM sweep
```

`tools/docker-build.sh` and `tools/docker-apk.sh` build the guest and the APK
without a local toolchain (both kernels, 4 KiB and 16 KiB, are fetched and
SHA-256-checked).

**The same steps by hand, one copy-paste block:**

```sh
PKG=io.github.dylanneve1.avfprobe
DATA=/sdcard/Android/data/$PKG/files

adb shell settings get global hidden_api_blacklist_exemptions   # note it; normally "null"

adb install -r probe/app/app/build/outputs/apk/debug/app-debug.apk
adb shell pm grant $PKG android.permission.MANAGE_VIRTUAL_MACHINE
adb shell pm grant $PKG android.permission.USE_CUSTOM_VIRTUAL_MACHINE
adb shell settings put global hidden_api_blacklist_exemptions \
  "'Landroid/system/virtualmachine/VirtualMachineCustomImageConfig\$Builder;,Landroid/system/virtualmachine/VirtualMachineConfig\$Builder;->setCustomImageConfig('"

adb shell mkdir -p $DATA/guest
adb push probe/guest/out/Image probe/guest/out/initrd.img $DATA/guest/
adb shell am force-stop $PKG
adb logcat -c
adb shell am start -W -n $PKG/.MainActivity --ez autorun true
sleep 75                                   # the probe gives the VM 60 s

adb pull $DATA/report.txt; adb pull $DATA/console.txt; adb pull $DATA/vmlog.txt
adb logcat -d | grep -iE 'virtmgr|virtualizationservice|crosvm|AvfProbe|hiddenapi|avc:' > avf-logcat.txt
```

**Revert each change:**

| Change | Revert |
|---|---|
| hidden-API exemption (global, affects all apps) | `adb shell settings delete global hidden_api_blacklist_exemptions` (or `put` back the old value if there was one) |
| MANAGE_VIRTUAL_MACHINE grant | `adb shell pm revoke $PKG android.permission.MANAGE_VIRTUAL_MACHINE` |
| USE_CUSTOM_VIRTUAL_MACHINE grant | `adb shell pm revoke $PKG android.permission.USE_CUSTOM_VIRTUAL_MACHINE` |
| app, pushed guest, VM instance dir | `adb uninstall $PKG` |

**Send back** `report.txt`, `console.txt` and `avf-logcat.txt`.
virtmgr logs the exact crosvm command line, so the logcat answers the "what
does crosvm get" question directly.

**Optional extra runs**, each answering one more question:

* `probe/run-on-device.sh --match-host-cpus`: vCPU count with
  `CPU_TOPOLOGY_MATCH_HOST` (the default is 1 vCPU).
* `probe/run-on-device.sh --protected`: expected to fail (`CONFIG_REJECTED` or
  `VM_START_FAILED`). virtmgr only lets a protected VM boot a kernel/initrd
  whose SELinux label marks it as coming from the system image
  (`check_label_for_kernel_files`), and ours comes from app storage [aosp].
  This confirms that pKVM-protected VMs with our own kernel are out of reach.

## 5. What crosvm will give the guest

From source, to be confirmed by the probe's `/proc/iomem`, device-tree and
`/proc/cpuinfo` dump and by the logged crosvm command line [aosp]:

* **Memory**: guest RAM starts at IPA `0x8000_0000`
  (`AARCH64_PHYS_MEM_START`), sized by `setMemoryBytes`. Low MMIO below that:
  RTC (PL030) at `0x2000`, VM watchdog at `0x3000`, 8250 UARTs at
  `0x3f8/0x2f8/0x3e8/0x2e8`, pvtime at `0x1ff0000`, virt-cpufreq at
  `0x1040000`. AVF moves PCI to MMIO `0x2c000000` (32 MiB) and CAM
  `0x2e000000` (16 MiB). GICv3 distributor at `0x3fff0000`, redistributors
  below it, ITS at `0x40000000`. This layout is fixed: there is no Java API to
  place RAM or MMIO elsewhere.
* **Devices** for a raw config (from `crosvm.rs`): two 8250 UARTs (#1 =
  console, #2 = failure reason), three virtio-consoles (`hvc0` = console,
  `hvc1` = ramdump, `hvc2` = log), virtio-pci, optional virtio-blk disks,
  optional virtio-balloon, vsock, and optionally (with the matching
  `VirtualMachineCustomImageConfig` options and build flags) virtio-gpu,
  display, input, sound, net, USB controller, and virtio-fs through
  `vhost-user-fs`. No PMU (`--no-pmu` is always passed on aarch64).
* **Console**: with `setVmOutputCaptured(true)` (requires `DEBUG_LEVEL_FULL`)
  ttyS0 and hvc0 both feed `getConsoleOutput()`. Our guest uses `console=hvc0`
  plus `earlycon=uart8250,mmio,0x3f8`. Both paths were exercised under QEMU
  (PL011 and virtio-console) [qemu].
* **vCPUs**: `CPU_TOPOLOGY_ONE_CPU` (1) or `CPU_TOPOLOGY_MATCH_HOST` (one per
  host CPU, with `--host-cpu-topology --virt-cpufreq` when the build enables
  `virt_cpufreq` and the caller may run on all CPUs). SVE is passed through
  automatically.
* **Debug / trace hooks**: console and log capture (SystemApi); a crosvm
  **gdb stub** (`gdbPort`) for non-protected debuggable VMs, but only in the
  raw AIDL config, which the Java API never sets. Same for
  `--dump-device-tree-blob`. Ramdumps go to tombstoned. Reaching gdb/DT-dump
  from an app would mean calling the BLOCKED `IVirtualizationService` AIDL
  directly. The `vm` shell tool (`/apex/com.android.virt/bin/vm run --gdb
  <port> --dump-device-tree <file>`) exposes both. AOSP's doc says to use it
  from `adb root`; whether plain `adb shell` is allowed on a user build is
  [untested].

## 6. README question 2: extension points for our own device models

[aosp], to confirm on device:

* The only device that can run **outside** virtmgr's crosvm is **virtio-fs**.
  With `SharedPath.appDomain`, the framework execs
  `/apex/com.android.virt/bin/crosvm device fs` *inside the app's process*
  and hands its socket to the VM's crosvm as `--vhost-user-fs`. So vhost-user
  plumbing exists, but only for that one device type. There's no API to attach
  an arbitrary vhost-user backend (e.g. Apple device models), and
  `SharedPath` and `addSharedPath` are `@hide` (BLOCKED) too. Whether `untrusted_app` may even exec
  that crosvm binary is [untested].
* `customMemoryBackingFiles` (`--file-backed-mapping` at a chosen IPA) exists in
  the raw AIDL config, but the Java `toVsRawConfig()` always sends an empty
  list. Same story as gdb.
* Device assignment (VFIO, DTBO) is for platform devices with system-side
  config, so it's out of scope for an app.

**Implication:** on a stock Pixel, Apple device models can't live in the phone's
crosvm. They would have to run in the guest (paravirtualised), in our app
(talking to the guest over vsock or virtio-fs), or the porting work proceeds on
a Linux KVM host where we control crosvm, as the README anticipates.

## 7. Fallback: the SystemApi-only (Microdroid) path

Without USE_CUSTOM_VIRTUAL_MACHINE or any hidden-API exemption, an app holding
MANAGE_VIRTUAL_MACHINE can still start **Microdroid**:
`VirtualMachineConfig.Builder.setPayloadBinaryName("libfoo.so")` runs a native
library from our own APK as a process inside a Google-provided minimal Android
guest, on Google's signed kernel, talking to the app over vsock
(`connectVsock` and `connectToVsockServer` are SystemApi). That's useful as a
**diagnostic fallback**. If the custom path is blocked on the Pixel 10, a
Microdroid run still tells us whether pKVM/crosvm VMs start at all for a
sideloaded app, and what boot latency and vsock throughput look like. It
can't host the iOS guest, though: we don't control the kernel, the payload runs
at EL0 under Linux, and there's no nested virtualisation. So it's no
substitute for the custom-kernel path, and it doesn't change the answer to
section 6.

## 8. How this was verified

| What | How | Result |
|---|---|---|
| Guest builds reproducibly | `probe/guest/build.sh` | Debian deb SHA-256 `88926feb…88da` matches the pin. `init` is a 17 KB static aarch64 ELF (23 KB with the later `AVFKV` summary and clang 19); `initrd.img` is 6-7 KB |
| Guest boots and prints the platform | QEMU 11.1, `-M virt,gic-version=3 -accel hvf -cpu host -smp 2 -m 512 -kernel Image -initrd initrd.img -append "console=ttyAMA0 panic=-1"` | 3 mounts ok, all sections printed, `=== AVFPROBE DONE ===`, `reboot: Power down` at 0.27 s [qemu]. Log: [`spike-1/qemu-hvf-console.txt`](spike-1/qemu-hvf-console.txt) |
| hvc0 console path | Same, with `-device virtio-serial-pci -device virtconsole` and `console=hvc0` | full output on the virtio-console; the PCI dump lists the virtio-console `1af4:1003` [qemu] |
| init's dump code on Android | `init --dry-run` under `adb shell` on the emulator | all sections printed, exit 0 [emu] |
| App builds | `./gradlew assembleDebug` (AGP 9.3.3, Gradle 9.7.1, built-in Kotlin) | ok |
| Permission protection levels | probe report + `dumpsys package permission …` | MANAGE `signature\|development\|preinstalled`, USE_CUSTOM `signature\|development`, DEBUG `signature` [emu] |
| Hidden-API blocks and the minimum exemption | probe without / with `hidden_api_blacklist_exemptions` (`:` vs `,`), and `hidden_api_policy 1`; `hiddenapi:` logcat lines | 7 members `denied` by default; `,`-list makes them `allowed`; `:`-list doesn't [emu] |
| Runner script and revert (first version) | `probe/run-on-device.sh -s emulator-5554` | install, grants, exemption, push, run, pull all ok. Afterwards the setting is back to `null` and the grants are revoked [emu] |
| Anything on a Pixel 10 | — | **not run** |

## 9. Open questions for the Pixel run

1. Does `run()` succeed, and how long until the first console byte (the
   report records `+ms` timings)?
2. The real `/proc/iomem`, device tree, `/proc/cpuinfo` (MIDR, so which Tensor
   G5 cores the vCPUs show) and `/proc/interrupts` inside the guest.
3. The exact crosvm command line from virtmgr's logcat.
4. Any SELinux denials (`avc:`) for crosvm reading kernel/initrd fds from app
   storage.
5. `--protected`: confirm the refusal and its message.
