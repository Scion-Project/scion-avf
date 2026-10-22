#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# THE one command for when the Pixel is plugged in: builds whatever is missing,
# then answers both questions that decide whether an AVF backend is worth
# building.
#   1. What does a sideloaded custom VM get?   probe/run-on-device.sh --full
#   2. Native-under-pKVM vs QEMU TCG?          bench/run-on-device.sh --also-16k
#
#   tools/run-all.sh [-s SERIAL] [--no-build] [--no-qemu-build] [--quick] [--out DIR]
#
#   --no-build        fail instead of building missing artifacts
#   --no-qemu-build   don't build the static QEMU (the TCG leg is then skipped
#                     unless bench/out/qemu-system-aarch64 already exists)
#   --quick           probe: single run only (no RAM sweep / CPU / 16K runs);
#                     bench: --scale 25 --reps 2
#
# Results: <DIR>/probe/summary.{md,json}, <DIR>/bench/summary.{md,json} plus raw
# logs (default DIR: results/<timestamp>; gitignored). See docs/AVF-BENCH.md.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
SERIAL=(); BUILD=1; QBUILD=1; QUICK=0; OUT="$repo/results/$(date +%Y%m%d-%H%M%S)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) SERIAL=(-s "${2:?}"); shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --no-qemu-build) QBUILD=0; shift ;;
    --quick) QUICK=1; shift ;;
    --out) OUT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
cd "$repo"
APK=probe/app/app/build/outputs/apk/debug/app-debug.apk

need_guest=0
for f in probe/guest/out/Image probe/guest/out/Image-16k probe/guest/out/initrd.img bench/out/Image bench/out/Image-16k bench/out/bench.img bench/out/bench; do
  [[ -f $f ]] || need_guest=1
done
if [[ $need_guest == 1 ]]; then
  [[ $BUILD == 1 ]] || { echo "guest images missing (run tools/docker-build.sh)" >&2; exit 1; }
  echo "== building guest images"
  if command -v clang >/dev/null && command -v ld.lld >/dev/null; then
    probe/guest/build.sh && bench/build.sh
  else
    tools/docker-build.sh
  fi
fi
if [[ ! -f $APK ]]; then
  [[ $BUILD == 1 ]] || { echo "APK missing (cd probe/app && ./gradlew assembleDebug)" >&2; exit 1; }
  echo "== building the probe app"
  (cd probe/app && ./gradlew --no-daemon -q assembleDebug)
fi
if [[ ! -f bench/out/qemu-system-aarch64 && $QBUILD == 1 && $BUILD == 1 ]]; then
  if command -v docker >/dev/null; then
    echo "== building static QEMU for the phone (about 20 min, once)"
    bench/qemu/build-static.sh || echo "warning: QEMU build failed; the TCG leg will be skipped" >&2
  else
    echo "warning: no docker, so no static QEMU: the TCG leg will be skipped (see docs/AVF-BENCH.md)" >&2
  fi
fi

mkdir -p "$OUT"
rc=0
echo; echo "######## 1/2: what does a custom VM get? (spike 1)"
if [[ $QUICK == 1 ]]; then p_args=(); else p_args=(--full); fi
# ${a[@]+"${a[@]}"}: expands an empty array under set -u even on bash 3.2 (stock macOS)
probe/run-on-device.sh ${SERIAL[@]+"${SERIAL[@]}"} ${p_args[@]+"${p_args[@]}"} --out "$OUT/probe" || rc=$?
echo; echo "######## 2/2: pKVM vs TCG"
if [[ $QUICK == 1 ]]; then b_args=(--scale 25 --reps 2); else b_args=(--also-16k); fi
bench/run-on-device.sh ${SERIAL[@]+"${SERIAL[@]}"} ${b_args[@]+"${b_args[@]}"} --out "$OUT/bench" || rc=$?
echo; echo "== all results in $OUT   (summary.md in probe/ and bench/)"
exit $rc
