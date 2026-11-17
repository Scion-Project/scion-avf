<!-- SPDX-License-Identifier: MIT-0 -->
# vmapple/: an open xnu-12377 VMAPPLE kernel for AVF

For developers. Builds Apple's open-source `xnu-12377.121.6` for its virtual
machine board, **VMAPPLE**, without Apple's Kernel Debug Kit, with Scion's
`SCION_NATIVE_PAC` change, and boots it on QEMU `virt` the way crosvm boots a
VM on the Pixel 10. Why and how far this goes: [docs/AVF-VMAPPLE.md](../docs/AVF-VMAPPLE.md).

Nothing of Apple's is in this directory. `setup.sh` downloads Apple's
open-source releases by tag at build time; the kernel it builds carries no
IPSW, KDK or firmware content.

| File | What | Licence |
|---|---|---|
| `setup.sh` | fetch sources, build the fake SDK root (availability.pl, xnu headers, libfirehose_kernel), apply `buildfix.sh` and `patches/` | AGPL-3.0-or-later |
| `buildfix.sh` | build-system edits so the open tree links without the KDK (no kernel behaviour change) | AGPL-3.0-or-later |
| `patches/0001…0007-*.patch` | 0001 PAC keys in the architectural registers instead of Apple's `hvc` calls (`SCION_NATIVE_PAC=1`); 0002 16550 console for crosvm; 0003 no Apple implementation-defined registers; 0004 pmap without a monitor; 0005 what the KDK archive supplies (no read-only region, BTI-padded `__chkstk_darwin`, …); 0006 chained-fixup rebase and signing in `arm_init`; 0007 physical-aperture slack. All behaviour changes only with `SCION_NATIVE_PAC=1` | APSL-2.0 (modify Apple's xnu; stated in each) |
| `kbuild.sh` | `make … MACHINE_CONFIGS=VMAPPLE SCION_NATIVE_PAC=1` | AGPL-3.0-or-later |
| `qemu-vmapple.sh` | avfboot + XNUP payload on QEMU virt, TCG `-cpu max` (PAuth) | AGPL-3.0-or-later |
| `crosvm-vmapple.md` | the same VM on the Pixel 10 (AVF) and on a Linux KVM host (crosvm) | AGPL-3.0-or-later |

## Build (macOS with Xcode 26+, Homebrew cmake and ninja)

```sh
vmapple/setup.sh /path/to/work                 # ~5 min
vmapple/kbuild.sh /path/to/work DEVELOPMENT    # -j4 at nice 10; long
ls /path/to/work/build/xnu.obj/kernel.development.vmapple
```

## Boot on QEMU

avfboot (scion-kernel `avf/shim/`) needs three small changes for a macOS-linked
xnu-12377 kernel: the kernel's virtual base from the Mach-O (VMAPPLE links at
`0xfffffe0007004000`, not iOS's `0xfffffff007004000`), the console named in
`/defaults/serial-device`, and a 256-byte `/chosen/random-seed`. They are in
Scion-Project/scion-kernel#248 (draft).

```sh
(cd $SCION_KERNEL && python3 xnuloader/mkidentity.py --placeholder > xnuloader/identity.h && avf/shim/build.sh)
vmapple/qemu-vmapple.sh $SCION_KERNEL /path/to/work/build/xnu.obj/kernel.development.vmapple 300 | tee boot.log
```

## Status

Builds and links; on QEMU it gets through Mach, VM and zone bootstrap and IOKit NVRAM, and stops in `PE_init_iokit` (`SHA1Init`: no corecrypto registered). Details and the next steps: docs/AVF-VMAPPLE.md section 6. Not run on a phone.
