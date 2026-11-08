# iOS 26 XNU (xnu-12377) on the Pixel 10's AVF: the VMAPPLE route

Date: 2026-11-07. Question: can Scion run an arm64e XNU from the iOS/macOS 26
sources (`xnu-12377`) as a custom VM under the Pixel 10's own hypervisor
(AVF → pKVM → crosvm), with no bootloader unlock, by building it for XNU's
open **VMAPPLE** board (Apple's virtual-machine platform)?

This is a desk study plus a kernel build and a QEMU boot. Nothing here ran on
a phone. No Apple binaries, keys, IPSW contents or KDK files are in this
repository; the build fetches Apple's open-source releases by tag.

Sources are marked: **[pixel]** measured on a Pixel 10 by an earlier run of
`probe/run-on-device.sh` (issue #6, Android 17 `DP11.260918.006`, user build);
**[xnu]** read from `apple-oss-distributions/xnu` tag `xnu-12377.121.6`;
**[crosvm]** read from `google/crosvm` `main`; **[aosp]**, **[spike1]** as in
[SPIKE-1-AVF-LAUNCH.md](SPIKE-1-AVF-LAUNCH.md); **[built]** / **[qemu]** done
on the build Mac tonight (section 6); **[prior]** other projects' published
results, not reproduced here.

## 1. Verdict

1. **The VM itself is not the obstacle.** A sideloaded app starts a
   non-protected custom-kernel VM on a stock, locked Pixel 10 with two
   `pm grant`s and a hidden-API exemption [pixel]. HakiOS's XNU (iOS 16.5,
   arm64) already reaches PID 1 there through `avfboot` (scion-kernel
   `avf/README.md`).
2. **Pointer authentication is available to that VM.** The guest vCPU is a
   Cortex-A725 (MIDR `0x410fd871`) whose `/proc/cpuinfo` lists `paca pacg`
   (QARMA3) [pixel]. crosvm asks KVM for `KVM_ARM_VCPU_PTRAUTH_ADDRESS` and
   `_GENERIC` whenever the host has the capabilities (crosvm commit
   `6ec88e1c1d`, May 2022) [crosvm]. So an arm64e kernel can run there; it
   just cannot use Apple's way of managing the keys.
3. **VMAPPLE fits crosvm's shape but talks to Apple's hypervisor.** It is a
   GICv3, PSCI, generic-timer, 16 KiB-page board with no PPL/SPTM
   (`NO_MONITOR`) [xnu], which is what crosvm offers. But its PAC keys, its
   kernel-text lock (paravirtualised CTRR) and a few services go through
   `hvc` calls to Apple's Virtualization.framework (`osfmk/arm64/hv_hvc.h`).
   KVM answers an unknown `hvc` with SMCCC "not supported" (-1), and XNU's
   PAC set-up spins on a non-zero answer (`cbnz x0, .`), so an unmodified
   VMAPPLE kernel hangs on its first PAC call under crosvm. Scion's
   `SCION_NATIVE_PAC` change (section 4) programs the ARMv8.3 key registers
   at EL1 instead.
4. **The open kernel is not a whole VMAPPLE kernel.** Apple links every
   VMAPPLE kernel with `libVMAPPLE.os.<config>.a` from the Kernel Debug Kit, a
   binary-only archive. Scion cannot use or ship it, so its symbols have to be
   written fresh (section 6 lists what the link asks for), and the drivers a
   Mac VM gets from kexts (platform expert, interrupt controller, virtio,
   storage) must come from Scion's own in-kernel drivers, as they already do
   for HakiOS under AVF.
5. **Feasibility: possible, not cheap.** No step needs root, an unlocked
   bootloader, a custom hypervisor or a protected VM. The work is kernel-side
   and testable under QEMU first. An independent project has already taken an
   `xnu-12377` kernel to the iPadOS home screen inside crosvm (on Qualcomm's
   Gunyah hypervisor, with its own crosvm build) [prior]; the Pixel's stock
   crosvm offers fewer devices than that build, so Scion has to stay on
   virtio-pci and the devices AVF already attaches.
6. **Measured tonight, on QEMU only:** the open VMAPPLE kernel, built without
   the KDK and with Scion's seven patches, boots on QEMU `virt` with FEAT_PAuth
   (QARMA3) through Mach, VM and zone bootstrap, logging and IOKit's NVRAM, and
   stops in `PE_init_iokit` because no corecrypto is registered (section 6).
   The next phone experiment is one read-only AVF run of this kernel (section 7).

## 2. What the app can start on a stock Pixel 10

Established by spike #1 and its Pixel run; summarised here, details in
[SPIKE-1-AVF-LAUNCH.md](SPIKE-1-AVF-LAUNCH.md).

| Question | Answer | Source |
|---|---|---|
| Custom kernel + initrd from an app | yes: `MANAGE_VIRTUAL_MACHINE` and `USE_CUSTOM_VIRTUAL_MACHINE` by `pm grant`, plus the two-prefix `hidden_api_blacklist_exemptions` | [pixel] `VERDICT: OK` |
| `DEBUG_VIRTUAL_MACHINE` | `signature` only, not grantable, not needed | [aosp] |
| Protected VM (pVM) with our kernel | no: virtmgr only boots a pVM kernel whose SELinux label says it came from the system image (`check_label_for_kernel_files`) | [aosp]; the `--protected` probe leg has not been run |
| Non-protected VM | yes; pKVM still isolates the host from it, but the guest's memory is not protected from the host | [pixel] |
| Hypervisor | `ro.boot.hypervisor.version = kvm.arm-protected` | [pixel] |
| vCPUs | 1, or one per host CPU with `CPU_TOPOLOGY_MATCH_HOST` (HakiOS booted 8 of 8) | [pixel], scion-kernel `avf/README.md` |
| RAM | starts at IPA `0x8000_0000`; size from `setMemoryBytes` | [pixel] |

What the guest sees [pixel] [spike1]: a `linux,dummy-virt` FDT, PSCI 1.1 over
`hvc`, GICv3 (distributor at `0x3fff0000`, redistributors below it, ITS at
`0x40000000`), the architected timer (virtual timer PPI 11), an **8250/16550
UART at `0x3f8`** (AVF's captured console; there is no PL011), an RTC at
`0x2000`, pvtime, virt-cpufreq, a VM watchdog, virtio-pci (CAM at
`0x2e000000`, MMIO at `0x2c000000`) with three virtio-consoles, vsock,
optional virtio-blk disks, balloon, and, through the hooks the display app
uses, virtio-input and a shared-memory framebuffer. crosvm always passes
`--no-pmu`. The guest gets no device of Apple's (no AIC, no Apple PV GPU, no
`vmapple` config or backdoor device) and the app cannot add one: the only
out-of-process device AVF lets an app supply is virtio-fs.

## 3. VMAPPLE against that machine

From `pexpert/pexpert/arm64/VMAPPLE.h` and its users [xnu]:

| VMAPPLE has | crosvm on the Pixel | Gap |
|---|---|---|
| `HAS_GIC_V3`; `pexpert/arm/pe_fiq.c` wakes the redistributor and takes the timer as a group-0 interrupt (FIQ) | GICv3 emulated by KVM's vGIC (group 0 signals vFIQ) | not reached yet: the QEMU boot stops before the first interrupt (section 6) |
| `PL011_UART` console | 8250 at `0x3f8` | a 16550 back end in `pe_serial.c` (HakiOS's patch 1000 does this for xnu-8796) |
| `__ARM_16K_PG__`, `__ARM_MIXED_PAGE_SIZE__` | Cortex-A725 implements the 16 KiB granule; the guest picks its own stage-1 granule, independent of pKVM's 4 KiB stage 2 | not yet seen on the phone: the AVF-BENCH `kernel-16k` leg answers it |
| `NO_MONITOR` (no PPL, no SPTM, no TXM) | nothing to provide | none; also nothing for the behaviour-preservation rule to keep |
| `CPU_HAS_APPLE_PAC` + `HAS_PARAVIRTUALIZED_PAC`: keys set by `hvc` (`VMAPPLE_PAC_SET_INITIAL_STATE`, `_SET_B_KEYS`, `_SET_EL0_DIVERSIFIER`, `_GET_DEFAULT_KEYS`) | architectural FEAT_PAuth keys (`APIAKey_EL1` …), QARMA3; no Apple diversifier | `SCION_NATIVE_PAC` (section 4) |
| `HAS_PARAVIRTUALIZED_CTRR`: kernel text locked by the hypervisor | nothing | the lock-down is in the KDK archive; without it text stays writable to the kernel (as on HakiOS today) |
| hypercalls for mach-absolute-time offset, boot-session UUID, vCPU kick/wait | KVM's vendor UID differs from `VMAPPLE_HVC_UID`, so `hvg_is_hcall_available()` reports them absent and XNU falls back | none expected |
| `-march=armv8.5a+sme2`, `HAS_ARM_FEAT_SME/SME2` | A725 has no SME | the kernel checks the ID registers before using SME; to confirm on the phone |
| Platform expert, interrupt controller driver, virtio, storage, display: kexts (`AppleVirtualPlatform` and friends) | n/a | Scion's in-kernel drivers (`avfboot` DT + virtio-pci, SCFB, virtio-input), ported from the xnu-8796 tree |
| `libVMAPPLE.os.<config>.a` (KDK, binary) | n/a | write the missing symbols (section 6) |

## 4. PAC without Apple's hypervisor (`SCION_NATIVE_PAC`)

On Apple silicon, and in Apple's VMs through the `hvc` calls above, EL0 and
EL1 sign with different keys, and each process gets its own user keys (an
EL0 "diversifier" for the A keys, per-process B keys). Standard FEAT_PAuth has
one set of key registers for EL0 and EL1 together. Scion's change, behind the
build switch `SCION_NATIVE_PAC=1` (off by default, VMAPPLE only):

* `PAC_INIT_KEY_STATE` (`osfmk/arm64/pac_asm.h`): the first CPU fills a
  key block from the physical and virtual counters, and every CPU (first and
  secondaries, MMU still off) loads `APIA/APIB/APDA/APDB/APGA` from it before
  `SCTLR_EL1` turns the keys on. `HAS_PARAVIRTUALIZED_PAC` is not defined, so
  every `hvc` key call drops out, and the context-switch key reprogramming
  (`cswitch.s`, `CSWITCH_*_KEYS`) compiles away.
* `ml_enable_user_jop_key` / `ml_disable_user_jop_key` are no-ops;
  `ml_default_rop_pid`/`ml_default_jop_pid` already return 0 without the
  paravirtual keys.

What this gives up, plainly: the kernel and every process share one key set
per boot, so a pointer signed in one process authenticates in another and in
the kernel. That is weaker than iOS. It is the same trade UniXNU makes for
non-Apple CPUs (`native-pac-keys.patch`, BSD-2-Clause-Patent), which Scion's
change follows in design; the code is Scion's own. A stronger version swaps
the user and kernel keys on every exception entry and return (eight to ten
`msr`s and an `isb` each way, as Linux does for its kernel key); that is the
follow-up, not this change.

Arm64 (not arm64e) processes run with user JOP disabled on Apple CPUs; with
one shared key set, their unsigned pointers fail authentication in arm64e
shared-cache code. UniXNU-droidvm handles that by turning IA/DA/DB off in
`SCTLR_EL1` while such a thread is at EL0. Scion needs the same before running
iOS user space; it is not needed to boot the kernel.

QARMA3 (Pixel), QARMA5 (QEMU's default) and Apple's own algorithm produce
different signatures, which does not matter: nothing signed on one machine is
authenticated on another. arm64e binaries carry unsigned chained fixups that
dyld and the kernel sign at load time.

## 5. Prior art and licences

| Project | What it shows | Licence / how Scion may use it |
|---|---|---|
| [UniXNU](https://github.com/UniXNU/UniXNU) | xnu-12377 arm64e on non-Apple ARM over UEFI; native PAC keys, public stand-ins for KDK-only headers, an optional KDK support archive | BSD-2-Clause-Patent: usable with its notice kept; Scion's APSL files are not relabelled. Used here for design only |
| [Droid-VM/UniXNU-droidvm](https://github.com/Droid-VM/UniXNU-droidvm) | iPadOS on xnu-12377 in **crosvm on Gunyah** (Snapdragon), lock and home screen, virtio-input, virtio-net; a forked crosvm with virtio-mmio devices; WFE avoided because Gunyah runs it in the guest | BSD-2-Clause-Patent; design only. Its crosvm fork is not available to an app on a Pixel |
| [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build) | how to build open XNU (incl. VMAPPLE) on a Mac; it needs the KDK archive and headers | MIT; build steps re-done in `vmapple/` without the KDK |
| medfa12/apple-silicon-anyos-project | macOS 26 under QEMU `vmapple` on Linux KVM: PAC across vCPUs, GIC, Apple hypercalls | GPL-2.0: reference only, no code |

## 6. Build and QEMU results

See [`vmapple/README.md`](../vmapple/README.md) for the commands.

### Build [built]

`xnu-12377.121.6`, `MACHINE_CONFIGS=VMAPPLE`, `KERNEL_CONFIGS=DEVELOPMENT`,
`SDKROOT=macosx` (Xcode 27.2 SDK), `SCION_NATIVE_PAC=1`, no KDK: links
`kernel.development.vmapple` (arm64e, 21 MB). What it took, in the order the build
hit it (each one is in `vmapple/buildfix.sh` or a patch):

| Blocker | Cause | Fix |
|---|---|---|
| `availability.pl`, `libfirehose_kernel.a`, KDK private headers | the open build expects an internal SDK | fake SDK root from Apple's open releases (`setup.sh`) |
| `lib<MACHINE>.os.<CONFIG>.a` force-loaded | KDK binary archive | link it only if present |
| `CoreEntitlements/V2`, `CodeSignature/Entitlements.h`, `TrustCache/*` | KDK-only headers | opaque types, four entitlement strings, TrustCache headers from xnu-8796.101.5 |
| no `start.s`, `locore.s`, `cswitch.s`, caches, pmap in the link (264 undefined symbols) | files marked `nos_arm_asm` / `nos_arm_pmap`; Apple ships them prebuilt in the KDK archive | add both options to `MASTER.arm64.MacOSX` and compile them from source |
| `arm64/ppl/sart.h`, `uat.h`, `arm64/tunables/tunables.s` | not in the release | empty stand-ins (no SART, UAT or CPU tunables on a VM) |
| `CPU_OVRD` undefined | Apple register, not defined for VMAPPLE | `NO_CPU_OVRD` (patch 0003) |
| pmap no-monitor compile errors; `amcc_rorgn_*.c`, `ml_enable_monitor`, `ml_device_is_prod_fused`, two cache helpers missing | KDK archive | patches 0004, 0005 |

### QEMU boot [qemu]

`vmapple/qemu-vmapple.sh`: QEMU 11.1 `virt,gic-version=3`, TCG,
`-cpu max,pauth-qarma3=on` (FEAT_PAuth with the Pixel's algorithm), 1 vCPU, 2 GB,
avfboot (scion-kernel#248) + XNUP payload, boot-args
`-v serial=3 debug=0x8 cpus=1 -noprogress`. Run on the build Mac.

Each stop and what moved it on:

| # | Stop | Diagnosis | Fix |
|---|---|---|---|
| 1 | silent; data abort at FAR `0x18d2c0` in `static_if_init` | data pointers still in chained-fixup form: Xcode 26+ `ld` links the kernel with `LC_DYLD_CHAINED_FIXUPS` (format 7) and can no longer emit `__thread_starts`, which is all `arm_init` knows how to rebase outside a kernel collection | patch 0006: `arm_init` walks the chains and signs authenticated pointers with the keys `SCION_NATIVE_PAC` loaded |
| 2 | `Expected 256 seed bytes from bootloader, but got 64` | xnu-12377 wants a bigger `/chosen/random-seed` | avfboot (scion-kernel#248) |
| 3 | assert in `arm_vm_physmap_init` | the physical aperture's twig alignment overruns `physmap_end` on a large-memory, monitor-less board when the kernel has no kexts | patch 0007 |
| 4 | Branch Target Exception at `__chkstk_darwin` | called through an authenticated pointer (`blraa`) with BTI enforced; Xcode's `libcc_kext.a` copy has no `bti c` | patch 0005 adds one with a landing pad |
| 5 | assert in `PE_init_iokit` (boot progress) | macOS draws boot progress by default and there is no framebuffer | boot-arg `-noprogress` |
| **6** | **data abort (FAR `0x28`) in `SHA1Init`, called from `IOPlatformExpertDevice::generatePlatformUUID()` in `PE_init_iokit`; the panic path then faults again in the extended panic log, so nothing is printed** | **XNU's crypto entry points are a table the corecrypto kext registers (`register_crypto_functions`); there is no kext here** | **next step, below** |

Console at the stop (the build user in the version string elided):

```
avfboot: jumping to XNU at 0x435f0480
Darwin Kernel Version 25.5.0: Sat Nov  7 22:25:47 GMT 2026; …:xnu.obj/DEVELOPMENT_ARM64_VMAPPLE
pmap_startup() init/release time: 2525233 microsec
vm_page_bootstrap: 124059 free pages, 4965 wired pages
...
zone_init: map VM    0xfffffe1000674000:0xfffffe14cd340000 (19G, 19G usable)
...
VM bootstrap done: 71 maps, 235 entries and 60 nodes left
Firehose configured: 16 chunks, 8 io pages
OSLog stream configured: stream: 8192 bytes, cache: 2112 bytes
...
Serial requested, consistent debug disabled or debug boot arg not present, configuring debugging over serial
iBoot version: iBoot-8422.100.650
IONVRAM.cpp:start:1447 - ...
IONVRAM.cpp:initImageFormat:1586 - NVRAM size is 8192 bytes
IONVRAM.cpp:handleEphDM:1373 - ephemeral-data-mode not supported
pNNNNMACH Reboot
```

What this establishes: the `SCION_NATIVE_PAC` key set works (every return
address, the chained-fixup signing and the `blraa` calls authenticate), the
16 KiB-page VMAPPLE pmap comes up without a monitor, the PL011 console runs,
and Mach, the VM system, zones, logging
and IOKit's NVRAM start, all on a non-Apple CPU model. (`iBoot version` is the
string compiled into the kernel, not a loader.) What it does not establish:
anything on the phone, the 16550 console path (patch 0002 is built, not run),
more than one vCPU, interrupts (the boot stops before the first timer
interrupt is needed), or user space.

How the stops were found without a console: QEMU `-d int` for the exception
and `ELR`, `atos` on the unstripped kernel, a frame-pointer walk through the
QEMU monitor, and lldb on QEMU's gdb stub for the caller of the faulting
function. The assert descriptors behind `brk #0xbffc` decode with the kernel's
own `__desc` records.

### Next steps (kernel)

1. Crypto in the kernel: register a `crypto_functions` table at early boot
   (UniXNU builds Apple's published corecrypto source into its kernel for
   this, `source-corecrypto14-bootstrap.patch`; how Scion's xnu-8796 tree
   handles it is to be checked), or, as a stop-gap, give `generatePlatformUUID` a
   platform UUID without SHA-1. The first is needed anyway for code signing.
2. A panic log region (`/pram` or `PLATFORM_PANIC_LOG_DISABLED` handled) so
   panics print instead of faulting in `is_debug_ptr_in_ext_paniclog`.
3. Interrupts: VMAPPLE's `pe_fiq.c` takes the timer as a GICv3 group-0 FIQ; the
   IRQ side (virtio, IPIs) needs Scion's GIC and virtio-pci drivers ported from
   the xnu-8796 tree onto the ios-26 base (scion-kernel#246).
4. Then the iOS side: `SDKROOT=iphoneos` (the ios-26 profile builds VMAPPLE for
   iPhoneOS) and arm64 user processes under one shared key set (section 4).

## 7. Next phone experiment (read-only, needs the owner's go)

One run of the probe app with the VMAPPLE kernel, the way HakiOS's kernel has
already been run (scion-kernel `avf/run-probe.sh`; details in
[`vmapple/crosvm-vmapple.md`](../vmapple/crosvm-vmapple.md) section 1). It is
read-only in the sense that matters: nothing is flashed, no partition or
setting outside the app is written, and `run-probe.sh` revokes the grants and
the hidden-API exemption on exit. It installs a test APK and runs one
non-protected VM for about a minute.

It answers three questions QEMU cannot:

1. Does a 16 KiB-granule guest boot under pKVM? (MMU on, kernel banner.)
2. Do `SCION_NATIVE_PAC`'s keys work under KVM on the Cortex-A725 (QARMA3)?
   (Banner and VM bootstrap; a PAC failure shows as a `brk #0xc47x` or an
   instruction abort right after the MMU comes on.)
3. Does patch 0002's 16550 console print on AVF's captured console?

Expected result if all three hold: the same stop as QEMU (`SHA1Init`), after
the VM bootstrap lines. It needs the owner's go, because the Pixel 10 is a
daily phone and the run installs and starts a VM on it.
