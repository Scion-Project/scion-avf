# AVF-BENCH: two questions, one command

When a Pixel 10 is plugged in, one command answers the two questions that
decide whether an AVF backend is worth building:

1. **What does a sideloaded app actually get from a non-protected custom VM?**
   Max guest RAM, vCPU count, 4 KiB vs 16 KiB guest pages, which virtio devices
   crosvm exposes, boot time. (This finishes
   [spike 1](SPIKE-1-AVF-LAUNCH.md).)
2. **How fast is native-under-pKVM compared with QEMU TCG** for the same arm64
   Linux workload, on the same phone?

Everything is stock Linux (a Debian kernel, busybox and a few hundred lines of our own C);
no Apple software is involved.

**Status:** the guest images, the TCG leg and every script are built and
smoke-tested on a Linux box (QEMU TCG, plus a fake `adb` that exercises the
runners' control flow). **Nothing has run on a Pixel yet.** Every step marked
*pending device* below needs the phone.

## The command

```sh
tools/run-all.sh            # add -s SERIAL if several devices are attached
```

It builds whatever is missing (guest images, the probe APK, a static QEMU for the
phone), runs both measurements, and leaves `results/<timestamp>/probe/summary.md`
and `results/<timestamp>/bench/summary.md`. Plan for about 5 minutes of phone
time (RAM sweep and three benchmark legs) after a one-off ~25 minute build.
`--quick` trims it to ~2 minutes.

*Pending device.* Before running it:

- developer options on, **USB debugging** on, the host's key authorised;
- the phone **unlocked, screen on, on a charger** (the runner sets
  stay-awake-while-plugged-in and restores it, but it can't unlock a PIN lock);
- Android 16 on a Pixel 10 with the virtualization framework
  (`pm list features | grep virtualization_framework`); if it's missing the probe
  says `FEATURE_MISSING` and the bench legs report no AVF numbers, which is a
  result too;
- the phone cool and not in battery saver, or the numbers will mostly measure
  throttling (`device-state.txt` in the results records battery and thermal state
  after each leg).

Nothing needs root, an unlocked bootloader, or a changed build. The runner
installs the probe app, `pm grant`s two development permissions, sets one global
setting (`hidden_api_blacklist_exemptions`) plus stay-awake-while-plugged-in, and
on exit **puts all of it back** (also on Ctrl-C), revoking the grants too. The
app stays installed (`adb uninstall io.github.dylanneve1.avfprobe` removes it).
Nothing prompts.

### Build prerequisites (host: Mac or Linux)

| Need | For | Notes |
|---|---|---|
| `adb` | everything | platform-tools |
| `python3` | summaries | stdlib only |
| JDK 17+ | the probe APK | `JAVA_HOME`, e.g. Android Studio's `jbr`; Gradle wrapper is in `probe/app` |
| `docker` | guest images (if no clang), static QEMU | `tools/docker-build.sh` uses a digest-pinned `debian:trixie-slim` |
| or `clang` + `ld.lld` | guest images | clang >= 14, any LLVM (Apple clang + Homebrew `lld`, or the NDK's) |
| `curl`, `ar`, `tar`+xz | guest images | to fetch the pinned Debian packages |

Written for bash 3.2, so stock macOS works. `timeout(1)` is optional (falls back
to `gtimeout`, then perl).

## What gets built, and why it's reproducible

Nothing built is committed (`*/out/` is gitignored). Every input is pinned:

| Artifact | Source | Pin |
|---|---|---|
| `Image` (guest kernel, **4 KiB pages**) | Debian 13 `linux-image-6.12.111+deb13-cloud-arm64` | SHA-256 in `probe/guest/kernel.sh` |
| `Image-16k` (**16 KiB pages**) | Debian 13 `linux-image-6.12.111+deb13-arm64-16k` | SHA-256 in `probe/guest/kernel.sh` |
| `busybox` | Debian 13 `busybox-static 1.37.0-6+b9` (arm64) | SHA-256 in `probe/guest/kernel.sh` |
| `bench` / `bench.img` | `bench/bench.c` compiled with clang `-O2 -march=armv8-a`, no libc | compiler version printed; hash is stable per toolchain |
| `qemu-system-aarch64` | upstream QEMU 10.2.2, static, TCG only, for aarch64-linux | source SHA-256 in `bench/qemu/build-static.sh` |

```sh
tools/docker-build.sh           # probe guest + bench guest (kernels, busybox, init, initramfs)
bench/qemu/build-static.sh      # static QEMU for the phone, ~20 min, needs docker
(cd probe/app && ./gradlew assembleDebug)
```

The kernel flavours matter: the Debian `cloud` kernel is 4 KiB-page, the
`arm64-16k` one is 16 KiB-page. Both have 8250/OF serial, virtio-pci and
virtio-console built in, which is what crosvm and QEMU expose, and both take a
gzip initramfs. The initramfs is `bench` as `/init` plus `/bin/busybox` (for
`bench.shell=1` debugging), about 1 MB.

## Part 1: what does a custom VM get? (`probe/run-on-device.sh --full`)

*Pending device.* Run alone with:

```sh
probe/run-on-device.sh --full          # -s SERIAL if needed; --no-boot to test the gates only
```

It runs the probe app repeatedly and writes, in `probe/results/<ts>/`:

| File | Content |
|---|---|
| `summary.md`, `summary.json` | the answers (below) |
| `<tag>-result.json` | one machine-readable result per run: verdict, host facts, timings, guest facts |
| `<tag>-report.txt` | the human report of that run (gate by gate) |
| `<tag>-console.txt` | the guest's console: `/proc/iomem`, device tree, PCI/virtio, interrupts, ... |
| `<tag>-logcat-avf.txt` | virtmgr/crosvm/hiddenapi/avc lines, including **the exact crosvm command line** |

Runs (`<tag>`): `base` (4K kernel, 256 MiB, default vCPUs), `cpus-host`
(`CPU_TOPOLOGY_MATCH_HOST`), `kernel-16k` (16 KiB-page guest kernel), and
`mem-512`, `mem-1024`, ... a RAM sweep that stops at the first size that doesn't
reach `OK` or at 90% of the phone's RAM. Add `--protected` to confirm a protected
VM with our own kernel is refused; `--mem-sweep 8192,9216,10240` to bisect a
ceiling; `--match-host-cpus`, `--mem`, `--kernel` for a single custom run.

### Reading the probe summary

| Question | Where | Meaning |
|---|---|---|
| Does it work at all? | `Base verdict` | `OK`, or the first gate that failed: `FEATURE_MISSING`, `PERMISSION_MISSING`, `HIDDEN_API_BLOCKED`, `GUEST_FILES_MISSING`, `CONFIG_REJECTED`, `VM_START_FAILED`, `VM_NO_OUTPUT`, `VM_INCOMPLETE_OUTPUT` (see SPIKE-1 section 2). Anything but `OK` is still a result: the detail says which wall we hit |
| Max guest RAM | `guest RAM: largest size that booted` | The biggest sweep size that reached `OK`. The first refused size and its message follow (`CONFIG_REJECTED` = virtmgr/the client said no; `VM_START_FAILED` = crosvm couldn't get the memory). The guest's own `MemTotal` is in `<tag>-result.json` -> `guest.mem_total_kb` |
| vCPU count | `vCPUs: default N, match-host M` | The default is 1. `match-host` is what `CPU_TOPOLOGY_MATCH_HOST` yields (one per host CPU, if allowed). There is no API for an arbitrary count |
| 4 KiB vs 16 KiB | `guest page size`, `16 KiB-page guest kernel` | The guest kernel's page size (from the auxv). If `kernel-16k` is `OK` and says 16384, a 16 KiB-granule guest boots under this hypervisor; if it fails, `<tag>-console.txt` has the kernel's complaint. `host_page_size` in the summary JSON is the phone's own |
| virtio devices | `virtio devices seen by the guest` | Decoded from `/sys/bus/virtio/devices` (`console(3)`, `blk(2)`, `rng(4)`, `balloon(5)`, `vsock(19)`, `net(1)`, `fs(26)`, ...); the PCI vendor:device ids are alongside. Compare with what SPIKE-1 section 5 predicted |
| Boot time | `boot:` line | `create` = `VirtualMachineManager.create`, `run() returned` = crosvm launched, `first console byte` = kernel started printing, `guest finished` = our init reached the end and powered off. `guest uptime at init` is the guest kernel's own clock when `/init` started (kernel boot only) |
| Which core | `core:` | The vCPU's MIDR_EL1 decoded to a Cortex name: which Tensor core the vCPU thread landed on |

## Part 2: pKVM vs TCG (`bench/run-on-device.sh`)

*Pending device.* Run alone with:

```sh
bench/run-on-device.sh --also-16k      # -s SERIAL; --scale 25 --reps 2 for a quick look
```

The same benchmark guest runs three ways on the same phone, back to back:

| Leg | How | What it measures |
|---|---|---|
| **phone native** | the `bench` ELF run directly from `adb shell` | the ceiling: no VM at all |
| **AVF/pKVM** | the guest in a non-protected custom VM, console captured by the probe app (1 vCPU, 512 MiB, `nokaslr`) | hardware virtualization: stage-2 translation, crosvm's virtio |
| **QEMU TCG** | static `qemu-system-aarch64 -M virt -cpu cortex-a72 -accel tcg -smp 1 -m 512`, pushed to `/data/local/tmp/avfbench`, same kernel and initramfs | software emulation: what the current QEMU backend is |

`--also-16k` adds an AVF leg with the 16 KiB-page kernel. If TCG can't map
executable memory from the `adb shell` context the runner retries once with
`-accel tcg,split-wx=on`; if that fails too, the TCG leg is reported failed (the
tail of its output is in `tcg.txt`) and the other legs still count.

### The workloads

From pyre's `docs/SAME-ISA-FASTPATH.md`, so numbers line up with its tables.
Each is a loop in `bench/bench.c`; every workload runs `--reps` times, and the
table uses the best (min) time per operation.

| Name | Work | `ops` is | Stresses |
|---|---|---|---|
| `int` | branchy integer switch loop + FNV-style hashing, 100 M iterations | iterations | straight-line integer code: TCG's translation quality, native for HW virt |
| `mem` | STREAM-like triad `a = b + s*c` over 3 x 8 MiB of doubles, 60 passes | bytes moved | memory bandwidth + FP/SIMD (TCG runs NEON in softfloat-ish helpers) |
| `chase` | dependent random loads over a 64 MiB cyclic permutation, 2 M steps | loads | TLB misses and DRAM latency: **where stage-2 walks cost** under HW virt |
| `sys` | `getppid()` 1 M times | syscalls | EL0->EL1->EL0 round trip (no KPTI: the guests boot with `nokaslr`, as pyre did) |
| `pf` | mmap 16 MiB, touch every 4 KiB, munmap, 40 times | pages touched | page-fault path and MMU-heavy kernel work |

Differences from pyre's setup: here the guest is a bare freestanding `/init`
(no CoreMark, no libc), and the CPU model for TCG is a Cortex-A72 as there.
`--scale PCT` shrinks every workload proportionally; the ratios use ns per
operation so they stay comparable, and the `check` hash (a result digest printed
per rep) must be identical across legs at equal scale. `MISMATCH` in the table
means the legs did not do the same work. Don't trust that row.

### Output

`bench/results/<ts>/` (or the `--out` directory):

| File | Content |
|---|---|
| `summary.md`, `summary.json` | the comparison table |
| `native.txt`, `avf-console.txt`, `avf16k-console.txt`, `tcg.txt` | raw guest output (`BENCH ...` lines, `AVFKV key=value` facts) |
| `avf-result.json`, `avf-logcat-avf.txt` | the AVF run's verdict and crosvm lines (check these first if the AVF leg is missing) |
| `device-state.txt` | battery level/temperature and thermal status after each leg |

A `BENCH` line: `BENCH name=int unit=iter rep=0 ops=100000000 ns=214000000 check=0x...`.

### Reading the table

```
| workload | unit | phone native ns/op | AVF/pKVM 4K ns/op | QEMU TCG ns/op | AVF/native | TCG/AVF | TCG/native | checks |
```

Lower ns/op is faster. The three ratio columns are what to look at:

- **TCG/AVF** is the answer to question 2: how many times faster the hardware
  path is than the emulator, per workload. A backend is worth building if this is
  large where it matters (the iPhone guest is integer/branch heavy plus a lot of
  MMIO and syscalls).
- **AVF/native** is the virtualization tax. Expect about 1.0x for `int`, `mem`
  and `sys`; the interesting ones are `chase` and `pf`, where two-stage address
  translation shows up. Several times 1.0 on `int` means the vCPU landed on a
  slower core than the native run did (check `core:` in `Environment`).
- **TCG/native** is the emulation tax.
- `Environment` lists, per leg, the kernel, guest page size, online CPUs and core,
  so you can see what ran where. `INCOMPLETE` means that leg's output was cut off.

Anchors from pyre on an M1 Mac mini (HVF vs upstream QEMU TCG, same method):
`int` 3.5x, `pf` 7x, `chase` 5x, `sys` 13x, `mem` (FP triad) 28x slower under
TCG. Large `mem` and `sys` ratios are expected; a phone core in TCG should land in
the same region, probably higher. Treat these as anchors for sanity, not targets.

### Caveats worth knowing before quoting a number

- One run on one phone at one temperature. Use `--reps 5`, repeat after a cool-down,
  and look at `device-state.txt`. A hot Tensor can halve the second leg.
- The Android scheduler decides which core each leg runs on (the `native` ELF, the
  VM's vCPU thread and the QEMU TCG thread can all differ). `core:` shows the
  guest-visible one for the VM legs and for the native leg; QEMU always reports its
  own emulated Cortex-A72.
- AVF's boot time includes crosvm startup and the Java API; QEMU's includes
  loading a 30 MB kernel through `adb`-pushed files. Only the in-guest timings
  (`ns=`) are directly comparable; boot figures are indicative.
- This is a **non-protected** VM. pKVM-protected VMs can't take our kernel (SPIKE-1
  section 4), so this measures the host-managed stage-2 path, not the isolated one.
- One vCPU everywhere. Multi-vCPU scaling is not measured.
- The 16 KiB leg needs a CPU and stage-2 setup with the 16 KiB granule. Recent
  Pixels run 16 KiB kernels (Android's developer option), so the cores should
  have it, but whether pKVM hosts a 16 KiB guest is exactly what `kernel-16k`
  tests. A Cortex-A72 model has no 16 KiB granule, which is why
  `bench/run-tcg.sh --kernel 16k` switches TCG to `-cpu max`; the phone TCG leg
  always uses the 4 KiB kernel.

## Smoke-testing without the phone

Both guests boot under any QEMU, so the guest side can be checked anywhere:

```sh
tools/docker-build.sh
bench/run-tcg.sh --scale 10 --reps 2    # needs qemu-system-aarch64 on PATH (--qemu BIN otherwise)
```

This prints the same table with just the TCG column (software emulation on your
host's CPU, so absolute numbers are meaningless; it proves the guest, the
`BENCH`/`AVFKV` format and the summariser). For the phone, the static QEMU from
`bench/qemu/build-static.sh` is what gets pushed.

## Pending-device checklist

| Step | Status |
|---|---|
| Guest images build from pinned inputs (probe + bench, both kernels) | done, tested |
| Benchmark guest boots, prints identical checks, powers off (QEMU TCG, 4K and 16K) | done, tested |
| Summaries, runner control flow (fake adb: install, grants, sweep, TCG retry, restore) | done, tested |
| Static QEMU (10.2.2, aarch64-linux, ~35 MB stripped) builds and boots the bench guest (run under qemu-user on x86) | done, tested |
| Probe app builds with the new options and `result.json` (`tools/docker-apk.sh`) | done, builds; **not run on any Android device or emulator** |
| `tools/run-all.sh` on a Pixel 10 | **pending device** |
| Does the AVF custom VM start for a sideloaded app (SPIKE-1 gates 1-7) | **pending device** |
| Does the static QEMU's TCG JIT run under `adb shell` (SELinux `execmem`) | **pending device** (falls back to `split-wx`) |
| Does the 16 KiB-page guest boot under pKVM | **pending device** |
