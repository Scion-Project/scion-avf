#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Spike 1 in one command: installs the AVF probe on an adb-connected phone,
# grants what it needs, boots the tiny Linux guest in a non-protected custom
# VM, pulls the results, and puts the phone back the way it was.
#
#   probe/run-on-device.sh [options]
#
#   -s SERIAL            adb serial (optional when exactly one device is attached)
#   --full               the whole questionnaire: base run, all-host-CPUs run, 16 KiB-page
#                        guest kernel, and a guest-RAM sweep up to the first refusal
#   --no-boot            check the gates only, don't start a VM
#   --protected          also try a protected VM (expected to be refused)
#   --match-host-cpus    one vCPU per host CPU instead of one
#   --kernel 4k|16k      guest kernel page size for the single run (default 4k)
#   --mem MIB            guest RAM for the single run (default 256)
#   --mem-sweep LIST     RAM sizes (MiB, comma-separated) for --full's sweep
#                        (default 512,1024,2048,4096,6144,8192,12288,16384)
#   --timeout SEC        per-VM time limit (default 60)
#   --keep-grants        leave the pm grants in place at exit
#   --out DIR            results directory (default probe/results/<timestamp>)
#
# Results land in DIR: summary.json + summary.md (the answers), plus per run
# <tag>-{result.json,report.txt,console.txt,vmlog.txt,logcat-avf.txt}.
# Exit status: 0 = probe ran and the verdict is OK, 1 = ran but a gate failed,
# 2 = bad usage, 3 = no usable device. A failed gate is still a valid result.
#
# Needs: adb, python3 (summary only), a built APK (probe/app: ./gradlew
# assembleDebug) and, unless --no-boot, a built guest (probe/guest/build.sh).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../tools/avf-lib.sh"

APK="$here/app/app/build/outputs/apk/debug/app-debug.apk"
GUEST="$here/guest/out"
OUT="$here/results/$(date +%Y%m%d-%H%M%S)"
SERIAL=""; FULL=0; BOOT=1; PROTECTED=0; MATCH=0; KERNEL=4k; MEM=256; TIMEOUT=60
SWEEP="512,1024,2048,4096,6144,8192,12288,16384"
KEEP_GRANTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) SERIAL="${2:?-s needs a serial}"; shift 2 ;;
    --full) FULL=1; shift ;;
    --no-boot) BOOT=0; shift ;;
    --protected) PROTECTED=1; shift ;;
    --match-host-cpus) MATCH=1; shift ;;
    --kernel) KERNEL="${2:?}"; shift 2 ;;
    --mem) MEM="${2:?}"; shift 2 ;;
    --mem-sweep) SWEEP="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --keep-grants) KEEP_GRANTS=1; shift ;;
    --out) OUT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done
[[ "$KERNEL" == 4k || "$KERNEL" == 16k ]] || die "--kernel must be 4k or 16k" 2

mkdir -p "$OUT"
avf_pick_device "$SERIAL"
avf_setup "$APK"

if [[ $BOOT == 1 ]]; then
  for f in Image initrd.img; do avf_push "$GUEST/$f" guest; done
  if [[ $FULL == 1 || $KERNEL == 16k ]]; then
    [[ -f "$GUEST/Image-16k" ]] && avf_push "$GUEST/Image-16k" guest || die "missing $GUEST/Image-16k (rebuild: probe/guest/build.sh)"
  fi
fi

PARAMS="console=hvc0 earlycon=uart8250,mmio,0x3f8 printk.devkmsg=on panic=-1 rdinit=/init"
runs=()   # tags, in order
# run <tag> [extras...]   (extras are `am start` extras)
run() {
  local tag="$1"; shift
  runs+=("$tag")
  avf_run_one "$tag" "$TIMEOUT" --es params "$PARAMS" "$@" || true
}
kfile() { [[ "$1" == 16k ]] && echo Image-16k || echo Image; }
boot_flag=(); [[ $BOOT == 1 ]] || boot_flag=(--ez boot false)

if [[ $FULL == 0 ]]; then
  extras=(--el mem_mib "$MEM" --es kernel "$(kfile "$KERNEL")" ${boot_flag[@]+"${boot_flag[@]}"})
  [[ $MATCH == 1 ]] && extras+=(--ez match_host_cpus true)
  [[ $PROTECTED == 1 ]] && extras+=(--ez protected true)
  run base "${extras[@]}"
else
  run base --el mem_mib 256 --es kernel Image ${boot_flag[@]+"${boot_flag[@]}"}
  if [[ $BOOT == 1 ]]; then
    run cpus-host --el mem_mib 256 --es kernel Image --ez match_host_cpus true
    run kernel-16k --el mem_mib 256 --es kernel Image-16k
    # RAM sweep: stop at the first size that doesn't reach OK, or that exceeds
    # ~90% of the phone's own RAM (the base run's host.ram_mib).
    ram="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["host"].get("ram_mib",0))' "$OUT/base-result.json" 2>/dev/null || echo 0)"
    IFS=, read -ra sizes <<<"$SWEEP"
    for m in "${sizes[@]}"; do
      if (( ram > 0 && m * 10 > ram * 9 )); then echo "  sweep: stopping before ${m} MiB (host RAM ${ram} MiB)"; break; fi
      run "mem-$m" --el mem_mib "$m" --es kernel Image
      v="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$OUT/mem-$m-result.json" 2>/dev/null || echo NORESULT)"
      [[ "$v" == OK ]] || { echo "  sweep: ${m} MiB -> $v; stopping"; break; }
    done
  fi
  [[ $PROTECTED == 1 ]] && run protected --el mem_mib 256 --ez protected true
fi

echo "== summary"
if command -v python3 >/dev/null; then
  python3 "$here/../tools/avf_summarize.py" probe "$OUT" || echo "(summary failed; raw files are in $OUT)" >&2
else
  echo "python3 not found: no summary.json/md, raw files are in $OUT" >&2
fi
echo "== results in $OUT"

# exit status mirrors the base run's verdict
v="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$OUT/base-result.json" 2>/dev/null || echo NORESULT)"
case "$v" in OK|CHECKS_OK_BOOT_SKIPPED) exit 0 ;; *) echo "base verdict: $v"; exit 1 ;; esac
