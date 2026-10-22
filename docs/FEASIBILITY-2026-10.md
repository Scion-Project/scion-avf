# Feasibility: running the iPhone 11 (t8030) guest under hardware virtualization on a Pixel 10

Date: 2026-10-22. Scope: can the emulated iPhone 11 (`t8030`, XNU from iOS 14.x,
and later iOS 27) run under the Pixel 10's hardware virtualization (Android
Virtualization Framework → pKVM → crosvm) instead of QEMU's TCG interpreter,
and if so, how. The owner's premise is correct in principle — native arm64
execution under a hypervisor is far faster than a JIT — so the question is
only whether it can be made to work on *this* device under *these* constraints.

Constraints taken as fixed (from the owner):

* **The Pixel 10 will not be rooted** and its bootloader stays locked.
* **ETHICS applies** ([ios-on-pixel/docs/ETHICS.md]): no Apple binaries or keys
  in the repo, and any guest change must *preserve behaviour* — the security
  monitors (PPL on 14.x; SPTM/TXM on 27) keep running and enforcing.

Sources are cited inline: `[inferno]` = our Inferno fork at `master`,
`[kvm]` = Linux 6.12 KVM arm64 (`torvalds/linux` v6.12), `[aosp]` = AOSP
`packages/modules/Virtualization` at `main` (Oct 2026), `[spike1]` =
`docs/SPIKE-1-AVF-LAUNCH.md`, `[kc26]` = a static scan of a **research copy**
of the iOS 26.6.2 t8030 kernelcache (read-only, outside any repo; used as the
closest pre-SPTM proxy — no 14.8 copy was available on the build hosts). No
Apple payload bytes appear here, only instruction/encoding counts.

---

## 1. Verdict (five lines)

1. With no root and a locked bootloader, the **only** hardware-virt route is a
   non-protected custom VM inside the system crosvm via AVF; QEMU-on-`/dev/kvm`
   (path B) is impossible because it needs root.
2. That route gives the guest **crosvm's virtual platform only** (GICv3, arch
   timer, 8250 UART, virtio) and **no way for our app to serve the t8030 device
   models** — the one extension point is virtio-fs `[aosp]`.
3. The CPU side is equally blocking: KVM on a Cortex core **injects UNDEF into
   the guest** on every Apple system register and on `GENTER`/`GEXIT` `[kvm]`,
   with **no userspace trap-and-emulate path** for system registers at all.
4. Making XNU survive that means rewriting, in the binary kernelcache, both its
   CPU bring-up (≈179 Apple-sysreg sites `[kc26]`) **and** every t8030 driver
   (AIC, ANS, SEP, display, MT-SPI, PMGR…) to target hardware XNU has no drivers
   for — and `GENTER`/`GEXIT` cannot be removed without disabling PPL/SPTM, which
   **ETHICS forbids**. This is a Corellium-class custom-hypervisor project, not a
   patch set, and AVF does not let us run a custom hypervisor.
5. **Recommendation: do not pursue the AVF/XNU port. Stay on TCG and optimise
   (path D).** Run exactly one cheap experiment first (spike-1 on the real phone
   + a Linux-guest pKVM-vs-TCG microbenchmark, §9) to measure the ceiling we are
   declining, then close the AVF backend as "researched, infeasible on stock
   hardware".

---

## 2. Why path B (QEMU + /dev/kvm) is out

QEMU keeping the t8030 device models and the Apple CPU model while running guest
instructions on `/dev/kvm` would have been the natural "best of both" design.
It is dead on arrival here for one reason: **`/dev/kvm` is not reachable by an
app on a stock Pixel.** Opening it needs a process in an SELinux domain with
`kvm_device`/`dev_type` access and the `KVM` capability surface; on a user build
only system components (virtmgr) have it, and granting it to our app needs root
to relabel the node and loosen SELinux. The owner has ruled out root, so this
path cannot even be prototyped on the target. (Were it available, it would still
hit every CPU-side wall in §4; it would simply let *QEMU* keep hosting the device
models in §5 instead of forcing them into the kernelcache.) It stays the right
design **only** on a Linux KVM host we control, which is where any development
has to happen (§9).

