#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Boot another OS through the display test app: HackiOS's XNU via avfboot, with the Scion shared
# framebuffer (SCFB) as its screen and virtio-input multi-touch, on an adb-connected phone.
#
#   display/run-os.sh --kernel IMAGE --initrd PAYLOAD [--disk FILE]... [--params "..."]
#                     [-s SERIAL] [--mem MIB] [--run S] [--fb WxH] [--tag T] [--shots N] [--out DIR]
#
# HackiOS: --kernel avf/shim/out/Image (avfboot) --initrd payload.bin (xnuloader/mkpayload.py:
# kernel + ramdisk=root.apfs) --disk system.apfs --params "rd=md0 md0=rvblk0 -v" --fb 1125x2436.
# The app adds scfb.addr/size/w/h itself. Files go into the app's internal storage with run-as
# (a disk is streamed with `adb exec-in` and skipped if a file of the same size is already
# there). Screenshots every --shots seconds while it runs. Takes /data/local/tmp/pixel.lock and
# reverts the grants and the hidden-API exemption on exit. Nothing here is Apple's: the images
# are whatever the caller has.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../tools/avf-lib.sh"
AVF_PKG=io.github.dylanneve1.avfdisplay
AVF_DATA="/sdcard/Android/data/$AVF_PKG/files"
AVF_EXEMPT='Landroid/system/virtualmachine/VirtualMachineCustomImageConfig,Landroid/system/virtualmachine/VirtualMachineConfig$Builder;->setCustomImageConfig(,Landroid/system/virtualmachine/VirtualMachine;->send,Landroid/system/virtualmachine/VirtualMachine;->setTouchScale(,Landroid/system/virtualmachine/VirtualizationService;,Landroid/system/virtualizationservice/,Landroid/os/ServiceManager;->checkService('

APK="$here/app/app/build/outputs/apk/debug/app-debug.apk"
OUT="$here/results/$(date +%Y%m%d-%H%M%S)"
SERIAL=""; TAG=os; RUN_S=180; MEM=4096; FB=1125x2436; SHOTS=15; PARAMS=""; KERNEL=""; INITRD=""; DISKS=(); CPUS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) SERIAL="$2"; shift 2 ;;
    --kernel) KERNEL="$2"; shift 2 ;;
    --initrd) INITRD="$2"; shift 2 ;;
    --disk) DISKS+=("$2"); shift 2 ;;
    --params) PARAMS="$2"; shift 2 ;;
    --mem) MEM="$2"; shift 2 ;;
    --run) RUN_S="$2"; shift 2 ;;
    --fb) FB="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --shots) SHOTS="$2"; shift 2 ;;
    --match-host-cpus) CPUS=(--ez match_host_cpus true); shift ;;
    --keep-grants) KEEP_GRANTS=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -f "$KERNEL" && -f "$INITRD" ]] || die "need --kernel and --initrd files" 2
for d in ${DISKS[@]+"${DISKS[@]}"}; do [[ -f "$d" ]] || die "missing disk $d" 2; done
mkdir -p "$OUT"
avf_pick_device "$SERIAL"

LOCK=/data/local/tmp/pixel.lock
until sh_rc mkdir "$LOCK" </dev/null 2>/dev/null; do echo "waiting for $LOCK"; sleep 10; done
release() { avf_teardown; sh_rc rmdir "$LOCK" </dev/null || true; echo "== lock released"; }
trap release EXIT
avf_setup "$APK"
trap release EXIT

put() {  # put <local> <name>: into files/guest/<name>, unless the same size is there already
  local size have
  size=$(wc -c < "$1" | tr -d ' ')
  have=$(sh_ "run-as $AVF_PKG stat -c %s files/guest/$2 2>/dev/null" || true)
  if [[ "$have" == "$size" ]]; then echo "  $2: already there ($size bytes)"; return; fi
  echo "  $2: $size bytes"
  "${ADB[@]}" exec-in "run-as $AVF_PKG sh -c 'cat > files/guest/$2'" < "$1"
  have=$(sh_ "run-as $AVF_PKG stat -c %s files/guest/$2")
  [[ "$have" == "$size" ]] || die "copy of $2 is $have bytes, expected $size"
}
log "guest files (run-as)"
sh_rc "run-as $AVF_PKG mkdir -p files/guest" </dev/null
put "$KERNEL" os-kernel
put "$INITRD" os-initrd
names=()
for d in ${DISKS[@]+"${DISKS[@]}"}; do n="disk-$(basename "$d")"; put "$d" "$n"; names+=("$n"); done
disks=$(IFS=,; echo "${names[*]:-}")

# Screenshots while it runs.
(
  sleep 10
  for k in $(seq 1 $(( (RUN_S + SHOTS - 1) / SHOTS ))); do
    sleep "$SHOTS"
    "${ADB[@]}" exec-out screencap -p </dev/null > "$OUT/$TAG-screen-$(printf %03d $((k * SHOTS))).png" 2>/dev/null || true
  done
) &
shots=$!

w=${FB%x*}; h=${FB#*x}
avf_run_one "$TAG" "$RUN_S" --ez os_mode true --es kernel os-kernel --es initrd os-initrd --es disks "$disks" \
  --es os_params "$PARAMS" --el mem_mib "$MEM" --ei fb_w "$w" --ei fb_h "$h" --ei run_s "$RUN_S" \
  ${CPUS[@]+"${CPUS[@]}"} || true
kill "$shots" 2>/dev/null || true
"${ADB[@]}" exec-out screencap -p </dev/null > "$OUT/$TAG-screen-end.png" 2>/dev/null || true
echo "== results in $OUT"
