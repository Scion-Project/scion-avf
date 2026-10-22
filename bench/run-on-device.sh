#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Question 2 in one command: how much faster is a guest running natively under
# the phone's hypervisor (AVF/crosvm on pKVM) than the same guest under QEMU
# TCG (software emulation) on the same phone? Runs the same benchmark guest
#   1. natively on the phone (the bench ELF via adb shell)  - the ceiling
#   2. in an AVF custom VM (probe app)                       - pKVM
#   3. under qemu-system-aarch64 TCG (pushed to the phone)   - emulation
# and prints a comparison table.
#
#   bench/run-on-device.sh [options]
#
#   -s SERIAL         adb serial (optional when exactly one device is attached)
#   --qemu BIN        aarch64 Linux qemu-system-aarch64 for the TCG leg
#                     (default bench/out/qemu-system-aarch64 if it exists;
#                     build one with bench/qemu/build-static.sh)
#   --scale PCT       work per workload as % of default (default 100)
#   --reps N          repetitions per workload (default 3)
#   --only LIST       workload subset, e.g. int,sys (default: int,mem,chase,sys,pf)
#   --also-16k        add an AVF run with the 16 KiB-page guest kernel
#   --no-native / --no-avf / --no-tcg   skip a leg
#   --mem MIB         guest RAM for AVF and TCG (default 512)
#   --timeout SEC     per-leg time limit (default 600)
#   --keep-grants     leave the pm grants in place at exit
#   --out DIR         results directory (default bench/results/<timestamp>)
#
# Needs: adb, python3, the APK (probe/app: ./gradlew assembleDebug) and the
# guest (bench/build.sh). Nothing prompts. The phone is restored on exit.
# Exit status: 0 = at least one leg produced numbers, 1 = none did, 2 = usage,
# 3 = no usable device.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../tools/avf-lib.sh"

APK="$here/../probe/app/app/build/outputs/apk/debug/app-debug.apk"
G="$here/out"
OUT="$here/results/$(date +%Y%m%d-%H%M%S)"
SERIAL=""; QEMU=""; SCALE=100; REPS=3; ONLY=""; ALSO16=0; DO_NATIVE=1; DO_AVF=1; DO_TCG=1
MEM=512; TIMEOUT=600; KEEP_GRANTS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) SERIAL="${2:?}"; shift 2 ;;
    --qemu) QEMU="${2:?}"; shift 2 ;;
    --scale) SCALE="${2:?}"; shift 2 ;;
    --reps) REPS="${2:?}"; shift 2 ;;
    --only) ONLY="${2:?}"; shift 2 ;;
    --also-16k) ALSO16=1; shift ;;
    --no-native) DO_NATIVE=0; shift ;;
    --no-avf) DO_AVF=0; shift ;;
    --no-tcg) DO_TCG=0; shift ;;
    --mem) MEM="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --keep-grants) KEEP_GRANTS=1; shift ;;
    --out) OUT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done
[[ -n "$QEMU" ]] || { [[ -x "$G/qemu-system-aarch64" ]] && QEMU="$G/qemu-system-aarch64"; }
for f in bench bench.img Image; do [[ -f "$G/$f" ]] || die "missing $G/$f: run bench/build.sh (or tools/docker-build.sh)"; done
[[ $ALSO16 == 0 || -f "$G/Image-16k" ]] || die "missing $G/Image-16k: run bench/build.sh"
if [[ $DO_TCG == 1 && -z "$QEMU" ]]; then
  echo "note: no qemu-system-aarch64 for the phone (bench/out/qemu-system-aarch64 or --qemu); skipping the TCG leg" >&2
  DO_TCG=0
fi
[[ -z "$QEMU" || -f "$QEMU" ]] || die "--qemu $QEMU: not a file"

mkdir -p "$OUT"
avf_pick_device "$SERIAL"
avf_setup "$APK"

RDIR=/data/local/tmp/avfbench
cleanup_bench() { sh_rc "rm -rf $RDIR" </dev/null >/dev/null 2>&1 || true; }
trap 'cleanup_bench; avf_teardown' EXIT

snapshot() {  # battery + thermal state, to judge throttling afterwards
  { echo "## $1 $(date -Is)"
    sh_ dumpsys battery | grep -E 'level|temperature|status' || true
    sh_ "dumpsys thermalservice 2>/dev/null | grep -E 'Thermal Status|mStatus|Temperature' | head -12" || true
  } >> "$OUT/device-state.txt"
}
snapshot start