---

## 3. What the AVF custom VM actually provides

From the spike-1 probe and the virtmgr source, a sideloaded app can start a
**non-protected** custom VM with its own kernel after two `pm grant`s and a
hidden-API exemption `[spike1 §1]` — still unconfirmed on a real Pixel 10
(issue #6). That VM gets a **fixed virtual platform** `[aosp` `crosvm.rs]`:

* guest RAM at IPA `0x8000_0000`; **GICv3** (distributor `0x3fff0000`, ITS
  `0x40000000`); the arch generic timer; two 8250 UARTs; virtio-console,
  -blk, -vsock, and optionally -gpu/-input/-net/-sound; **no PMU** (`--no-pmu`
  always passed on aarch64, `crosvm.rs:1283`).
* The memory map and device set are **not configurable** by the app beyond the
  Java `VirtualMachineCustomImageConfig` knobs `[spike1 §5]`.

This is a generic arm64 "virt" board. It is nothing like a t8030.

---

## 4. CPU: what KVM on a Cortex-X4/A725/A520 does with Apple behaviour

The Tensor G5 is 1×Cortex-X4 + 5×Cortex-A725 + 2×Cortex-A520 (Armv9.2)
`[web: Android Authority/Notebookcheck]`. None of these implement Apple's
IMPLEMENTATION DEFINED features. Inferno's TCG model shows exactly how much
Apple-specific behaviour XNU depends on; under KVM each item behaves as follows.

**How KVM handles an unknown register or instruction (the key fact):** a trapped
EL1 access to a system register KVM does not recognise ends in
`emulate_sys_reg() → kvm_inject_undefined(vcpu)` `[kvm sys_regs.c:4042-4058]`.
**There is no userspace exit for system registers.** The userspace-visible exits
are `KVM_EXIT_MMIO`, `KVM_EXIT_ARM_NISV` (data aborts with no valid syndrome,
behind `KVM_CAP_ARM_NISV_TO_USER`, *not* for sysregs) `[kvm api.rst:6979]`, and
`KVM_EXIT_HYPERCALL` (only for `HVC` routed by the SMCCC filter)
`[kvm hypercalls.c:256]`. So an Apple sysreg cannot be "trapped to the VMM and
emulated": the guest just takes an undefined-instruction exception. (`HCR_EL2`
even sets `HCR_TIDCP` `[kvm kvm_arm.h:97]`, which *traps* IMPDEF EL1 accesses to
EL2 — but KVM's handler for them is the same UNDEF injection.)

| Apple feature | XNU use | Inferno models it as | On a Cortex core under KVM | Removable by binary patch? |
|---|---|---|---|---|
| **GXF / `GENTER`,`GEXIT`** (PPL entry on 14/26; SPTM/TXM dispatch on 27) | 20 `GENTER` / 48 `GEXIT` static sites `[kc26]`; 187 `GENTER` on iOS 27 | custom decode + `EXCP_GENTER` `[inferno a64.decode:1912, helper.c]` | reserved-encoding instruction → **EL1 UNDEF** (not an HVC, never a hypercall) | **No** — removing it disables the guarded monitor; ETHICS forbids |
| **SPRR / MPRR / APRR** (page-perm remap) | config + per-switch | 20+ regs `S3_6_C15_*` `[inferno a13_gxf.c]` | **UNDEF** | only by disabling PPL/SPTM — forbidden |
| **HID0-16, EHID\*** (core init) | early boot, per-core | RAZ/WI storage `[inferno a13.c:406-417]` | **UNDEF** | NOP/RAZ-WI possible, but see MIDR below |
| **Fast IPI** `IPI_RR_{LOCAL,GLOBAL}`,`IPI_SR`,`IPI_CR` | SMP cross-calls | MMIO-like writefns `[inferno a13.c:449-498]` | **UNDEF** | would need rewrite to GICv3 SGIs |
| **KTRR/CTRR** `CTRR_*_EL1` | ROM/text lockdown | RW storage `[inferno a13.c:443-448]` | **UNDEF** | NOP-able |
| **AMX** `AMX_CONFIG/STATUS/CTL` | commpage cap bit | regs + decode | **UNDEF** | **Yes** — Inferno already NOPs it `[inferno kernel_patches.c:516 ck_kp_amx_patch]` |
| **WKdm** `WKDMC`/`WKDMD` | VM compressor | custom decode `[inferno a64.decode:1910]` | **UNDEF** | hard — compressor hot path |
| **PAC (Apple keys)** `apia…apga`,`kernel`,`m`, `m_key_lo/hi` diversifier | arm64e everywhere | key regs + diversifier `[inferno cpu.h:754-760,1119]` | Armv9 has standard FEAT_PAuth, but **Apple key-management sysregs UNDEF**; key *values* differ | Inferno already force-enables PAC keys in the boot SCTLR and neutralises the per-pmap JOP toggle under virt `[inferno kernel_patches.c:744,778]` — but that was written for Apple's **HVF**, not KVM |
| **16 KB granule** | mandatory for t8030 | QEMU honours guest TCR | guest stage-1 granule is the guest's own choice; **independent of host stage-2** — not itself a blocker, but IPA-size and MMIO-overlap must be checked on-device | n/a |

Counts `[kc26]`: **179** static Apple sysreg sites in the `op0=3, CRn=15,
op1∈{4,5,6}` space (op1=6/GXF-SPRR: 94; op1=4/HID-CTRR-AMX: 46; op1=5/IPI-UPMU:
39). These are static instruction sites across the fileset, so the number
reached on a cold boot is lower, but every one that *is* reached is a guest
UNDEF unless patched. iOS 14.8 is architecturally the same PPL/APRR family and
would be the same order of magnitude.

**MIDR is the quiet killer.** XNU's early CPU bring-up and its HID register
programming are keyed on the core identity. Inferno's HVF backend *hardcodes*
`MIDR_EL1` implementer `0x61` (Apple) precisely because XNU checks it
`[inferno hvf.c:707-710]`. Under KVM arm64, `MIDR_EL1` is an **invariant**
register reset to the host core's value; userspace cannot set it to Apple's.
Under AVF we cannot touch it at all. So even with every sysreg patched to RAZ/WI,
XNU would be configuring a Cortex it believes is an Apple core — a mismatch that
has to be patched out function by function.

**Net CPU conclusion:** the Apple-sysreg surface is patchable *in the style
Inferno already uses* only for the benign, leaf cases (AMX, CTRR, some HID). The
load-bearing ones — `GENTER`/`GEXIT`, SPRR/MPRR, fast IPI, PAC key management,
MIDR-keyed init — cannot be removed without either breaking the monitors
(forbidden) or rewriting XNU's CPU layer. KVM gives us no trap-to-VMM seam to
absorb them, unlike HVF (which Inferno already targets) or a custom EL2 (which
AVF forbids).

---

## 5. Devices: nowhere for the t8030 models to live

Inferno implements ~40 t8030 device models in QEMU `[inferno hw/arm/t8030.c]`:
AIC, DART (IOMMU), ANS/NVMe, SEP (+SEP-SIM), display pipe + MIPI DSIM + backlight,
MT-SPI touch, PMGR, SPMI/PMU, SMC, SIO, AOP, MCA/audio codecs, I²C/GPIO,
AES, SART, scaler, USB/DWC3+TypeC, WDT, baseband. XNU's drivers bind to exactly
these.

On a stock Pixel the app **cannot add device models to the VM's crosvm**
`[aosp, spike1 §6]`:

* The only backend served from outside virtmgr's crosvm is **virtio-fs**
  (`--vhost-user-fs`, `crosvm.rs:1418`). There is **no API to attach an arbitrary
  vhost-user or vfio-user backend**; `SharedPath`/`addSharedPath` are `@hide`.
* **vfio** is restricted to *platform* devices with a system-side device-tree
  symbol and `iommu=pkvm-iommu` (`crosvm.rs:1007`) — not app-supplied.
* `customMemoryBackingFiles` (`--file-backed-mapping`) exists in the raw AIDL but
  the Java `toVsRawConfig()` always sends an empty list `[spike1 §6]`.

So Apple device models would have to be **replaced inside the XNU binary** with
drivers for GICv3 + virtio. XNU **has no GICv3 driver and no virtio drivers** —
it has never run on anything but Apple interrupt controllers and Apple IP. The
"smallest subset for a first console line" is not small:

* **UART**: crosvm's 8250 at MMIO `0x3f8` vs Apple's S3C-style UART
  `[inferno t8030.c:197]`. XNU's `serial` console driver is Apple-specific;
  it would need an 8250 shim patched in. (This alone is roughly what darwin-vm
  does, but darwin-vm runs under QEMU with Apple device models present, not on a
  virtio board.)
* **Interrupts**: AIC → GICv3. AIC is MMIO + fast-IPI sysregs; XNU's AIC driver
  and its IPI path would have to be rewritten to GICv3 MMIO + SGIs. No precedent
  exists for an XNU-on-GIC port.
* **Timer**: Apple per-core timers → arch generic timer. Partial precedent (XNU
  does know the arch timer), but wired through the AIC today.
* **Root media**: ANS/NVMe → virtio-blk; **SEP** → stub; **display** →
  virtio-gpu; **MT-SPI touch** → virtio-input; **PMGR/SPMI** → stub. Each is a
  new in-kernel driver or a bind-time bypass in a signed kernelcache.

**Precedent check.** `xnu-qemu-arm64` (Project Zero / Trung Nguyen, archived
2022) and Inferno both took the opposite approach — emulate the *Apple* hardware
faithfully in the VMM — exactly because XNU is welded to it. Corellium runs iOS
on arm64 too, but with a **custom hypervisor that models the Apple SoC**
(custom EL2 that emulates Apple sysregs and presents Apple device models), not a
stock KVM/virtio board. There is no public example of XNU booting on a GICv3 +
virtio machine, because it would mean maintaining a parallel board-support port
of a closed kernel. That is the task AVF forces, and it is the reason the answer
is "infeasible", not "hard".

---

## 6. The hybrid question, and Corellium

Could the CPU run natively under the hypervisor while the unsupported bits are
emulated in a VMM? On **KVM: no** — there is no userspace exit for system
registers (§4); the guest gets UNDEF before any VMM sees the access. On **Apple
HVF** (which Inferno already supports, `target/arm/hvf/`): *yes*, HVF delivers
`EC_SYSTEMREGISTERTRAP` to the VMM, and Inferno's `hvf_sysreg_read_cp`/`_write_cp`
re-dispatch Apple registers into the QEMU cpreg table `[inferno hvf.c:920,946]` —
but HVF is macOS/Apple-silicon only. A **custom EL2** (Corellium's model) also
works, because you write the trap handlers yourself. AVF/pKVM exposes **neither**:
the app runs a *guest* under Google's hypervisor; it cannot install EL2 code and
cannot intercept the guest's sysreg traps. The hybrid design is real and already
in our tree — it just requires a hypervisor we are not allowed to provide on this
phone.

---

## 7. Ranked paths

| Path | What | Feasible on stock Pixel 10? | Effort | Expected speedup |
|---|---|---|---|---|
| **A. Stock Pixel + AVF, XNU in a custom VM** | boot XNU on crosvm's virtio board | **No.** §4 (CPU UNDEFs, MIDR) + §5 (no device models, XNU has no GIC/virtio drivers) + ETHICS (can't remove GENTER/GEXIT) | — (not reachable) | native, if it existed |
| **B. Rooted Pixel + QEMU on /dev/kvm + kernel patches** | QEMU keeps device models; guest insns on KVM | **No** — needs root (ruled out). Would still hit every §4 CPU wall | very high | native CPU |
| **C. Unlocked bootloader + custom GKI with a Corellium-style EL2** | own hypervisor that models Apple sysregs | **No** on a locked phone; a research OS project in its own right | ~multiple engineer-years | native CPU |
| **D. Stay on TCG, optimise** | the shipping QEMU backend | **Yes** — already works | weeks, incremental | see §8 |

Only **D** is open on this device. A and B/C are closed by, respectively, the
platform and the owner's constraints.

---

## 8. The TCG ceiling we actually have (path D)

From `ios-on-pixel/docs/PERF.md` (iOS 14.8 restore boot, measured):

* Boot is **not throughput-bound** (~0.95 host cores busy), so faster *cores*
  help less than the headline "native vs JIT" suggests for this workload.
* **34%** of host CPU is guest code; the biggest pure-QEMU cost is
  **indirect-branch TB lookup ≈18%** (`helper_lookup_tb_ptr` 12%). Improving
  jump-cache hit rate is the single largest TCG win available.
* **System-register helpers ≈6.5%** — Apple IMPDEF regs in `a13.c`/`a13_gxf.c`
  made `ARM_CP_CONST`/no-`accessfn` would inline in TCG.
* The **`-smp 2`** finding already cuts the restore boot from 13.1 s to 8.5 s
  (a guest-side `enable_usb` race, #51).

These are real, bounded, ethics-clean gains measured in weeks, against an AVF
port measured in engineer-years that cannot legally remove the monitors.

---

## 9. Concrete next experiment (M0) — the only phone work worth doing now

Two measurements, both needing just the phone (owner back ~26 Oct), neither
needing any Apple software:

1. **Spike-1 on the real Pixel 10** (issue #6): run `probe/run-on-device.sh`.
   Confirms whether a sideloaded app can boot a custom non-protected VM at all,
   captures the real crosvm command line, `/proc/iomem`, `/proc/cpuinfo` (the
   vCPU MIDR — which Tensor cores show), and SELinux denials, and re-confirms
   that virtio-fs is the only device extension point. This bounds §3/§5 with
   facts instead of source reading.
2. **Linux-guest pKVM-vs-TCG microbenchmark**: boot the same stock Debian arm64
   guest `[spike1]` twice on the phone — once in the AVF VM (pKVM, native), once
   under our QEMU TCG build — and compare a fixed CPU-bound workload
   (e.g. a kernel-build or a tight integer/crypto loop). This puts a single
   number on the theoretical ceiling: how much faster native arm64 is than TCG
   on Tensor G5. That number is the upper bound the AVF/XNU port could *ever*
   reach — useful to record, even though §4–§6 say XNU can't reach it on this
   platform.

After M0: **go/no-go is already no-go for XNU.** M0 simply quantifies the ceiling
and closes the AVF backend honestly.

---

## 10. Effort estimate, if the owner still wanted to try

A stock-Pixel AVF/XNU port is not a patch set; it is a port of a closed kernel to
a new board plus a CPU-compatibility rewrite, under a rule that the security
monitors must keep enforcing (which KVM structurally cannot host). Even
discounting the ETHICS blocker, the device-replacement work alone (XNU GICv3 +
virtio drivers for console, interrupts, block, input, display; SEP/PMGR stubs)
has **no precedent** and would be **multiple engineer-years**, with a real chance
it is simply impossible because `GENTER`/`GEXIT` and the guarded monitors have
nowhere to run. Against that, path D delivers measurable wins now. The
recommendation stands: **optimise TCG; do not port to AVF.**

---

### Appendix: files read

`ios-on-pixel-avf`: `README.md`, `docs/SPIKE-1-AVF-LAUNCH.md`, issues #2–#6.
`ios-on-pixel`: `docs/{ETHICS,PERF,HANDOFF}.md`, `docs/ios27/GXF-GAP.md`.
`Inferno@master`: `hw/arm/{t8030.c,a13.c,a13_gxf.c,kernel_patches.c}`,
`target/arm/{cpu.h,cpu64.c,hvf/hvf.c,tcg/a64.decode}`.
Linux v6.12: `arch/arm64/kvm/{sys_regs.c,arm.c,hypercalls.c,mmio.c}`,
`arch/arm64/include/asm/kvm_arm.h`, `Documentation/virt/kvm/api.rst`.
AOSP Virtualization `main`: `android/virtmgr/src/crosvm.rs`.
Static scan: research copy of the iOS 26.6.2 t8030 kernelcache (pre-SPTM proxy;
no 14.8 copy on the build hosts), counting Apple `op0=3, CRn=15` MSR/MRS and
`GENTER`/`GEXIT` sites only.
