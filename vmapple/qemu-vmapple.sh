#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Boot a VMAPPLE kernel the way crosvm would, on QEMU virt: avfboot as the "Linux Image", the kernel in
# an XNUP payload as the initrd, FDT in x0, PSCI over hvc, GICv3. TCG with -cpu max,pauth-qarma3=on: FEAT_PAuth with the Pixel 10's algorithm (QARMA3).
#
#   vmapple/qemu-vmapple.sh SCION_KERNEL_CHECKOUT KERNEL [seconds] [extra qemu args...]
#
# SCION_KERNEL_CHECKOUT: a Scion-Project/scion-kernel tree with avf/shim built (avf/shim/build.sh; needs
# the "VMAPPLE" avfboot change, see README) and xnuloader/mkpayload.py. KERNEL: kernel.*.vmapple.
# env: BOOTARGS (default "-v serial=3 debug=0x8 cpus=1"), MEM (2G), SMP (1), CPU (max,pauth-qarma3=on)
set -euo pipefail
SK=$(cd "${1:?scion-kernel checkout}" && pwd); KERNEL=${2:?kernel}; SECS=${3:-120}
shift $(( $# >= 3 ? 3 : $# ))
IMAGE=$SK/avf/shim/out/Image
[ -f "$IMAGE" ] || { echo "build avfboot first: $SK/avf/shim/build.sh" >&2; exit 2; }
PAYLOAD=$(mktemp -t vmapple-payload); trap 'rm -f "$PAYLOAD"' EXIT
python3 "$SK/xnuloader/mkpayload.py" --no-version -o "$PAYLOAD" kernel="$KERNEL"
qemu-system-aarch64 -M virt,gic-version=3,virtualization=off,secure=off \
	-accel tcg,thread=multi -cpu "${CPU:-max,pauth-qarma3=on}" -smp "${SMP:-1}" -m "${MEM:-2G}" \
	-kernel "$IMAGE" -initrd "$PAYLOAD" -append "${BOOTARGS:--v serial=3 debug=0x8 cpus=1}" \
	-nographic -serial stdio -monitor none -no-reboot "$@" &
QPID=$!
( sleep "$SECS"; kill "$QPID" 2>/dev/null ) &
wait "$QPID" || true
