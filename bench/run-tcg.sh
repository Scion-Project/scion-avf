#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Runs the benchmark guest under QEMU TCG (software CPU emulation) on THIS
# machine and writes the console to <out>/tcg.txt. Use it to smoke-test the
# guest on a Mac/Linux box; bench/run-on-device.sh does the same on the phone.
#
#   bench/run-tcg.sh [--qemu BIN] [--kernel 4k|16k] [--scale PCT] [--reps N]
#                    [--only int,mem,...] [--cpu MODEL] [--mem MIB]
#                    [--timeout SEC] [--out DIR]
#
# --cpu defaults to cortex-a72 (what pyre's measurements use); the 16k kernel
# needs `max` because a Cortex-A72 has no 16 KiB translation granule, and that
# is picked automatically. Prints the summary table when done.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../tools/avf-lib.sh"   # for avf_timeout (stock macOS has no timeout(1))
QEMU="${QEMU:-qemu-system-aarch64}"; KERNEL=4k; SCALE=100; REPS=3; ONLY=""; CPU=""; MEM=512; TMO=900
OUT="$here/results/$(date +%Y%m%d-%H%M%S)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --qemu) QEMU="${2:?}"; shift 2 ;;
    --kernel) KERNEL="${2:?}"; shift 2 ;;
    --scale) SCALE="${2:?}"; shift 2 ;;
    --reps) REPS="${2:?}"; shift 2 ;;
    --only) ONLY="${2:?}"; shift 2 ;;
    --cpu) CPU="${2:?}"; shift 2 ;;
    --mem) MEM="${2:?}"; shift 2 ;;
    --timeout) TMO="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
command -v "$QEMU" >/dev/null || [[ -x "$QEMU" ]] || { echo "qemu-system-aarch64 not found (--qemu BIN)" >&2; exit 3; }
img="$here/out/Image"; [[ "$KERNEL" == 16k ]] && img="$here/out/Image-16k"
for f in "$img" "$here/out/bench.img"; do [[ -f "$f" ]] || { echo "missing $f: run bench/build.sh" >&2; exit 1; }; done
[[ -n "$CPU" ]] || { [[ "$KERNEL" == 16k ]] && CPU=max || CPU=cortex-a72; }
mkdir -p "$OUT"

append="console=ttyAMA0 nokaslr panic=-1 rdinit=/init bench.scale=$SCALE bench.reps=$REPS bench.label=tcg-$KERNEL"
[[ -z "$ONLY" ]] || append+=" bench.only=$ONLY"
avf_timeout "$TMO" "$QEMU" -M virt,gic-version=3 -cpu "$CPU" -accel tcg -smp 1 -m "$MEM" \
  -display none -monitor none -serial stdio -nic none -no-reboot \
  -kernel "$img" -initrd "$here/out/bench.img" -append "$append" </dev/null | tr -d '\r' > "$OUT/tcg.txt" || true
grep -q '=== AVFBENCH DONE ===' "$OUT/tcg.txt" || { echo "run did not complete; tail of $OUT/tcg.txt:" >&2; tail -15 "$OUT/tcg.txt" >&2; exit 1; }
python3 "$here/../tools/avf_summarize.py" bench "$OUT"
echo "== results in $OUT"
