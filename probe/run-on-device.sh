#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Installs the AVF probe on an adb-connected device, grants what it needs,
# runs it once, collects the results, and reverts the global hidden-API
# exemption afterwards.
#
#   probe/run-on-device.sh [-s SERIAL] [--no-boot] [--protected] [--match-host-cpus]
#                          [--mem MIB] [--timeout SEC] [--keep-grants] [--out DIR]
#
# Needs: adb, a built APK (probe/app: ./gradlew assembleDebug) and, unless
# --no-boot, a built guest (probe/guest/build.sh).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
PKG=io.github.dylanneve1.avfprobe
APK="$here/app/app/build/outputs/apk/debug/app-debug.apk"
GUEST="$here/guest/out"
OUT="$here/results/$(date +%Y%m%d-%H%M%S)"
ADB=(adb)
EXTRAS=()
BOOT=1
KEEP_GRANTS=0
TIMEOUT=60

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) ADB=(adb -s "$2"); shift 2 ;;
    --no-boot) BOOT=0; EXTRAS+=(--ez boot false); shift ;;
    --protected) EXTRAS+=(--ez protected true); shift ;;
    --match-host-cpus) EXTRAS+=(--ez match_host_cpus true); shift ;;
    --mem) EXTRAS+=(--el mem_mib "$2"); shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --keep-grants) KEEP_GRANTS=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
EXTRAS+=(--el timeout_s "$TIMEOUT")

# Minimum hidden-API exemption: the @hide custom-image builder, and the one
# @hide setter that attaches it to a VirtualMachineConfig. Each entry is a
# prefix of a dex member signature; entries are separated by ','.
# (Verified on the Android 16 emulator: ':' doesn't work, ',' does.)
EXEMPT='Landroid/system/virtualmachine/VirtualMachineCustomImageConfig$Builder;,Landroid/system/virtualmachine/VirtualMachineConfig$Builder;->setCustomImageConfig('

sh_() { "${ADB[@]}" shell "$@"; }

[[ -f "$APK" ]] || { echo "build the app first: (cd $here/app && ./gradlew assembleDebug)" >&2; exit 1; }
mkdir -p "$OUT"

echo "== device"
sh_ getprop ro.product.model
sh_ getprop ro.build.fingerprint

echo "== install + grants"
"${ADB[@]}" install -r -g "$APK" >/dev/null
sh_ pm grant "$PKG" android.permission.MANAGE_VIRTUAL_MACHINE
sh_ pm grant "$PKG" android.permission.USE_CUSTOM_VIRTUAL_MACHINE

echo "== hidden-API exemption (global, reverted at exit)"
prev="$(sh_ settings get global hidden_api_blacklist_exemptions | tr -d '\r')"
restore() {
  if [[ "$prev" == "null" || -z "$prev" ]]; then
    sh_ settings delete global hidden_api_blacklist_exemptions >/dev/null
  else
    sh_ settings put global hidden_api_blacklist_exemptions "'$prev'"
  fi
  echo "== hidden_api_blacklist_exemptions restored to: $prev"
  if [[ $KEEP_GRANTS == 0 ]]; then
    sh_ pm revoke "$PKG" android.permission.MANAGE_VIRTUAL_MACHINE || true
    sh_ pm revoke "$PKG" android.permission.USE_CUSTOM_VIRTUAL_MACHINE || true
    echo "== grants revoked (use --keep-grants to keep them)"
  fi
}
trap restore EXIT
[[ "$prev" == "null" || -z "$prev" ]] || echo "note: an exemption list was already set: $prev"
sh_ settings put global hidden_api_blacklist_exemptions "'$EXEMPT'"

DATA="/sdcard/Android/data/$PKG/files"
sh_ mkdir -p "$DATA/guest"
sh_ rm -f "$DATA/report.txt" "$DATA/console.txt" "$DATA/vmlog.txt"
if [[ $BOOT == 1 ]]; then
  [[ -f "$GUEST/Image" && -f "$GUEST/initrd.img" ]] || { echo "build the guest first: $here/guest/build.sh" >&2; exit 1; }
  echo "== pushing guest"
  "${ADB[@]}" push "$GUEST/Image" "$GUEST/initrd.img" "$DATA/guest/" >/dev/null
fi

echo "== running probe"
sh_ am force-stop "$PKG"   # new process so it picks up the exemption
"${ADB[@]}" logcat -c || true
sh_ am start -W -n "$PKG/.MainActivity" --ez autorun true "${EXTRAS[@]}" >/dev/null

deadline=$(( $(date +%s) + TIMEOUT + 60 ))
until sh_ grep -q '^VERDICT:' "$DATA/report.txt" 2>/dev/null; do
  (( $(date +%s) < deadline )) || { echo "probe didn't finish in time" >&2; break; }
  sleep 2
done

for f in report.txt console.txt vmlog.txt; do
  "${ADB[@]}" pull "$DATA/$f" "$OUT/$f" >/dev/null 2>&1 || true
done
"${ADB[@]}" logcat -d > "$OUT/logcat.txt" || true
# virtmgr logs the full crosvm command line; keep the AVF-related lines.
grep -iE 'virtmgr|virtualizationservice|crosvm|AvfProbe|hiddenapi|avc:.*(crosvm|virt)' \
  "$OUT/logcat.txt" > "$OUT/logcat-avf.txt" || true

echo "== results in $OUT"
grep '^VERDICT:' "$OUT/report.txt" 2>/dev/null || echo "no verdict (see $OUT/logcat-avf.txt)"
