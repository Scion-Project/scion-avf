#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Boots the gpu3d probe guest (hackios-xnu-kernel avf/gpu3d/probe, out/Image) in an AVF VM
# that has a virtio-gpu with the gfxstream renderer, and pulls its console.
#
#   gpu3d/run-on-device.sh [-s SERIAL] [--image PATH] [--initrd PATH] [--match-host-cpus]
#                          [--params "gpu3d.size=828x1792"]
#                          [--contexts gfxstream-gles] [--no-gpu] [--vulkan] [--timeout SEC]
#                          [--tag NAME] [--out DIR]
#
# Takes the shared phone lock (/data/local/tmp/pixel.lock), installs the harness app
# (gpu3d/app, its own package: io.github.dylanneve1.gpu3dprobe), grants it the two VM
# permissions, sets the hidden-API exemption for the custom-image config, runs, and restores
# the exemption, revokes the grants and releases the lock on exit. It touches no other app.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
PKG=io.github.dylanneve1.gpu3dprobe
APK="$here/app/app/build/outputs/apk/debug/app-debug.apk"
IMAGE=""; INITRD=""; CPUS=1; PARAMS=""; CONTEXTS="gfxstream-gles"; GPU=true; VULKAN=false; TIMEOUT=90; TAG=run
OUT="$here/results/$(date +%Y%m%d-%H%M%S)"; SERIAL="${ANDROID_SERIAL:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) SERIAL="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --initrd) INITRD="$2"; shift 2 ;;
    --match-host-cpus) CPUS=8; shift ;;
    --params) PARAMS="$2"; shift 2 ;;
    --contexts) CONTEXTS="$2"; shift 2 ;;
    --no-gpu) GPU=false; shift ;;
    --vulkan) VULKAN=true; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[[ -n "$IMAGE" ]] || { echo "--image PATH (the probe's out/Image) is required" >&2; exit 2; }
[[ -f "$APK" ]] || { echo "build the app first: (cd $here/app && ./gradlew assembleDebug)" >&2; exit 2; }
ADB=(adb ${SERIAL:+-s "$SERIAL"})
EXEMPT_KEY=hidden_api_blacklist_exemptions
EXEMPT='Landroid/system/virtualmachine/VirtualMachineCustomImageConfig,Landroid/system/virtualmachine/VirtualMachineConfig$Builder;->setCustomImageConfig('

# wait up to LOCK_WAIT seconds (default 900) for the shared phone lock
lock_deadline=$((SECONDS + ${LOCK_WAIT:-900}))
until "${ADB[@]}" shell 'mkdir /data/local/tmp/pixel.lock' 2>/dev/null; do
  (( SECONDS < lock_deadline )) || { echo "phone is locked by someone else" >&2; exit 3; }
  sleep 5
done
old=$("${ADB[@]}" shell settings get global "$EXEMPT_KEY" | tr -d '\r')
cleanup() {
  if [[ "$old" == "null" || -z "$old" ]]; then "${ADB[@]}" shell settings delete global "$EXEMPT_KEY" >/dev/null || true
  else "${ADB[@]}" shell settings put global "$EXEMPT_KEY" "'$old'" >/dev/null || true; fi
  "${ADB[@]}" shell am force-stop "$PKG" || true
  for p in MANAGE_VIRTUAL_MACHINE USE_CUSTOM_VIRTUAL_MACHINE; do
    "${ADB[@]}" shell pm revoke "$PKG" "android.permission.$p" >/dev/null 2>&1 || true
  done
  "${ADB[@]}" shell 'rmdir /data/local/tmp/pixel.lock' || true
}
trap cleanup EXIT

"${ADB[@]}" install -r -t "$APK" >/dev/null
for p in MANAGE_VIRTUAL_MACHINE USE_CUSTOM_VIRTUAL_MACHINE; do
  "${ADB[@]}" shell pm grant "$PKG" "android.permission.$p"
done
"${ADB[@]}" shell settings put global "$EXEMPT_KEY" "'$EXEMPT'"
ext="/sdcard/Android/data/$PKG/files"
"${ADB[@]}" shell mkdir -p "$ext"
"${ADB[@]}" push "$IMAGE" "$ext/Image" >/dev/null
INITRD_ARGS=()
if [[ -n "$INITRD" ]]; then
  "${ADB[@]}" push "$INITRD" "$ext/initrd" >/dev/null
  INITRD_ARGS=(--es initrd initrd)
fi
"${ADB[@]}" shell rm -f "$ext/$TAG-report.txt" "$ext/$TAG-console.txt"
"${ADB[@]}" logcat -c || true
"${ADB[@]}" shell am force-stop "$PKG"
"${ADB[@]}" shell am start -n "$PKG/.MainActivity" --es kernel Image ${INITRD_ARGS[@]+"${INITRD_ARGS[@]}"} --ei cpus "$CPUS" --es params "'$PARAMS'" \
  --es contexts "$CONTEXTS" --ez gpu "$GPU" --ez vulkan "$VULKAN" --ei timeout "$TIMEOUT" --es tag "$TAG" >/dev/null
deadline=$((SECONDS + TIMEOUT + 30))
until "${ADB[@]}" shell "test -f $ext/$TAG-report.txt" 2>/dev/null; do
  (( SECONDS < deadline )) || { echo "harness did not finish" >&2; break; }
  sleep 2
done
mkdir -p "$OUT"
"${ADB[@]}" pull "$ext/$TAG-report.txt" "$OUT/" >/dev/null 2>&1 || true
"${ADB[@]}" pull "$ext/$TAG-console.txt" "$OUT/" >/dev/null 2>&1 || true
"${ADB[@]}" logcat -d 2>/dev/null | grep -i -E "crosvm|virtmgr|gfxstream|virtualization|gpu3d" > "$OUT/$TAG-logcat.txt" || true
echo "results: $OUT"
cat "$OUT/$TAG-report.txt" 2>/dev/null || true
