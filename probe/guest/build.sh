#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Builds the throwaway Linux guest used by the AVF probe:
#   out/Image       a stock Debian arm64 "cloud" kernel, 4 KiB pages (SHA-256 pinned)
#   out/Image-16k   the stock Debian arm64-16k kernel, 16 KiB pages (SHA-256 pinned)
#   out/initrd.img  our freestanding init (init.c) in a newc initramfs
#
# Nothing here is committed: the kernel is downloaded from Debian at build
# time, and the init is built from source. Needs: clang (any recent Apple or
# LLVM clang, or the NDK's), ld.lld, curl, python3, ar, tar with xz support.
# No toolchain? `tools/docker-build.sh` runs this in a pinned Debian container.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/out}"
mkdir -p "$out"

# ---- kernels --------------------------------------------------------------
# Both Debian 13 flavours (see kernel.sh): 4 KiB pages -> out/Image, 16 KiB
# pages -> out/Image-16k. ONLY=4k skips the 16k download.
. "$here/kernel.sh"
fetch_kernel 4k "$out/kernel-4k"
cp -f "$out/kernel-4k/Image" "$out/Image"
if [[ "${ONLY:-}" != 4k ]]; then
  fetch_kernel 16k "$out/kernel-16k"
  cp -f "$out/kernel-16k/Image" "$out/Image-16k"
fi

# ---- init + initramfs -----------------------------------------------------
CC="${CC:-clang}"
LLD="${LLD:-$(command -v ld.lld || true)}"
[[ -n "$LLD" ]] || { echo "need ld.lld (set LLD=/path/to/ld.lld)" >&2; exit 1; }

"$CC" --target=aarch64-linux-gnu -O2 -Wall -Wextra -ffreestanding -fno-builtin \
  -fno-stack-protector -fno-pic -fno-asynchronous-unwind-tables -mgeneral-regs-only \
  -nostdlib -static -fuse-ld=lld --ld-path="$LLD" -Wl,-e,_start -Wl,--build-id=none \
  -o "$out/init" "$here/init.c"
python3 "$here/mkinitramfs.py" "$out/init" "$out/initrd.img"

echo "kernel:    $out/Image ($(sha256 "$out/Image"))"
[[ ! -f "$out/Image-16k" ]] || echo "kernel16k: $out/Image-16k ($(sha256 "$out/Image-16k"))"
echo "initramfs: $out/initrd.img ($(sha256 "$out/initrd.img"))"
