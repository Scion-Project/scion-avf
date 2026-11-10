<!-- SPDX-License-Identifier: MIT-0 -->
# Running the VMAPPLE kernel under crosvm

The kernel from `kbuild.sh` (`SCION_NATIVE_PAC=1`) goes into an XNUP payload
and boots behind avfboot, exactly as HakiOS's kernel does today
(scion-kernel `avf/README.md`). Same files for all three hosts:

```sh
python3 $SCION_KERNEL/xnuloader/mkpayload.py --no-version -o payload.bin kernel=kernel.development.vmapple
IMAGE=$SCION_KERNEL/avf/shim/out/Image      # avfboot with the VMAPPLE changes
```

Boot-args: `serial=3 debug=0x8 -v cpus=1 -noprogress` (`-noprogress`: a macOS kernel draws boot
progress by default and asserts without a framebuffer). Keep a leading `-` out of the
parameters on AVF (avf/README.md: crosvm once rejected `-v cpus=8`).

## 1. Pixel 10, AVF (needs the owner's go; nothing is flashed)

```sh
$SCION_KERNEL/avf/run-probe.sh $IMAGE payload.bin -s SERIAL --mem 2048 --params "serial=3 debug=0x8 -v cpus=1 -noprogress"
```

`run-probe.sh` installs the probe app from this repo, grants
`MANAGE_VIRTUAL_MACHINE` and `USE_CUSTOM_VIRTUAL_MACHINE`, sets the hidden-API
exemption, copies the two files into the app's own storage, runs one
non-protected VM for its time limit, pulls the console, and on exit revokes the
grants, removes the exemption and releases `/data/local/tmp/pixel.lock`. It
writes nothing outside the app's storage and `/data/local/tmp`.

What the console tells us, in order:

| Last thing on the console | Meaning |
|---|---|
| nothing from avfboot | the VM did not start (see the probe's `VERDICT`) |
| `avfboot: jumping to XNU at …`, then nothing | XNU died before its console: most likely the 16 KiB granule (MMU on) or the first PAC instruction |
| XNU's version banner and early `kprintf`s | 16 KiB pages and FEAT_PAuth work under pKVM; the run then stops where QEMU does (`SHA1Init` from `PE_init_iokit`, docs/AVF-VMAPPLE.md section 6) or earlier |

The probe app's own result files (`report.txt`, `console.txt`,
`avf-logcat.txt`) also record the crosvm command line virtmgr used.

## 2. Linux arm64 host with KVM (developer machine)

```sh
crosvm run --disable-sandbox --no-pmu --cpus 1 --mem size=2048 \
  --serial type=stdout,hardware=serial,num=1,console=true,earlycon=true \
  --params "serial=3 debug=0x8 -v cpus=1 -noprogress" --initrd payload.bin $IMAGE
```

This is the device set AVF gives a raw-config VM, minus virtio-console and the
other virtio devices virtmgr adds (`android/virtmgr/src/crosvm.rs`). On a
Cortex-A7x/X host crosvm turns on PAuth for the vCPU as long as the host KVM
offers it.

## 3. QEMU virt (any Mac or Linux)

`qemu-vmapple.sh`: TCG with `-cpu max` (FEAT_PAuth, QARMA5 or `pauth-impdef`),
PL011 console instead of the 8250.
