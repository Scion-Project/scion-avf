#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Builds the display/touch test guest:
#   out/Image       the probe's stock Debian 13 cloud kernel (4 KiB pages, SHA-256 pinned)
#   out/initrd.img  scfb-init (init.c) + virtio_input.ko.xz + evdev.ko.xz from the same
#                   Debian package (the cloud kernel builds both as modules)
#
# The cloud kernel has no DRM, which is fine: the guest draws into the shared
# framebuffer (display/SCFB.md) through /dev/mem, not through virtio-gpu.
# Nothing is committed; everything is fetched or built here.
# Needs: clang, ld.lld, curl, python3, ar, tar with xz support.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
probe="$here/../../probe/guest"
out="${1:-$here/out}"
mkdir -p "$out"
. "$probe/kernel.sh"

KVER="${KVER_BASE}+deb13-cloud-arm64"
DEB="linux-image-${KVER}-unsigned_${KVER_BASE}-1_arm64.deb"
DEB_SHA256="88926feba4ab6db49c6ce072f099640cd14512af8b47a1fa2394b8d596f688da"
DEB_SHA1="5fc7cdcba015e86b3c777cb585aaa26b3437d241"

if [[ ! -f "$out/Image" || ! -f "$out/virtio_input.ko.xz" || ! -f "$out/evdev.ko.xz" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  urls=($(_deb_url l/linux "$DEB" "$DEB_SHA1"))
  fetch_deb "$tmp/k.deb" "$DEB_SHA256" "${urls[@]}"
  m="./usr/lib/modules/$KVER/kernel/drivers"
  (cd "$tmp" && _ar x k.deb data.tar.xz &&
    tar xJf data.tar.xz "./boot/vmlinuz-$KVER" "./boot/config-$KVER" \
      "$m/virtio/virtio_input.ko.xz" "$m/input/evdev.ko.xz")
  cp "$tmp/boot/vmlinuz-$KVER" "$out/Image"
  cp "$tmp/boot/config-$KVER" "$out/kernel.config"
  cp "$tmp/$m/virtio/virtio_input.ko.xz" "$tmp/$m/input/evdev.ko.xz" "$out/"
fi

# -mstrict-align: /dev/mem maps the shared region as Device memory (it is not
# System RAM to this kernel), where an unaligned access is an alignment fault.
CC="${CC:-clang}"
LLD="${LLD:-$(command -v ld.lld || true)}"
[[ -n "$LLD" ]] || { echo "need ld.lld (set LLD=/path/to/ld.lld)" >&2; exit 1; }
"$CC" --target=aarch64-linux-gnu -O2 -Wall -Wextra -ffreestanding -fno-builtin \
  -fno-stack-protector -mstrict-align -fno-pic -fno-asynchronous-unwind-tables -mgeneral-regs-only \
  -nostdlib -static -fuse-ld=lld --ld-path="$LLD" -Wl,-e,_start -Wl,--build-id=none \
  -o "$out/init" "$here/init.c"
python3 "$probe/mkinitramfs.py" "$out/init" "$out/initrd.img" \
  --add "/lib/modules/virtio_input.ko.xz=$out/virtio_input.ko.xz:644" \
  --add "/lib/modules/evdev.ko.xz=$out/evdev.ko.xz:644"

echo "kernel:    $out/Image ($(sha256 "$out/Image"))"
echo "initramfs: $out/initrd.img ($(sha256 "$out/initrd.img"))"
