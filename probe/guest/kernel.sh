# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Sourced by probe/guest/build.sh and bench/build.sh. Provides:
#
#   fetch_deb <outfile> <sha256> <url...>   download + verify (tries each URL)
#   fetch_kernel <4k|16k> <outdir>          writes <outdir>/Image (+ kernel.config)
#   fetch_busybox <outdir>                  writes <outdir>/busybox (static arm64)
#   sha256 <file>
#
# Everything is a stock Debian 13 (trixie) arm64 package pinned by SHA-256, so
# the guest is rebuildable bit-for-bit and no binary is ever committed. Both
# kernels are raw arm64 Images with 8250 + OF serial, virtio-pci and
# virtio-console built in (what crosvm and QEMU need), and gzip initramfs.
#   4k   linux-image-*-cloud-arm64   CONFIG_ARM64_4K_PAGES
#   16k  linux-image-*-arm64-16k     CONFIG_ARM64_16K_PAGES
# Needs: curl, ar (binutils or llvm-ar), tar with xz support. Written for bash 3.2+
# (stock macOS): no mapfile, no empty-array expansion under set -u.

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
_ar() { if command -v ar >/dev/null; then ar "$@"; else llvm-ar "$@"; fi; }

fetch_deb() {
  local dest="$1" want="$2"; shift 2
  local u
  for u in "$@"; do
    echo "fetching $u" >&2
    if curl -fsSL --retry 3 --connect-timeout 20 -o "$dest" "$u" && [[ "$(sha256 "$dest")" == "$want" ]]; then
      return 0
    fi
    rm -f "$dest"
  done
  echo "download failed or checksum mismatch for $(basename "$dest")" >&2
  return 1
}

KVER_BASE="6.12.111"
_deb_url() {  # pool-dir file sha1 -> url list (one per line)
  echo "https://deb.debian.org/debian/pool/main/$1/${2//+/%2B}"
  echo "https://snapshot.debian.org/file/$3"
}

fetch_kernel() {
  local flavour="$1" out="$2" kver deb sha256w sha1w
  case "$flavour" in
    4k)
      kver="${KVER_BASE}+deb13-cloud-arm64"
      deb="linux-image-${kver}-unsigned_${KVER_BASE}-1_arm64.deb"
      sha256w="88926feba4ab6db49c6ce072f099640cd14512af8b47a1fa2394b8d596f688da"
      sha1w="5fc7cdcba015e86b3c777cb585aaa26b3437d241" ;;
    16k)
      kver="${KVER_BASE}+deb13-arm64-16k"
      deb="linux-image-${kver}-unsigned_${KVER_BASE}-1_arm64.deb"
      sha256w="d3aa8a4218c4ba2bdcd7465ea5371979f76f3f1b16980d90fe7d0658e06712af"
      sha1w="bd7824b15444b31f7fbe425eb4dd1a3c979b684d" ;;
    *) echo "unknown kernel flavour: $flavour (4k|16k)" >&2; return 2 ;;
  esac
  mkdir -p "$out"
  [[ -f "$out/Image" ]] && return 0
  local tmp; tmp="$(mktemp -d)"
  urls=($(_deb_url l/linux "$deb" "$sha1w"))   # no spaces in URLs; bash 3.2 has no mapfile
  fetch_deb "$tmp/k.deb" "$sha256w" "${urls[@]}" || { rm -rf "$tmp"; return 1; }
  (cd "$tmp" && _ar x k.deb data.tar.xz && tar xJf data.tar.xz "./boot/vmlinuz-$kver" "./boot/config-$kver")
  cp "$tmp/boot/vmlinuz-$kver" "$out/Image"
  cp "$tmp/boot/config-$kver" "$out/kernel.config"
  rm -rf "$tmp"
}

fetch_busybox() {
  local out="$1"
  local deb="busybox-static_1.37.0-6+b9_arm64.deb"
  mkdir -p "$out"
  [[ -f "$out/busybox" ]] && return 0
  local tmp; tmp="$(mktemp -d)"
  urls=($(_deb_url b/busybox "$deb" "6d31276d7d9ae8fd1fd27b9b368bef89e7677d62"))
  fetch_deb "$tmp/b.deb" "c833be48abfa16bc19c4966ec93e289ff1ce5d2f1476cad3a57bd105378cd15c" "${urls[@]}" \
    || { rm -rf "$tmp"; return 1; }
  (cd "$tmp" && _ar x b.deb data.tar.xz && tar xJf data.tar.xz ./usr/bin/busybox)
  cp "$tmp/usr/bin/busybox" "$out/busybox"
  chmod 755 "$out/busybox"
  rm -rf "$tmp"
}
