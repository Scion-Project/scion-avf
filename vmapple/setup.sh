#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prepare an open-source xnu-12377 VMAPPLE kernel build on a Mac, without Apple's Kernel Debug Kit.
#
#   vmapple/setup.sh [WORKDIR]        (default: vmapple/work)
#
# Fetches Apple's open-source releases by tag (xnu, AvailabilityVersions, libdispatch, libplatform,
# and the TrustCache headers of xnu-8796.101.5, the last release that shipped them), builds the fake
# SDK root they need (availability.pl, xnu's exported headers, libfirehose_kernel.a), makes the
# build-system edits of buildfix.sh and applies Scion's patches. Needs Xcode (macOS 26+ SDK) and
# Homebrew cmake + ninja. Nothing of Apple's is stored in this repository.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mkdir -p "${1:-$HERE/work}" && cd "${1:-$HERE/work}" && pwd)
S=$W/src FR=$W/fakeroot B=$W/build XNU=$W/xnu
mkdir -p "$S" "$FR" "$B"
export RC_DARWIN_KERNEL_VERSION=${RC_DARWIN_KERNEL_VERSION:-25.5.0}   # xnu-12377.121.6 = macOS 26.5
export SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
step() { echo "== $(date +%T) $*"; }

fetch() {   # fetch PROJECT TAG
	[ -d "$S/$1-$2" ] || curl -fsSL "https://github.com/apple-oss-distributions/$1/archive/refs/tags/$2.tar.gz" | tar -xz -C "$S"
}
fetch xnu xnu-12377.121.6
fetch AvailabilityVersions AvailabilityVersions-157.2
fetch libdispatch libdispatch-1542.100.32
fetch libplatform libplatform-375.120.2
[ -d "$S/xnu-xnu-8796.101.5" ] || curl -fsSL https://github.com/apple-oss-distributions/xnu/archive/refs/tags/xnu-8796.101.5.tar.gz |
	tar -xz -C "$S" xnu-xnu-8796.101.5/EXTERNAL_HEADERS/TrustCache

if [ ! -f "$FR/usr/local/libexec/availability.pl" ]; then
	step AvailabilityVersions
	make -C "$S/AvailabilityVersions-AvailabilityVersions-157.2" install CMAKE="$(command -v cmake)" NINJA="$(command -v ninja)" \
		DSTROOT="$FR" OBJROOT="$B/av" SYMROOT="$B/av"
fi

if [ ! -d "$XNU/.git" ]; then
	step "xnu working tree"
	rm -rf "$XNU"; cp -R "$S/xnu-xnu-12377.121.6" "$XNU"
	git -C "$XNU" init -q; git -C "$XNU" add -A; git -C "$XNU" -c user.name=base -c user.email=base@localhost commit -qm xnu-12377.121.6
	"$HERE/buildfix.sh" "$XNU" "$FR" "$S/xnu-xnu-8796.101.5/EXTERNAL_HEADERS/TrustCache"
	for p in "$HERE"/patches/*.patch; do step "patch $(basename "$p")"; git -C "$XNU" apply "$p"; done
fi

if [ ! -f "$FR/.xnu-headers" ]; then
	step "xnu installhdrs"
	(cd "$XNU" && make installhdrs SDKROOT=macosx ARCH_CONFIGS=ARM64 OBJROOT="$B/hdrs.obj" SYMROOT="$B/hdrs.sym" DSTROOT="$FR" \
		FAKEROOT_DIR="$FR" KERNEL_BUILDS_IN_PARALLEL=1 -j4)
	touch "$FR/.xnu-headers"
fi

if [ ! -f "$FR/usr/local/include/_simple.h" ]; then
	step "libplatform headers"
	ditto "$S/libplatform-libplatform-375.120.2/include" "$FR/usr/local/include"
	ditto "$S/libplatform-libplatform-375.120.2/private" "$FR/usr/local/include"
fi

if [ ! -f "$FR/usr/local/lib/kernel/libfirehose_kernel.a" ]; then
	step libfirehose_kernel
	D=$B/libdispatch; rm -rf "$D"; cp -R "$S/libdispatch-libdispatch-1542.100.32" "$D"
	sed -i '' 's|$(SDKROOT)/System/Library/Frameworks/Kernel.framework/PrivateHeaders|$(FAKEROOT_DIR)/System/Library/Frameworks/Kernel.framework/PrivateHeaders|g; s|$(SDKROOT)/usr/local/include|$(FAKEROOT_DIR)/usr/local/include|g' \
		"$D/xcodeconfig/libfirehose_kernel.xcconfig"
	(cd "$D" && xcodebuild install -target libfirehose_kernel -sdk macosx ARCHS=arm64e VALID_ARCHS=arm64e \
		OBJROOT="$B/fh.obj" SYMROOT="$B/fh.sym" DSTROOT="$FR" FAKEROOT_DIR="$FR" -jobs 4)
	mv -f "$FR/usr/local/lib/kernel/liblibfirehose_kernel.a" "$FR/usr/local/lib/kernel/libfirehose_kernel.a" 2>/dev/null || true
fi
step "ready: vmapple/kbuild.sh $W"
