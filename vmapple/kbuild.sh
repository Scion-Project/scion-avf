#!/usr/bin/env bash
# SPDX-License-Identifier: MIT-0
#
# Build kernel.<config>.vmapple from the tree vmapple/setup.sh prepared, with SCION_NATIVE_PAC=1.
#
#   vmapple/kbuild.sh [WORKDIR] [DEVELOPMENT|RELEASE] [extra make args, e.g. -k]
#
# Output: WORKDIR/build/xnu.obj/kernel.<config>.vmapple (and .unstripped). Uses -j4 at nice 10.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(cd "${1:-$HERE/work}" && pwd); CFG=${2:-DEVELOPMENT}; shift $(( $# >= 2 ? 2 : $# ))
export RC_DARWIN_KERNEL_VERSION=${RC_DARWIN_KERNEL_VERSION:-25.5.0}
cd "$W/xnu"
exec nice -n 10 make SDKROOT=macosx ARCH_CONFIGS=ARM64 MACHINE_CONFIGS=VMAPPLE KERNEL_CONFIGS="$CFG" \
	SCION_NATIVE_PAC=1 BUILD_LTO=0 BUILD_WERROR=0 KDKROOT=/nonexistent FAKEROOT_DIR="$W/fakeroot" \
	OBJROOT="$W/build/xnu.obj" SYMROOT="$W/build/xnu.sym" DSTROOT="$W/build/xnu.dst" \
	KERNEL_BUILDS_IN_PARALLEL=1 LOGCOLORS=n -j4 "$@"
