#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Cross-builds a fully static, TCG-only qemu-system-aarch64 (upstream QEMU
# 10.2.2, the version pyre's measurements use) that runs on a stock Android
# phone from `adb shell` (no root, no Termux, no libs): output is
#   bench/out/qemu-system-aarch64     aarch64-linux, static glibc
#
# It builds inside a digest-pinned debian:trixie container on any x86-64 or
# arm64 Linux/macOS host with Docker (~15-25 min on 4 cores, ~3 GB disk). The
# source tarball is SHA-256 pinned. Only the 'virt' machine, PL011, GICv3 and
# the generic devices needed by bench/ are enabled (--without-default-features).
#
#   bench/qemu/build-static.sh [-j JOBS]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/../out"; mkdir -p "$out"
JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
[[ "${1:-}" == -j ]] && JOBS="${2:?}"
IMAGE='debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad'
QV=10.2.2
QSHA=784b296ff29c1417aa72323abcb2d2ea9ab9771724f577dcd785c3b04f21e176

docker run --rm -v "$out:/out" -e JOBS="$JOBS" -e QV="$QV" -e QSHA="$QSHA" "$IMAGE" bash -euxc '
  export DEBIAN_FRONTEND=noninteractive
  dpkg --add-architecture arm64
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    gcc-aarch64-linux-gnu libc6-dev-arm64-cross make ninja-build pkg-config python3 python3-venv \
    xz-utils curl ca-certificates gcc libc6-dev bzip2 \
    libglib2.0-dev:arm64 libpcre2-dev:arm64 zlib1g-dev:arm64 libpixman-1-dev:arm64 libffi-dev:arm64 libfdt-dev:arm64 \
    libglib2.0-dev-bin libmount-dev:arm64 libselinux1-dev:arm64 libblkid-dev:arm64 >/dev/null
  mkdir /b && cd /b
  curl -fsSLo q.tar.xz https://download.qemu.org/qemu-$QV.tar.xz
  echo "$QSHA  q.tar.xz" | sha256sum -c -
  tar xf q.tar.xz && mkdir build && cd build
  export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig
  ../qemu-$QV/configure --cross-prefix=aarch64-linux-gnu- --static --target-list=aarch64-softmmu \
    --without-default-features --enable-fdt=system --enable-tcg --disable-werror --disable-docs --disable-tools \
    --disable-guest-agent --disable-download --enable-strip
  make -j"$JOBS" qemu-system-aarch64
  aarch64-linux-gnu-strip qemu-system-aarch64
  ls -l qemu-system-aarch64
  cp qemu-system-aarch64 /out/qemu-system-aarch64
  sha256sum /out/qemu-system-aarch64
'
echo "built $out/qemu-system-aarch64"
