#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Builds the throwaway Linux guest used by the AVF probe:
#   out/Image       a stock Debian arm64 "cloud" kernel (pinned by SHA-256)
#   out/initrd.img  our freestanding init (init.c) in a newc initramfs
#
# Nothing here is committed: the kernel is downloaded from Debian at build
# time, and the init is built from source. Needs: clang (any recent Apple or
# LLVM clang, or the NDK's), ld.lld, curl, python3, tar with xz support.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/out}"
mkdir -p "$out"

# ---- kernel ---------------------------------------------------------------
# Debian 13 (trixie) cloud kernel: small, built for VMs, and has the drivers
# crosvm's arm64 platform needs built in (8250 + OF serial, virtio-pci,
# virtio-console, GICv3, PSCI, initramfs). It's a raw arm64 Image, which is
# what crosvm loads.
KVER="6.12.111+deb13-cloud-arm64"
DEB="linux-image-${KVER}-unsigned_6.12.111-1_arm64.deb"
DEB_SHA256="88926feba4ab6db49c6ce072f099640cd14512af8b47a1fa2394b8d596f688da"
DEB_SHA1="5fc7cdcba015e86b3c777cb585aaa26b3437d241"   # for snapshot.debian.org
URLS=(
  "https://deb.debian.org/debian/pool/main/l/linux/${DEB//+/%2B}"
  "https://snapshot.debian.org/file/${DEB_SHA1}"
)

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

if [[ ! -f "$out/Image" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  got=""
  for u in "${URLS[@]}"; do
    echo "fetching $u"
    if curl -fL --retry 3 -C - -o "$tmp/k.deb" "$u" && [[ "$(sha256 "$tmp/k.deb")" == "$DEB_SHA256" ]]; then
      got=1; break
    fi
    rm -f "$tmp/k.deb"
  done
  [[ -n "$got" ]] || { echo "kernel download failed or checksum mismatch" >&2; exit 1; }
  (cd "$tmp" && ar x k.deb data.tar.xz && tar xJf data.tar.xz "./boot/vmlinuz-$KVER" "./boot/config-$KVER")
  cp "$tmp/boot/vmlinuz-$KVER" "$out/Image"
  cp "$tmp/boot/config-$KVER" "$out/kernel.config"
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
echo "initramfs: $out/initrd.img ($(sha256 "$out/initrd.img"))"
