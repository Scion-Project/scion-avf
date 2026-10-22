#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Builds the benchmark guest. Nothing built here is committed.
#   out/Image         stock Debian 13 arm64 "cloud" kernel, 4 KiB pages   (pinned SHA-256)
#   out/Image-16k     stock Debian 13 arm64-16k kernel, 16 KiB pages      (pinned SHA-256)
#   out/bench         bench.c as a static aarch64 ELF (also runs natively, e.g. via adb shell)
#   out/bench.img     gzip newc initramfs: /init = bench, /bin/busybox = Debian busybox-static
#
# Toolchain (documented in docs/AVF-BENCH.md): clang >= 14 with lld, curl,
# python3, ar, tar+xz. `tools/docker-build.sh` runs this inside a pinned Debian
# image if you have none of that. The build is deterministic for a given toolchain: same inputs ->
# same bench.img. Kernel and busybox are SHA-256-pinned; the compiler version
# (printed at the end) is not, so hashes of bench/init may differ across clangs.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/out}"
mkdir -p "$out"
. "$here/../probe/guest/kernel.sh"

fetch_kernel 4k "$out/kernel-4k"
cp -f "$out/kernel-4k/Image" "$out/Image"
if [[ "${ONLY:-}" != 4k ]]; then
  fetch_kernel 16k "$out/kernel-16k"
  cp -f "$out/kernel-16k/Image" "$out/Image-16k"
fi
fetch_busybox "$out"

CC="${CC:-clang}"
LLD="${LLD:-$(command -v ld.lld || command -v ld.lld-18 || true)}"
[[ -n "$LLD" ]] || { echo "need ld.lld (set LLD=/path/to/ld.lld)" >&2; exit 1; }

# -O2 and the generic armv8-a target so the same binary runs on a Cortex-A72
# (QEMU TCG), a Tensor core (pKVM guest or adb shell) and anything else.
"$CC" --target=aarch64-linux-gnu -march=armv8-a -O2 -Wall -Wextra -ffreestanding -fno-builtin \
  -fno-stack-protector -fno-pic -fno-asynchronous-unwind-tables \
  -nostdlib -static -fuse-ld=lld --ld-path="$LLD" -Wl,-e,_start -Wl,--build-id=none \
  -o "$out/bench" "$here/bench.c"
python3 "$here/../probe/guest/mkinitramfs.py" "$out/bench" "$out/bench.img" \
  --add "/bin/busybox=$out/busybox"

echo "compiler:  $("$CC" --version | head -1)"
echo "kernel:    $out/Image ($(sha256 "$out/Image"))"
[[ ! -f "$out/Image-16k" ]] || echo "kernel16k: $out/Image-16k ($(sha256 "$out/Image-16k"))"
echo "bench:     $out/bench ($(sha256 "$out/bench"), $(wc -c <"$out/bench") bytes)"
echo "initramfs: $out/bench.img ($(sha256 "$out/bench.img"), $(wc -c <"$out/bench.img") bytes)"
