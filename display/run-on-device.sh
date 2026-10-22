#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Display/touch test on an adb-connected phone: installs display/app, grants
# the two AVF development permissions, sets the hidden-API exemption, streams
# the guest into the app's internal storage, runs one VM, takes a screenshot,
# drives a few real touches through `input swipe`, pulls the results, and puts
# the phone back the way it was (exemption restored, grants revoked).
#
#   display/run-on-device.sh [-s SERIAL] [--tag T] [--stock-display] [--gpu-backend B]
#                            [--mem MIB] [--bench S] [--run S] [--taps N] [--shm auto|ashmem|sharedmemory]
#                            [--fmt xb24|xr24] [--scale-div N] [--keep-grants] [--out DIR]
#
# Takes the shared-device lock /data/local/tmp/pixel.lock for the whole run.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../tools/avf-lib.sh"
AVF_PKG=io.github.dylanneve1.avfdisplay
AVF_DATA="/sdcard/Android/data/$AVF_PKG/files"
# Spike 1's two prefixes widened to the whole custom-image config tree, plus
# the members display/touch needs (docs/DISPLAY-INPUT.md, section 5).
AVF_EXEMPT='Landroid/system/virtualmachine/VirtualMachineCustomImageConfig,Landroid/system/virtualmachine/VirtualMachineConfig$Builder;->setCustomImageConfig(,Landroid/system/virtualmachine/VirtualMachine;->send,Landroid/system/virtualmachine/VirtualMachine;->setTouchScale(,Landroid/system/virtualmachine/VirtualizationService;,Landroid/system/virtualizationservice/,Landroid/os/ServiceManager;->checkService('

APK="$here/app/app/build/outputs/apk/debug/app-debug.apk"
GUEST="$here/guest/out"
OUT="$here/results/$(date +%Y%m%d-%H%M%S)"
SERIAL=""; TAG=display; RUN_S=40; EXTRAS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) SERIAL="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --stock-display) EXTRAS+=(--ez stock_display true); shift ;;   # DisplayConfig + useTouch (fails on DP11)
    --gpu-backend) EXTRAS+=(--es gpu_backend "$2"); shift 2 ;;
    --mem) EXTRAS+=(--el mem_mib "$2"); shift 2 ;;
    --bench) EXTRAS+=(--ei bench_s "$2"); shift 2 ;;
    --run) RUN_S="$2"; shift 2 ;;
    --taps) EXTRAS+=(--ei taps "$2"); shift 2 ;;
    --shm) EXTRAS+=(--es shm "$2"); shift 2 ;;
    --fmt) EXTRAS+=(--es fmt "$2"); shift 2 ;;
    --scale-div) EXTRAS+=(--ei scale_div "$2"); shift 2 ;;
    --keep-grants) KEEP_GRANTS=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
EXTRAS+=(--ei run_s "$RUN_S")
[[ -f "$GUEST/Image" && -f "$GUEST/initrd.img" ]] || die "build the guest first: display/guest/build.sh"
mkdir -p "$OUT"
avf_pick_device "$SERIAL"

LOCK=/data/local/tmp/pixel.lock
until sh_rc mkdir "$LOCK" </dev/null 2>/dev/null; do echo "waiting for $LOCK"; sleep 10; done
release() { avf_teardown; sh_rc rmdir "$LOCK" </dev/null || true; echo "== lock released"; }
trap release EXIT
avf_setup "$APK"      # (re)sets its own EXIT trap; put ours back
trap release EXIT

log "can the app's SELinux domain look up virtualizationservice? (the stock display hand-off needs it)"
sh_ "run-as $AVF_PKG service check android.system.virtualizationservice" | tee "$OUT/$TAG-service-check.txt" || true
log "streaming guest into files/guest (run-as)"
sh_rc "run-as $AVF_PKG mkdir -p files/guest" </dev/null
for f in Image initrd.img; do
  "${ADB[@]}" push "$GUEST/$f" "/data/local/tmp/avfdisplay-$f" </dev/null >/dev/null
  sh_rc "cat /data/local/tmp/avfdisplay-$f | run-as $AVF_PKG sh -c 'cat > files/guest/$f'" </dev/null
  sh_rc rm -f "/data/local/tmp/avfdisplay-$f" </dev/null
done

# While the run is in its interactive window: a screenshot, then real touches.
(
  sleep 8   # past avf_run_one's logcat -c
  for _ in $(seq 1 120); do
    "${ADB[@]}" logcat -d -s AvfDisplay </dev/null 2>/dev/null | grep -q "interactive for" && break
    sleep 1
  done
  sleep 1
  "${ADB[@]}" exec-out screencap -p </dev/null > "$OUT/$TAG-screen.png" 2>/dev/null || true
  for k in 1 2 3 4 5; do
    sh_rc input swipe $((200 + k * 100)) 800 $((300 + k * 100)) 1600 300 </dev/null || true
    sleep 0.5
  done
  sh_rc input tap 540 1200 </dev/null || true
  sleep 1
  "${ADB[@]}" exec-out screencap -p </dev/null > "$OUT/$TAG-screen-touch.png" 2>/dev/null || true
) &
helper=$!

avf_run_one "$TAG" $((RUN_S + 60)) "${EXTRAS[@]}" || true
wait "$helper" 2>/dev/null || true
# avf_run_one keeps only virtmgr/crosvm lines; also keep ours and servicemanager's SELinux denials.
"${ADB[@]}" logcat -d </dev/null 2>/dev/null | grep -E 'AvfDisplay|virtualization_service|crosvm|virtmgr|hiddenapi' > "$OUT/$TAG-logcat-display.txt" || true
echo "== results in $OUT"