args=("--scale=$SCALE" "--reps=$REPS"); [[ -z "$ONLY" ]] || args+=("--only=$ONLY")
cmd_native="" ; cmd_guest="bench.scale=$SCALE bench.reps=$REPS"; [[ -z "$ONLY" ]] || cmd_guest+=" bench.only=$ONLY"
legs_ok=0

# ---- 1. native ------------------------------------------------------------
if [[ $DO_NATIVE == 1 ]]; then
  log "native (bench ELF run directly under adb shell)"
  sh_rc "mkdir -p $RDIR" </dev/null
  "${ADB[@]}" push "$G/bench" "$RDIR/bench" </dev/null >/dev/null
  sh_rc "chmod 755 $RDIR/bench" </dev/null
  if avf_timeout "$TIMEOUT" "${ADB[@]}" shell "cd $RDIR && ./bench ${args[*]} --label=native" </dev/null | tr -d '\r' > "$OUT/native.txt" \
     && grep -q 'AVFBENCH DONE' "$OUT/native.txt"; then legs_ok=$((legs_ok+1)); else echo "  native leg failed; see $OUT/native.txt" >&2; fi
  snapshot after-native
fi

# ---- 2. AVF custom VM -----------------------------------------------------
avf_leg() {  # tag kernelfile
  local tag="$1" kernel="$2"
  avf_push "$G/$kernel" bench; avf_push "$G/bench.img" bench
  avf_run_one "$tag" "$TIMEOUT" --es guest_dir bench --es kernel "$kernel" --es initrd bench.img \
    --el mem_mib "$MEM" \
    --es params "console=hvc0 earlycon=uart8250,mmio,0x3f8 panic=-1 nokaslr rdinit=/init $cmd_guest bench.label=$tag" || true
  if grep -q 'AVFBENCH DONE' "$OUT/$tag-console.txt" 2>/dev/null; then legs_ok=$((legs_ok+1))
  else echo "  AVF leg '$tag' did not complete (verdict in $OUT/$tag-result.json, log in $OUT/$tag-logcat-avf.txt)" >&2; fi
}
if [[ $DO_AVF == 1 ]]; then
  avf_leg avf Image
  snapshot after-avf
  [[ $ALSO16 == 0 ]] || { avf_leg avf16k Image-16k; snapshot after-avf16k; }
fi

# ---- 3. QEMU TCG on the phone ---------------------------------------------
if [[ $DO_TCG == 1 ]]; then
  log "QEMU TCG on the phone ($(basename "$QEMU"))"
  sh_rc "mkdir -p $RDIR" </dev/null
  "${ADB[@]}" push "$QEMU" "$RDIR/qemu-system-aarch64" </dev/null >/dev/null
  "${ADB[@]}" push "$G/Image" "$G/bench.img" "$RDIR/" </dev/null >/dev/null
  sh_rc "chmod 755 $RDIR/qemu-system-aarch64" </dev/null
  tcg() {  # $1 = extra -accel options
    avf_timeout "$TIMEOUT" "${ADB[@]}" shell "cd $RDIR && ./qemu-system-aarch64 -M virt,gic-version=3 -cpu cortex-a72 -accel tcg$1 -smp 1 -m $MEM -display none -monitor none -serial stdio -nic none -no-reboot -kernel Image -initrd bench.img -append 'console=ttyAMA0 nokaslr panic=-1 rdinit=/init $cmd_guest bench.label=tcg' 2>&1" </dev/null | tr -d '\r' > "$OUT/tcg.txt" || true
  }
  tcg ""
  if ! grep -q 'AVFBENCH DONE' "$OUT/tcg.txt"; then
    echo "  first TCG attempt failed (tail below); retrying with split-wx (W^X-safe JIT)" >&2
    tail -5 "$OUT/tcg.txt" >&2
    mv "$OUT/tcg.txt" "$OUT/tcg-attempt1.txt"
    tcg ",split-wx=on"
  fi
  if grep -q 'AVFBENCH DONE' "$OUT/tcg.txt"; then legs_ok=$((legs_ok+1)); else echo "  TCG leg failed; see $OUT/tcg.txt" >&2; fi
  snapshot after-tcg
fi

echo "== summary"
python3 "$here/../tools/avf_summarize.py" bench "$OUT" || echo "(no numbers to summarise)" >&2
echo "== results in $OUT"
(( legs_ok > 0 )) || exit 1
